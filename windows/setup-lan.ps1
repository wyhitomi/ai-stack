<#
.SYNOPSIS
  Expose ai-stack (running in WSL2) to your LAN.

.DESCRIPTION
  Mirrored mode (default, recommended — Windows 11 22H2+):
    * writes %UserProfile%\.wslconfig with networkingMode=mirrored (backs up an existing one)
    * opens the Hyper-V firewall (which filters mirrored WSL traffic) for the stack ports
    * opens the regular Windows firewall for the same ports, Private profile only

  NAT mode (-Mode Nat, for Windows 10 / older WSL):
    * forwards Windows:<port> -> <WSL IP>:<port> with netsh portproxy
    * the WSL IP changes on every reboot: re-run this script (or schedule it at logon)

.EXAMPLE
  # PowerShell as Administrator
  Set-ExecutionPolicy -Scope Process Bypass
  .\setup-lan.ps1                   # mirrored mode
  .\setup-lan.ps1 -Mode Nat         # NAT + portproxy
  .\setup-lan.ps1 -Remove           # undo firewall rules / port proxies
#>
[CmdletBinding()]
param(
  [ValidateSet('Mirrored', 'Nat')] [string] $Mode = 'Mirrored',
  [int[]] $Ports = @(4000, 8642),
  # Restrict to your LAN. 'LocalSubnet' = same subnet as this PC.
  [string] $RemoteAddress = 'LocalSubnet',
  [string] $Distro = '',
  [switch] $Remove
)

$ErrorActionPreference = 'Stop'
$RulePrefix = 'ai-stack'
# Fixed GUID that identifies the WSL VM to the Hyper-V firewall.
$WslVmCreatorId = '{40E0AC32-46A5-438A-A0B2-2B479E8F2E90}'

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)) {
  throw 'Run this script from an elevated (Administrator) PowerShell.'
}

function Remove-StackRules {
  Get-NetFirewallRule -DisplayName "$RulePrefix*" -ErrorAction SilentlyContinue | Remove-NetFirewallRule
  if (Get-Command Get-NetFirewallHyperVRule -ErrorAction SilentlyContinue) {
    Get-NetFirewallHyperVRule -Name "$RulePrefix*" -ErrorAction SilentlyContinue | Remove-NetFirewallHyperVRule
  }
  foreach ($p in $Ports) { netsh interface portproxy delete v4tov4 listenport=$p listenaddress=0.0.0.0 2>$null | Out-Null }
}

if ($Remove) { Remove-StackRules; Write-Host 'Removed ai-stack firewall rules and port proxies.'; return }

Remove-StackRules   # idempotent re-run

# Regular Windows firewall — Private network profile only (never Public Wi-Fi).
New-NetFirewallRule -DisplayName "$RulePrefix inbound" -Direction Inbound -Action Allow `
  -Protocol TCP -LocalPort $Ports -RemoteAddress $RemoteAddress -Profile Private | Out-Null

if ($Mode -eq 'Mirrored') {
  $cfg = Join-Path $env:USERPROFILE '.wslconfig'
  $src = Join-Path $PSScriptRoot 'wslconfig.example'
  if (Test-Path $cfg) {
    if (-not (Select-String -Path $cfg -Pattern '^\s*networkingMode\s*=\s*mirrored' -Quiet)) {
      Copy-Item $cfg "$cfg.bak-$(Get-Date -Format yyyyMMddHHmmss)"
      Write-Warning ".wslconfig exists without mirrored mode. Backed it up; merge networkingMode=mirrored from $src by hand."
    }
  } else {
    Copy-Item $src $cfg
    Write-Host "Wrote $cfg"
  }

  if (Get-Command New-NetFirewallHyperVRule -ErrorAction SilentlyContinue) {
    foreach ($p in $Ports) {
      New-NetFirewallHyperVRule -Name "$RulePrefix-$p" -DisplayName "$RulePrefix $p" `
        -Direction Inbound -VMCreatorId $WslVmCreatorId -Protocol TCP -LocalPorts $p -Action Allow | Out-Null
    }
    Write-Host "Opened Hyper-V firewall for WSL on ports $($Ports -join ', ')"
  } else {
    Write-Warning 'Hyper-V firewall cmdlets not found (older Windows). Use -Mode Nat instead.'
  }

  Write-Host "`nNow run:  wsl --shutdown   then start WSL and 'docker compose up -d' again."
}
else {
  $wslArgs = @(); if ($Distro) { $wslArgs = @('-d', $Distro) }
  $wslIp = (wsl @wslArgs -- hostname -I).Trim().Split(' ')[0]
  if (-not $wslIp) { throw 'Could not read the WSL IP. Is WSL running?' }
  foreach ($p in $Ports) {
    netsh interface portproxy add v4tov4 listenport=$p listenaddress=0.0.0.0 connectport=$p connectaddress=$wslIp | Out-Null
  }
  Write-Host "Forwarding ports $($Ports -join ', ') -> $wslIp"
  Write-Warning 'The WSL IP changes on reboot. Re-run this script after each restart (or add it to Task Scheduler at logon).'
}

$lan = (Get-NetIPConfiguration | Where-Object { $_.IPv4DefaultGateway -and $_.NetAdapter.Status -eq 'Up' } |
        Select-Object -First 1).IPv4Address.IPAddress
Write-Host "`nFrom another LAN machine:"
Write-Host "  curl http://${lan}:4000/health/liveliness"
Write-Host "  LiteLLM base URL: http://${lan}:4000/v1"
Write-Host "`nMake sure this network is set to 'Private' in Windows Settings > Network."
