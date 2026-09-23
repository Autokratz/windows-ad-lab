<#
.SYNOPSIS
    Promote a fresh Windows Server to the first domain controller of a new forest.

.DESCRIPTION
    Step 1 of the Meridian Logistics lab build. Sets a static address, installs
    AD DS and DNS, and creates the forest.

    The domain is corp.meridian.internal, deliberately NOT a .local name.
    .local is reserved for multicast DNS (RFC 6762) and collides with Bonjour
    and Avahi on mixed networks; .internal is reserved for private use, which
    is what this is. Picking .local is one of the most common and most
    expensive mistakes in a first AD build, because renaming a forest root
    afterwards is close to impossible.

    Idempotent: safe to re-run. If the forest already exists the script reports
    and exits without touching it.

.NOTES
    Run elevated on the server that will become DC01. Reboots on completion.
#>

[CmdletBinding()]
param(
    [string] $DomainName    = 'corp.meridian.internal',
    [string] $NetbiosName   = 'MERIDIAN',
    [string] $ComputerName  = 'DC01',
    [string] $IPAddress     = '10.20.0.10',
    [byte]   $PrefixLength  = 24,
    [string] $Gateway       = '10.20.0.1',
    [string] $InterfaceAlias
)

$ErrorActionPreference = 'Stop'

function Write-Step { param($m) Write-Host "`n== $m" -ForegroundColor Cyan }
function Write-Ok   { param($m) Write-Host "   OK    $m" -ForegroundColor Green }
function Write-Skip { param($m) Write-Host "   SKIP  $m" -ForegroundColor DarkGray }

# --- guard: already a DC? -----------------------------------------------
if (Get-WindowsFeature -Name AD-Domain-Services | Where-Object Installed) {
    try {
        $existing = Get-ADDomain -ErrorAction Stop
        Write-Skip "Already a domain controller for $($existing.DNSRoot). Nothing to do."
        return
    } catch {
        Write-Step 'AD DS binaries present but no domain found; continuing with promotion.'
    }
}

# --- network ------------------------------------------------------------
Write-Step 'Configuring static address'

if (-not $InterfaceAlias) {
    $InterfaceAlias = (Get-NetAdapter -Physical |
        Where-Object Status -eq 'Up' |
        Sort-Object ifIndex |
        Select-Object -First 1).Name
}
if (-not $InterfaceAlias) { throw 'No connected physical adapter found.' }

$current = Get-NetIPAddress -InterfaceAlias $InterfaceAlias -AddressFamily IPv4 -ErrorAction SilentlyContinue

if ($current.IPAddress -contains $IPAddress) {
    Write-Skip "$IPAddress already set on $InterfaceAlias"
} else {
    # Clear DHCP-assigned config before pinning a static address, otherwise
    # New-NetIPAddress fails with "Instance MSFT_NetIPAddress already exists".
    Get-NetIPAddress -InterfaceAlias $InterfaceAlias -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue
    Get-NetRoute -InterfaceAlias $InterfaceAlias -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
        Remove-NetRoute -Confirm:$false -ErrorAction SilentlyContinue
    Set-NetIPInterface -InterfaceAlias $InterfaceAlias -Dhcp Disabled

    New-NetIPAddress -InterfaceAlias $InterfaceAlias `
                     -IPAddress $IPAddress `
                     -PrefixLength $PrefixLength `
                     -DefaultGateway $Gateway | Out-Null
    Write-Ok "$IPAddress/$PrefixLength via $Gateway on $InterfaceAlias"
}

# A domain controller must resolve against itself, or SYSVOL and netlogon
# registration fail in ways that only surface much later as GPO problems.
Set-DnsClientServerAddress -InterfaceAlias $InterfaceAlias -ServerAddresses $IPAddress
Write-Ok "DNS client pointed at self ($IPAddress)"

# --- hostname -----------------------------------------------------------
if ($env:COMPUTERNAME -ne $ComputerName) {
    Write-Step "Renaming $env:COMPUTERNAME to $ComputerName"
    Rename-Computer -NewName $ComputerName -Force
    Write-Host "`n   Rename staged. Reboot, then run this script again." -ForegroundColor Yellow
    Restart-Computer -Force
    return
}
Write-Skip "Hostname already $ComputerName"

# --- roles --------------------------------------------------------------
Write-Step 'Installing AD DS and DNS'
Install-WindowsFeature -Name AD-Domain-Services, DNS -IncludeManagementTools | Out-Null
Write-Ok 'AD-Domain-Services, DNS'

# --- forest -------------------------------------------------------------
Write-Step "Creating forest $DomainName"

$dsrm = Read-Host 'Directory Services Restore Mode password' -AsSecureString

Import-Module ADDSDeployment

Install-ADDSForest `
    -DomainName                    $DomainName `
    -DomainNetbiosName             $NetbiosName `
    -SafeModeAdministratorPassword $dsrm `
    -InstallDns                    $true `
    -DomainMode                    'WinThreshold' `
    -ForestMode                    'WinThreshold' `
    -DatabasePath                  'C:\Windows\NTDS' `
    -LogPath                       'C:\Windows\NTDS' `
    -SysvolPath                    'C:\Windows\SYSVOL' `
    -NoRebootOnCompletion:$false `
    -Force:$true

# Install-ADDSForest reboots; execution does not continue past this point.
