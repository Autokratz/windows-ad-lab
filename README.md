# windows-ad-lab

**A Windows Server domain built entirely from scripts, validated by an automated health check, and then deliberately broken three times to prove it can be diagnosed.**

Meridian Logistics is a fictional freight company with 32 staff across five departments and three sites. Everything below — the forest, DNS, DHCP, the OU tree, the users, the group model, the policies, the delegation — is created by the numbered scripts in `provision/`. There is no click-through in this build, and no screenshot of a wizard anywhere in this repository.

```
corp.meridian.internal          forest root, Server 2022 functional level
├── DC01   10.20.0.10           AD DS · DNS · DHCP · file shares
└── WS01   DHCP                 Windows 11 domain member
```

---

## Why it is built this way

Most Active Directory labs demonstrate that a domain *can* be stood up. That is not a difficult claim and it is not worth much, because the wizard does the work.

Three things here are meant to be worth something instead:

**1. It is reproducible.** Every script is idempotent and safe to re-run. Tear the VM down, run the five provisioning scripts, and you have a byte-for-byte equivalent domain. Infrastructure that exists only as a sequence of remembered clicks cannot be rebuilt under pressure, and the person who built it is the single point of failure.

**2. It validates itself.** `validate/Test-DomainHealth.ps1` answers 27 questions about the domain with PASS, WARN or FAIL, and exits non-zero on any failure. It exists because the failures that cost the most time are the silent ones — a missing reverse zone, an unauthorised DHCP server, a SYSVOL share that never came back after a reboot. None of those announce themselves. They surface days later as *"Group Policy isn't applying"*, by which point nobody connects it to the change that caused it.

**3. It breaks on purpose.** `faults/Invoke-FaultInjection.ps1` injects three real faults and repairs them. Each was chosen because the symptom the user reports points nowhere near the cause.

---

## The three faults

| Fault | What the user says | What it actually is |
|---|---|---|
| `GpoNotApplying` | "my desktop settings disappeared" | Security filtering replaced, so **Authenticated Users can no longer read the GPO**. The link is still there and GPMC looks completely normal. `gpresult /r` shows it as *Denied (Inaccessible)*. |
| `AccountLockout` | "it keeps locking me out and I'm not even logged in" | A **stale credential retrying in the background**. The lockout is recorded on the PDC emulator, but event 4740 names the source workstation — which is where the answer is. Resetting the password fixes nothing; it locks again within the hour. |
| `DnsMisconfig` | "nobody at the site can log in" | The DC's own resolver was pointed at a **public DNS server**, usually while someone was "fixing" internet access. SRV records stop resolving, clients cannot locate a DC, and the console still browses the web perfectly. |

Each fault records what it changed to `evidence/fault-state.json`, so `-Repair` restores the previous value instead of guessing at a default.

The diagnosis walkthrough for each is in **[docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md)** — symptom, the commands that narrow it down, the evidence at each step, and the fix.

---

## Design decisions worth defending

**The domain is `.internal`, not `.local`.** `.local` is reserved for multicast DNS (RFC 6762) and collides with Bonjour and Avahi on mixed networks. `.internal` is reserved for private use, which is what this is. Renaming a forest root afterwards is close to impossible, so this is a decision you make once.

**Default containers are redirected.** `CN=Computers` and `CN=Users` are containers, not OUs, and **Group Policy cannot be linked to a container**. A machine joined by a technician in a hurry lands there and silently receives no policy at all. `redircmp` and `redirusr` repoint the defaults at real OUs.

**Group model follows AGDLP.** Global groups hold people, domain local groups hold permissions, and the global nests into the domain local. It looks like ceremony on day one. It is the reason a permission change in year two means editing one group instead of auditing every folder on the file server.

**Helpdesk delegation is two rights, not a role.** Password reset normally requires Account Operators or Domain Admins, so the usual shortcut hands Tier 1 the ability to edit any object in the directory. `dsacls` grants exactly *Reset Password*, *write pwdLastSet* and *write lockoutTime*, on the staff subtree only. That is the entire job and nothing else.

**Every account gets its own random initial password.** A single shared `Welcome123` across an import is the most common way a lab habit becomes a production incident. Generated credentials are written to a handover CSV that is gitignored — real initial passwords do not belong in a repository.

**Drive mapping is a logon script, not Group Policy Preferences.** GPP drive maps live in XML inside SYSVOL with no first-class PowerShell cmdlet. Generating that XML by hand would be the most brittle part of this build. A logon script is plainer, version-controlled and readable by whoever comes next.

**A fine-grained password policy covers IT and Finance.** A 14-character minimum is correct for an account that can change the directory. It is the wrong answer for a forklift operator typing into a shared scanning terminal wearing gloves, and a policy people cannot comply with gets written on a sticky note.

---

## Build order

Full VM setup, including the hypervisor, is in **[docs/LAB-BUILD.md](docs/LAB-BUILD.md)**.

```powershell
# On the server that will become DC01, elevated:
.\provision\01-Install-Forest.ps1        # static IP, AD DS + DNS, forest. Reboots.
.\provision\02-Configure-DnsDhcp.ps1     # forwarders, reverse zone, authorised DHCP scope
.\provision\03-Build-OuStructure.ps1     # OU tree, security groups, AGDLP nesting, redircmp
.\provision\04-Import-Users.ps1 -WhatIf  # dry run first
.\provision\04-Import-Users.ps1          # 32 accounts from data/staff.csv
.\provision\05-Set-GpoBaseline.ps1       # GPOs, fine-grained policy, helpdesk delegation

.\validate\Test-DomainHealth.ps1         # 27 checks (24 with -Quick), exits 1 on any failure
.\validate\Get-LabEvidence.ps1           # capture raw state into evidence/
```

Then break it:

```powershell
.\faults\Invoke-FaultInjection.ps1 -Fault GpoNotApplying -Inject
# ... diagnose it, following docs/TROUBLESHOOTING.md
.\faults\Invoke-FaultInjection.ps1 -Fault GpoNotApplying -Repair
```

---

## Repository layout

```
provision/    numbered build scripts, each idempotent
validate/     Test-DomainHealth.ps1 (27 checks) and Get-LabEvidence.ps1
faults/       fault injection and repair
scripts/      Map-DepartmentDrives.ps1, deployed to NETLOGON
data/         staff.csv, the 32-person import source
docs/         LAB-BUILD.md, RUNBOOK.md, TROUBLESHOOTING.md
evidence/     raw captured output, committed after the first run
```

`docs/RUNBOOK.md` is the ten tasks a Level 1 service desk actually performs — password reset, account unlock, group membership, mapped drive repair, GPO not applying, stale computer account, DHCP exhaustion — each with the exact command and the verification step that proves it worked.

---

## Status

The scripts are written and the design decisions above are the substance of the work. **The captured evidence in `evidence/` is committed after the first full run**, and every figure quoted in this README will point at a file in that directory, exactly as the [network lab](https://github.com/Autokratz/network-qos-lab) does.

Numbers are not published here before they are measured.

---

## Stack

Windows Server 2022 · Active Directory Domain Services · DNS · DHCP · Group Policy · PowerShell 5.1 · dsacls · KVM/QEMU

Built by [Hector Cabra](https://autokratz.github.io) alongside an Advanced Diploma of Networking Engineering.
