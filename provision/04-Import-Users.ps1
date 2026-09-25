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

[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSAvoidUsingConvertToSecureStringWithPlainText', '',
    Justification = 'The password is generated in this process and must exist as plaintext briefly to be set on the account and written to the handover CSV. It is never read from disk, never logged, and the handover file is gitignored. Bulk provisioning has no SecureString-only path.'
)]
[CmdletBinding(SupportsShouldProcess)]
param(
    [string] $CsvPath      = (Join-Path $PSScriptRoot '..\data\staff.csv'),
    [string] $HandoverPath = (Join-Path $PSScriptRoot '..\evidence\initial-credentials.csv'),
    [string] $UpnSuffix    = 'meridian.example',
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
    #
    # Get-Random is System.Random, which is not a cryptographic generator.
    # These are real account passwords, so they come from the CSPRNG and the
    # shuffle is Fisher-Yates rather than a biased sort-by-random-key.
    $sets = @(
        'ABCDEFGHJKLMNPQRSTUVWXYZ',
        'abcdefghijkmnopqrstuvwxyz',
        '23456789',
        '!#$%&*+-=?'
    )
    $rand = { param($n) [System.Security.Cryptography.RandomNumberGenerator]::GetInt32($n) }

    $chars = [System.Collections.Generic.List[char]]::new()
    foreach ($s in $sets) { $chars.Add($s[(& $rand $s.Length)]) }   # guarantee each class
    $all = -join $sets
    for ($i = 0; $i -lt 12; $i++) { $chars.Add($all[(& $rand $all.Length)]) }

    for ($i = $chars.Count - 1; $i -gt 0; $i--) {
        $j = & $rand ($i + 1)
        $tmp = $chars[$i]; $chars[$i] = $chars[$j]; $chars[$j] = $tmp
    }
    -join $chars
}

function ConvertTo-AdFilterLiteral {
    # A surname like O'Brien closes the quote in an AD filter string. Left
    # unescaped the duplicate check silently matches nothing, so every re-run
    # creates another account and the documented idempotency breaks.
    param([string] $Value)
    $Value -replace "'", "''"
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

# Written as we go, not at the end. Any failure inside the loop is terminating
# under $ErrorActionPreference = 'Stop', and a handover flushed only on success
# is exactly the file you need when the import dies at user 20 of 32.
$dir = Split-Path $HandoverPath -Parent
if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
if (Test-Path $HandoverPath) { Remove-Item $HandoverPath }

$created = 0; $skipped = 0; $wrote = 0

foreach ($person in $staff) {

    $display = "$($person.FirstName) $($person.LastName)"
    $ou = "OU=$($person.Department),OU=Users,OU=Meridian,$DomainDN"

    if (-not (Get-ADOrganizationalUnit -Filter "DistinguishedName -eq '$ou'" -ErrorAction SilentlyContinue)) {
        Write-Warn "$display - OU missing ($($person.Department)); run 03-Build-OuStructure.ps1 first"
        continue
    }

    # The group is used after the account is created. Checking it here means a
    # missing group skips the person instead of aborting mid-import.
    $group = "SEC-$($person.Department.ToUpper())"
    if (-not (Get-ADGroup -Filter "Name -eq '$group'" -ErrorAction SilentlyContinue)) {
        Write-Warn "$display - group $group missing; run 03-Build-OuStructure.ps1 first"
        continue
    }

    # Match on display name, because the SAM resolver would mint a fresh
    # unique name on a re-run and happily create a duplicate person.
    $displayFilter = ConvertTo-AdFilterLiteral $display
    if (Get-ADUser -Filter "DisplayName -eq '$displayFilter'" -SearchBase $ou -ErrorAction SilentlyContinue) {
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

        Add-ADGroupMember -Identity $group -Members $sam

        [pscustomobject]@{
            DisplayName     = $display
            SamAccount      = $sam
            UPN             = $upn
            Department      = $person.Department
            InitialPassword = $pw
        } | Export-Csv -Path $HandoverPath -NoTypeInformation -Encoding UTF8 -Append
        $wrote++

        Write-Ok "$display -> $sam ($($person.Department))"
        $created++
    }
}

# --- handover file ------------------------------------------------------
if ($wrote -gt 0) {
    Write-Host "`n   Initial credentials written to $HandoverPath" -ForegroundColor Yellow
    Write-Host "   This file is gitignored. Distribute it, then delete it." -ForegroundColor Yellow
}

Write-Host "`nCreated $created, skipped $skipped.`n" -ForegroundColor Cyan
