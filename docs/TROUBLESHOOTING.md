# Fault diagnosis walkthroughs

Three faults, each worked the way it would be worked on a real desk: start from what the user said, narrow by layer, confirm with evidence, then fix.

The point of each is the same — **the symptom points nowhere near the cause**, and the obvious check comes back clean.

---

## Fault 1 — "My desktop settings disappeared"

```powershell
.\faults\Invoke-FaultInjection.ps1 -Fault GpoNotApplying -Inject
```

### What the user reports

The screen no longer locks itself. A warehouse supervisor noticed because a terminal was left open on the floor overnight. Nothing was changed on their machine.

### Narrowing it

**Is the policy reaching the machine at all?**

```powershell
gpupdate /force
gpresult /r /scope:computer
```

The baseline GPO appears under **Denied**, with the reason `Inaccessible`.

That word is the whole answer, and it is easy to read past. *Inaccessible* does not mean the GPO is missing, unlinked, or empty. It means the computer account **cannot read the GPO object** — so it cannot evaluate it, and reports it as denied.

**Confirm the link is actually fine**, because the instinct is to blame the link:

```powershell
(Get-GPInheritance -Target 'OU=Workstations,OU=Computers,OU=Meridian,DC=corp,DC=meridian,DC=internal').GpoLinks
```

The link is present and enabled. GPMC shows nothing wrong. This is why the fault is worth practising.

**Check who can read it:**

```powershell
Get-GPPermission -Name 'MERIDIAN - Workstation Baseline' -All
```

`Authenticated Users` is absent. Somebody replaced security filtering with a specific group and, in doing so, removed the Read permission that every computer in scope needs in order to evaluate the policy at all.

### Why it happens

Since MS16-072, Group Policy is retrieved in the **computer's** security context, not the user's. Filtering a user-targeted GPO to a group of users — without leaving `Authenticated Users` with Read — breaks it for everyone, because the computer doing the fetching is not in that group.

The correct pattern is the one in `05-Set-GpoBaseline.ps1`: leave `Authenticated Users` with **Read**, and grant **Apply** to the target group only.

### Fix

```powershell
.\faults\Invoke-FaultInjection.ps1 -Fault GpoNotApplying -Repair
# then on the client:
gpupdate /force ; gpresult /r /scope:computer
```

---

## Fault 2 — "It keeps locking me out and I'm not even logged in"

```powershell
.\faults\Invoke-FaultInjection.ps1 -Fault AccountLockout -Inject
```

### What the user reports

Fatima in IT is locked out three times a day. It happens while she is in meetings. Her password was reset yesterday and it made no difference.

### The wrong move

Unlock the account and move on. It locks again within the hour, the ticket reopens, and now the user has no confidence in the desk.

**The reset making no difference is the diagnostic clue, not a dead end.** If a password reset does not stop repeated lockouts, the attempts are not coming from the user typing.

### Narrowing it

**Confirm the lockout:**

```powershell
Search-ADAccount -LockedOut | Select Name, SamAccountName, LastLogonDate
```

**Find where the attempts originate.** Lockouts are always recorded on the PDC emulator regardless of which DC processed the attempt:

```powershell
Get-WinEvent -ComputerName (Get-ADDomain).PDCEmulator `
    -FilterHashtable @{ LogName = 'Security'; Id = 4740 } -MaxEvents 10 |
    Select-Object TimeCreated,
                  @{n='User';   e={$_.Properties[0].Value}},
                  @{n='Source'; e={$_.Properties[1].Value}}
```

Event **4740** names the **caller computer name**. That is the machine holding the stale credential.

For the failed attempts themselves, event **4625** on that source machine carries the logon type, which narrows it further:

| Logon type | Usually means |
|---|---|
| 2 | Someone physically typing at the console |
| 3 | Network — a mapped drive or a share |
| 4 | Batch — a scheduled task |
| 5 | Service — a service configured to run as the user |

### The usual culprits

A mapped drive with saved credentials, a scheduled task running as the user, a service account whose password was rotated in one place but not the other, a phone with a stale Exchange password, or an RDP session left disconnected on another machine.

### Fix

Clear the stale credential at the source, **then** unlock:

```powershell
# on the source machine
cmdkey /list
cmdkey /delete:TERMSRV/dc01

.\faults\Invoke-FaultInjection.ps1 -Fault AccountLockout -Repair
```

Unlocking first is the mistake. Find the source, clear it, then unlock — otherwise you are treating the symptom on a fifteen-minute loop.

---

## Fault 3 — "Nobody at the site can log in"

```powershell
.\faults\Invoke-FaultInjection.ps1 -Fault DnsMisconfig -Inject
```

### What the user reports

Melbourne staff cannot sign in. Sydney is fine. Someone mentions the server was "worked on" yesterday.

### Narrowing it

**Is the DC up?** Yes. It responds, the console works, it browses the internet perfectly. This is the part that misleads people — outbound browsing works precisely *because* of the misconfiguration.

**Can a client locate a domain controller?** Domain logon depends on SRV records, not on general connectivity:

```powershell
Resolve-DnsName -Name '_ldap._tcp.dc._msdcs.corp.meridian.internal' -Type SRV
```

This fails. Clients cannot find a DC, so they cannot authenticate.

**Check what the DC itself is resolving against:**

```powershell
Get-DnsClientServerAddress -AddressFamily IPv4
```

`8.8.8.8`. A domain controller pointed at a public resolver cannot see its own zone, so it cannot confirm or maintain its SRV registrations.

**Confirm with the purpose-built test:**

```powershell
dcdiag /test:dns /v
ipconfig /registerdns
```

### Why it happens

Almost always while someone is "fixing internet access" on the server. Public DNS resolves external names perfectly, which makes the change look successful, and the damage only becomes visible when a client next needs to locate a DC.

A domain controller must resolve against itself — or another DC in the same forest. Public resolvers belong in the DNS server's **forwarders**, which is exactly where `02-Configure-DnsDhcp.ps1` puts them, and never on the DC's own client resolver.

### Fix

```powershell
.\faults\Invoke-FaultInjection.ps1 -Fault DnsMisconfig -Repair

ipconfig /flushdns
ipconfig /registerdns
Resolve-DnsName -Name '_ldap._tcp.dc._msdcs.corp.meridian.internal' -Type SRV
```

---

## The pattern across all three

| | Obvious check | What it showed | Where the answer was |
|---|---|---|---|
| GPO | Is it linked? | Linked and enabled | Read permission on the GPO object |
| Lockout | Is it locked? | Locked; reset changed nothing | Event 4740 caller computer |
| DNS | Is the DC up? | Up, browsing fine | The DC's own client resolver |

In each case the first check came back clean, and the instinct after a clean first check is to conclude nothing is wrong and escalate. The habit worth building is the opposite one: **a clean obvious check narrows the problem, it does not close it.**
