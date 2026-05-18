# Contributing to Peakmon

Thanks for considering a contribution. Peakmon aims to stay small,
native, and easy to understand. The rules below keep it that way.

## Coding rules (summary)

- Swift 6.2+, macOS 26.4+ SDK.
- SwiftUI + Swift Concurrency. **No** Combine, **no** NSTimer/
  DispatchSourceTimer for metric polling.
- Only `MetricsScheduler` polls the system. Views and ViewModels read
  the `MetricsStore`.
- `PeakmonCore` has zero non-Apple dependencies. Features must not
  import each other.
- Run `swiftformat .` and `swiftlint` before committing.

## Build and test

```sh
# Full app build
xcodebuild -project Peakmon.xcodeproj -scheme Peakmon \
           -destination 'platform=macOS' build

# Per-package tests
swift test --package-path Packages/PeakmonCore
```

CI runs the same commands plus SwiftLint/SwiftFormat in `--strict` mode.

## Pull requests

- One topic per PR. Small PRs get merged faster.
- Add tests when the affected package has a `Tests/` target.

## Commit messages

Use [Conventional Commits](https://www.conventionalcommits.org/) with a
short scope, e.g.:

```
feat(collectors): add CPUCollector based on host_statistics64
fix(scheduler): cancel in-flight tasks when paused
docs(readme): document menu-bar segments
```

## Reporting bugs

Open a GitHub issue with:

- macOS version + Mac model
- Peakmon version (commit SHA if built from source)
- Reproduction steps
- Expected vs actual behaviour
- Logs (`log show --predicate 'subsystem == "ai.peakmon"' --info --last 5m`)

## Code of conduct

Be kind. Be specific. Be patient with new contributors.
