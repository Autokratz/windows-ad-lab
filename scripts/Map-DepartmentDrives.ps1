<#
.SYNOPSIS
    Logon script: map department and company shares based on group membership.

.DESCRIPTION
    Deployed to NETLOGON and invoked by the MERIDIAN - Drive Mapping GPO.

    Membership is read from the logon token rather than queried from AD. The
    token is what the file server will actually evaluate when the connection
    is made, so a group added since the user last signed in is correctly
    absent here too - the map and the permission agree instead of producing a
    drive that appears and then denies access.

    Failures are written to the user's temp directory and never block logon.
    A drive map that throws is an annoyance; a logon script that hangs is an
    outage.
#>

[CmdletBinding()]
param(
    [string] $FileServer = 'DC01'
)

$log = Join-Path $env:TEMP 'drive-mapping.log'
function Write-MapLog { param($m) "$(Get-Date -Format s)  $m" | Add-Content -Path $log }

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$groups = $identity.Groups | ForEach-Object {
    # A SID with no resolvable account (a deleted group, a well-known SID
    # with no local name) is normal here and is simply not a group we map on.
    try { $_.Translate([Security.Principal.NTAccount]).Value }
    catch { Write-MapLog "unresolved SID $($_.Exception.Message)" }
}

$maps = @(
    @{ Letter = 'S'; Share = 'Company'; Group = 'MERIDIAN\SEC-SHARE-ALL-RO' }
    @{ Letter = 'O'; Share = 'Ops';     Group = 'MERIDIAN\SEC-SHARE-OPS-RW' }
    @{ Letter = 'F'; Share = 'Finance'; Group = 'MERIDIAN\SEC-SHARE-FINANCE-RW' }
)

foreach ($m in $maps) {

    if ($groups -notcontains $m.Group) { continue }

    $path = "\\$FileServer\$($m.Share)"
    $existing = Get-PSDrive -Name $m.Letter -ErrorAction SilentlyContinue

    if ($existing -and $existing.DisplayRoot -eq $path) {
        Write-MapLog "$($m.Letter): already mapped to $path"
        continue
    }

    try {
        if ($existing) {
            # A stale map to the wrong target is worse than no map, because the
            # user reports "my drive is empty" rather than "my drive is missing".
            Remove-PSDrive -Name $m.Letter -Force -ErrorAction Stop
            Write-MapLog "$($m.Letter): removed stale map to $($existing.DisplayRoot)"
        }
        New-PSDrive -Name $m.Letter -PSProvider FileSystem -Root $path -Persist -Scope Global -ErrorAction Stop | Out-Null
        Write-MapLog "$($m.Letter): mapped to $path"
    }
    catch {
        Write-MapLog "$($m.Letter): FAILED mapping $path - $($_.Exception.Message)"
    }
}
