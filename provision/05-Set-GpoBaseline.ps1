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
    [string] $FileServer = 'DC01'
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

# Lock the screen after 10 minutes idle, and require the password on resume.
Set-GPRegistryValue -Name $g.DisplayName `
    -Key 'HKLM\Software\Policies\Microsoft\Windows\Control Panel\Desktop' `
    -ValueName 'ScreenSaveTimeOut' -Type String -Value '600' | Out-Null
Set-GPRegistryValue -Name $g.DisplayName `
    -Key 'HKLM\Software\Policies\Microsoft\Windows\Control Panel\Desktop' `
    -ValueName 'ScreenSaverIsSecure' -Type String -Value '1' | Out-Null
Set-GPRegistryValue -Name $g.DisplayName `
    -Key 'HKLM\Software\Policies\Microsoft\Windows\Control Panel\Desktop' `
    -ValueName 'ScreenSaveActive' -Type String -Value '1' | Out-Null

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
Set-GpoLink -Name $k.DisplayName -Target $ouTerminals
Set-GPPermission -Name $k.DisplayName -TargetName 'Authenticated Users' `
                 -TargetType Group -PermissionLevel GpoRead -Replace | Out-Null
Set-GPPermission -Name $k.DisplayName -TargetName 'SEC-KIOSK-LOCKDOWN' `
                 -TargetType Group -PermissionLevel GpoApply | Out-Null
Write-Ok 'security filtered to SEC-KIOSK-LOCKDOWN'

# ------------------------------------------------------------------------
Write-Step 'GPO: drive mapping logon script'

$m = Get-OrNewGpo -Name 'MERIDIAN - Drive Mapping' -Comment 'Department share mapping at logon'

$sysvolScripts = "\\$DomainName\SYSVOL\$DomainName\scripts"
$scriptSource  = Join-Path $PSScriptRoot '..\scripts\Map-DepartmentDrives.ps1'
if (Test-Path $scriptSource) {
    Copy-Item $scriptSource -Destination $sysvolScripts -Force
    Write-Ok "Map-DepartmentDrives.ps1 copied to NETLOGON"
}

Set-GPRegistryValue -Name $m.DisplayName `
    -Key 'HKCU\Software\Microsoft\Windows\CurrentVersion\Group Policy\Scripts\Logon\0\0' `
    -ValueName 'Script' -Type String `
    -Value "$sysvolScripts\Map-DepartmentDrives.ps1" | Out-Null
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
& dsacls.exe $targetOu /I:S /G 'MERIDIAN\SEC-HELPDESK-TIER1:CA;Reset Password;user'      | Out-Null
& dsacls.exe $targetOu /I:S /G 'MERIDIAN\SEC-HELPDESK-TIER1:WP;pwdLastSet;user'          | Out-Null
& dsacls.exe $targetOu /I:S /G 'MERIDIAN\SEC-HELPDESK-TIER1:WP;lockoutTime;user'         | Out-Null
Write-Ok 'SEC-HELPDESK-TIER1 may reset passwords and unlock accounts under OU=Users'

Write-Host "`nBaseline policy complete. Run validate\Test-DomainHealth.ps1 next.`n" -ForegroundColor Cyan
