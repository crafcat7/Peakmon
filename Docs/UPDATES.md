# App updates

Peakmon uses Sparkle 2.10.0 in the app target. The metric packages have no
Sparkle dependency. Debug builds and Homebrew-managed bundles do not start
the updater. Homebrew detection resolves symlinks before examining the Cellar
path, so a link in `/Applications` remains managed by Homebrew.

## User experience

Settings → General provides a manual check and an opt-in daily automatic
check. Sparkle owns the preference and scheduling. Automatic downloading and
installation are disabled; installing an update requires the user's action.
Background checks add an update reminder in Settings and the popover without
activating the app. Manual checks first query GitHub's latest stable release:

- If there is no newer version/build, show an up-to-date confirmation.
- If there is a newer release with `appcast.xml`, use Sparkle's signed update flow.
- If there is a newer release without the feed, offer a link to that specific
  release page for manual download. This does not install an unsigned archive.
- Network, rate-limit, and unrecognized metadata errors remain check failures;
  they are never interpreted as "up to date."

Version discovery reads the release's Build Info table (Version/Build), then
falls back to its Peakmon title or a semantic tag for older releases. Date tags
are never compared to marketing versions. `1.6` equals `1.6.0`; components are
compared numerically. Automatic checks still use Sparkle and require the signed feed.
GitHub's API metadata is used only for discovery and browser navigation.

Peakmon's settings strings support English and Simplified Chinese; Sparkle's
standard dialogs currently follow macOS's preferred language rather than the
in-app language selection.

Monitoring data is never included in update requests. System profiling is
disabled. Update checks and downloads contact GitHub.

Existing releases without Sparkle require one manual installation of the
first update-enabled release. No feed can retrofit updater code into an
already installed binary.

## Feed and archive security

The fixed feed URL is:

`https://github.com/crafcat7/Peakmon/releases/latest/download/appcast.xml`

Each feed entry points to the ZIP under an explicit release tag, not to a
mutable latest ZIP. Both the feed and ZIP must carry valid Ed25519 signatures.
Feed verification does not expire, and archive verification occurs before
extraction. The public key is embedded in `Peakmon/Info.plist`.

The signing key was created in the maintainer's macOS login Keychain under
account `com.crafcat7.Peakmon`. It is not stored in the repository. Back up the
key securely using Sparkle's `generate_keys --account com.crafcat7.Peakmon -x`
and protect the exported file outside the checkout. Do not rotate or lose this
key without planning a migration: ad-hoc signatures cannot provide Developer ID
fallback for key rotation, especially with strict pre-extraction verification.

## Signing compatibility

The app is currently ad-hoc signed with Hardened Runtime. macOS Library
Validation rejects loading Sparkle because ad-hoc signatures have no Team ID.
`Peakmon/Peakmon.entitlements` disables Library Validation for the main app;
Hardened Runtime remains enabled. This relaxes dynamic library validation and
is an explicit tradeoff of continuing ad-hoc distribution. Ed25519 protects
update authenticity but does not replace Gatekeeper trust or notarization.

For Developer ID distribution, remove the Library Validation exception after
signing and validating all nested Sparkle components with the same team, and
complete notarization. Simply changing the outer app signature is insufficient.

## Preparing a release

1. Bump the marketing version and monotonically increasing build number in
   both Xcode build configurations. `CFBundleVersion`, not the GitHub release
   title or tag, determines update ordering. Use a suffix for multiple builds
   on the same date; never ship two distinct updates with equal build numbers.
2. Obtain the pinned Sparkle 2.10.0 distribution from its official release,
   verify it, and extract its tools into `build/sparkle-tools`, or set
   `SPARKLE_TOOLS_DIR` to the extracted distribution directory. These tools are
   separate from the framework fetched by Swift Package Manager.
3. Run `RELEASE_TAG=<actual-tag> ./Tools/release.sh`. The script builds and
   verifies `build/release/Peakmon.app.zip`, then generates and verifies
   `build/release/appcast.xml`. Alternatively run `Tools/generate_appcast.sh
   <actual-tag>` immediately after building the final ZIP. It rejects a
   signing key that does not match the embedded public key.
4. Create a draft GitHub Release and upload **both** `Peakmon.app.zip` and
   `appcast.xml`. Verify the assets before publishing and marking it latest.
   Publishing a new latest release without the feed breaks checks for
   installed update-enabled versions. Prereleases must not become latest.
5. Do not change the ZIP after feed generation. Any change requires re-signing
   and regenerating the feed. Keep the Homebrew formula synchronized with the
   final ZIP's SHA-256.

The initial generator emits one stable release entry and no delta archives.
If a later release raises the macOS minimum or restricts supported hardware,
preserve signed feed entries for users who cannot install that release before
publishing. Do not assume the single-entry workflow handles compatibility
branches. No release is published by these scripts.

## Preparing 1.6.3

Version 1.6.3 uses build `20260930` and the date tag `20260930`. Prepare the
final archive and signed feed together:

```sh
RELEASE_TAG=20260930 ./Tools/release.sh
```

Use `RELEASE_NOTES_v1.6.3.md` as the release body, with its SHA-256 updated
from the final ZIP. Upload `build/release/Peakmon.app.zip` and
`build/release/appcast.xml` to the same draft release before publishing it.
The app's fixed `SUFeedURL` and embedded public key remain valid for this
release; version and build comparisons read the app bundle and release body.

Users on 1.6.2 or earlier must install 1.6.3 manually once to gain update
support. Homebrew installations continue to use the formula's upgrade path.
