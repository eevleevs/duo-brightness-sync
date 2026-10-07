#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$TaskName = 'Duo Brightness Sync',
    [switch]$KeepLog
)

$ErrorActionPreference = 'Stop'
$daemonName = 'duo-brightness-sync.ps1'
$installDir = Join-Path $env:LOCALAPPDATA 'duo-brightness-sync'

Write-Host "Stopping scheduled task '$TaskName'..."
Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue

Write-Host 'Stopping running daemon processes...'
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
    Where-Object { $_.CommandLine -like "*$daemonName*" } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }

if (Test-Path -LiteralPath $installDir) {
    if ($KeepLog) {
        Write-Host "Removing installed daemon (keeping logs in $installDir)..."
        Get-ChildItem -LiteralPath $installDir -File |
            Where-Object { $_.Name -ne 'duo-brightness-sync.log' -and $_.Name -ne 'duo-brightness-sync.log.old' } |
            Remove-Item -Force
    } else {
        Write-Host "Removing $installDir..."
        Remove-Item -LiteralPath $installDir -Recurse -Force
    }
}

Write-Host 'Uninstalled.'
