<#
.SYNOPSIS
    Break the lab on purpose, then repair it. Each fault is a real one, taken
    from the kind of ticket a service desk actually receives.

.DESCRIPTION
    A lab that only ever works teaches nothing. These are three faults chosen
    because the symptom the user reports points nowhere near the cause:

      GpoNotApplying   "my desktop settings disappeared"
                       Cause: security filtering replaced, so Authenticated
                       Users can no longer READ the GPO. The link is still
                       there, the policy still exists, gpresult shows it as
                       Denied (Inaccessible) - and the GPMC link view looks
                       completely normal.

      AccountLockout   "it keeps locking me out and I'm not even logged in"
                       Cause: a stale credential retrying in the background.
                       The lockout is recorded on the PDC emulator, but the
                       4740 event names the source workstation, which is where
                       the answer is. Resetting the password fixes nothing and
                       the account locks again within the hour.

      DnsMisconfig     "nobody at the site can log in"
                       Cause: the DC's own resolver was pointed at a public
                       server. SRV records stop resolving, clients cannot
                       locate a domain controller, and the DC itself looks
                       perfectly healthy from the console.

    Every fault records what it changed to evidence\fault-state.json, so
    -Repair restores the prior value rather than guessing at a default.

.EXAMPLE
    .\Invoke-FaultInjection.ps1 -Fault GpoNotApplying -Inject
    .\Invoke-FaultInjection.ps1 -Fault GpoNotApplying -Repair

.NOTES
    Lab use only. Never point this at a production domain.
#>

[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSAvoidUsingConvertToSecureStringWithPlainText', '',
    Justification = 'This is a deliberately incorrect password used to drive an account past ' +
                    'the lockout threshold. Failing to authenticate is the entire purpose, so ' +
                    'there is no credential here to protect.'
)]
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)]
    [ValidateSet('GpoNotApplying', 'AccountLockout', 'DnsMisconfig')]
    [string] $Fault,

    [switch] $Inject,
    [switch] $Repair,

    [string] $StatePath = (Join-Path $PSScriptRoot '..\evidence\fault-state.json')
)

$ErrorActionPreference = 'Stop'
Import-Module GroupPolicy -ErrorAction SilentlyContinue

if ($Inject -and $Repair) { throw 'Choose one of -Inject or -Repair.' }
if (-not ($Inject -or $Repair)) { throw 'Specify -Inject or -Repair.' }

function Write-Act  { param($m) Write-Host "   $m" -ForegroundColor Yellow }
function Write-Ok   { param($m) Write-Host "   OK   $m" -ForegroundColor Green }
function Write-Hint { param($m) Write-Host "   $m"  -ForegroundColor DarkGray }

# ---------------------------------------------------------------- state io
function Get-State {
    if (Test-Path $StatePath) { return (Get-Content $StatePath -Raw | ConvertFrom-Json) }
    return [pscustomobject]@{}
}
function Set-State {
    param([string] $Key, $Value)
    $s = Get-State
    $s | Add-Member -NotePropertyName $Key -NotePropertyValue $Value -Force
    $dir = Split-Path $StatePath -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
    $s | ConvertTo-Json -Depth 6 | Set-Content -Path $StatePath -Encoding UTF8
}
function Clear-State {
    param([string] $Key)
    $s = Get-State
    if ($s.PSObject.Properties.Name -contains $Key) {
        $s.PSObject.Properties.Remove($Key)
        $s | ConvertTo-Json -Depth 6 | Set-Content -Path $StatePath -Encoding UTF8
    }
}

# ============================================================= GPO not applying
function Invoke-GpoNotApplying {
    param([switch] $Undo)

    $gpoName = 'MERIDIAN - Workstation Baseline'
    # Fail fast if the GPO is absent; the object itself is not needed.
    Get-GPO -Name $gpoName -ErrorAction Stop | Out-Null

    if ($Undo) {
        Set-GPPermission -Name $gpoName -TargetName 'Authenticated Users' `
                         -TargetType Group -PermissionLevel GpoRead | Out-Null
        Write-Ok "restored Read for Authenticated Users on '$gpoName'"
        Clear-State 'GpoNotApplying'
        Write-Hint 'On the client: gpupdate /force, then gpresult /r'
        return
    }

    Set-State 'GpoNotApplying' @{ Gpo = $gpoName; Removed = 'Authenticated Users : GpoRead' }

    # Removing Read is subtler than unlinking: the link stays visible in GPMC
    # and the policy still exists, so the obvious checks all look correct.
    Set-GPPermission -Name $gpoName -TargetName 'Authenticated Users' `
                     -TargetType Group -PermissionLevel None -Replace | Out-Null

    Write-Act "removed Read permission for Authenticated Users on '$gpoName'"
    Write-Hint ''
    Write-Hint 'Symptom : workstation settings silently stop applying.'
    Write-Hint 'Diagnose: gpresult /r on the client -> the GPO appears under'
    Write-Hint '          "Denied (Inaccessible)" rather than Applied.'
    Write-Hint '          Get-GPPermission -Name "<gpo>" -All  confirms it server-side.'
}

# =============================================================== account lockout
function Invoke-AccountLockout {
    param([switch] $Undo)

    $sam = 'fnasser'
    # Confirm the account exists before trying to lock it.
    Get-ADUser -Identity $sam -ErrorAction Stop | Out-Null

    if ($Undo) {
        Unlock-ADAccount -Identity $sam
        Write-Ok "unlocked $sam"
        Clear-State 'AccountLockout'
        Write-Hint 'In production the unlock is the LAST step, not the first:'
        Write-Hint 'find the source workstation in event 4740 before you unlock,'
        Write-Hint 'or it locks again as soon as the stale credential retries.'
        return
    }

    $policy = Get-ADDefaultDomainPasswordPolicy
    $threshold = $policy.LockoutThreshold
    if ($threshold -eq 0) {
        throw "Lockout threshold is 0 (disabled) - set one in the default domain policy first, or the account cannot lock."
    }

    Set-State 'AccountLockout' @{ Sam = $sam }

    Write-Act "driving $sam past the $threshold-attempt lockout threshold"
    $wrong = ConvertTo-SecureString 'ThisIsNotThePassword!1' -AsPlainText -Force
    $cred = [pscredential]::new("$((Get-ADDomain).NetBIOSName)\$sam", $wrong)

    for ($i = 1; $i -le ($threshold + 1); $i++) {
        try {
            # Any authenticating call works; a directory bind is the cleanest.
            Get-ADUser -Identity $sam -Credential $cred -ErrorAction Stop | Out-Null
        } catch { }
        Write-Host "     attempt $i" -ForegroundColor DarkGray
    }

    $now = Get-ADUser -Identity $sam -Properties LockedOut
    if ($now.LockedOut) { Write-Ok "$sam is locked out" } else { Write-Act "$sam did not lock - check the policy" }

    Write-Hint ''
    Write-Hint 'Diagnose: Search-ADAccount -LockedOut'
    Write-Hint '          Get-WinEvent -FilterHashtable @{LogName="Security";Id=4740} -MaxEvents 5 |'
    Write-Hint '            Format-List TimeCreated, Message'
    Write-Hint '          The 4740 message names the CALLER COMPUTER. That machine'
    Write-Hint '          holds the stale credential - a mapped drive, a scheduled'
    Write-Hint '          task, or a service running as the user.'
}

# ================================================================ DNS misconfig
function Invoke-DnsMisconfig {
    param([switch] $Undo)

    $alias = (Get-NetAdapter -Physical | Where-Object Status -eq 'Up' | Select-Object -First 1).Name

    if ($Undo) {
        $saved = (Get-State).DnsMisconfig
        if (-not $saved) { throw 'No saved DNS state; set the resolver back manually.' }
        Set-DnsClientServerAddress -InterfaceAlias $saved.Alias -ServerAddresses $saved.Servers
        Clear-DnsClientCache
        Write-Ok "restored DNS servers on $($saved.Alias): $($saved.Servers -join ', ')"
        Clear-State 'DnsMisconfig'
        Write-Hint 'Confirm: Resolve-DnsName _ldap._tcp.dc._msdcs.<domain> -Type SRV'
        return
    }

    $current = (Get-DnsClientServerAddress -InterfaceAlias $alias -AddressFamily IPv4).ServerAddresses
    Set-State 'DnsMisconfig' @{ Alias = $alias; Servers = $current }

    # Pointing a DC at a public resolver is a real and common mistake, usually
    # made while "fixing" internet access on the server.
    Set-DnsClientServerAddress -InterfaceAlias $alias -ServerAddresses @('8.8.8.8')
    Clear-DnsClientCache

    Write-Act "set $alias resolver to 8.8.8.8 (was $($current -join ', '))"
    Write-Hint ''
    Write-Hint 'Symptom : clients cannot find a domain controller; logons fail'
    Write-Hint '          at remote sites first.'
    Write-Hint 'Diagnose: Resolve-DnsName _ldap._tcp.dc._msdcs.<domain> -Type SRV'
    Write-Hint '          fails, while the DC console still browses the web fine.'
    Write-Hint '          dcdiag /test:dns  reports the registration failure.'
}

# ---------------------------------------------------------------------- run
$target = "$Fault on $env:COMPUTERNAME"
$action = if ($Inject) { 'INJECT FAULT' } else { 'REPAIR' }

if (-not $PSCmdlet.ShouldProcess($target, $action)) { return }

Write-Host "`n== $action : $Fault" -ForegroundColor Cyan

switch ($Fault) {
    'GpoNotApplying' { Invoke-GpoNotApplying -Undo:$Repair }
    'AccountLockout' { Invoke-AccountLockout -Undo:$Repair }
    'DnsMisconfig'   { Invoke-DnsMisconfig   -Undo:$Repair }
}

Write-Host ''
