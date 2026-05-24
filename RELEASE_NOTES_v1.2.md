# Peakmon 1.2

## Summary

Sensor depth release: native temperature, fan and system-power
telemetry on Apple silicon, a fully modular dashboard, and the
removal of every macOS 14+ permission prompt.

## Highlights

- **Temperature monitoring** — new SMC bridge reads CPU and GPU
  die temperatures directly from IOKit and exposes them as
  `.thermalCPU` / `.thermalGPU` series in the existing chart
  pipeline. Surfaced inside the CPU and GPU cards as live
  accessory text.
- **Fan telemetry** — `FanCollector` reads `F0Ac` / `F1Ac` SMC
  keys for left and right fan RPM (single-fan SKUs report on the
  left channel only). Wired into the Power card subsystem row.
- **System wattage** — `SystemPowerCollector` reads the SMC
  `PSTR` rail so the Power card now shows true wall-socket draw
  in addition to per-subsystem (CPU / GPU / display) estimates.
- **Display power** — `.powerDisplay` replaces `.powerANE`, which
  was never populated on user hardware. Display wattage is
  derived from the SoC IOReport stream alongside CPU and GPU.
- **Per-card dashboard files** — every card is now its own file
  (`CPUCard.swift`, `MemoryCard.swift`, `BatteryCard.swift`, …)
  and the main `DashboardView` is a ~245-line dispatcher that
  reads card visibility / width / order / tint from a single
  `CardSettings` environment value.
- **Battery card simplification** — replaced the animated
  charging sweep, standby indicator and low-battery breathing
  border with one small status dot in the card's top-leading
  corner (tinted while charging, grey while AC-idle, hidden on
  battery). Follows Apple's restrained motion language and the
  green LED metaphor familiar from physical chargers.
- **No more TCC prompts** — menu bar text colour no longer
  samples wallpaper pixels, which on macOS 14+ triggered a
  "Peakmon wants to access data from other apps" permission
  prompt at first launch. The colour now derives from system
  appearance plus a full-screen-overlay probe.
- **Quieter codebase** — every `os_log` call site and on-disk log
  dump has been removed. Errors propagate via collector
  `lastError` instead of being written to disk.

## Notes

- Temperature, fan and system-power data require Apple silicon
  (M-series). Intel Macs continue to work but those cards
  display "—".
- Single-fan models (M3 / M4 MacBook Air, M3 / M4 Pro 14") only
  populate `.fanLeftRPM`. The Power card hides the right-fan row
  when no samples arrive within the first few ticks.
- The wallpaper-aware menu bar colour heuristic from 1.1 was
  removed because it required reading
  `~/Library/Application Support/com.apple.wallpaper/…`, which
  macOS 14+ gates behind an uncancellable permission prompt.
  Light Mode + dark photo wallpaper now renders dark glyphs (the
  same behaviour as the system menu bar itself); full-screen
  apps still force white glyphs via the public CGWindowList API.

## Full Changelog

- `[feat] core` — add SMC bridge + celsius/rpm units + BatteryCornerDot
- `[feat] collectors` — add ThermalCollector
- `[feat] collectors` — add FanCollector
- `[feat] collectors` — add SystemPowerCollector
- `[refactor] collectors/power` — rework PowerCollector, drop ANE, add Display
- `[refactor] collectors/gpu` — drop renderer/tiler utilization
- `[chore] logging` — strip os_log call sites + Log facade
- `[feat] app` — introduce CardSettings environment
- `[refactor] dashboard` — per-card files + thin dispatcher shell
- `[fix] menubar` — avoid TCC prompt by removing wallpaper-pixel sampling
- `[chore] release` — bump version to 1.2 (build 20260524)

## Checksums

```
SHA-256  69342879a1f1abeb95971859a18973bf653555b9e64dd3c3c40ced82435f8d95  Peakmon.app.zip
```

---

Thanks for trying Peakmon. Bug reports and ideas welcome via GitHub
Issues.
