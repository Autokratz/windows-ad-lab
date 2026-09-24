<#
.SYNOPSIS
    Preflight and health check for the Meridian domain. Run it before you
    trust the lab, and again after any change.

.DESCRIPTION
    Exists for the same reason the preflight in my generation pipeline does:
    the failures that cost the most time are the SILENT ones. A domain
    controller with a missing reverse zone, an unauthorised DHCP server, or a
    SYSVOL share that never came back after a reboot will not announce itself.
    It surfaces three days later as "Group Policy isn't applying" or "nobody
    can log in at the Melbourne site", and by then nobody connects it to the
    change that caused it.

    Every check answers one question with PASS, WARN or FAIL, and nothing here
    modifies the directory - it is safe to run at any time, including in
    production.

    Exit codes:  0 = no failures   1 = at least one FAIL

.EXAMPLE
    .\Test-DomainHealth.ps1
    .\Test-DomainHealth.ps1 -Quick        # skip replication and DNS resolution
#>

[CmdletBinding()]
param(
    [switch] $Quick,
    [string] $ExpectedDomain = 'corp.meridian.internal',
    [string] $ScopeId        = '10.20.0.0'
)

$ErrorActionPreference = 'Continue'

$script:Pass = 0; $script:Warn = 0; $script:Fail = 0

function Test-Item {
    param(
        [string]    $Name,
        [scriptblock] $Check,
        [string]    $FailHint = ''
    )
    try {
        $result = & $Check
    } catch {
        $result = @{ Status = 'FAIL'; Detail = $_.Exception.Message }
    }

    switch ($result.Status) {
        'PASS' { Write-Host ('  PASS  {0,-46} {1}' -f $Name, $result.Detail) -ForegroundColor Green;  $script:Pass++ }
        'WARN' { Write-Host ('  WARN  {0,-46} {1}' -f $Name, $result.Detail) -ForegroundColor Yellow; $script:Warn++ }
        default {
            Write-Host ('  FAIL  {0,-46} {1}' -f $Name, $result.Detail) -ForegroundColor Red
            if ($FailHint) { Write-Host ('        -> {0}' -f $FailHint) -ForegroundColor DarkGray }
            $script:Fail++
        }
    }
}

function New-CheckResult {
    param($Status, $Detail)
    @{ Status = $Status; Detail = $Detail }
}

Write-Host "`nMeridian domain health check  -  $(Get-Date -Format 'yyyy-MM-dd HH:mm')" -ForegroundColor Cyan
Write-Host ('=' * 78)

# ---------------------------------------------------------------- services
Write-Host "`n-- core services"

foreach ($svc in 'NTDS', 'DNS', 'Netlogon', 'W32Time', 'kdc') {
    Test-Item -Name "service $svc" -FailHint "Start-Service $svc, then check the System event log" -Check {
        $s = Get-Service -Name $svc -ErrorAction Stop
        if ($s.Status -eq 'Running') { New-CheckResult 'PASS' $s.Status } else { New-CheckResult 'FAIL' $s.Status }
    }
}

# ------------------------------------------------------------------ shares
Write-Host "`n-- SYSVOL and NETLOGON"

foreach ($share in 'SYSVOL', 'NETLOGON') {
    Test-Item -Name "share $share published" -FailHint 'SYSVOL did not replicate in; check DFSR state and the Netlogon service' -Check {
        if (Get-SmbShare -Name $share -ErrorAction SilentlyContinue) { New-CheckResult 'PASS' 'published' }
        else { New-CheckResult 'FAIL' 'missing' }
    }
}

Test-Item -Name 'SYSVOL readable over UNC' -Check {
    $p = "\\$env:COMPUTERNAME\SYSVOL"
    if (Test-Path $p) { New-CheckResult 'PASS' $p } else { New-CheckResult 'FAIL' "cannot read $p" }
}

# --------------------------------------------------------------- directory
Write-Host "`n-- directory"

Test-Item -Name 'domain reachable' -Check {
    $d = Get-ADDomain -ErrorAction Stop
    if ($d.DNSRoot -eq $ExpectedDomain) { New-CheckResult 'PASS' $d.DNSRoot }
    else { New-CheckResult 'WARN' "found $($d.DNSRoot), expected $ExpectedDomain" }
}

Test-Item -Name 'forest and domain functional level' -Check {
    $f = (Get-ADForest).ForestMode
    $d = (Get-ADDomain).DomainMode
    New-CheckResult 'PASS' "forest $f / domain $d"
}

Test-Item -Name 'FSMO roles held' -Check {
    $d = Get-ADDomain; $f = Get-ADForest
    $holders = @($f.SchemaMaster, $f.DomainNamingMaster, $d.PDCEmulator, $d.RIDMaster, $d.InfrastructureMaster) |
               Select-Object -Unique
    New-CheckResult 'PASS' ($holders -join ', ')
}

Test-Item -Name 'OU structure present' -FailHint 'run provision\03-Build-OuStructure.ps1' -Check {
    $dn = (Get-ADDomain).DistinguishedName
    $need = @(
        "OU=Meridian,$dn"
        "OU=Users,OU=Meridian,$dn"
        "OU=Computers,OU=Meridian,$dn"
        "OU=Groups,OU=Meridian,$dn"
    )
    $missing = $need | Where-Object {
        -not (Get-ADOrganizationalUnit -Filter "DistinguishedName -eq '$_'" -ErrorAction SilentlyContinue)
    }
    if ($missing) { New-CheckResult 'FAIL' "missing: $($missing -join '; ')" }
    else { New-CheckResult 'PASS' "$($need.Count) base OUs" }
}

Test-Item -Name 'default containers redirected' -FailHint 'run redircmp/redirusr in 03-Build-OuStructure.ps1' -Check {
    $dn = (Get-ADDomain).DistinguishedName
    $wk = (Get-ADObject -Identity $dn -Properties wellKnownObjects).wellKnownObjects
    $computersRedirected = -not ($wk -match 'CN=Computers,' + [regex]::Escape($dn))
    if ($computersRedirected) { New-CheckResult 'PASS' 'new computers land in an OU' }
    else { New-CheckResult 'WARN' 'new computers still land in CN=Computers and receive no GPO' }
}

Test-Item -Name 'staff accounts' -Check {
    $dn = (Get-ADDomain).DistinguishedName
    $n = (Get-ADUser -Filter * -SearchBase "OU=Users,OU=Meridian,$dn" -ErrorAction Stop | Measure-Object).Count
    if ($n -eq 0) { New-CheckResult 'FAIL' 'no users; run 04-Import-Users.ps1' } else { New-CheckResult 'PASS' "$n accounts" }
}

Test-Item -Name 'no accounts with non-expiring passwords' -Check {
    $dn = (Get-ADDomain).DistinguishedName
    $bad = Get-ADUser -Filter 'PasswordNeverExpires -eq $true' -SearchBase "OU=Users,OU=Meridian,$dn" -ErrorAction SilentlyContinue
    if ($bad) { New-CheckResult 'WARN' "$(($bad | Measure-Object).Count): $((($bad).SamAccountName) -join ', ')" }
    else { New-CheckResult 'PASS' 'none' }
}

Test-Item -Name 'helpdesk delegation in place' -FailHint 'run provision\05-Set-GpoBaseline.ps1' -Check {
    $dn = (Get-ADDomain).DistinguishedName
    $acl = (& dsacls.exe "OU=Users,OU=Meridian,$dn") -join "`n"
    if ($acl -match 'SEC-HELPDESK-TIER1') { New-CheckResult 'PASS' 'SEC-HELPDESK-TIER1 has explicit rights' }
    else { New-CheckResult 'FAIL' 'no delegation found' }
}

# --------------------------------------------------------------------- DNS
Write-Host "`n-- DNS"

Test-Item -Name 'forward lookup zone' -Check {
    if (Get-DnsServerZone -Name $ExpectedDomain -ErrorAction SilentlyContinue) { New-CheckResult 'PASS' $ExpectedDomain }
    else { New-CheckResult 'FAIL' "no zone for $ExpectedDomain" }
}

Test-Item -Name 'reverse lookup zone' -FailHint 'PTR records will not register; event logs will show addresses, not names' -Check {
    $rev = Get-DnsServerZone -ErrorAction SilentlyContinue | Where-Object { $_.ZoneName -like '*.in-addr.arpa' }
    if ($rev) { New-CheckResult 'PASS' (($rev.ZoneName) -join ', ') } else { New-CheckResult 'WARN' 'none configured' }
}

Test-Item -Name 'forwarders configured' -Check {
    $f = (Get-DnsServerForwarder).IPAddress.IPAddressToString
    if ($f) { New-CheckResult 'PASS' ($f -join ', ') } else { New-CheckResult 'WARN' 'no forwarders; external resolution will fail' }
}

Test-Item -Name 'DC points DNS at itself' -FailHint 'a DC resolving via an external server breaks SRV registration' -Check {
    $self = (Get-NetIPAddress -AddressFamily IPv4 |
             Where-Object { $_.IPAddress -notlike '127.*' }).IPAddress
    $configured = (Get-DnsClientServerAddress -AddressFamily IPv4 |
                   Where-Object { $_.ServerAddresses }).ServerAddresses | Select-Object -Unique
    $ok = $configured | Where-Object { $self -contains $_ }
    if ($ok) { New-CheckResult 'PASS' ($configured -join ', ') } else { New-CheckResult 'FAIL' "resolves via $($configured -join ', ')" }
}

if (-not $Quick) {
    Test-Item -Name 'domain SRV record resolves' -FailHint 'clients cannot locate a DC; logons will fail' -Check {
        $srv = Resolve-DnsName -Name "_ldap._tcp.dc._msdcs.$ExpectedDomain" -Type SRV -ErrorAction Stop
        if ($srv) { New-CheckResult 'PASS' "$(($srv | Measure-Object).Count) record(s)" } else { New-CheckResult 'FAIL' 'no SRV records' }
    }
}

# -------------------------------------------------------------------- DHCP
Write-Host "`n-- DHCP"

Test-Item -Name 'DHCP authorised in AD' -FailHint 'an unauthorised DHCP server leases nothing and logs almost nothing' -Check {
    $fqdn = "$env:COMPUTERNAME.$ExpectedDomain"
    if (Get-DhcpServerInDC -ErrorAction SilentlyContinue | Where-Object DnsName -eq $fqdn) { New-CheckResult 'PASS' $fqdn }
    else { New-CheckResult 'FAIL' "$fqdn not authorised" }
}

Test-Item -Name 'scope active with free addresses' -Check {
    $s = Get-DhcpServerv4Scope -ScopeId $ScopeId -ErrorAction Stop
    if ($s.State -ne 'Active') { return New-CheckResult 'FAIL' "scope is $($s.State)" }
    $stats = Get-DhcpServerv4ScopeStatistics -ScopeId $ScopeId -ErrorAction Stop
    if ($stats.PercentageInUse -gt 90) { New-CheckResult 'WARN' "$([math]::Round($stats.PercentageInUse,1))% in use" }
    else { New-CheckResult 'PASS' "$($stats.Free) free of $($stats.Free + $stats.InUse)" }
}

# ---------------------------------------------------------- group policy
Write-Host "`n-- group policy"

Test-Item -Name 'baseline GPOs exist' -FailHint 'run provision\05-Set-GpoBaseline.ps1' -Check {
    $want = 'MERIDIAN - Workstation Baseline',
            'MERIDIAN - Warehouse Terminal Lockdown',
            'MERIDIAN - Drive Mapping'
    $have = (Get-GPO -All -ErrorAction Stop).DisplayName
    $missing = $want | Where-Object { $have -notcontains $_ }
    if ($missing) { New-CheckResult 'FAIL' "missing: $($missing -join '; ')" } else { New-CheckResult 'PASS' "$($want.Count) GPOs" }
}

Test-Item -Name 'every GPO is linked somewhere' -Check {
    $unlinked = Get-GPO -All | Where-Object {
        ([xml](Get-GPOReport -Guid $_.Id -ReportType Xml)).GPO.LinksTo -eq $null -and
        $_.DisplayName -notmatch 'Default Domain'
    }
    if ($unlinked) { New-CheckResult 'WARN' "unlinked: $((($unlinked).DisplayName) -join ', ')" }
    else { New-CheckResult 'PASS' 'all linked' }
}

# ------------------------------------------------------------ replication
if (-not $Quick) {
    Write-Host "`n-- replication and time"

    Test-Item -Name 'no replication failures' -Check {
        $f = Get-ADReplicationFailure -Target $env:COMPUTERNAME -ErrorAction SilentlyContinue
        if ($f) { New-CheckResult 'FAIL' "$(($f | Measure-Object).Count) failure(s)" } else { New-CheckResult 'PASS' 'none' }
    }

    Test-Item -Name 'time source' -FailHint 'Kerberos fails once skew passes 5 minutes' -Check {
        $src = (& w32tm.exe /query /source) -join ''
        if ($src -match 'Local CMOS Clock' ) { New-CheckResult 'WARN' "$src (PDC should sync to an external source)" }
        else { New-CheckResult 'PASS' $src }
    }
}

# ------------------------------------------------------------------ result
Write-Host ''
Write-Host ('=' * 78)
Write-Host ("  {0} passed   {1} warnings   {2} failures" -f $script:Pass, $script:Warn, $script:Fail) -ForegroundColor Cyan
Write-Host ''

if ($script:Fail -gt 0) { exit 1 } else { exit 0 }
