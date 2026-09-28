#!/usr/bin/env bash
# Generate a signed feed for the final ZIP. Upload both files to the same release.
set -euo pipefail

PROJECT_ROOT="${PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
SPARKLE_TOOLS_DIR="${SPARKLE_TOOLS_DIR:-$PROJECT_ROOT/build/sparkle-tools}"
RELEASE_TAG="${1:?usage: Tools/generate_appcast.sh <GitHub release tag>}"
APP_PATH="$PROJECT_ROOT/build/release/Peakmon.app"
ZIP_PATH="$PROJECT_ROOT/build/release/Peakmon.app.zip"
FEED_PATH="$PROJECT_ROOT/build/release/appcast.xml"
KEY_ACCOUNT="com.crafcat7.Peakmon"

[[ "$RELEASE_TAG" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "Invalid release tag" >&2; exit 1; }
for tool in generate_keys generate_appcast sign_update; do
    [ -x "$SPARKLE_TOOLS_DIR/bin/$tool" ] || {
        echo "Missing $tool. Extract Sparkle 2.10.0 tools into $SPARKLE_TOOLS_DIR." >&2
        exit 1
    }
done
[ -f "$ZIP_PATH" ] && [ -d "$APP_PATH" ] || { echo "Run Tools/release.sh first." >&2; exit 1; }

EMBEDDED_KEY="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$APP_PATH/Contents/Info.plist")"
SIGNING_KEY="$("$SPARKLE_TOOLS_DIR/bin/generate_keys" --account "$KEY_ACCOUNT" -p)"
[ "$EMBEDDED_KEY" = "$SIGNING_KEY" ] || { echo "Signing key does not match the app's embedded public key." >&2; exit 1; }

# Keep generation separate from the app bundle and the final release artifact.
UPDATE_DIR="$(mktemp -d "$PROJECT_ROOT/build/update-feed.XXXXXX")"
trap 'rm -rf "$UPDATE_DIR"' EXIT
cp "$ZIP_PATH" "$UPDATE_DIR/Peakmon.app.zip"
"$SPARKLE_TOOLS_DIR/bin/generate_appcast" \
    --account "$KEY_ACCOUNT" \
    --maximum-deltas 0 \
    --download-url-prefix "https://github.com/crafcat7/Peakmon/releases/download/$RELEASE_TAG/" \
    --link "https://github.com/crafcat7/Peakmon/releases/tag/$RELEASE_TAG" \
    --full-release-notes-url "https://github.com/crafcat7/Peakmon/releases/tag/$RELEASE_TAG" \
    "$UPDATE_DIR"
"$SPARKLE_TOOLS_DIR/bin/sign_update" --account "$KEY_ACCOUNT" --verify "$UPDATE_DIR/appcast.xml"
cp "$UPDATE_DIR/appcast.xml" "$FEED_PATH"
echo "Signed feed: $FEED_PATH"
echo "Upload Peakmon.app.zip and appcast.xml together before making the release latest."
