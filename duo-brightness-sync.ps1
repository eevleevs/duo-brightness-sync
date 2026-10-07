#Requires -Version 5.1
[CmdletBinding()]
param(
    [ValidateRange(1000, 60000)]
    [int]$IdleFallbackMs = 2000,

    [ValidateRange(25, 2000)]
    [int]$BurstIntervalMs = 150,

    [ValidateRange(200, 30000)]
    [int]$BurstQuietMs = 1500,

    [ValidateRange(0, 100)]
    [int]$MinPercent = 0,

    [ValidateRange(0, 1000)]
    [int]$SmoothMs = 100,

    [switch]$UseLinear,

    [string]$LogFile = (Join-Path $env:LOCALAPPDATA 'duo-brightness-sync\duo-brightness-sync.log'),

    [switch]$NoLogFile,

    [switch]$NoWatchers,

    [switch]$LogEvents,

    [switch]$Probe
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Management

if (-not ('DuoBrightness.Igcl' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;

namespace DuoBrightness
{
    public static class Igcl
    {
        delegate uint TInit(IntPtr args, out IntPtr handle);
        delegate uint TClose(IntPtr handle);
        delegate uint TEnum(IntPtr handle, ref uint count, IntPtr arr);
        delegate uint TCall(IntPtr handle, IntPtr p);

        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        static extern IntPtr LoadLibrary(string path);
        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Ansi)]
        static extern IntPtr GetProcAddress(IntPtr h, string name);
        [DllImport("kernel32.dll")]
        static extern bool FreeLibrary(IntPtr h);

        static IntPtr lib;
        static IntPtr api;
        static TInit ctlInit;
        static TClose ctlClose;
        static TEnum ctlEnumDevices;
        static TEnum ctlEnumOutputs;
        static TCall ctlGetBright;
        static TCall ctlSetBright;
        static IntPtr[] ok = new IntPtr[64];
        static int okCount;

        [StructLayout(LayoutKind.Sequential)]
        struct InitArgs { public uint Size; public byte Version; public uint AppVersion; public uint Flags; public uint SupportedVersion; public Guid Uid; }

        [StructLayout(LayoutKind.Sequential)]
        struct SetB { public uint Size; public byte Version; public uint Target; public uint Smooth; public uint R1; public uint R2; public uint R3; public uint R4; }

        [StructLayout(LayoutKind.Sequential)]
        struct GetB { public uint Size; public byte Version; public uint Target; public uint Current; public uint R1; public uint R2; public uint R3; public uint R4; }

        static IntPtr Alloc<T>(T s) where T : struct
        {
            int size = Marshal.SizeOf(typeof(T));
            IntPtr p = Marshal.AllocHGlobal(size);
            Marshal.StructureToPtr(s, p, false);
            return p;
        }

        static IntPtr Fn(string name)
        {
            IntPtr p = GetProcAddress(lib, name);
            if (p == IntPtr.Zero) throw new Exception("missing export " + name);
            return p;
        }

        public static string Load(string path)
        {
            if (lib != IntPtr.Zero) { FreeLibrary(lib); lib = IntPtr.Zero; }
            api = IntPtr.Zero;
            okCount = 0;
            lib = LoadLibrary(path);
            if (lib == IntPtr.Zero) return "LoadLibrary failed err=" + Marshal.GetLastWin32Error();
            try
            {
                ctlInit = (TInit)Marshal.GetDelegateForFunctionPointer(Fn("ctlInit"), typeof(TInit));
                ctlClose = (TClose)Marshal.GetDelegateForFunctionPointer(Fn("ctlClose"), typeof(TClose));
                ctlEnumDevices = (TEnum)Marshal.GetDelegateForFunctionPointer(Fn("ctlEnumerateDevices"), typeof(TEnum));
                ctlEnumOutputs = (TEnum)Marshal.GetDelegateForFunctionPointer(Fn("ctlEnumerateDisplayOutputs"), typeof(TEnum));
                ctlGetBright = (TCall)Marshal.GetDelegateForFunctionPointer(Fn("ctlGetBrightnessSetting"), typeof(TCall));
                ctlSetBright = (TCall)Marshal.GetDelegateForFunctionPointer(Fn("ctlSetBrightnessSetting"), typeof(TCall));
            }
            catch (Exception ex)
            {
                FreeLibrary(lib); lib = IntPtr.Zero;
                return ex.Message;
            }
            return "loaded";
        }

        public static string Init()
        {
            if (lib == IntPtr.Zero) return "not loaded";
            InitArgs a = new InitArgs();
            a.Size = (uint)Marshal.SizeOf(typeof(InitArgs));
            a.Version = 0;
            a.AppVersion = (1u << 16) | 1u;
            a.Flags = 0;
            a.Uid = Guid.Empty;
            IntPtr p = Alloc(a);
            IntPtr h;
            uint r = ctlInit(p, out h);
            Marshal.FreeHGlobal(p);
            if (r != 0) return "ctlInit failed 0x" + r.ToString("X8");
            api = h;
            return "init ok";
        }

        public static string Enumerate()
        {
            okCount = 0;
            var sb = new StringBuilder();
            if (api == IntPtr.Zero) return "not initialized";
            uint devCount = 0;
            uint r = ctlEnumDevices(api, ref devCount, IntPtr.Zero);
            if (r != 0) return "ctlEnumerateDevices failed 0x" + r.ToString("X8");
            IntPtr devs = Marshal.AllocHGlobal((int)devCount * IntPtr.Size);
            r = ctlEnumDevices(api, ref devCount, devs);
            if (r != 0) { Marshal.FreeHGlobal(devs); return "ctlEnumerateDevices failed 0x" + r.ToString("X8"); }
            for (uint d = 0; d < devCount; d++)
            {
                IntPtr dev = Marshal.ReadIntPtr(devs, (int)(d * IntPtr.Size));
                uint outCount = 0;
                r = ctlEnumOutputs(dev, ref outCount, IntPtr.Zero);
                if (r != 0) continue;
                IntPtr outs = Marshal.AllocHGlobal((int)outCount * IntPtr.Size);
                r = ctlEnumOutputs(dev, ref outCount, outs);
                if (r != 0) { Marshal.FreeHGlobal(outs); continue; }
                for (uint i = 0; i < outCount; i++)
                {
                    IntPtr o = Marshal.ReadIntPtr(outs, (int)(i * IntPtr.Size));
                    GetB g = new GetB();
                    g.Size = (uint)Marshal.SizeOf(typeof(GetB));
                    IntPtr gp = Alloc(g);
                    uint gr = ctlGetBright(o, gp);
                    Marshal.FreeHGlobal(gp);
                    if (gr == 0)
                    {
                        if (okCount < ok.Length) { ok[okCount] = o; okCount++; }
                        sb.Append("output[").Append(d).Append(':').Append(i).Append("] ok; ");
                    }
                }
                Marshal.FreeHGlobal(outs);
            }
            Marshal.FreeHGlobal(devs);
            sb.Append("addressable=").Append(okCount);
            return sb.ToString();
        }

        public static string Get(int idx)
        {
            if (api == IntPtr.Zero || idx < 0 || idx >= okCount) return "no addressable output";
            GetB g = new GetB();
            g.Size = (uint)Marshal.SizeOf(typeof(GetB));
            IntPtr gp = Alloc(g);
            uint r = ctlGetBright(ok[idx], gp);
            GetB res = (GetB)Marshal.PtrToStructure(gp, typeof(GetB));
            Marshal.FreeHGlobal(gp);
            if (r != 0) return "get failed 0x" + r.ToString("X8");
            return String.Format("current={0} target={1}", res.Current, res.Target);
        }

        public static string Set(int idx, uint target, uint smoothMs)
        {
            if (api == IntPtr.Zero || idx < 0 || idx >= okCount) return "no addressable output";
            SetB s = new SetB();
            s.Size = (uint)Marshal.SizeOf(typeof(SetB));
            s.Version = 0;
            s.Target = target;
            s.Smooth = smoothMs;
            IntPtr sp = Alloc(s);
            uint r = ctlSetBright(ok[idx], sp);
            Marshal.FreeHGlobal(sp);
            if (r != 0) return "set failed 0x" + r.ToString("X8");
            return "set ok";
        }

        public static string Shutdown()
        {
            var sb = new StringBuilder();
            if (api != IntPtr.Zero) { uint r = ctlClose(api); sb.Append("ctlClose=0x").Append(r.ToString("X")); api = IntPtr.Zero; }
            if (lib != IntPtr.Zero) { FreeLibrary(lib); lib = IntPtr.Zero; }
            okCount = 0;
            return sb.ToString();
        }
    }
}
'@
}

$Prefix = '[duo-brightness-sync]'

$script:CurveTop = @(0, 5, 10, 15, 20, 25, 30, 35, 40, 45, 50, 55, 60, 65, 70, 75, 80, 85, 90, 95, 100)
$script:CurveBottom = @(1012, 2024, 3036, 4048, 5263, 7180, 9311, 11903, 14893, 18482, 22469, 27189, 32524, 38475, 45041, 52429, 60457, 69308, 79189, 89687, 101214)

$script:WmiQuery = $null
$script:MainInstanceName = $null
$script:Watchers = @()
$script:LogFileReady = $false
$script:ErrKey = ''
$script:ErrTime = [datetime]::MinValue
$script:LastWatcherReset = [datetime]::MinValue
$script:LastIgclReset = [datetime]::MinValue
$script:LastWritten = $null
$script:PanelIndex = 0
$script:LastIgclError = ''
$script:ControlLibPath = $null
$script:EnumLogged = $false

function Initialize-LogFile {
    if ($NoLogFile -or [string]::IsNullOrWhiteSpace($LogFile)) { return }
    try {
        $dir = Split-Path -Parent $LogFile
        if ($dir -and -not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
        if (Test-Path -LiteralPath $LogFile) {
            $item = Get-Item -LiteralPath $LogFile
            if ($item.Length -gt 1MB) {
                Remove-Item -LiteralPath ($item.FullName + '.old') -Force -ErrorAction SilentlyContinue
                Rename-Item -LiteralPath $item.FullName -NewName ($item.Name + '.old') -Force
            }
        }
        $script:LogFileReady = $true
    } catch {
        $script:LogFileReady = $false
    }
}

function Write-Log {
    param([string]$Message, [string]$Color = 'Gray')
    $line = '{0} {1} {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Prefix, $Message
    if ($script:LogFileReady) {
        try {
            Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8
        } catch {
            $script:LogFileReady = $false
        }
    }
    Write-Host $line -ForegroundColor $Color
}

function Write-LogThrottled {
    param([string]$Key, [string]$Message, [string]$Color = 'Gray')
    $now = Get-Date
    if ($Key -eq $script:ErrKey -and ($now - $script:ErrTime).TotalSeconds -lt 30) { return }
    $script:ErrKey = $Key
    $script:ErrTime = $now
    Write-Log $Message $Color
}

function Get-ControlLibPath {
    $classRoot = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}'
    foreach ($sub in @(Get-ChildItem -Path $classRoot -ErrorAction SilentlyContinue)) {
        $value = Get-ItemProperty -Path $sub.PSPath -Name 'ControlApiPath' -ErrorAction SilentlyContinue
        if ($value -and -not [string]::IsNullOrWhiteSpace($value.ControlApiPath)) {
            if (Test-Path -LiteralPath $value.ControlApiPath) { return $value.ControlApiPath }
        }
    }
    return $null
}

function Reset-Igcl {
    $script:LastIgclReset = Get-Date
    [void][DuoBrightness.Igcl]::Shutdown()
    if ($null -eq $script:ControlLibPath) {
        $script:ControlLibPath = Get-ControlLibPath
    }
    if ($null -eq $script:ControlLibPath) {
        $script:LastIgclError = 'IntelControlLib.dll path not found in display class registry'
        return $false
    }
    $load = [DuoBrightness.Igcl]::Load($script:ControlLibPath)
    if ($load -ne 'loaded') {
        $script:LastIgclError = $load
        return $false
    }
    $init = [DuoBrightness.Igcl]::Init()
    if ($init -ne 'init ok') {
        $script:LastIgclError = $init
        return $false
    }
    $enum = [DuoBrightness.Igcl]::Enumerate()
    if ($enum -notmatch 'addressable=(\d+)') {
        $script:LastIgclError = $enum
        return $false
    }
    $count = [int]$Matches[1]
    if ($count -lt 1) {
        $script:LastIgclError = 'no brightness-addressable display output (companion panel absent or display off?)'
        return $false
    }
    $script:PanelIndex = 0
    if (-not $script:EnumLogged -or $count -gt 1) {
        Write-Log ("IGCL outputs addressable: {0} ({1})" -f $count, $enum) Green
        $script:EnumLogged = $true
    }
    return $true
}

function Get-Panel2State {
    $r = [DuoBrightness.Igcl]::Get($script:PanelIndex)
    if ($r -match 'current=(\d+) target=(\d+)') {
        return @{ Current = [int]$Matches[1]; Target = [int]$Matches[2] }
    }
    $script:LastIgclError = $r
    return $null
}

function Set-Panel2 {
    param([int]$Target)
    return [DuoBrightness.Igcl]::Set($script:PanelIndex, [uint32]$Target, [uint32]$SmoothMs)
}

function Reset-MainWmi {
    $scope = New-Object System.Management.ManagementScope('\\.\root\wmi')
    $scope.Connect()
    $query = New-Object System.Management.ManagementObjectSearcher(
        $scope,
        (New-Object System.Management.ObjectQuery(
            'SELECT InstanceName, Active, CurrentBrightness FROM WmiMonitorBrightness')))
    $script:WmiQuery = $query
}

function Get-MainCandidates {
    if ($null -eq $script:WmiQuery) { Reset-MainWmi }
    try {
        $collection = $script:WmiQuery.Get()
    } catch {
        Reset-MainWmi
        $collection = $script:WmiQuery.Get()
    }
    $candidates = @()
    foreach ($obj in $collection) {
        $nameProp = $obj.Properties['InstanceName']
        $brightProp = $obj.Properties['CurrentBrightness']
        if ($null -eq $nameProp -or $null -eq $brightProp) { continue }
        $activeProp = $obj.Properties['Active']
        $active = $true
        if ($null -ne $activeProp) { $active = [bool]$activeProp.Value }
        $candidates += [pscustomobject]@{
            Name       = [string]$nameProp.Value
            Active     = $active
            Brightness = [int]$brightProp.Value
        }
    }
    return $candidates
}

function Choose-MainInstance {
    param([object[]]$Candidates)
    $override = $env:MAIN_BRIGHTNESS_INSTANCE
    if (-not [string]::IsNullOrWhiteSpace($override)) {
        $matches = @($Candidates | Where-Object { $_.Name -eq $override -or $_.Name -like "*$override*" })
        if ($matches.Count -gt 0) { return ($matches | Select-Object -First 1) }
        return $null
    }
    $active = @($Candidates | Where-Object { $_.Active })
    if ($active.Count -gt 0) { return ($active | Sort-Object Name | Select-Object -First 1) }
    if ($Candidates.Count -gt 0) { return ($Candidates | Sort-Object Name | Select-Object -First 1) }
    return $null
}

function Get-MainBrightness {
    $candidates = @(Get-MainCandidates)
    if ($candidates.Count -eq 0) { return $null }
    $chosen = $null
    if ($null -ne $script:MainInstanceName) {
        $chosen = $candidates | Where-Object { $_.Name -eq $script:MainInstanceName } | Select-Object -First 1
    }
    if ($null -eq $chosen) {
        $chosen = Choose-MainInstance -Candidates $candidates
        if ($null -eq $chosen) { return $null }
        $script:MainInstanceName = $chosen.Name
        if (-not $Probe) {
            Write-Log ("main monitor '{0}' (brightness {1}%)" -f $chosen.Name, $chosen.Brightness) Cyan
            if ($candidates.Count -gt 1) {
                Write-Log ("multiple WMI brightness instances found; set MAIN_BRIGHTNESS_INSTANCE to override (have: {0})" -f (($candidates | ForEach-Object { $_.Name }) -join ', ')) Yellow
            }
        }
    }
    return [int]$chosen.Brightness
}

function Reset-Watchers {
    foreach ($watcher in $script:Watchers) {
        try { $watcher.Stop() } catch { }
        try { $watcher.Dispose() } catch { }
    }
    $script:Watchers = @()
    Get-Event -ErrorAction SilentlyContinue |
        Where-Object { $_.SourceIdentifier -like 'DuoBrightness.*' } |
        Remove-Event -ErrorAction SilentlyContinue
    if ($NoWatchers) { return }
    $queries = @(
        @{ Id = 'DuoBrightness.Change'; Wql = "SELECT * FROM __InstanceModificationEvent WITHIN 1 WHERE TargetInstance ISA 'WmiMonitorBrightness'" },
        @{ Id = 'DuoBrightness.Hotkey'; Wql = 'SELECT * FROM AsusAtkWmiEvent' }
    )
    foreach ($entry in $queries) {
        $watcher = $null
        try {
            $scope = New-Object System.Management.ManagementScope('\\.\root\wmi')
            $scope.Connect()
            $eventQuery = New-Object System.Management.WqlEventQuery($entry.Wql)
            $watcher = New-Object System.Management.ManagementEventWatcher($scope, $eventQuery)
            Register-ObjectEvent -InputObject $watcher -EventName 'EventArrived' -SourceIdentifier $entry.Id | Out-Null
            $watcher.Start()
            $script:Watchers += $watcher
        } catch {
            if ($null -ne $watcher) {
                try { $watcher.Dispose() } catch { }
            }
            Unregister-Event -SourceIdentifier $entry.Id -ErrorAction SilentlyContinue
            Write-Log ("event watcher '{0}' unavailable: {1}" -f $entry.Id, $_.Exception.Message) Yellow
        }
    }
    $script:LastWatcherReset = Get-Date
}

function Handle-QueuedEvents {
    $queued = @(Get-Event -ErrorAction SilentlyContinue |
        Where-Object { $_.SourceIdentifier -like 'DuoBrightness.*' })
    if ($queued.Count -eq 0) { return $false }
    foreach ($item in $queued) {
        Remove-Event -EventIdentifier $item.EventIdentifier -ErrorAction SilentlyContinue
        if ($LogEvents) {
            $detail = ''
            try {
                $newEvent = $item.SourceEventArgs.NewEvent
                if ($null -ne $newEvent) {
                    $parts = @()
                    foreach ($prop in $newEvent.Properties) {
                        $parts += ('{0}={1}' -f $prop.Name, $prop.Value)
                    }
                    $detail = ' ' + ($parts -join ' ')
                }
            } catch {
                $detail = ''
            }
            Write-Log ("event {0}:{1}" -f $item.SourceIdentifier, $detail) DarkGray
        }
    }
    return $true
}

function ConvertTo-Panel2Target {
    param([int]$Percent)
    $value = 0
    if ($UseLinear) {
        $value = [int][Math]::Round($Percent * 1000.0)
    } else {
        $tops = $script:CurveTop
        $bots = $script:CurveBottom
        if ($Percent -le $tops[0]) {
            $value = $bots[0]
        } elseif ($Percent -ge $tops[$tops.Count - 1]) {
            $value = $bots[$bots.Count - 1]
        } else {
            for ($i = 1; $i -lt $tops.Count; $i++) {
                if ($Percent -le $tops[$i]) {
                    $span = $tops[$i] - $tops[$i - 1]
                    $frac = ($Percent - $tops[$i - 1]) / [double]$span
                    $value = [int][Math]::Round($bots[$i - 1] + $frac * ($bots[$i] - $bots[$i - 1]))
                    break
                }
            }
        }
    }
    $floor = $MinPercent * 1000
    if ($value -lt $floor) { $value = $floor }
    return [int]$value
}

function Sync-Once {
    $percent = Get-MainBrightness
    if ($null -eq $percent) {
        Write-LogThrottled 'main-read' 'cannot read main display brightness' Red
        return
    }
    $target = ConvertTo-Panel2Target -Percent $percent

    $state = Get-Panel2State
    if ($null -eq $state) {
        if (((Get-Date) - $script:LastIgclReset).TotalSeconds -ge 10) {
            if (Reset-Igcl) { $state = Get-Panel2State }
        }
        if ($null -eq $state) {
            Write-LogThrottled 'panel2-read' ("second panel unavailable: {0}" -f $script:LastIgclError) Red
            return
        }
    }

    if ([Math]::Abs($state.Target - $target) -le 100) {
        $script:LastWritten = $target
        $script:ErrKey = ''
        return
    }
    if ($script:LastWritten -eq $target) { return }

    $r = Set-Panel2 -Target $target
    if ($r -ne 'set ok' -and ((Get-Date) - $script:LastIgclReset).TotalSeconds -ge 10) {
        if (Reset-Igcl) { $r = Set-Panel2 -Target $target }
    }
    if ($r -eq 'set ok') {
        Write-Log ("main {0}% -> panel2 {1:N1}%" -f $percent, ($target / 1000.0)) Cyan
        $script:LastWritten = $target
        $script:ErrKey = ''
        $script:ErrTime = [datetime]::MinValue
    } else {
        Write-LogThrottled 'panel2-write' ("second panel write failed: {0}" -f $r) Red
    }
}

function Invoke-Probe {
    $ok = $true
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    Write-Host ("user: {0}" -f $identity.Name)
    Write-Host ("elevated: {0}" -f $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator))
    $script:ControlLibPath = Get-ControlLibPath
    if ($null -eq $script:ControlLibPath) {
        Write-Host 'IntelControlLib.dll: FAILED (ControlApiPath not found in display class registry)'
        $ok = $false
    } else {
        Write-Host ("IntelControlLib.dll: {0}" -f $script:ControlLibPath)
        if (Reset-Igcl) {
            $state = Get-Panel2State
            if ($null -ne $state) {
                Write-Host ("panel2: current={0} target={1} (milli-percent)" -f $state.Current, $state.Target)
            } else {
                Write-Host ("panel2: FAILED ({0})" -f $script:LastIgclError)
                $ok = $false
            }
        } else {
            Write-Host ("IGCL: FAILED ({0})" -f $script:LastIgclError)
            $ok = $false
        }
    }
    try {
        $percent = Get-MainBrightness
        if ($null -eq $percent) {
            Write-Host 'main panel: FAILED (no WmiMonitorBrightness instance)'
            $ok = $false
        } else {
            Write-Host ("main panel: instance={0} brightness={1}%" -f $script:MainInstanceName, $percent)
        }
    } catch {
        Write-Host ("main panel: FAILED - {0}" -f $_.Exception.Message)
        $ok = $false
    }
    Reset-Watchers
    Write-Host ("watchers: {0}/2 registered" -f $script:Watchers.Count)
    if ($script:Watchers.Count -lt 1) { $ok = $false }
    return $ok
}

if ($Probe) {
    $probeOk = Invoke-Probe
    foreach ($watcher in $script:Watchers) {
        try { $watcher.Stop() } catch { }
        try { $watcher.Dispose() } catch { }
    }
    [void][DuoBrightness.Igcl]::Shutdown()
    if ($probeOk) { exit 0 }
    exit 1
}

Initialize-LogFile
Write-Log 'starting' Green

if (-not (Reset-Igcl)) {
    Write-Log ("IGCL init failed: {0}" -f $script:LastIgclError) Red
    Write-Log 'is the Intel graphics driver (with ControlApiPath) installed?' Yellow
    exit 1
}

try {
    $startupPercent = Get-MainBrightness
} catch {
    $startupPercent = $null
}
if ($null -eq $startupPercent) {
    Write-Log 'no WmiMonitorBrightness instance found under root\wmi; exiting' Red
    exit 1
}

$state = Get-Panel2State
if ($null -ne $state) {
    Write-Log ("panel2 current={0:N1}% target={1:N1}%" -f ($state.Current / 1000.0), ($state.Target / 1000.0)) Green
} else {
    Write-Log ("panel2 not readable yet: {0}" -f $script:LastIgclError) Yellow
}
Write-Log ("idle fallback {0}ms, burst {1}ms/{2}ms quiet, floor {3}%, smooth {4}ms, mapping {5}" -f $IdleFallbackMs, $BurstIntervalMs, $BurstQuietMs, $MinPercent, $SmoothMs, $(if ($UseLinear) { 'linear' } else { 'captured-curve' })) Green

Reset-Watchers
if ($script:Watchers.Count -lt 2) {
    Write-Log ("only {0}/2 event watchers active; falling back to {1}ms polling for the rest" -f $script:Watchers.Count, $IdleFallbackMs) Yellow
}

try {
    Sync-Once
} catch {
    Write-LogThrottled 'sync-error' ("initial sync failed: {0}" -f $_.Exception.Message) Red
}

$fastUntil = [datetime]::MinValue

try {
    while ($true) {
        $bursting = [datetime]::Now -lt $fastUntil
        if ($bursting) {
            Start-Sleep -Milliseconds $BurstIntervalMs
        } else {
            $seconds = [Math]::Max(1, [Math]::Ceiling($IdleFallbackMs / 1000.0))
            Wait-Event -Timeout $seconds -ErrorAction SilentlyContinue | Out-Null
        }
        $handled = $false
        try {
            $handled = Handle-QueuedEvents
        } catch {
            Write-LogThrottled 'event-error' ("event handling failed: {0}" -f $_.Exception.Message) Red
        }
        if ($handled) {
            $fastUntil = [datetime]::Now.AddMilliseconds($BurstQuietMs)
        }
        try {
            Sync-Once
        } catch {
            Write-LogThrottled 'sync-error' ("sync failed: {0}" -f $_.Exception.Message) Red
            if (((Get-Date) - $script:LastWatcherReset).TotalSeconds -gt 30) {
                Reset-MainWmi
                Reset-Watchers
            }
        }
        if (((Get-Date) - $script:LastWatcherReset).TotalMinutes -ge 30) {
            Reset-Watchers
        }
    }
} finally {
    Write-Log 'stopping' Yellow
    foreach ($watcher in $script:Watchers) {
        try { $watcher.Stop() } catch { }
        try { $watcher.Dispose() } catch { }
    }
    Get-Event -ErrorAction SilentlyContinue |
        Where-Object { $_.SourceIdentifier -like 'DuoBrightness.*' } |
        Remove-Event -ErrorAction SilentlyContinue
    [void][DuoBrightness.Igcl]::Shutdown()
}
