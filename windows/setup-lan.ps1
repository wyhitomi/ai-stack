<#
.SYNOPSIS
  Expose ai-stack (running in WSL2) to your HOME LAN only.

.DESCRIPTION
  Mirrored mode (default, recommended — Windows 11 22H2+):
    * writes %UserProfile%\.wslconfig with networkingMode=mirrored (backs up an existing one)
    * opens the Hyper-V firewall (which filters mirrored WSL traffic) for the stack ports,
      restricted to your LAN subnet
    * opens the regular Windows firewall for the same ports: Private profile + LAN subnet only

  NAT mode (-Mode Nat, for older Windows / WSL):
    * forwards Windows:<port> -> <WSL IP>:<port> with netsh portproxy
    * the WSL IP changes on every reboot: re-run this script (or schedule it at logon)

  Only LiteLLM (4000) and Hermes (8642) are opened. Postgres, Hindsight and the
  model servers never listen on the network.

.EXAMPLE
  # PowerShell as Administrator
  Set-ExecutionPolicy -Scope Process Bypass
  .\setup-lan.ps1                     # mirrored mode, LAN subnet auto-detected
  .\setup-lan.ps1 -LanSubnet 192.168.1.0/24
  .\setup-lan.ps1 -Mode Nat           # NAT + portproxy
  .\setup-lan.ps1 -Remove             # undo firewall rules / port proxies
#>
[CmdletBinding()]
param(
  [ValidateSet('Mirrored', 'Nat')] [string] $Mode = 'Mirrored',
  [int[]] $Ports = @(4000, 8642),
  # Your home LAN, e.g. 192.168.1.0/24. Empty = detect from the active adapter.
  [string] $LanSubnet = '',
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

function Get-LanSubnet {
  # The IPv4 network of the adapter that holds the default route, as a.b.c.d/nn
  $cfg = Get-NetIPConfiguration | Where-Object { $_.IPv4DefaultGateway -and $_.NetAdapter.Status -eq 'Up' } |
         Select-Object -First 1
  if (-not $cfg) { throw 'No active network adapter with a default gateway. Pass -LanSubnet.' }
  $addr = $cfg.IPv4Address | Select-Object -First 1
  $prefix = [int]$addr.PrefixLength
  $bytes = ([Net.IPAddress]::Parse($addr.IPAddress)).GetAddressBytes()
  [Array]::Reverse($bytes)
  $ip = [BitConverter]::ToUInt32($bytes, 0)
  # 4294967295 = 0xFFFFFFFF (a hex literal would parse as Int32 -1)
  $mask = if ($prefix -eq 0) { [uint32]0 } else { [uint32](([uint64]4294967295 -shl (32 - $prefix)) -band [uint64]4294967295) }
  $net = [BitConverter]::GetBytes([uint32]($ip -band $mask))
  [Array]::Reverse($net)
  return ('{0}/{1}' -f ([Net.IPAddress]::new($net)).ToString(), $prefix)
}

function Remove-StackRules {
  Get-NetFirewallRule -DisplayName "$RulePrefix*" -ErrorAction SilentlyContinue | Remove-NetFirewallRule
  if (Get-Command Get-NetFirewallHyperVRule -ErrorAction SilentlyContinue) {
    Get-NetFirewallHyperVRule -Name "$RulePrefix*" -ErrorAction SilentlyContinue | Remove-NetFirewallHyperVRule
  }
  foreach ($p in $Ports) { netsh interface portproxy delete v4tov4 listenport=$p listenaddress=0.0.0.0 2>$null | Out-Null }
}

if ($Remove) { Remove-StackRules; Write-Host 'Removed ai-stack firewall rules and port proxies.'; return }

if (-not $LanSubnet) { $LanSubnet = Get-LanSubnet }
Write-Host "Home LAN subnet: $LanSubnet  (only this range can reach ports $($Ports -join ', '))"

Remove-StackRules   # idempotent re-run

# Regular Windows firewall — Private network profile and LAN subnet only.
New-NetFirewallRule -DisplayName "$RulePrefix inbound (LAN)" -Direction Inbound -Action Allow `
  -Protocol TCP -LocalPort $Ports -RemoteAddress $LanSubnet -Profile Private | Out-Null

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
      $rule = @{
        Name = "$RulePrefix-$p"; DisplayName = "$RulePrefix $p (LAN)"; Direction = 'Inbound'
        VMCreatorId = $WslVmCreatorId; Protocol = 'TCP'; LocalPorts = $p; Action = 'Allow'
      }
      try {
        New-NetFirewallHyperVRule @rule -RemoteAddresses $LanSubnet | Out-Null
      } catch {
        # Older builds lack -RemoteAddresses: the port is then open to any source
        # the Hyper-V firewall sees. Keep the network Private and the router closed.
        Write-Warning "Hyper-V firewall on this Windows build can't filter by source; port $p allowed without a subnet filter."
        New-NetFirewallHyperVRule @rule | Out-Null
      }
    }
    Write-Host "Opened Hyper-V firewall for WSL on ports $($Ports -join ', ') from $LanSubnet"
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
  Write-Host "Forwarding ports $($Ports -join ', ') -> $wslIp (Windows firewall limits it to $LanSubnet)"
  Write-Warning 'The WSL IP changes on reboot. Re-run this script after each restart (or add it to Task Scheduler at logon).'
}

$lan = (Get-NetIPConfiguration | Where-Object { $_.IPv4DefaultGateway -and $_.NetAdapter.Status -eq 'Up' } |
        Select-Object -First 1).IPv4Address.IPAddress
Write-Host "`nFrom another machine on the home LAN:"
Write-Host "  curl http://${lan}:4000/health/liveliness"
Write-Host "  LiteLLM base URL: http://${lan}:4000/v1"
Write-Host "`nSet this network to 'Private' in Windows Settings > Network (the rule only applies there)."
Write-Host "Laptop on another network (café, office)? Public profile + different subnet = nothing is reachable."
