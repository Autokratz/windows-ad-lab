<#
.SYNOPSIS
    Configure DNS forwarders, a reverse lookup zone, and an authorised DHCP scope.

.DESCRIPTION
    Step 2 of the Meridian Logistics lab build.

    The reverse lookup zone matters more than it looks. Without it, PTR records
    never register, and every tool that resolves an address back to a name -
    event logs, printer discovery, half of what a service desk reads during an
    incident - shows raw addresses instead of hostnames. It costs one command
    at build time and hours later.

    DHCP must be authorised in AD or it silently refuses to lease. That single
    behaviour accounts for a large share of "DHCP isn't working" tickets in
    small domains.

    Idempotent: re-running reports existing objects and moves on.
#>

[CmdletBinding()]
param(
    [string]   $ScopeName      = 'MERIDIAN-LAN',
    [string]   $ScopeId        = '10.20.0.0',
    [string]   $StartRange     = '10.20.0.100',
    [string]   $EndRange       = '10.20.0.200',
    [string]   $SubnetMask     = '255.255.255.0',
    [string]   $Gateway        = '10.20.0.1',
    [string]   $DnsServer      = '10.20.0.10',
    [string]   $DomainName     = 'corp.meridian.internal',
    [string[]] $Forwarders     = @('1.1.1.1', '9.9.9.9'),
    [string]   $ReverseNetwork = '0.20.10.in-addr.arpa'
)

$ErrorActionPreference = 'Stop'

function Write-Step { param($m) Write-Host "`n== $m" -ForegroundColor Cyan }
function Write-Ok   { param($m) Write-Host "   OK    $m" -ForegroundColor Green }
function Write-Skip { param($m) Write-Host "   SKIP  $m" -ForegroundColor DarkGray }

# --- DNS forwarders -----------------------------------------------------
Write-Step 'DNS forwarders'
$current = (Get-DnsServerForwarder).IPAddress.IPAddressToString
foreach ($f in $Forwarders) {
    if ($current -contains $f) { Write-Skip "forwarder $f" }
    else { Add-DnsServerForwarder -IPAddress $f -PassThru | Out-Null; Write-Ok "forwarder $f" }
}

# --- reverse lookup zone ------------------------------------------------
Write-Step 'Reverse lookup zone'
if (Get-DnsServerZone -Name $ReverseNetwork -ErrorAction SilentlyContinue) {
    Write-Skip "$ReverseNetwork already exists"
} else {
    Add-DnsServerPrimaryZone -NetworkId "$ScopeId/24" `
                             -ReplicationScope 'Domain' `
                             -DynamicUpdate 'Secure'
    Write-Ok "$ReverseNetwork created, secure dynamic update"
}

# --- DHCP role ----------------------------------------------------------
Write-Step 'DHCP Server role'
if ((Get-WindowsFeature -Name DHCP).Installed) {
    Write-Skip 'DHCP already installed'
} else {
    Install-WindowsFeature -Name DHCP -IncludeManagementTools | Out-Null
    Write-Ok 'DHCP installed'
}

# --- authorise in AD ----------------------------------------------------
# A DHCP server that is not authorised in Active Directory will start, log no
# obvious error, and hand out nothing at all.
Write-Step 'Authorising DHCP in Active Directory'
$fqdn = "$env:COMPUTERNAME.$DomainName"
if (Get-DhcpServerInDC | Where-Object DnsName -eq $fqdn) {
    Write-Skip "$fqdn already authorised"
} else {
    Add-DhcpServerInDC -DnsName $fqdn -IPAddress $DnsServer
    Write-Ok "$fqdn authorised"
}

# --- scope --------------------------------------------------------------
Write-Step 'DHCP scope'
if (Get-DhcpServerv4Scope -ScopeId $ScopeId -ErrorAction SilentlyContinue) {
    Write-Skip "scope $ScopeId already exists"
} else {
    Add-DhcpServerv4Scope -Name       $ScopeName `
                          -StartRange $StartRange `
                          -EndRange   $EndRange `
                          -SubnetMask $SubnetMask `
                          -State      Active
    Write-Ok "$ScopeName $StartRange - $EndRange"
}

Set-DhcpServerv4OptionValue -ScopeId $ScopeId `
                            -Router     $Gateway `
                            -DnsServer  $DnsServer `
                            -DnsDomain  $DomainName
Write-Ok "options: gateway $Gateway, DNS $DnsServer, domain $DomainName"

# Exclude the static server range so the scope never leases an address that
# is already pinned to infrastructure.
$exclusionStart = '10.20.0.1'
$exclusionEnd   = '10.20.0.99'
$existingExcl = Get-DhcpServerv4ExclusionRange -ScopeId $ScopeId -ErrorAction SilentlyContinue
if ($existingExcl | Where-Object { $_.StartRange.IPAddressToString -eq $exclusionStart }) {
    Write-Skip "exclusion $exclusionStart - $exclusionEnd"
} else {
    Add-DhcpServerv4ExclusionRange -ScopeId $ScopeId -StartRange $exclusionStart -EndRange $exclusionEnd
    Write-Ok "exclusion $exclusionStart - $exclusionEnd (static infrastructure)"
}

Restart-Service dhcpserver
Write-Ok 'DHCP service restarted'
