#!/usr/bin/env bash
#
# Tools/release.sh — Build, ad-hoc sign and package Peakmon for release.
#
# Output: build/release/Peakmon.app.zip + SHA-256 printed to stdout.
# Set RELEASE_TAG to also generate the signed Sparkle appcast.xml.
#
# Usage:
#   Tools/release.sh                       # use current dir as project root
#   PROJECT_ROOT=/path/to/Peakmon ./release.sh
#   RELEASE_TAG=20260930 ./Tools/release.sh
#
# Required tools: xcodebuild, codesign, ditto, shasum (all ship with macOS).
#

set -euo pipefail

# ----------------------------------------------------------------------
# Configuration
# ----------------------------------------------------------------------

PROJECT_ROOT="${PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
SCHEME="${SCHEME:-Peakmon}"
CONFIGURATION="${CONFIGURATION:-Release}"
PROJECT_FILE="${PROJECT_FILE:-Peakmon.xcodeproj}"

BUILD_DIR="$PROJECT_ROOT/build/release"
APP_NAME="Peakmon.app"
APP_PATH="$BUILD_DIR/$APP_NAME"
ZIP_PATH="$BUILD_DIR/$APP_NAME.zip"

# ----------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------

log() { printf '\033[1;34m[release]\033[0m %s\n' "$*"; }
err() { printf '\033[1;31m[release]\033[0m %s\n' "$*" >&2; }

require() {
    command -v "$1" >/dev/null 2>&1 || { err "missing required tool: $1"; exit 1; }
}

# ----------------------------------------------------------------------
# Preflight
# ----------------------------------------------------------------------

require xcodebuild
require codesign
require ditto
require shasum

cd "$PROJECT_ROOT"
[ -d "$PROJECT_FILE" ] || { err "$PROJECT_FILE not found in $PROJECT_ROOT"; exit 1; }

if [ -n "${RELEASE_TAG:-}" ]; then
    [[ "$RELEASE_TAG" =~ ^[A-Za-z0-9._-]+$ ]] || { err "invalid release tag: $RELEASE_TAG"; exit 1; }
    for tool in generate_keys generate_appcast sign_update; do
        tool_path="${SPARKLE_TOOLS_DIR:-$PROJECT_ROOT/build/sparkle-tools}/bin/$tool"
        [ -x "$tool_path" ] || { err "missing Sparkle tool: $tool_path"; exit 1; }
    done
fi

log "project root : $PROJECT_ROOT"
log "scheme       : $SCHEME ($CONFIGURATION)"
log "output dir   : $BUILD_DIR"

# ----------------------------------------------------------------------
# 1) Clean output dir
# ----------------------------------------------------------------------

log "cleaning previous build output…"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

# ----------------------------------------------------------------------
# 2) Build with ad-hoc signing
# ----------------------------------------------------------------------

log "building $SCHEME / $CONFIGURATION with ad-hoc signing…"
xcodebuild \
    -project "$PROJECT_FILE" \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -destination 'generic/platform=macOS' \
    CONFIGURATION_BUILD_DIR="$BUILD_DIR" \
    CODE_SIGN_IDENTITY=- \
    CODE_SIGNING_REQUIRED=YES \
    CODE_SIGN_STYLE=Manual \
    DEVELOPMENT_TEAM= \
    PROVISIONING_PROFILE_SPECIFIER= \
    build >/dev/null

[ -d "$APP_PATH" ] || { err "build produced no $APP_NAME"; exit 1; }

# ----------------------------------------------------------------------
# 3) Verify code signature
# ----------------------------------------------------------------------

log "verifying signature…"
codesign --verify --deep --strict --verbose=2 "$APP_PATH" 2>&1 | sed 's/^/  /'

# Capture identifier + signature kind for the report.
APP_ID="$(codesign -dvv "$APP_PATH" 2>&1 | awk -F= '/^Identifier=/{print $2}')"
APP_SIG="$(codesign -dvv "$APP_PATH" 2>&1 | awk -F= '/^Signature=/{print $2}')"
APP_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_PATH/Contents/Info.plist")"
APP_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP_PATH/Contents/Info.plist")"

# ----------------------------------------------------------------------
# 4) Package with ditto (preserves resource forks + xattrs)
# ----------------------------------------------------------------------

log "packaging $APP_NAME → $(basename "$ZIP_PATH")…"
ditto -c -k --keepParent --sequesterRsrc "$APP_PATH" "$ZIP_PATH"

ZIP_SIZE="$(stat -f '%z' "$ZIP_PATH")"
ZIP_SIZE_MB="$(awk -v b="$ZIP_SIZE" 'BEGIN{printf "%.2f", b/1024/1024}')"

# ----------------------------------------------------------------------
# 5) SHA-256
# ----------------------------------------------------------------------

SHA256="$(shasum -a 256 "$ZIP_PATH" | awk '{print $1}')"

# Optionally prepare Sparkle metadata for a concrete GitHub release tag.
if [ -n "${RELEASE_TAG:-}" ]; then
    "$PROJECT_ROOT/Tools/generate_appcast.sh" "$RELEASE_TAG"
fi

# ----------------------------------------------------------------------
# Report
# ----------------------------------------------------------------------

REPORT_TAG="${RELEASE_TAG:-<TAG>}"
REPORT_FEED_ARGUMENT=""
if [ -n "${RELEASE_TAG:-}" ]; then
    REPORT_FEED_ARGUMENT=" \"$BUILD_DIR/appcast.xml\""
fi
cat <<EOF

──────────────────────────────────────────────────────────────────────
 Build report
──────────────────────────────────────────────────────────────────────
 App bundle    : $APP_PATH
 App ID        : ${APP_ID:-(unknown)}
 Version       : $APP_VERSION
 Build         : $APP_BUILD
 Signature     : ${APP_SIG:-(unknown)}
 Archive       : $ZIP_PATH
 Size          : ${ZIP_SIZE_MB} MB
 SHA-256       : $SHA256
──────────────────────────────────────────────────────────────────────

Next steps:
  git push origin HEAD
  git push origin "$REPORT_TAG"
  gh release create "$REPORT_TAG" --draft \\
      --title "Peakmon $APP_VERSION" \\
      --notes-file "$PROJECT_ROOT/RELEASE_NOTES_v$APP_VERSION.md" \\
      "$ZIP_PATH"$REPORT_FEED_ARGUMENT
EOF
