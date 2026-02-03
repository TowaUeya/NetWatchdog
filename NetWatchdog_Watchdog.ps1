# NetWatchdog_Watchdog.ps1
# Runs as SYSTEM (non-interactive). Checks connectivity; on failure does backoff (3m,3m,4m).
# If still down: writes a state file under C:\Users\Public\NetWatchdog, emits an event (Application log),
# waits up to 60s for cancellation, then rechecks and reboots if still down and not canceled.
#
# Schedule: every 10 minutes (or OnStart + repeat 10m). "Run whether user is logged on or not".
#          Check "Run with highest privileges".

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ----------------------
# Config
# ----------------------
$Targets = @(
  @{ Host = "www.microsoft.com"; Port = 443 },
  @{ Host = "www.google.com";    Port = 443 },
  @{ Host = "cloudflare.com";    Port = 443 }
)

$RetrySleeps   = @(180, 180, 180)   # 3m,3m,3m
$WarnCountdown = 60                # seconds shown to user before reboot attempt
$CooldownSec   = 30 * 60           # after a cancel, do nothing for 30 min
$MinGapBetweenActionsSec = 15 * 60 # avoid spamming events/reboot attempts

# Shared directory that standard users can write
$SharedDir = Join-Path $env:PUBLIC "NetWatchdog"
$StatePath = Join-Path $SharedDir "state.json"
$LogPath   = Join-Path $SharedDir "NetWatchdog.log"

# Event settings
$EventLogName = "Application"
$EventSource  = "NetWatchdog"
$EventIdDown  = 910
$EventIdInfo  = 911

# ----------------------
# Utilities
# ----------------------
function Log($msg) {
  $ts = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
  Add-Content -Path $LogPath -Value "[$ts] $msg"
}

function Ensure-SharedDir {
  if (-not (Test-Path $SharedDir)) {
    New-Item -ItemType Directory -Path $SharedDir -Force | Out-Null
  }
}

function Load-State {
  if (Test-Path $StatePath) {
    try { return (Get-Content $StatePath -Raw | ConvertFrom-Json) } catch { }
  }
  return [pscustomobject]@{
    lastCancelUtc = $null
    lastActionUtc = $null
    pendingToken  = $null
    pendingUntilUtc = $null
    canceledToken = $null
  }
}

function Save-State($state) {
  ($state | ConvertTo-Json -Depth 5) | Set-Content -Path $StatePath -Encoding UTF8
}

function Is-Online {
  foreach ($t in $Targets) {
    try {
      if (Test-NetConnection -ComputerName $t.Host -Port $t.Port -InformationLevel Quiet) { return $true }
    } catch { }
  }
  return $false
}

function Emit-Event([string]$type, [int]$id, [string]$msg) {
  # Use eventcreate so we don't need to pre-register an event source.
  # /t: ERROR|WARNING|INFORMATION
  $safe = $msg.Replace('"','''')
  & eventcreate.exe /l $EventLogName /t $type /id $id /so $EventSource /d $safe | Out-Null
}

# ----------------------
# Single-instance guard (mutex)
# ----------------------
$mutex = New-Object System.Threading.Mutex($false, "Global\NetWatchdog_Mutex")
if (-not $mutex.WaitOne(0)) { exit 0 }

try {
  Ensure-SharedDir
  Log "Run started."

  $state = Load-State

  # Cancel cooldown
  if ($state.lastCancelUtc) {
    $lastCancel = [DateTime]::Parse($state.lastCancelUtc).ToUniversalTime()
    $elapsed = ([DateTime]::UtcNow - $lastCancel).TotalSeconds
    if ($elapsed -lt $CooldownSec) {
      Log "In cancel cooldown (${elapsed}s < ${CooldownSec}s). Exit."
      exit 0
    }
  }

  # Don't spam actions
  if ($state.lastActionUtc) {
    $lastAction = [DateTime]::Parse($state.lastActionUtc).ToUniversalTime()
    $elapsedA = ([DateTime]::UtcNow - $lastAction).TotalSeconds
    if ($elapsedA -lt $MinGapBetweenActionsSec) {
      Log "Within min gap between actions (${elapsedA}s < ${MinGapBetweenActionsSec}s). Exit."
      exit 0
    }
  }

  if (Is-Online) {
    Log "Network OK."
    exit 0
  }

  Log "Network DOWN. Starting retries..."
  foreach ($s in $RetrySleeps) {
    Log "Sleep ${s}s then recheck..."
    Start-Sleep -Seconds $s
    if (Is-Online) {
      Log "Recovered during retries."
      exit 0
    }
  }

  # Still down -> arm pending reboot window and signal Popup task by writing an event
  $token = [guid]::NewGuid().ToString()
  $until = [DateTime]::UtcNow.AddSeconds($WarnCountdown)

  $state.pendingToken = $token
  $state.pendingUntilUtc = $until.ToString("o")
  $state.canceledToken = $null
  $state.lastActionUtc = [DateTime]::UtcNow.ToString("o")
  Save-State $state

  $msg = "Network still down after retries. Showing user warning; will reboot in ${WarnCountdown}s unless canceled. token=${token}"
  Log $msg
  Emit-Event -type "WARNING" -id $EventIdDown -msg $msg

  # Wait the countdown, but check for cancel once per second so cancel feels immediate
  $end = [DateTime]::UtcNow.AddSeconds($WarnCountdown)
  while ([DateTime]::UtcNow -lt $end) {
    Start-Sleep -Seconds 1
    $st = Load-State
    if ($st.canceledToken -and $st.canceledToken -eq $token) {
      Log "Cancel observed for token=$token. No reboot."
      Emit-Event -type "INFORMATION" -id $EventIdInfo -msg "User canceled reboot. token=${token}"
      exit 0
    }
  }

  # Before reboot: recheck network (could have recovered while warning was displayed)
  if (Is-Online) {
    Log "Recovered during warning window. No reboot."
    Emit-Event -type "INFORMATION" -id $EventIdInfo -msg "Recovered during warning window. token=${token}"
    exit 0
  }

  Log "Proceeding to reboot now (token=$token)."
  # Force close apps to ensure reboot happens and remote access recovers
  & shutdown.exe /r /f /c "NetWatchdog: network down; rebooting to recover remote access" | Out-Null
}
catch {
  try { Ensure-SharedDir; Log "ERROR: $($_.Exception.Message)" } catch { }
  exit 1
}
finally {
  $mutex.ReleaseMutex() | Out-Null
  $mutex.Dispose()
}
