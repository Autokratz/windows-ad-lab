<#
.SYNOPSIS
    Create the baseline GPOs, a fine-grained password policy, and delegate
    password-reset rights to the Tier 1 helpdesk group.

.DESCRIPTION
    Step 5 of the Meridian Logistics lab build.

    The delegation at the end is the part that matters most for a service desk.
    Out of the box, resetting a user's password requires Account Operators or
    Domain Admins - so the usual shortcut is to put the helpdesk in one of
    those, which hands Tier 1 the ability to edit any object in the directory.
    dsacls grants exactly two rights on exactly one subtree instead: reset
    password, and write lockoutTime and pwdLastSet. That is the whole job, and
    nothing else.

    Drive mapping is delivered by a logon script rather than Group Policy
    Preferences. GPP drive maps live in XML inside SYSVOL and have no
    first-class PowerShell cmdlet; generating that XML by hand is brittle and
    would be the least reliable part of this build. A logon script is plainer,
    version-controlled, and easy for the next person to read.

    Idempotent.
#>

[CmdletBinding()]
param(
    [string] $DomainDN   = (Get-ADDomain).DistinguishedName,
    [string] $DomainName = (Get-ADDomain).DNSRoot,
    [string] $FileServer = 'DC01'   # passed to the logon script below
)

$ErrorActionPreference = 'Stop'
Import-Module GroupPolicy

function Write-Step { param($m) Write-Host "`n== $m" -ForegroundColor Cyan }
function Write-Ok   { param($m) Write-Host "   OK    $m" -ForegroundColor Green }
function Write-Skip { param($m) Write-Host "   SKIP  $m" -ForegroundColor DarkGray }

function Get-OrNewGpo {
    param([string] $Name, [string] $Comment)
    $gpo = Get-GPO -Name $Name -ErrorAction SilentlyContinue
    if ($gpo) { Write-Skip "GPO $Name exists"; return $gpo }
    $gpo = New-GPO -Name $Name -Comment $Comment
    Write-Ok "GPO $Name created"
    return $gpo
}

function Set-GpoLink {
    param([string] $Name, [string] $Target)
    $existing = (Get-GPInheritance -Target $Target).GpoLinks | Where-Object DisplayName -eq $Name
    if ($existing) { Write-Skip "link $Name -> $Target" }
    else {
        New-GPLink -Name $Name -Target $Target -LinkEnabled Yes | Out-Null
        Write-Ok "link $Name -> $Target"
    }
}

$ouUsers      = "OU=Users,OU=Meridian,$DomainDN"
$ouWorkstn    = "OU=Workstations,OU=Computers,OU=Meridian,$DomainDN"
$ouTerminals  = "OU=WarehouseTerminals,OU=Computers,OU=Meridian,$DomainDN"

# ------------------------------------------------------------------------
Write-Step 'GPO: workstation security baseline'

$g = Get-OrNewGpo -Name 'MERIDIAN - Workstation Baseline' `
                  -Comment 'Screen lock, SMB hardening, no removable autorun'

# Lock the screen after 10 minutes idle.
#
# The screen-saver trio (ScreenSaveTimeOut / ScreenSaverIsSecure /
# ScreenSaveActive) is User Configuration and lives under HKCU. Written under
# HKLM they are inert, and this GPO is linked to computer OUs. The machine
# inactivity limit is the computer-side control that actually applies here.
Set-GPRegistryValue -Name $g.DisplayName `
    -Key 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' `
    -ValueName 'InactivityTimeoutSecs' -Type DWord -Value 600 | Out-Null

# Turn off autorun on every drive type. Still one of the cheapest controls
# against a USB dropped in a warehouse car park.
Set-GPRegistryValue -Name $g.DisplayName `
    -Key 'HKLM\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer' `
    -ValueName 'NoDriveTypeAutoRun' -Type DWord -Value 255 | Out-Null

# Require SMB signing, so a machine on the warehouse floor cannot be relayed.
Set-GPRegistryValue -Name $g.DisplayName `
    -Key 'HKLM\System\CurrentControlSet\Services\LanmanWorkstation\Parameters' `
    -ValueName 'RequireSecuritySignature' -Type DWord -Value 1 | Out-Null

Write-Ok 'screen lock 600s, autorun disabled, SMB signing required'
Set-GpoLink -Name $g.DisplayName -Target $ouWorkstn
Set-GpoLink -Name $g.DisplayName -Target $ouTerminals

# ------------------------------------------------------------------------
Write-Step 'GPO: warehouse terminal lockdown'

$k = Get-OrNewGpo -Name 'MERIDIAN - Warehouse Terminal Lockdown' `
                  -Comment 'Restricted desktop for shared scanning terminals'

foreach ($v in @(
    @{ n = 'NoControlPanel';        v = 1 }
    @{ n = 'NoRun';                 v = 1 }
    @{ n = 'NoManageMyComputerVerb';v = 1 }
    @{ n = 'DisableCMD';            v = 2 }   # 2 = block cmd, still allow scripts
)) {
    Set-GPRegistryValue -Name $k.DisplayName `
        -Key 'HKCU\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer' `
        -ValueName $v.n -Type DWord -Value $v.v | Out-Null
}
Write-Ok 'control panel, Run, cmd and computer management hidden'

# Apply to the terminals OU, but only for members of the kiosk group, so an
# IT technician signing in to the same terminal keeps a full desktop.
# Every setting above is User Configuration, but this GPO is linked to a
# COMPUTER OU, and user policy is chosen by where the USER object lives. Staff
# accounts sit under OU=Users, so without loopback none of this applies to
# anybody and the security filtering below filters a policy that never runs.
# Merge mode keeps the user's own policy and layers the terminal's on top.
Set-GPRegistryValue -Name $k.DisplayName `
    -Key 'HKLM\Software\Policies\Microsoft\Windows\System' `
    -ValueName 'UserPolicyMode' -Type DWord -Value 1 | Out-Null
Write-Ok 'loopback processing enabled (merge), so user settings apply per terminal'

Set-GpoLink -Name $k.DisplayName -Target $ouTerminals
# Loopback is resolved by the computer, so the terminal accounts need Read.
Set-GPPermission -Name $k.DisplayName -TargetName 'Domain Computers' `
                 -TargetType Group -PermissionLevel GpoRead | Out-Null
Set-GPPermission -Name $k.DisplayName -TargetName 'Authenticated Users' `
                 -TargetType Group -PermissionLevel GpoRead -Replace | Out-Null
Set-GPPermission -Name $k.DisplayName -TargetName 'SEC-KIOSK-LOCKDOWN' `
                 -TargetType Group -PermissionLevel GpoApply | Out-Null
Write-Ok 'security filtered to SEC-KIOSK-LOCKDOWN'

# ------------------------------------------------------------------------
Write-Step 'GPO: drive mapping logon script'

$m = Get-OrNewGpo -Name 'MERIDIAN - Drive Mapping' -Comment 'Department share mapping at logon'

$scriptSource = Join-Path $PSScriptRoot '..\scripts\Map-DepartmentDrives.ps1'
if (-not (Test-Path $scriptSource)) {
    throw "Map-DepartmentDrives.ps1 not found at $scriptSource"
}

# Logon scripts are delivered by the Scripts client-side extension, which reads
# scripts.ini from the GPO's own User\Scripts folder in SYSVOL. Writing the
# Scripts key through Set-GPRegistryValue puts it under an unmanaged path, so
# it tattoos (it survives the GPO being unlinked) and the Scripts extension
# rewrites it from scripts.ini anyway.
$gpoPath = "\\$DomainName\SYSVOL\$DomainName\Policies\{$($m.Id)}\User\Scripts"
$logonDir = Join-Path $gpoPath 'Logon'
New-Item -ItemType Directory -Path $logonDir -Force | Out-Null
Copy-Item $scriptSource -Destination $logonDir -Force

@'
[Logon]
0CmdLine=Map-DepartmentDrives.ps1
0Parameters=
'@ | Set-Content -Path (Join-Path $gpoPath 'scripts.ini') -Encoding ASCII

# IsPowershell tells gpscript to invoke it as PowerShell rather than treat it
# as a legacy script, and the extension GUIDs tell the client this GPO has
# user-side scripts to process at all.
Set-Content -Path (Join-Path $gpoPath 'psscripts.ini') -Encoding Unicode -Value @'
[Logon]
0CmdLine=Map-DepartmentDrives.ps1
0Parameters=
[ScriptsConfig]
StartExecutePSFirst=true
'@

$gpoDn = "CN={$($m.Id)},CN=Policies,CN=System,$DomainDN"
Set-ADObject -Identity $gpoDn -Replace @{
    gPCUserExtensionNames = '[{42B5FAAE-6536-11D2-AE5A-0000F87571E3}{40B6664F-4972-11D1-A7CA-0000F87571E3}]'
} -ErrorAction Stop
Write-Ok 'logon script registered through scripts.ini and gPCUserExtensionNames'

Set-GpoLink -Name $m.DisplayName -Target $ouUsers

# ------------------------------------------------------------------------
Write-Step 'Fine-grained password policy for privileged accounts'

# The default domain policy governs everyone. A fine-grained policy lets the
# IT and Finance groups carry a stricter rule without imposing a 14-character
# minimum on a forklift operator typing into a scanning terminal with gloves on.
$fgppName = 'PSO-Privileged'
if (Get-ADFineGrainedPasswordPolicy -Filter "Name -eq '$fgppName'" -ErrorAction SilentlyContinue) {
    Write-Skip "$fgppName exists"
} else {
    New-ADFineGrainedPasswordPolicy `
        -Name $fgppName `
        -Precedence 10 `
        -MinPasswordLength 14 `
        -PasswordHistoryCount 24 `
        -ComplexityEnabled $true `
        -LockoutThreshold 5 `
        -LockoutDuration '00:15:00' `
        -LockoutObservationWindow '00:15:00' `
        -MaxPasswordAge '90.00:00:00' `
        -MinPasswordAge '1.00:00:00' `
        -Description 'Stricter policy for IT and Finance staff'
    Write-Ok "$fgppName created (14 char min, 5 attempt lockout)"
}

foreach ($grp in 'SEC-IT', 'SEC-FINANCE') {
    $subjects = (Get-ADFineGrainedPasswordPolicySubject -Identity $fgppName -ErrorAction SilentlyContinue).Name
    if ($subjects -contains $grp) { Write-Skip "$grp already subject to $fgppName" }
    else {
        Add-ADFineGrainedPasswordPolicySubject -Identity $fgppName -Subjects $grp
        Write-Ok "$grp -> $fgppName"
    }
}

# ------------------------------------------------------------------------
Write-Step 'Delegating password reset to Tier 1 helpdesk'

# Least privilege, explicitly. Reset password + write the two attributes an
# unlock actually touches, on the staff subtree only. No Account Operators,
# no Domain Admins.
$targetOu = $ouUsers

# The NetBIOS name comes from the directory. Hardcoding MERIDIAN meant running
# 01-Install-Forest.ps1 with any other -NetbiosName silently delegated to a
# principal that does not exist, while still reporting the control as applied.
$netbios = (Get-ADDomain).NetBIOSName
$principal = "$netbios\SEC-HELPDESK-TIER1"

# dsacls is a native executable: a non-zero exit does not raise under
# $ErrorActionPreference = 'Stop', and | Out-Null throws the reason away.
foreach ($right in @(
    'CA;Reset Password;user'
    'WP;pwdLastSet;user'
    'WP;lockoutTime;user'
)) {
    $output = & dsacls.exe $targetOu /I:S /G "${principal}:$right" 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "dsacls failed granting '$right' to ${principal}: $output"
    }
}
Write-Ok "$principal may reset passwords and unlock accounts under OU=Users"

Write-Host "`nBaseline policy complete. Run validate\Test-DomainHealth.ps1 next.`n" -ForegroundColor Cyan
