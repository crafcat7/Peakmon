# Peakmon

[![macOS](https://img.shields.io/badge/macOS-14.0%2B-blue?logo=apple)](https://github.com/crafcat7/Peakmon/releases)
[![License](https://img.shields.io/badge/license-Apache--2.0-blue)](LICENSE)

[English](README.md) · [简体中文](README.zh-CN.md)

Peakmon is a native macOS menu-bar system monitor for viewing common system metrics in the menu bar and a dashboard window.

It currently supports real-time CPU, GPU, Memory, Battery, Disk, Network, and Processes metrics. Built with SwiftUI and local Swift packages. No Electron shell, no telemetry — data is collected and displayed locally only.

<p align="center">
  <img alt="Menu bar (light)" src="Docs/assets/Run-Light.png" width="280" />
  &nbsp;&nbsp;
  <img alt="Menu bar (dark)" src="Docs/assets/Run-Dark.png" width="280" />
</p>

<p align="center">
  <img alt="Dashboard (light)" src="Docs/assets/Dashboard-Light.png" width="640" />
</p>

<p align="center">
  <img alt="Dashboard (dark)" src="Docs/assets/Dashboard-Dark.png" width="640" />
</p>

## Download

**[https://github.com/crafcat7/Peakmon/releases](https://github.com/crafcat7/Peakmon/releases)**

Download the latest `Peakmon.app.zip`, unzip, drop into `/Applications`. Right-click → Open on first launch to bypass Gatekeeper.

### Homebrew

```sh
brew install crafcat7/cellar/peakmon
```

## What it shows

**Menu bar** — compact segments (CPU %, memory pressure, network rate, GPU utilization, etc.) rendered as a single image. Text color adapts to the menu bar background (light / dark / full-screen).

**Popover** — click the menu bar icon for sparkline charts, per-metric stats, and a top-process list.

**Dashboard** — unified window with per-metric cards (CPU, Memory, GPU, Power, Disk, Network). Each card has headline numbers, sparkline charts, and expanded detail sections. Open via menu bar icon or global hotkey `⌃⌥⌘D`.

**Customization** — toggle cards on/off, reorder by drag, pick per-card accent colors, choose which metrics appear in the menu bar.

## Data sources

All data stays on-device. No network requests.

| Metric | Source |
|--------|--------|
| CPU / Memory | `host_statistics64` (Darwin) |
| GPU utilization | IOAccelerator `PerformanceStatistics` (IOKit) |
| Power (per-rail) | IOReport "Energy Model" (libIOReport, dlopen) |
| Temperature | SMC keys `Tp0X` / `Tg0D` |
| Fan RPM | SMC key `F0Ac` |
| Battery | IOKit `AppleSmartBattery` |
| Disk | IOKit `IOBlockStorageDriver` |
| Network | `getifaddrs` (Darwin) |
| Processes | `proc_pidinfo` (libproc) |

## Requirements

- macOS **14.0** Sonoma or newer
- Apple Silicon recommended; Intel best-effort

## Build from source

```sh
git clone https://github.com/crafcat7/Peakmon.git
cd Peakmon
./Tools/release.sh
```

Or open `Peakmon.xcodeproj` in Xcode and press Run.

Tests:

```sh
swift test --package-path Packages/PeakmonCore
```

## Repository layout

```
Peakmon/                   # App target (menu bar + dashboard + settings)
Packages/
  PeakmonCore/             # MetricKind, MetricsStore, MetricsScheduler, SMC/IOReport bridges
  PeakmonCollectors/       # 10 collectors (CPU, GPU, Memory, Power, Thermal, Fan, Battery, Disk, Network, Processes)
  PeakmonUI/               # Shared views (sparkline, card templates, DashboardComponents)
```

## License

[Apache License 2.0](LICENSE)
