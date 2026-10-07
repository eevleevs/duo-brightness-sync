#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$TaskName = 'Duo Brightness Sync',
    [switch]$NoStart
)

$ErrorActionPreference = 'Stop'
$daemonName = 'duo-brightness-sync.ps1'
$srcDir = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($srcDir)) { $srcDir = Split-Path -Parent $MyInvocation.MyCommand.Definition }
$daemonSrc = Join-Path $srcDir $daemonName

if (-not (Test-Path -LiteralPath $daemonSrc)) {
    throw "$daemonName not found next to install.ps1 ($daemonSrc)"
}

Write-Host 'Running preflight checks...'
$probeOutput = & "$PSHOME\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File $daemonSrc -Probe
$probeOutput | ForEach-Object { Write-Host "  $_" }
if ($LASTEXITCODE -ne 0) {
    throw 'Preflight failed - not installing. Fix the issues above and re-run install.ps1.'
}

$installDir = Join-Path $env:LOCALAPPDATA 'duo-brightness-sync'
$daemonDst = Join-Path $installDir $daemonName
$currentUser = [Security.Principal.WindowsIdentity]::GetCurrent().Name

Write-Host "Stopping any running instance..."
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
    Where-Object { $_.CommandLine -like "*$daemonName*" } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }

Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue

Write-Host "Installing daemon -> $daemonDst"
New-Item -ItemType Directory -Path $installDir -Force | Out-Null
Copy-Item -LiteralPath $daemonSrc -Destination $daemonDst -Force

Write-Host "Registering scheduled task '$TaskName' (at logon, current user, no admin needed)..."
$exe = Join-Path $PSHOME 'powershell.exe'
$action = New-ScheduledTaskAction -Execute $exe `
    -Argument "-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$daemonDst`""
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $currentUser
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit ([TimeSpan]::Zero)
$principal = New-ScheduledTaskPrincipal -UserId $currentUser -LogonType Interactive -RunLevel Limited
Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings `
    -Principal $principal -Force | Out-Null

$xml = Export-ScheduledTask -TaskName $TaskName
if ($xml -match '<ExecutionTimeLimit>([^<]+)</ExecutionTimeLimit>') {
    Write-Host "  ExecutionTimeLimit: $($Matches[1]) (PT0S = unlimited)"
}
if ($xml -match '<UserId>([^<]+)</UserId>') {
    Write-Host "  runs as: $($Matches[1])"
}

if (-not $NoStart) {
    Write-Host 'Starting...'
    Start-ScheduledTask -TaskName $TaskName
    Start-Sleep -Seconds 5
    $task = Get-ScheduledTask -TaskName $TaskName
    Write-Host "  task state: $($task.State)"
    $log = Join-Path $installDir 'duo-brightness-sync.log'
    if (Test-Path -LiteralPath $log) {
        Write-Host '  last log lines:'
        Get-Content -LiteralPath $log -Tail 4 | ForEach-Object { Write-Host "    $_" }
    } else {
        Write-Host '  WARNING: log file not yet created'
    }
}

Write-Host ''
Write-Host 'Done. Tail the log with:'
Write-Host "  Get-Content -Wait `"$installDir\duo-brightness-sync.log`""
Write-Host 'Uninstall with: ./uninstall.ps1'
