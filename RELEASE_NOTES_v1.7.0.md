## Summary

Peakmon 1.7.0 adds a dedicated Frame Rate page after History. Run a 60-second observation of desktop presentation activity or a supported application's Metal presentation source, mark moments of interest, and inspect the recorded trend.

## Highlights

- **Desktop observation** — measures one display source without combining frame counts from multiple displays.
- **Application observation** — reads Metal presentation statistics on macOS 27 or newer and lets you choose a source when an application exposes multiple layers.
- **Focused interaction** — compact target controls, start and stop actions, time markers, and hover or pinned inspection of recorded windows.
- **Retained results** — collection continues while switching pages or hiding the window; results remain until the target changes or a new observation starts.
- **Clear data states** — missing readings remain unavailable. Optional frame intervals use measured mean frame-on-glass intervals.

Desktop observation requires available Apple Silicon display counters. Application observation requires a readable Metal presentation source; some applications do not expose one.

## Build Info

| Field | Value |
| --- | --- |
| Version | 1.7.0 |
| Build | 20261010 |
| Minimum macOS | 14 Sonoma |
| Architectures | arm64, x86_64 |
| Archive | `Peakmon.app.zip` |
| Update feed | `appcast.xml` |
| SHA-256 | `825e1092d4ff672bf5eb3a10d3b6036f69147f8d687f901e700d4666078958a8` |
