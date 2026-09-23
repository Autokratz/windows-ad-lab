<#
.SYNOPSIS
    Bulk-create staff accounts from data/staff.csv into their department OUs.

.DESCRIPTION
    Step 4 of the Meridian Logistics lab build. Creates 32 users, places each
    in its department OU, sets the UPN to the mail-style name people actually
    type, adds the account to its department security group, and forces a
    password change at first logon.

    Three things worth noting:

    * Usernames collide. First-initial-plus-surname is the most common
      convention and it breaks the first time two people share it. The
      resolver below appends a digit and keeps going, rather than throwing
      halfway through a 32-account import and leaving the directory in an
      unknown state.

    * Each account gets its own random initial password, not one shared value.
      A single shared "Welcome123" across an import is the most common way a
      lab habit becomes a production incident.

    * The generated credentials are written to a handover CSV which is
      gitignored. Real initial passwords never belong in a repository.

    Idempotent: existing accounts are reported and skipped, not overwritten.

.PARAMETER WhatIf
    Supported. Run it first.
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [string] $CsvPath      = (Join-Path $PSScriptRoot '..\data\staff.csv'),
    [string] $HandoverPath = (Join-Path $PSScriptRoot '..\evidence\initial-credentials.csv'),
    [string] $UpnSuffix    = 'meridian.com.au',
    [string] $DomainDN     = (Get-ADDomain).DistinguishedName
)

$ErrorActionPreference = 'Stop'

function Write-Step { param($m) Write-Host "`n== $m" -ForegroundColor Cyan }
function Write-Ok   { param($m) Write-Host "   OK    $m" -ForegroundColor Green }
function Write-Skip { param($m) Write-Host "   SKIP  $m" -ForegroundColor DarkGray }
function Write-Warn { param($m) Write-Host "   WARN  $m" -ForegroundColor Yellow }

function New-InitialPassword {
    # 16 characters from a set with no ambiguous glyphs, so it can be read
    # aloud over the phone without "was that a one or an ell".
    $sets = @(
        'ABCDEFGHJKLMNPQRSTUVWXYZ',
        'abcdefghijkmnopqrstuvwxyz',
        '23456789',
        '!#$%&*+-=?'
    )
    $chars = foreach ($s in $sets) { $s[(Get-Random -Maximum $s.Length)] }   # guarantee each class
    $all = -join $sets
    $chars += 1..12 | ForEach-Object { $all[(Get-Random -Maximum $all.Length)] }
    -join ($chars | Sort-Object { Get-Random })
}

function Resolve-SamAccountName {
    param([string] $First, [string] $Last)
    $base = ('{0}{1}' -f $First.Substring(0,1), $Last) -replace '[^a-zA-Z0-9]', ''
    $base = $base.ToLower()
    if ($base.Length -gt 18) { $base = $base.Substring(0, 18) }   # leave room for a suffix

    $candidate = $base
    $n = 1
    while (Get-ADUser -Filter "SamAccountName -eq '$candidate'" -ErrorAction SilentlyContinue) {
        $n++
        $candidate = "$base$n"
    }
    return $candidate
}

# --- load ---------------------------------------------------------------
if (-not (Test-Path $CsvPath)) { throw "Staff list not found: $CsvPath" }
$staff = Import-Csv -Path $CsvPath
Write-Step "Importing $($staff.Count) staff records from $(Split-Path $CsvPath -Leaf)"

$handover = [System.Collections.Generic.List[object]]::new()
$created = 0; $skipped = 0

foreach ($person in $staff) {

    $display = "$($person.FirstName) $($person.LastName)"
    $ou = "OU=$($person.Department),OU=Users,OU=Meridian,$DomainDN"

    if (-not (Get-ADOrganizationalUnit -Filter "DistinguishedName -eq '$ou'" -ErrorAction SilentlyContinue)) {
        Write-Warn "$display - OU missing ($($person.Department)); run 03-Build-OuStructure.ps1 first"
        continue
    }

    # Match on display name, because the SAM resolver would mint a fresh
    # unique name on a re-run and happily create a duplicate person.
    if (Get-ADUser -Filter "DisplayName -eq '$display'" -SearchBase $ou -ErrorAction SilentlyContinue) {
        Write-Skip "$display already exists"
        $skipped++
        continue
    }

    $sam = Resolve-SamAccountName -First $person.FirstName -Last $person.LastName
    $upn = "$($person.FirstName).$($person.LastName)@$UpnSuffix".ToLower()
    $pw  = New-InitialPassword

    if ($PSCmdlet.ShouldProcess($display, "Create $sam in $($person.Department)")) {
        New-ADUser `
            -Name                   $display `
            -DisplayName            $display `
            -GivenName              $person.FirstName `
            -Surname                $person.LastName `
            -SamAccountName         $sam `
            -UserPrincipalName      $upn `
            -Title                  $person.JobTitle `
            -Department             $person.Department `
            -Office                 $person.Office `
            -Company                'Meridian Logistics' `
            -Path                   $ou `
            -AccountPassword        (ConvertTo-SecureString $pw -AsPlainText -Force) `
            -ChangePasswordAtLogon  $true `
            -Enabled                $true

        Add-ADGroupMember -Identity "SEC-$($person.Department.ToUpper())" -Members $sam

        $handover.Add([pscustomobject]@{
            DisplayName = $display
            SamAccount  = $sam
            UPN         = $upn
            Department  = $person.Department
            InitialPassword = $pw
        })

        Write-Ok "$display -> $sam ($($person.Department))"
        $created++
    }
}

# --- handover file ------------------------------------------------------
if ($handover.Count -gt 0) {
    $dir = Split-Path $HandoverPath -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
    $handover | Export-Csv -Path $HandoverPath -NoTypeInformation -Encoding UTF8
    Write-Host "`n   Initial credentials written to $HandoverPath" -ForegroundColor Yellow
    Write-Host "   This file is gitignored. Distribute it, then delete it." -ForegroundColor Yellow
}

Write-Host "`nCreated $created, skipped $skipped.`n" -ForegroundColor Cyan
