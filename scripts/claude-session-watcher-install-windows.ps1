#requires -Version 5.1
<#
.SYNOPSIS
  Install the Claude session watcher as a per-user Scheduled Task on the
  Windows-native side of kai-desktop-tower.

.DESCRIPTION
  Component 1 of the cross-machine session-aggregation pipeline
  (coilyco-flight-deck/infrastructure#224). Watches %USERPROFILE%\.claude\projects
  for session-file changes and HTTP POSTs each one to the tailnet-only
  session-sink on kai-server.

  Idempotent: re-run to upgrade the script, refresh the venv, or change
  the machine id. Run as the interactive user in a non-elevated
  PowerShell.

  SESSION_SINK_URL is resolved from SSM (/coilysiren/session-sink/url) or
  taken from the SESSION_SINK_URL env var. It embeds a tailnet FQDN (an
  opaque id), so it is never committed - it lands only in the local
  launcher .cmd inside the install dir.

.PARAMETER Machine
  Stable machine id sent to the sink. Default 'kai-desktop-tower-native'.

.PARAMETER SinkUrl
  Override the sink URL instead of resolving it from SSM.

.PARAMETER Uninstall
  Remove the Scheduled Task and install dir.

.NOTES
  Prereqs: uv on PATH, aws CLI configured (unless -SinkUrl is passed).
#>

[CmdletBinding()]
param(
  [string]$Machine = 'kai-desktop-tower-native',
  [string]$SinkUrl = '',
  [switch]$Uninstall
)

$ErrorActionPreference = 'Stop'
function Fail($msg) { Write-Error $msg; exit 1 }

$TaskName   = 'ClaudeSessionWatcher'
$InstallDir = Join-Path $env:USERPROFILE '.local\share\claude-session-watcher'
$SsmParam   = '/coilysiren/session-sink/url'

if ($Uninstall) {
  if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
    Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    Write-Host "==> removed Scheduled Task '$TaskName'"
  }
  if (Test-Path -LiteralPath $InstallDir) {
    Remove-Item -LiteralPath $InstallDir -Recurse -Force
    Write-Host "==> removed install dir $InstallDir"
  }
  Write-Host 'done. %USERPROFILE%\.claude\projects is untouched.'
  exit 0
}

# --- locate uv --------------------------------------------------------
$uv = Get-Command uv -ErrorAction SilentlyContinue
if (-not $uv) { Fail 'uv not found on PATH. Install uv and re-run.' }

# --- resolve the sink URL --------------------------------------------
if (-not $SinkUrl) { $SinkUrl = $env:SESSION_SINK_URL }
if (-not $SinkUrl) {
  Write-Host "==> resolve SESSION_SINK_URL from SSM $SsmParam"
  try {
    $SinkUrl = (& aws ssm get-parameter --name $SsmParam --with-decryption `
      --query Parameter.Value --output text 2>$null).Trim()
  } catch { $SinkUrl = '' }
}
if (-not $SinkUrl -or $SinkUrl -eq 'None') {
  Fail ("Could not resolve the session-sink URL. Pass -SinkUrl explicitly, " +
        "or create the SSM param $SsmParam once the session-sink Flask app ships.")
}

# --- provision install dir + venv ------------------------------------
$repoDir = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$srcScript = Join-Path $repoDir 'scripts\claude-session-watcher.py'
if (-not (Test-Path -LiteralPath $srcScript)) {
  Fail "watcher script not found at $srcScript"
}
New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
Copy-Item -LiteralPath $srcScript -Destination (Join-Path $InstallDir 'claude-session-watcher.py') -Force

$venvDir = Join-Path $InstallDir 'venv'
$venvPy  = Join-Path $venvDir 'Scripts\python.exe'
if (-not (Test-Path -LiteralPath $venvPy)) {
  & uv venv $venvDir
}
& uv pip install --python $venvPy --quiet watchdog requests
Write-Host "==> provisioned venv at $venvDir"

# --- write the launcher .cmd (carries env, opaque URL stays local) ---
# Task Scheduler actions do not carry environment variables cleanly, so
# a thin .cmd sets them and execs the watcher.
$launcher = Join-Path $InstallDir 'run-watcher.cmd'
$launcherBody = @"
@echo off
set "SESSION_SINK_URL=$SinkUrl"
set "SESSION_WATCHER_MACHINE=$Machine"
"$venvPy" "$InstallDir\claude-session-watcher.py"
"@
Set-Content -LiteralPath $launcher -Value $launcherBody -Encoding ASCII
Write-Host "==> wrote launcher $launcher"

# --- register the Scheduled Task (run at logon) ----------------------
$action = New-ScheduledTaskAction -Execute $launcher -WorkingDirectory $InstallDir
$trigger = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"
$settings = New-ScheduledTaskSettingsSet `
  -AllowStartIfOnBatteries `
  -DontStopIfGoingOnBatteries `
  -StartWhenAvailable `
  -RestartCount 5 `
  -RestartInterval (New-TimeSpan -Minutes 1) `
  -ExecutionTimeLimit ([TimeSpan]::Zero)
$principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Limited

if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
  Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
}
Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings -Principal $principal | Out-Null
Start-ScheduledTask -TaskName $TaskName

Write-Host ''
Write-Host "installed. machine id: $Machine"
Write-Host 'Verify with:'
Write-Host "  Get-ScheduledTask -TaskName $TaskName | Get-ScheduledTaskInfo"
Write-Host "  Get-Process -Name python -ErrorAction SilentlyContinue"
