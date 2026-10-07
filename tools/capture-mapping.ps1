#Requires -Version 5.1
[CmdletBinding()]
param(
    [int]$StepPercent = 5,
    [int]$SettleMs = 800
)

$ErrorActionPreference = 'Stop'
$regKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}\0000'

Write-Host '=== duo-brightness-sync: curve capture ==='
Write-Host 'Prerequisites:'
Write-Host '  1. Stop the duo-brightness-sync daemon (uninstall.ps1 or stop the task)'
Write-Host '  2. In ScreenXpert brightness settings, turn ON "Sync brightness across both screens"'
Write-Host ''

$wmiBrightness = Get-WmiObject -Namespace root\wmi -Class WmiMonitorBrightness
$wmiMethods = Get-WmiObject -Namespace root\wmi -Class WmiMonitorBrightnessMethods
if (-not $wmiMethods) { throw 'WmiMonitorBrightnessMethods not found - is this an Intel/ASUS dual-panel laptop?' }
$originalTop = [int]$wmiBrightness.CurrentBrightness

function Get-Top { [int](Get-WmiObject -Namespace root\wmi -Class WmiMonitorBrightness).CurrentBrightness }
function Get-Bottom {
    try {
        $v = (Get-ItemProperty -Path $regKey -Name 'SecondaryDisplayBrightness' -ErrorAction Stop).SecondaryDisplayBrightness
        return [BitConverter]::ToUInt32([byte[]]$v, 0)
    } catch { return -1 }
}
function Set-Top {
    param([int]$Pct)
    [void]$wmiMethods.WmiSetBrightness(0, $Pct)
    $deadline = (Get-Date).AddSeconds(4)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 300
        if ((Get-Top) -eq $Pct) { break }
    }
    Start-Sleep -Milliseconds $SettleMs
    return (Get-Top)
}

"original top: $originalTop%  bottom: $(Get-Bottom)"
$bottomBefore = Get-Bottom

$actual = Set-Top -Pct 0
if ($actual -ne 0) {
    throw "Could not set top brightness programmatically (actual=$actual). Set the top slider to 0% manually and re-run."
}
$bottom0 = Get-Bottom
if ([Math]::Abs($bottom0 - $bottomBefore) -lt 50 -and $bottomBefore -gt 0) {
    throw "ScreenXpert sync does not follow top changes (bottom $bottomBefore -> $bottom0). Is the 'Sync brightness across both screens' checkbox ON?"
}
Write-Host 'ScreenXpert sync confirmed following - sweeping'
Write-Host ''

$pairs = @()
try {
    for ($pct = 0; $pct -le 100; $pct += $StepPercent) {
        $top = Set-Top -Pct $pct
        $bottom = Get-Bottom
        $pairs += [pscustomobject]@{ Top = $top; Bottom = $bottom }
        "top=$top% bottom=$bottom"
    }
} finally {
    [void]$wmiMethods.WmiSetBrightness(0, $originalTop)
    Start-Sleep -Milliseconds 1500
}
"restored top=$(Get-Top)% bottom=$(Get-Bottom)"

Write-Host ''
Write-Host '=== paste into duo-brightness-sync.ps1 ==='
$tops = ($pairs | ForEach-Object { $_.Top }) -join ', '
$bots = ($pairs | ForEach-Object { $_.Bottom }) -join ', '
"`$script:CurveTop = @($tops)"
"`$script:CurveBottom = @($bots)"
