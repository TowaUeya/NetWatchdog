Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$shared = Join-Path $env:PUBLIC "NetWatchdog"
$flag   = Join-Path $shared "postreboot.flag"
$log    = Join-Path $shared "PostReboot.log"

function Log($m){
  $ts = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
  Add-Content -Path $log -Value "[$ts] $m"
}

function Wait-Network([int]$timeoutSec = 180){
  $end = (Get-Date).AddSeconds($timeoutSec)
  while((Get-Date) -lt $end){
    try{
      if(Test-NetConnection -ComputerName "www.microsoft.com" -Port 443 -InformationLevel Quiet){
        return $true
      }
    } catch {}
    Start-Sleep -Seconds 5
  }
  return $false
}

try{
  if(!(Test-Path $flag)){
    exit 0
  }

  Log "Flag found. Waiting for network..."
  if(!(Wait-Network -timeoutSec 300)){
    Log "Network not ready after timeout. Will keep flag and exit."
    exit 0
  }

  Log "Network OK. Running python..."

  $python = "python.exe"
  $script = "C:\ProgramData\NetWatchdog\notify_chatwork.py"
  $args   = @()

  $p = Start-Process -FilePath $python -ArgumentList @($script) + $args -Wait -PassThru -WindowStyle Hidden
  Log "Python exit code: $($p.ExitCode)"

  Remove-Item -Force $flag
  Log "Flag removed. Done."
}
catch{
  Log "ERROR: $($_.Exception.Message)"
  exit 1
}
