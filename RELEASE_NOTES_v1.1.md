# Peakmon 1.1

## Summary

First release after 1.0, focused on dashboard depth, layout polish,
broader macOS compatibility, and menu bar legibility.

## Highlights

- **GPU monitoring** — new GPU card with utilisation, model and core
  count, plus matching menu bar segments (percent and bar chart).
- **Top Processes card** — opt-in card showing the top CPU consumers,
  sampled via `libproc`.
- **Half-width pairing & drag-to-reorder** — place two cards side by
  side, and drag preview thumbnails in Settings → Display to reorder
  the dashboard.
- **Readable menu bar label on any wallpaper** — the label now picks
  black or white text based on the actual wallpaper colour beneath
  the menu bar, fixing the case where a dark photo wallpaper made
  Light-Mode glyphs disappear.
- **Lower menu bar CPU** — steady-state menu bar CPU is now **0%**
  (down from 20–30% in pre-1.0 builds), thanks to a rasterised
  `MenuBarLabelSignature` cache that only invalidates when the
  displayed values actually change.
- **Wider macOS support** — minimum deployment target lowered from
  macOS 26.4 to **macOS 14 Sonoma**.

## Notes

- Minimum macOS version changed from **26.4** to **14.0 Sonoma**.
  Existing 26.4 users are unaffected; users on Sonoma, Sequoia, and
  later can now install Peakmon.
- The wallpaper sampler cannot detect live/video wallpapers, opaque
  dark windows under the menu bar, or wallpapers set by third-party
  apps that bypass `NSWorkspace`. If the label colour looks wrong on
  your setup, please open an issue.

## Full Changelog

- `[chore] release` — bump version to 1.1 (build 20260520)
- `[fix] menubar` — derive label colour from wallpaper luminance
- `[chore] log` — drop stale v0.1 version tag from runtime log
- `[fix] dashboard` — align half-width card heights
- `[chore] build` — lower deployment target from macOS 26.4 to 14.0
- `[feat] dashboard` — match popover header glyph to app icon
- `[feat] dashboard` — add GPU utilisation card and menu bar segments
- `[fix] dashboard` — keep battery card aligned with neighbour at half width
- `[feat] display` — drag-to-reorder via card preview thumbnails
- `[feat] dashboard` — allow two half-width cards per row
- `[feat] dashboard` — add Top Processes card with libproc collector
- `[perf] menubar` — cut steady-state CPU from 20-30% to 0%

## Checksums

```
SHA-256  212530bfcf9cc425da4e43b1ee0a968a55203963e074e4a01675432bfe4ea09d  Peakmon.app.zip
```

---

Thanks for trying Peakmon. Bug reports and ideas welcome via GitHub
Issues.
