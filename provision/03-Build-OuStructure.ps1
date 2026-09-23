<#
.SYNOPSIS
    Build the OU tree, department security groups, and redirect the default
    computer and user containers.

.DESCRIPTION
    Step 3 of the Meridian Logistics lab build.

    Two details here are the ones that separate a working domain from a tidy one:

    1. CN=Computers and CN=Users are *containers*, not OUs, and Group Policy
       cannot be linked to a container. Anything that joins the domain without
       being told otherwise lands in CN=Computers and silently receives no
       policy. redircmp/redirusr repoint those defaults at real OUs so a
       machine joined by a helpdesk technician in a hurry is still governed.

    2. Every OU is created with -ProtectedFromAccidentalDeletion. A single
       mis-aimed delete on an OU takes every object beneath it, and the
       restore is a authoritative-restore exercise nobody wants to run at
       four in the afternoon.

    Idempotent.
#>

[CmdletBinding()]
param(
    [string] $DomainDN = (Get-ADDomain).DistinguishedName
)

$ErrorActionPreference = 'Stop'

function Write-Step { param($m) Write-Host "`n== $m" -ForegroundColor Cyan }
function Write-Ok   { param($m) Write-Host "   OK    $m" -ForegroundColor Green }
function Write-Skip { param($m) Write-Host "   SKIP  $m" -ForegroundColor DarkGray }

function New-LabOU {
    param([string] $Name, [string] $Path)
    $dn = "OU=$Name,$Path"
    if (Get-ADOrganizationalUnit -Filter "DistinguishedName -eq '$dn'" -ErrorAction SilentlyContinue) {
        Write-Skip $dn
    } else {
        New-ADOrganizationalUnit -Name $Name -Path $Path -ProtectedFromAccidentalDeletion $true
        Write-Ok $dn
    }
    return $dn
}

# --- tree ---------------------------------------------------------------
Write-Step 'Organisational units'

$root = New-LabOU -Name 'Meridian' -Path $DomainDN

$ouUsers    = New-LabOU -Name 'Users'           -Path $root
$ouComputer = New-LabOU -Name 'Computers'       -Path $root
$ouGroups   = New-LabOU -Name 'Groups'          -Path $root
$ouSvc      = New-LabOU -Name 'ServiceAccounts' -Path $root

$departments = 'Operations', 'Warehouse', 'Finance', 'IT', 'Drivers'
foreach ($d in $departments) { New-LabOU -Name $d -Path $ouUsers | Out-Null }

'Workstations', 'WarehouseTerminals', 'Laptops' |
    ForEach-Object { New-LabOU -Name $_ -Path $ouComputer | Out-Null }

# --- default container redirection --------------------------------------
Write-Step 'Redirecting default containers'
# redircmp/redirusr are the supported way to change where unqualified joins
# and creations land. They are one-shot and safe to re-run.
& redircmp.exe "OU=Workstations,$ouComputer" | Out-Null
Write-Ok "new computers -> OU=Workstations,$ouComputer"
& redirusr.exe $ouUsers | Out-Null
Write-Ok "new users -> $ouUsers"

# --- security groups ----------------------------------------------------
Write-Step 'Department security groups'

foreach ($d in $departments) {
    $name = "SEC-$($d.ToUpper())"
    if (Get-ADGroup -Filter "Name -eq '$name'" -ErrorAction SilentlyContinue) {
        Write-Skip $name
    } else {
        New-ADGroup -Name $name `
                    -SamAccountName $name `
                    -GroupCategory Security `
                    -GroupScope Global `
                    -Path $ouGroups `
                    -Description "All staff in $d"
        Write-Ok $name
    }
}

Write-Step 'Role and access groups'

$roleGroups = @(
    @{ Name = 'SEC-SHARE-FINANCE-RW';  Scope = 'DomainLocal'; Desc = 'Read/write to the Finance share' }
    @{ Name = 'SEC-SHARE-OPS-RW';      Scope = 'DomainLocal'; Desc = 'Read/write to the Operations share' }
    @{ Name = 'SEC-SHARE-ALL-RO';      Scope = 'DomainLocal'; Desc = 'Read-only to the company-wide share' }
    @{ Name = 'SEC-VPN-USERS';         Scope = 'Global';      Desc = 'Permitted remote access' }
    @{ Name = 'SEC-KIOSK-LOCKDOWN';    Scope = 'Global';      Desc = 'Warehouse terminal restricted desktop' }
    @{ Name = 'SEC-HELPDESK-TIER1';    Scope = 'Global';      Desc = 'Delegated password reset and unlock rights' }
)

foreach ($g in $roleGroups) {
    if (Get-ADGroup -Filter "Name -eq '$($g.Name)'" -ErrorAction SilentlyContinue) {
        Write-Skip $g.Name
    } else {
        New-ADGroup -Name $g.Name `
                    -SamAccountName $g.Name `
                    -GroupCategory Security `
                    -GroupScope $g.Scope `
                    -Path $ouGroups `
                    -Description $g.Desc
        Write-Ok "$($g.Name) [$($g.Scope)]"
    }
}

# Global groups hold people, domain local groups hold permissions, and the
# global goes into the domain local. This is AGDLP, and following it is why
# a permission change later means editing one group instead of auditing
# every folder on the file server.
Write-Step 'Nesting department groups into resource groups (AGDLP)'
$nesting = @{
    'SEC-SHARE-FINANCE-RW' = @('SEC-FINANCE')
    'SEC-SHARE-OPS-RW'     = @('SEC-OPERATIONS', 'SEC-WAREHOUSE')
    'SEC-SHARE-ALL-RO'     = @('SEC-OPERATIONS', 'SEC-WAREHOUSE', 'SEC-FINANCE', 'SEC-IT', 'SEC-DRIVERS')
}
foreach ($resource in $nesting.Keys) {
    foreach ($member in $nesting[$resource]) {
        $already = Get-ADGroupMember -Identity $resource -ErrorAction SilentlyContinue |
                   Where-Object Name -eq $member
        if ($already) { Write-Skip "$member -> $resource" }
        else {
            Add-ADGroupMember -Identity $resource -Members $member
            Write-Ok "$member -> $resource"
        }
    }
}

Write-Host "`nDirectory structure complete.`n" -ForegroundColor Cyan
