<#
.SYNOPSIS
    Capture the domain's actual state to evidence\ as text, for the README.

.DESCRIPTION
    The network lab in my other repository commits the raw capture files
    alongside the results, so every figure in the write-up can be diffed
    against the output that produced it. This does the same thing for the
    domain.

    Nothing here is modified or rendered - each file is the unedited stdout of
    one command. If a number in the README does not appear in these files, the
    number is wrong.

    Credentials are never captured. initial-credentials.csv is written by the
    user import and is gitignored.
#>

[CmdletBinding()]
param(
    [string] $OutDir = (Join-Path $PSScriptRoot '..\evidence')
)

$ErrorActionPreference = 'Continue'

if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Path $OutDir | Out-Null }

$captures = [ordered]@{
    'domain-summary.txt'   = { Get-ADDomain | Format-List * }
    'forest-summary.txt'   = { Get-ADForest | Format-List * }
    'ou-tree.txt'          = { Get-ADOrganizationalUnit -Filter * |
                               Select-Object -ExpandProperty DistinguishedName | Sort-Object }
    'users-by-dept.txt'    = { Get-ADUser -Filter * -Properties Department, Title, Office |
                               Where-Object Department |
                               Sort-Object Department, Surname |
                               Format-Table SamAccountName, Name, Department, Title, Office -AutoSize }
    'groups.txt'           = { Get-ADGroup -Filter 'Name -like "SEC-*"' -Properties Description, GroupScope |
                               Sort-Object Name |
                               Format-Table Name, GroupScope, Description -AutoSize }
    'group-membership.txt' = { Get-ADGroup -Filter 'Name -like "SEC-*"' | Sort-Object Name | ForEach-Object {
                                 "`n=== $($_.Name) ==="
                                 (Get-ADGroupMember -Identity $_ -ErrorAction SilentlyContinue).Name | Sort-Object
                               } }
    'gpo-inventory.txt'    = { Get-GPO -All | Sort-Object DisplayName |
                               Format-Table DisplayName, GpoStatus, CreationTime, ModificationTime -AutoSize }
    'gpo-links.txt'        = { Get-ADOrganizationalUnit -Filter * | ForEach-Object {
                                 $l = (Get-GPInheritance -Target $_.DistinguishedName).GpoLinks
                                 if ($l) { "`n=== $($_.DistinguishedName) ==="; $l.DisplayName }
                               } }
    'password-policy.txt'  = { Get-ADDefaultDomainPasswordPolicy | Format-List *
                               "`n=== fine grained ==="
                               Get-ADFineGrainedPasswordPolicy -Filter * | Format-List Name, Precedence,
                                   MinPasswordLength, LockoutThreshold, LockoutDuration, AppliesTo }
    'delegation.txt'       = { & dsacls.exe "OU=Users,OU=Meridian,$((Get-ADDomain).DistinguishedName)" }
    'dns-zones.txt'        = { Get-DnsServerZone | Format-Table ZoneName, ZoneType, IsDsIntegrated, DynamicUpdate -AutoSize
                               "`n=== forwarders ==="
                               Get-DnsServerForwarder }
    'dhcp-scope.txt'       = { Get-DhcpServerv4Scope | Format-List *
                               "`n=== statistics ==="
                               Get-DhcpServerv4ScopeStatistics | Format-List *
                               "`n=== options ==="
                               Get-DhcpServerv4OptionValue -ScopeId '10.20.0.0' | Format-Table -AutoSize }
    'replication.txt'      = { & repadmin.exe /showrepl }
    'dcdiag.txt'           = { & dcdiag.exe /c /v }
    'health-check.txt'     = { & (Join-Path $PSScriptRoot 'Test-DomainHealth.ps1') }
}

Write-Host "`nCapturing domain evidence to $OutDir`n" -ForegroundColor Cyan

foreach ($file in $captures.Keys) {
    $path = Join-Path $OutDir $file
    try {
        $header = @(
            "# $file",
            "# captured $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz') on $env:COMPUTERNAME",
            ('#' * 70),
            ''
        )
        $body = & $captures[$file] 2>&1 | Out-String -Width 200
        ($header + $body) | Set-Content -Path $path -Encoding UTF8
        Write-Host ('  {0,-24} {1,7:N0} bytes' -f $file, (Get-Item $path).Length) -ForegroundColor Green
    }
    catch {
        Write-Host ('  {0,-24} FAILED: {1}' -f $file, $_.Exception.Message) -ForegroundColor Red
    }
}

Write-Host "`nDone. Commit the contents of evidence\ except initial-credentials.csv.`n" -ForegroundColor Cyan
