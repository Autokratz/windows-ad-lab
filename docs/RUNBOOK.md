# Service desk runbook

The ten tasks a Level 1 desk performs most often, each with the exact command, the verification step that proves it worked, and the mistake that makes the ticket come back.

Every procedure here was run against the lab domain. Where a GUI path exists it is noted, but the command is given first — it is faster, it is auditable, and it is the only version that can be handed to someone else unchanged.

---

## 1. Reset a password

```powershell
Set-ADAccountPassword -Identity fnasser -Reset `
    -NewPassword (Read-Host 'New password' -AsSecureString)

Set-ADUser -Identity fnasser -ChangePasswordAtLogon $true
```

**Verify:** `Get-ADUser fnasser -Properties PasswordLastSet | Select PasswordLastSet`

**The mistake:** forgetting `-ChangePasswordAtLogon`. The temporary password you read out over the phone stays valid indefinitely, and you now share a credential with the user.

**Identity check first.** Never reset on the strength of a caller knowing a name and a department — that is the entire premise of a helpdesk social engineering call. Verify against something the directory holds that a stranger would not: employee ID, manager's name, or a callback to the number on the account.

---

## 2. Unlock an account

```powershell
Search-ADAccount -LockedOut | Select Name, SamAccountName, LastLogonDate
Unlock-ADAccount -Identity fnasser
```

**The mistake that guarantees a repeat ticket:** unlocking before finding the cause. If a stale credential is retrying in the background, the account locks again within the hour and the user calls back angrier.

Find the source first:

```powershell
Get-WinEvent -ComputerName (Get-ADDomain).PDCEmulator `
    -FilterHashtable @{ LogName = 'Security'; Id = 4740 } -MaxEvents 10 |
    Select-Object TimeCreated, @{n='User';e={$_.Properties[0].Value}},
                                @{n='Source';e={$_.Properties[1].Value}}
```

Event 4740 names the **caller computer**. That machine holds the stale credential — a mapped drive, a scheduled task, a service running as the user, or a phone with a saved Exchange password. Lockouts are always recorded on the PDC emulator regardless of which DC processed the attempt.

---

## 3. Add or remove group membership

```powershell
Add-ADGroupMember    -Identity SEC-VPN-USERS -Members fnasser
Remove-ADGroupMember -Identity SEC-VPN-USERS -Members fnasser -Confirm:$false

Get-ADPrincipalGroupMembership fnasser | Select Name | Sort Name
```

**Verify:** the user must sign out and back in. Group membership is written into the Kerberos ticket at logon; an existing session keeps the old token and will keep being denied, which reads to the user as "you didn't actually do it".

**The mistake:** adding people directly to a resource group. People go in global `SEC-<DEPT>` groups, permissions go on domain local `SEC-SHARE-*` groups, and the global nests into the domain local. Break that and the permission model stops being reviewable.

---

## 4. Repair a mapped drive

```powershell
Get-PSDrive -PSProvider FileSystem | Where DisplayRoot
Get-Content $env:TEMP\drive-mapping.log -Tail 20
```

Work it in this order — the answer is usually found before the last step:

1. Is the share reachable at all? `Test-Path \\DC01\Finance`
2. Is the user in the group that the map is conditional on? `Get-ADPrincipalGroupMembership`
3. Did they gain that group **since** their last logon? Sign out and in.
4. Is the map stale — pointing at a decommissioned server? The log names the old target.
5. Is it a permission problem rather than a mapping problem? A drive that maps but shows empty is NTFS, not the script.

**The mistake:** re-running the logon script while the stale drive still exists. `New-PSDrive` on a letter already in use fails silently in some contexts; the mapping script removes the stale map first for exactly this reason.

---

## 5. Group Policy is not applying

```powershell
gpupdate /force
gpresult /r /scope:computer
gpresult /h C:\temp\gpo.html ; start C:\temp\gpo.html
```

Read the report for the policy under **Denied**, and read the reason given:

| Reason shown | What it means |
|---|---|
| *Inaccessible* | The user or computer cannot **read** the GPO — security filtering was changed. The link still looks fine in GPMC. |
| *Empty* | The relevant half (user or computer) of the GPO has no settings. |
| *Disabled Link* | Linked, but the link is switched off. |
| *Filtered (WMI)* | A WMI filter evaluated false on this machine. |

Server side:

```powershell
Get-GPPermission -Name 'MERIDIAN - Workstation Baseline' -All
(Get-GPInheritance -Target 'OU=Workstations,OU=Computers,OU=Meridian,DC=corp,DC=meridian,DC=internal').GpoLinks
```

**The one people miss:** a GPO needs **Read** for Authenticated Users to be evaluated at all. Replacing security filtering with a specific group without also leaving Read in place silently disables the policy for everyone, and nothing in the link view indicates it.

---

## 6. Join a workstation to the domain

```powershell
Add-Computer -DomainName corp.meridian.internal `
             -OUPath 'OU=Workstations,OU=Computers,OU=Meridian,DC=corp,DC=meridian,DC=internal' `
             -Credential (Get-Credential) -Restart
```

**Always pass `-OUPath`.** Without it the object lands in whatever `redircmp` points at — and on a domain where that was never set, it lands in `CN=Computers`, where **no Group Policy can reach it**. The machine works, appears healthy, and is unmanaged.

**Verify:** `nltest /sc_verify:corp.meridian.internal` and confirm the object is in the intended OU.

---

## 7. Fix a broken secure channel

Symptom: *"The trust relationship between this workstation and the primary domain failed."*

```powershell
Test-ComputerSecureChannel -Verbose
Test-ComputerSecureChannel -Repair -Credential (Get-Credential)
```

**Do not rejoin the domain to fix this.** Removing and re-adding destroys the computer object's SID, which orphans anything tied to it — BitLocker recovery keys escrowed in AD among them. `-Repair` resets the password on the existing object and preserves it. Rejoining is a last resort, not a first move.

---

## 8. Find and clean stale computer accounts

```powershell
$cutoff = (Get-Date).AddDays(-90)
Search-ADAccount -ComputersOnly -AccountInactive -TimeSpan 90.00:00:00 |
    Select Name, LastLogonDate, DistinguishedName | Sort LastLogonDate
```

Disable before deleting, and leave them disabled for a full cycle:

```powershell
Search-ADAccount -ComputersOnly -AccountInactive -TimeSpan 90.00:00:00 |
    Disable-ADAccount
```

**The mistake:** deleting straight away. A laptop belonging to someone on three months of parental leave looks identical to a decommissioned machine in this query. Disabling is reversible in seconds; deleting means a rejoin and a lost BitLocker key.

---

## 9. DHCP: user has no address

```powershell
Get-DhcpServerv4ScopeStatistics -ScopeId 10.20.0.0
Get-DhcpServerv4Lease -ScopeId 10.20.0.0 | Measure-Object
Get-DhcpServerInDC
```

Check in this order:

1. **Is the scope exhausted?** `PercentageInUse` near 100 with a short lease duration usually means transient devices, not growth.
2. **Is the server still authorised?** An unauthorised DHCP server leases nothing and logs almost nothing. This is the one that wastes an afternoon.
3. **Is the client actually on the right VLAN**, and does that segment have a relay?
4. Client side: `ipconfig /release` then `/renew`. A `169.254.x.x` address means no server was reached at all — that is a network path problem, not a DHCP configuration problem.

---

## 10. Confirm the domain is healthy before escalating

```powershell
.\validate\Test-DomainHealth.ps1
dcdiag /c /v
repadmin /showrepl
w32tm /query /source
```

Run this **before** escalating to Tier 2, and attach the output to the ticket. Half of what gets escalated as an application fault is a domain fault with a local symptom, and the twenty seconds this takes is what separates a useful handover from a bounced ticket.

**Time is the one to check first on anything Kerberos-shaped.** Authentication fails once clock skew passes five minutes, and the error it produces never mentions the clock.

---

## Escalation

Escalate to Tier 2 when: replication is failing, a FSMO role holder is unreachable, SYSVOL is not replicating, or a change affects more than one site.

Include in the handover: what the user reported in their words, what you have already checked, the exact error text, the affected accounts and machines, and the output from task 10. A ticket without those four things comes straight back.
