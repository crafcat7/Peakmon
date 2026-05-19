<p align="center">
  <img src="Docs/assets/peakmon-icon.png" alt="Peakmon" width="128" height="128" />
</p>

<h1 align="center">Peakmon</h1>

<p align="center"><b>Native, lightweight macOS menu-bar system monitor.</b></p>

<p align="center"><a href="README.md">English</a> · <a href="README.zh-CN.md">简体中文</a></p>

Peakmon shows live CPU, GPU, Memory, Battery, Disk, Network, and
top-process metrics right in your menu bar — no Activity Monitor, no
Electron, no telemetry. Configure exactly what you want to see, pick
your colours, and forget it is there.

<p align="left">
  <img alt="macOS" src="https://img.shields.io/badge/macOS-14.0%2B-blue?logo=apple" />
  <img alt="Swift" src="https://img.shields.io/badge/Swift-6.3-orange?logo=swift" />
  <img alt="Xcode" src="https://img.shields.io/badge/Xcode-26.4-1575F9?logo=xcode" />
  <img alt="License" src="https://img.shields.io/badge/license-Apache--2.0-blue" />
</p>

---

## Screenshots

<p align="center">
  <img alt="Menu bar (light)" src="Docs/assets/Run-Light.png" width="280" />
  &nbsp;&nbsp;
  <img alt="Menu bar (dark)" src="Docs/assets/Run-Dark.png" width="280" />
</p>

## Design goals

- **Native.** SwiftUI + Swift Concurrency + Swift Charts. No Combine,
  no NSTimer, no third-party UI / DI / logging frameworks.
- **Lightweight.** Lives quietly in the menu bar, sips CPU, and stays
  out of your way.
- **Apple Silicon first.** Uses unified-memory metrics, IOReport
  channels, and HID sensor services.
- **Modular & open.** Code is split into local Swift Packages so a
  new contributor can navigate the entire codebase in under an hour.

## Requirements

- macOS **14.0** Sonoma or newer.
- Xcode **26.4** or newer.
- Apple Silicon recommended; Intel best-effort.

## Build

```sh
# Open in Xcode and Run, or:
xcodebuild \
  -project Peakmon.xcodeproj \
  -scheme Peakmon \
  -destination 'platform=macOS' \
  build
```

Per-package tests:

```sh
swift test --package-path Packages/PeakmonCore
```

## Install

### Homebrew

```sh
brew install crafcat7/cellar/peakmon
```

This installs the latest release of Peakmon into your Homebrew
prefix and prints instructions for symlinking it into `/Applications`
if you want it to show up in Spotlight.

### Pre-built binary

Each release also ships an ad-hoc signed `.app.zip` on the
[GitHub Releases][releases] page. Download, unzip, and drop the
`.app` into `/Applications`.

**App Sandbox is intentionally disabled** so Peakmon can read
system-level metrics. The binary is ad-hoc signed; on first launch
right-click → Open to bypass Gatekeeper.

Mac App Store release is not planned for the near future.

[releases]: https://github.com/crafcat7/Peakmon/releases

## Repository layout

```
Peakmon/                 # App target sources (MenuBarExtra entry)
Packages/
  PeakmonCore/           # Models, scheduler, store, logger facade
  PeakmonCollectors/     # CPU / GPU / Memory / Battery / Disk / Network / Processes
  PeakmonUI/             # Reusable views (sparkline, color hex helpers…)
```

## Contributing

See [`Docs/CONTRIBUTING.md`](Docs/CONTRIBUTING.md). TL;DR:

- Swift 6.2+, macOS 14.0+ SDK.
- SwiftUI + Swift Concurrency. **No** Combine, **no** NSTimer for
  metric polling.
- Only `MetricsScheduler` polls the system. Views read `MetricsStore`.
- Run `swiftlint` before committing. CI runs `--strict`.
- Conventional Commits (e.g. `feat(collectors): add NetworkCollector`).

## License

Peakmon is released under the [Apache License 2.0](LICENSE).
