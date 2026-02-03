# NetWatchdog - Setup Guide

## Shared state/log directory:
- C:\Users\Public\NetWatchdog\
  - state.json, NetWatchdog.log, Popup.log

## Install location suggestion:
- Put scripts under: C:\ProgramData\NetWatchdog\
  - NetWatchdog_Watchdog.ps1
  - NetWatchdog_Popup.ps1

## TASK 1: "NetWatchdog - Watchdog" (SYSTEM)
- General:
  - Run whether user is logged on or not
  - Run with highest privileges
  - User account: NT AUTHORITY\SYSTEM
- Triggers:
  - At startup (optional) with delay 2 minutes
  - Repeat every 10 minutes indefinitely
- Actions:
  - Program: powershell.exe
  - Arguments:
    -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "C:\ProgramData\NetWatchdog\NetWatchdog_Watchdog.ps1"
- Settings:
  - If the task is already running: Do not start a new instance

## TASK 2: "NetWatchdog - Popup" (interactive user)
- General:
  - Run only when user is logged on
  - Choose the user account you normally remote in with (so the popup appears in that desktop)
- Trigger:
  - On an event:
    - Log: Application
    - Source: NetWatchdog
    - Event ID: 910
- Actions:
  - Program: powershell.exe
  - Arguments:
    -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "C:\ProgramData\NetWatchdog\NetWatchdog_Popup.ps1"

## How it works:
- Watchdog checks TCP(443) connectivity to several sites.
- If down: waits 3m,3m,3m; still down -> writes state.json and emits event 910 (Application log).
- Popup task triggers on that event, reads state.json and shows OK/Cancel.
- Cancel writes canceledToken back; Watchdog notices during its 60s countdown and skips reboot.
- If nobody is logged on: Popup won't show (by design), Watchdog still reboots to recover remote access.
