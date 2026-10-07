# duo-brightness-sync

Keep the **second (lower) screen of an ASUS ZenBook Duo** at the same brightness
as the main screen on **Windows**.

On Windows the brightness slider and Fn keys only drive the *main* panel. The
second panel keeps whatever level it last had, so the two screens drift apart —
usually the lower panel looks much brighter. This is a tiny PowerShell daemon
that mirrors the main panel's brightness onto the second panel using the same
mechanism ASUS's own ScreenXpert uses, with the **exact brightness curve ASUS
uses**, so both screens match perceptually.

Works **without administrator rights**, with zero dependencies beyond
PowerShell 5.1.

## How it works

| | |
|---|---|
| Read main brightness | WMI `root\wmi` → `WmiMonitorBrightness.CurrentBrightness` (0–100) |
| React to changes | WMI event watchers: `__InstanceModificationEvent` on `WmiMonitorBrightness` (slider/OS changes) + `AsusAtkWmiEvent` (Fn hotkeys) → instant wake, then a 150 ms burst that tracks drags until 1.5 s of quiet; 2 s fallback re-sync catches missed events |
| Write second panel | **Intel IGCL**: `ctlSetBrightnessSetting()` from `IntelControlLib.dll` (milli-percent 0–100000, applied to the driver's *companion display* output). No ACPI, no registry writes, no admin. |
| Mapping | A captured **curve table** (below) translates main % → second-panel milli-percent: equal % looks equally bright on both panels, and main minimum dims the second panel to ~1 % instead of switching it off |
| Dedup | Writes only when the target changes; if you set the second panel manually (e.g. via ScreenXpert), that value sticks until the *main* brightness changes |

Idle cost: **~0.6 % of one core** — the process blocks in `Wait-Event` between
syncs.

### Why not the obvious ACPI path?

ASUS's ACPI device `0x00050032` ("ScreenPad brightness") still exists in the
firmware and happily stores values you write, but on the 2024/2025 ZenBook Duo
it is **not wired to the panel** — writes succeed and change nothing (verified
visually; the asusctl project flags the same control as "erroneously available"
on UX8406). ScreenXpert drives the panel through the Intel graphics driver
instead, and so does this daemon. The registry value
`SecondaryDisplayBrightness` under the display-adapter class key is a mirror of
that driver state, which is how the curve below was captured.

## Requirements

- Windows 10/11 with PowerShell 5.1
- ASUS dual-panel laptop with an **Intel Arc** graphics driver that exposes
  `IntelControlLib.dll` (IGCL) and a *companion display* output.
  Verified on **ASUS ZenBook Duo UX8407AA** (Intel Core Ultra 9 386H,
  driver 32.0.101.8724).
- ScreenXpert installed (only needed to capture/re-capture the curve; the
  daemon itself doesn't require it).

AMD (ADL) and NVIDIA paths exist in ASUS's own stack but are **not implemented
here** — the daemon is Intel-only for now.

## Install

```powershell
git clone <repo>
cd duo-brightness-sync
.\install.ps1
```

The installer runs a preflight (`duo-brightness-sync.ps1 -Probe`), copies the
daemon to `%LOCALAPPDATA%\duo-brightness-sync\`, registers a **logon scheduled
task** for your user (no admin, battery-friendly, unlimited runtime) and starts
it.

Tail the log:

```powershell
Get-Content -Wait "$env:LOCALAPPDATA\duo-brightness-sync\duo-brightness-sync.log"
```

## Uninstall

```powershell
.\uninstall.ps1          # removes task + installed files (logs kept with -KeepLog)
```

## Configuration

Edit the parameters in the scheduled task (or test interactively by running
`duo-brightness-sync.ps1` with them):

| Parameter | Default | Meaning |
|---|---|---|
| `-IdleFallbackMs` | 2000 | Fallback re-sync interval (ms) |
| `-BurstIntervalMs` | 150 | Poll interval while tracking a drag |
| `-BurstQuietMs` | 1500 | Quiet time before leaving burst mode |
| `-MinPercent` | 0 | Floor for the *second* panel (0–100). `3` = never dimmer than 3 % |
| `-SmoothMs` | 100 | IGCL brightness transition time (0–1000 ms) |
| `-UseLinear` | off | Ignore the captured curve, map main % × 1000 directly |
| `-NoWatchers` | off | Disable event watchers (pure 2 s polling) |
| `-LogEvents` | off | Log raw WMI event payloads (debugging) |

Environment: `MAIN_BRIGHTNESS_INSTANCE` overrides auto-detection of the main
panel's WMI instance name if several exist.

### The captured curve

The embedded table was captured on a UX8407AA with ScreenXpert's own
"Sync brightness across both screens" (main % → panel value in milli-percent):

```
top:  0     5     10    15    20    25    30    35    40    45    50
bot:  1012  2024  3036  4048  5263  7180  9311  11903 14893 18482 22469
top:  55    60    65    70    75    80    85    90    95    100
bot:  27189 32524 38475 45041 52429 60457 69308 79189 89687 101214
```

Different generations may differ. Re-capture on your machine:

1. Stop the daemon (`uninstall.ps1`, or disable the task)
2. In ScreenXpert brightness settings, turn **ON** "Sync brightness across both
   screens"
3. `.\tools\capture-mapping.ps1` — it sweeps the main panel 0→100 %, records
   the second panel's value at each step, restores your brightness, and prints
   the two arrays to paste into `duo-brightness-sync.ps1`
4. Turn the sync checkbox back off, reinstall/restart the daemon

## ScreenXpert interplay

- The daemon only writes when the *main* brightness changes, so setting the
  second panel independently in ScreenXpert keeps working until you touch the
  main slider/keys again.
- If ScreenXpert's own sync checkbox is ON, both compute the same curve, so
  they agree; leaving it OFF is still cleaner (the daemon alone owns it).
- ASUS shows a toast that **HDR on the second display blocks brightness
  control** — turn HDR off on that display if adjustments don't take.

## Troubleshooting

- Run the probe first — it prints exactly what works:

  ```powershell
  .\duo-brightness-sync.ps1 -Probe
  ```

  Exit code 0 = ready; any `FAILED` line explains what's missing.
- **`no brightness-addressable display output`** — the Intel driver doesn't
  expose a companion display (not a ZenBook Duo dual-panel machine, the second
  display is off, or a non-Intel GPU).
- **`IntelControlLib.dll path not found`** — no Intel display driver
  `ControlApiPath` in the registry; install/update the Intel Arc driver.
- **`no WmiMonitorBrightness instance`** — unusual WMI state; reboot or check
  `Get-CimInstance -Namespace root/wmi -ClassName WmiMonitorBrightness`.
- **Second panel ignores writes** — check HDR is off on the second display.
- Events not firing after sleep/resume: the daemon re-registers watchers on
  errors and every 30 minutes; the 2 s fallback keeps syncing regardless.

## Credits

- [Ryxwaer/asus-screenpad-brightness-sync](https://github.com/Ryxwaer/asus-screenpad-brightness-sync)
  — the Linux original this project mirrors
- [intel/drivers.gpu.control-library](https://github.com/intel/drivers.gpu.control-library)
  — public IGCL API (`ctlSetBrightnessSetting`, companion-display semantics)
- [elfakyn/screenpad_brightness](https://github.com/elfakyn/screenpad_brightness)
  and [seerge/g-helper](https://github.com/seerge/g-helper) — ATKACPI
  `DEVS`/`DSTS` reverse engineering (and the proof of what *doesn't* work here)
- [NeroReflex/asusctl#25](https://github.com/NeroReflex/asusctl/issues/25) —
  flagging the erroneously-available screenpad brightness control on UX8406
- ASUS's ScreenXpert binaries — strings revealing
  `PanelBrightnessManager.cpp` / `ctlSetBrightnessSetting`, which pointed the
  way to the real mechanism

## License

MIT — see [LICENSE](LICENSE).
