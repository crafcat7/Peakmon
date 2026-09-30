## Summary

Peakmon 1.6.3 improves telemetry accuracy and adds in-app update checks. Unavailable readings are kept distinct from measured zeroes, network throughput follows the active external connection, and power readings identify their measurement scope. The dashboard also keeps device information and system health aligned as the window changes size.

## Highlights

### App Updates

- **Check for Updates** — General settings can check the latest stable GitHub Release and confirm when the installed version is current
- **Signed update support** — releases with a signed update feed use Sparkle to verify the feed and archive before installation; releases without a feed offer a link to their download page
- **Optional daily checks** — enable background update checks and see available-version reminders in Settings and the popover; installation still requires your action
- **Homebrew-aware updates** — Homebrew installations keep using `brew upgrade crafcat7/cellar/peakmon`, including apps linked into `/Applications`

### Telemetry Correctness

- **Truthful unavailable readings** — missing telemetry appears as unavailable across the dashboard, menu bar, and history instead of being presented as a valid zero or retained old value
- **Clearer power sources** — distinguish system power, energy-model estimates, and hardware supply readings, with validated M3 Max supply fallbacks when model counters stop providing readings
- **Active-connection network rates** — measure physical interfaces on the active external path and reset the sampling baseline when that path changes, avoiding duplicate tunnel traffic and scope-change spikes
- **Memory and battery clarity** — distinguish memory usage from pressure state, and validate battery health and temperature sources before displaying them

### Dashboard

- **Balanced device banner** — center system health beside the two rows of device information at medium widths; narrower layouts wrap the facts while keeping all fields visible
- **Content-aware sizing** — account for the banner's measured height when sizing the Processes panel
- **Consistent power presentation** — use the same availability rules and source labels in the dashboard, popover, and menu bar

## Upgrading

Peakmon 1.6.2 and earlier require a manual installation of 1.6.3 to gain in-app update support. Download `Peakmon.app.zip` from this release, or update through Homebrew once the formula is available. Future releases can use the signed update flow after 1.6.3 is installed.

## Build Info

| Field | Value |
| --- | --- |
| Version | 1.6.3 |
| Build | 20260930 |
| Minimum macOS | 14 Sonoma |
| Archive | `Peakmon.app.zip` |
| Update feed | `appcast.xml` |
| SHA-256 | `924ba663061a98ee7e1c5dd0c040e08c9dc20d8d232fb4c89289c9caa2f42d96` |

---

Thanks for trying Peakmon. Bug reports and ideas welcome via GitHub Issues. ❤️
