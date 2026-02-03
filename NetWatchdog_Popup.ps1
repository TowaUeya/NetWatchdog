# NetWatchdog_Popup.ps1
# Runs in an INTERACTIVE user session (Task Scheduler: "Run only when user is logged on").
# Trigger: On Event (Application log), Source=NetWatchdog, Event ID=910.
# Behavior: Reads state.json under C:\Users\Public\NetWatchdog, shows an OK/Cancel popup for remaining seconds.
# If Cancel: writes canceledToken to state.json (no admin needed), Watchdog will observe and skip reboot.

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$SharedDir = Join-Path $env:PUBLIC "NetWatchdog"
$StatePath = Join-Path $SharedDir "state.json"
$LogPath   = Join-Path $SharedDir "Popup.log"

function Log($msg) {
  $ts = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
  Add-Content -Path $LogPath -Value "[$ts] $msg"
}

function Load-State {
  if (Test-Path $StatePath) {
    try { return (Get-Content $StatePath -Raw | ConvertFrom-Json) } catch { }
  }
  return $null
}

function Save-State($state) {
  ($state | ConvertTo-Json -Depth 5) | Set-Content -Path $StatePath -Encoding UTF8
}

function Show-CancelPopup([string]$message, [int]$timeoutSec) {
  $ws = New-Object -ComObject WScript.Shell
  # 1=OK/Cancel, 48=Exclamation, 4096=System modal
  $type = 1 + 48 + 4096
  $ret = $ws.Popup($message, $timeoutSec, "Network Watchdog", $type)
  switch ($ret) {
    -1 { return "Timeout" }
     1 { return "OK" }
     2 { return "Cancel" }
     default { return "Unknown" }
  }
}

try {
  if (-not (Test-Path $SharedDir)) { exit 0 }
  Log "Popup started."

  $state = Load-State
  if (-not $state) { Log "No state.json."; exit 0 }
  if (-not $state.pendingToken -or -not $state.pendingUntilUtc) { Log "No pending info."; exit 0 }

  $until = [DateTime]::Parse($state.pendingUntilUtc).ToUniversalTime()
  $remain = [int][Math]::Ceiling(($until - [DateTime]::UtcNow).TotalSeconds)
  if ($remain -le 0) { Log "Pending already expired."; exit 0 }

  $token = [string]$state.pendingToken

  $msg = @"
インターネット接続が復旧しないため、PCを再起動します。
・キャンセルを押すと中止できます（以後しばらく警告しません）
・何もしなければ ${remain} 秒後に再起動コマンドを実行します
"@

  $ans = Show-CancelPopup -message $msg -timeoutSec $remain
  Log "Popup result: $ans (token=$token, remain=$remain)"

  if ($ans -eq "Cancel") {
    # Mark cancel for this token
    $state.lastCancelUtc = [DateTime]::UtcNow.ToString("o")
    $state.canceledToken = $token
    Save-State $state
    Log "Cancel recorded for token=$token."
  }
}
catch {
  try { Log "ERROR: $($_.Exception.Message)" } catch { }
  exit 1
}
