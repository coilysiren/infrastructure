#requires -Version 5.1
<#
.SYNOPSIS
  Register the Claude Code remote-control daemon as a per-user Scheduled
  Task on the Windows-native side of kai-desktop-tower.

.DESCRIPTION
  This host registers as 'kai-desktop-tower-native' in claude.ai/code's
  Remote Control dropdown. The WSL installer registers the same physical
  tree (X:\projects-x <-> /mnt/x/projects-x) as
  'kai-desktop-tower-wsl'; the two --name values must stay distinct or
  the dropdown collapses them.

  Idempotent: re-run after changing the workdir or claude location.
  Bail-don't-overwrite on unexpected pre-existing .claude.json values.

  Run as the interactive user (firem) in a non-elevated PowerShell.

.NOTES
  Prereqs:
    - npm-global `claude` installed under the running user's profile.
    - `claude login` already completed against the active claude.ai
      subscription.
    - X:\projects-x reachable.
#>

[CmdletBinding()]
param(
  [string]$WorkDir   = 'X:\projects-x',
  [string]$Name      = 'kai-desktop-tower-native',
  [string]$TaskName  = 'ClaudeRemoteControl',
  [string]$RestartTaskName = 'ClaudeRemoteControlDailyRestart'
)

$ErrorActionPreference = 'Stop'

function Fail($msg) { Write-Error $msg; exit 1 }

if (-not (Test-Path -LiteralPath $WorkDir)) {
  Fail "Workdir $WorkDir not reachable. Confirm the X: drive is attached and the projects-x tree exists."
}

# --- locate claude ----------------------------------------------------
# Get-Command at install time, bake the resolved path into the Scheduled
# Task action. No hardcoded paths. Prefer .cmd over .ps1: Task Scheduler
# can launch a .cmd directly, but a .ps1 has to be wrapped in
# powershell.exe -File.
$claudeCmd = Get-Command claude -ErrorAction SilentlyContinue
if (-not $claudeCmd) {
  Fail "claude not found on PATH for user $env:USERNAME. Install the npm package and re-run (do NOT hardcode a path)."
}
$claudeExe = $claudeCmd.Source
if ($claudeExe -like '*.ps1') {
  $siblingCmd = [System.IO.Path]::ChangeExtension($claudeExe, 'cmd')
  if (Test-Path -LiteralPath $siblingCmd) {
    $claudeExe = $siblingCmd
  } else {
    Fail "Resolved claude as $claudeExe but no sibling .cmd found. Task Scheduler cannot launch a .ps1 directly."
  }
}
Write-Host "==> resolved claude: $claudeExe"

# --- verify remote-control subcommand exists --------------------------
# Run the subcommand's own --help and check exit code; help-text parsing
# of `claude --help` is brittle across platforms.
$null = & $claudeExe remote-control --help 2>&1
if ($LASTEXITCODE -ne 0) {
  Fail "``$claudeExe remote-control --help`` exited with $LASTEXITCODE. The Windows-native Claude build does not support remote-control; upgrade before re-running."
}
Write-Host '==> claude remote-control subcommand present'

# --- patch %USERPROFILE%\.claude.json --------------------------------
$claudeJson = Join-Path $env:USERPROFILE '.claude.json'
if (-not (Test-Path -LiteralPath $claudeJson)) {
  Fail "$claudeJson missing. Run `claude login` once as $env:USERNAME before re-running this installer."
}

$json = Get-Content -LiteralPath $claudeJson -Raw | ConvertFrom-Json

function Assert-OkOrUnset($obj, $prop) {
  if ($obj.PSObject.Properties.Name -contains $prop) {
    if ($obj.$prop -ne $true) {
      Fail "$prop already set to a non-true value in $claudeJson; refusing to overwrite. Inspect and resolve by hand."
    }
  }
}

Assert-OkOrUnset $json 'remoteControlAtStartup'
Assert-OkOrUnset $json 'remoteDialogSeen'

if (-not ($json.PSObject.Properties.Name -contains 'projects')) {
  $json | Add-Member -NotePropertyName 'projects' -NotePropertyValue ([pscustomobject]@{})
}
if (-not ($json.projects.PSObject.Properties.Name -contains $WorkDir)) {
  $json.projects | Add-Member -NotePropertyName $WorkDir -NotePropertyValue ([pscustomobject]@{})
}
Assert-OkOrUnset $json.projects.$WorkDir 'hasTrustDialogAccepted'

function Set-Prop($obj, $prop, $val) {
  if ($obj.PSObject.Properties.Name -contains $prop) {
    $obj.$prop = $val
  } else {
    $obj | Add-Member -NotePropertyName $prop -NotePropertyValue $val
  }
}

Set-Prop $json 'remoteControlAtStartup' $true
Set-Prop $json 'remoteDialogSeen' $true
Set-Prop $json.projects.$WorkDir 'hasTrustDialogAccepted' $true

# Atomic write: temp file in same dir, then move-and-replace.
$tmp = "$claudeJson.tmp"
$json | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $tmp -Encoding UTF8 -NoNewline
Move-Item -LiteralPath $tmp -Destination $claudeJson -Force
Write-Host "==> patched $claudeJson"

# --- register main Scheduled Task (run at logon) ----------------------
# Run as the interactive user, not SYSTEM, so the user-scoped claude
# config and PATH apply. The task's own -WorkingDirectory handles cwd;
# `claude remote-control` does not accept a --working-directory flag.
# --name labels the pre-created session; --remote-control-session-name-prefix
# drives the bottom line of the dropdown row (default `hostname` would
# collide with WSL inside this same tower).
$argLine = "remote-control --spawn same-dir --name $Name --remote-control-session-name-prefix $Name"
$action = New-ScheduledTaskAction -Execute $claudeExe -Argument $argLine -WorkingDirectory $WorkDir
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
Write-Host "==> registered Scheduled Task '$TaskName' (runs at logon as $env:USERNAME)"

# --- register daily 03:00 restart task --------------------------------
$restartAction = New-ScheduledTaskAction `
  -Execute 'powershell.exe' `
  -Argument "-NoProfile -WindowStyle Hidden -Command `"Stop-ScheduledTask -TaskName '$TaskName' -ErrorAction SilentlyContinue; Start-Sleep -Seconds 5; Start-ScheduledTask -TaskName '$TaskName'`""
$restartTrigger = New-ScheduledTaskTrigger -Daily -At 3am
$restartTrigger.RandomDelay = 'PT5M'  # matches kai-server timer's 5min jitter

if (Get-ScheduledTask -TaskName $RestartTaskName -ErrorAction SilentlyContinue) {
  Unregister-ScheduledTask -TaskName $RestartTaskName -Confirm:$false
}
Register-ScheduledTask -TaskName $RestartTaskName -Action $restartAction -Trigger $restartTrigger -Settings $settings -Principal $principal | Out-Null
Write-Host "==> registered Scheduled Task '$RestartTaskName' (daily 03:00 +/- 5min)"

# --- start the main task now ------------------------------------------
Start-ScheduledTask -TaskName $TaskName
Write-Host ''
Write-Host "==> '$TaskName' started. In claude.ai/code the Remote Control dropdown should now list 'kai-desktop-tower-native'."
Write-Host 'Verify with:'
Write-Host "  Get-ScheduledTask -TaskName $TaskName | Get-ScheduledTaskInfo"
Write-Host "  Get-Process -Name claude -ErrorAction SilentlyContinue"
