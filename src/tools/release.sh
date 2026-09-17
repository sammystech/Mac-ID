#!/bin/bash
#
# Cuts a Mac ID release: builds, packages, signs the update, and regenerates the appcast.
#
#     ./tools/release.sh 1.3
#
# What it does NOT do is publish. It prints the exact `gh release create` line at the end so
# uploading stays a deliberate act — a bad appcast reaches every installed copy.
#
# Requirements, checked below and explained when missing:
#   * Sparkle's tools (generate_appcast, sign_update) from the SPM checkout
#   * The EdDSA private key in the login keychain (created once by generate_keys)
#   * SUFeedURL in Info.plist pointing at a real repo
#   * For anyone else's Mac: a Developer ID Application certificate and notarization
#
set -euo pipefail

VERSION="${1:-}"
if [[ -z "$VERSION" ]]; then
    echo "usage: ./tools/release.sh <version>    e.g. ./tools/release.sh 1.3" >&2
    exit 1
fi

cd "$(dirname "$0")/.."
PROJECT="glance.xcodeproj"
SCHEME="glance"
APP_NAME="Mac ID"
INFO_PLIST="glance/Info.plist"
# generate_appcast scans this directory and refuses two archives carrying the same bundle version,
# so it holds the update zips and nothing else. Hand-install DMGs live separately.
RELEASES_DIR="$PWD/releases"
DIST_DIR="$PWD/dist"
BUILD_DIR="$PWD/.release-build"

say()  { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[33mwarning: %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[31merror: %s\033[0m\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- preflight

FEED_URL=$(/usr/libexec/PlistBuddy -c "Print :SUFeedURL" "$INFO_PLIST" 2>/dev/null || echo "")
[[ -n "$FEED_URL" ]] || die "SUFeedURL is missing from $INFO_PLIST."
if [[ "$FEED_URL" == *REPLACE-ME* ]]; then
    die "SUFeedURL is still the placeholder:
    $FEED_URL
  Set it to your real repo first. Every copy you ship asks this exact URL forever, and
  copies already installed cannot be redirected by a later release."
fi

# Everything in the appcast must be reachable under this prefix. Derived from the feed URL so
# the two can't drift apart.
DOWNLOAD_PREFIX="${FEED_URL%/*}/"

PUB_KEY=$(/usr/libexec/PlistBuddy -c "Print :SUPublicEDKey" "$INFO_PLIST" 2>/dev/null || echo "")
[[ -n "$PUB_KEY" ]] || die "SUPublicEDKey is missing from $INFO_PLIST."

SPARKLE_BIN=$(find ~/Library/Developer/Xcode/DerivedData \
    -path '*artifacts/sparkle/Sparkle/bin' -type d 2>/dev/null | head -1)
[[ -n "$SPARKLE_BIN" ]] || die "Can't find Sparkle's tools. Build the app once so SwiftPM checks Sparkle out, then retry."

say "Releasing $APP_NAME $VERSION"
echo "  feed:     $FEED_URL"
echo "  download: ${DOWNLOAD_PREFIX}"
echo "  pub key:  $PUB_KEY"

# ---------------------------------------------------------------- version

CURRENT_BUILD=$(grep 'CURRENT_PROJECT_VERSION = ' "$PROJECT/project.pbxproj" | head -1 | sed -E 's/.*= ([0-9]+);/\1/')
NEXT_BUILD=$((CURRENT_BUILD + 1))
say "Version $VERSION, build $NEXT_BUILD (was build $CURRENT_BUILD)"
sed -i '' -E "s/MARKETING_VERSION = [^;]+;/MARKETING_VERSION = $VERSION;/g" "$PROJECT/project.pbxproj"
sed -i '' -E "s/CURRENT_PROJECT_VERSION = [0-9]+;/CURRENT_PROJECT_VERSION = $NEXT_BUILD;/g" "$PROJECT/project.pbxproj"

# ---------------------------------------------------------------- build

say "Building"
rm -rf "$BUILD_DIR"
xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Release \
    -derivedDataPath "$BUILD_DIR" build > "$BUILD_DIR.log" 2>&1 \
    || { tail -40 "$BUILD_DIR.log"; die "Build failed. Full log: $BUILD_DIR.log"; }

APP="$BUILD_DIR/Build/Products/Release/$APP_NAME.app"
[[ -d "$APP" ]] || die "Built app not found at $APP"

# ---------------------------------------------------------------- signing checks

say "Checking the signature"
# Captured first rather than piped: `grep -m1` closes the pipe as soon as it matches, codesign
# takes SIGPIPE, and `set -o pipefail` turns that into a fatal error mid-script.
SIGINFO=$(codesign -d --verbose=2 "$APP" 2>&1 || true)
AUTHORITY=$(printf '%s\n' "$SIGINFO" | grep '^Authority=' | head -1 | cut -d= -f2-)
echo "  signed by: $AUTHORITY"

DISTRIBUTABLE=1
if [[ "$AUTHORITY" != Developer\ ID\ Application* ]]; then
    DISTRIBUTABLE=0
    warn "This is signed with '$AUTHORITY', not a Developer ID Application certificate.
  It will run on your own Macs and nowhere else — Gatekeeper blocks it for everyone else,
  and Sparkle's installer will fail on their machines even though the update downloads.
  Shipping to other people needs a paid Apple Developer account, then:
      1. Create a 'Developer ID Application' certificate
      2. Rebuild with it
      3. xcrun notarytool submit --wait, then xcrun stapler staple"
elif ! xcrun stapler validate "$APP" >/dev/null 2>&1; then
    DISTRIBUTABLE=0
    warn "Signed with Developer ID but not notarized. Gatekeeper will still block it on first launch.
      xcrun notarytool submit <zip> --keychain-profile <profile> --wait
      xcrun stapler staple '$APP'"
fi

codesign --verify --deep --strict "$APP" || die "Signature does not verify."

# Sparkle is embedded; if its Team ID doesn't match the app's, dyld refuses to load it and the
# app dies before main. This exact failure shipped once already.
APP_TEAM=$(printf '%s\n' "$SIGINFO" | grep TeamIdentifier | head -1 | cut -d= -f2)
FW="$APP/Contents/Frameworks/Sparkle.framework"
if [[ -d "$FW" ]]; then
    FW_INFO=$(codesign -d --verbose=2 "$FW" 2>&1 || true)
    FW_TEAM=$(printf '%s\n' "$FW_INFO" | grep TeamIdentifier | head -1 | cut -d= -f2)
    [[ "$APP_TEAM" == "$FW_TEAM" ]] \
        || die "Sparkle.framework Team ID ($FW_TEAM) != app Team ID ($APP_TEAM). The app would crash in dyld at launch."
    echo "  Sparkle team matches: $APP_TEAM"
fi

# ---------------------------------------------------------------- package

say "Packaging"
mkdir -p "$RELEASES_DIR"
ZIP="$RELEASES_DIR/MacID-$VERSION.zip"
rm -f "$ZIP"
# ditto --keepParent preserves the bundle; Sparkle requires the app at the archive root.
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
echo "  $(du -h "$ZIP" | cut -f1)  $ZIP"

# A DMG for people installing by hand. Sparkle updates from the zip, and the DMG is deliberately
# kept out of RELEASES_DIR — generate_appcast treats a zip and a DMG of the same version as
# duplicate updates and refuses to build the feed.
mkdir -p "$DIST_DIR"
DMG="$DIST_DIR/$APP_NAME $VERSION.dmg"
rm -f "$DMG"
DMG_ROOT=$(mktemp -d)
cp -R "$APP" "$DMG_ROOT/"
ln -s /Applications "$DMG_ROOT/Applications"
hdiutil create -volname "$APP_NAME" -srcfolder "$DMG_ROOT" -ov -format UDZO -fs HFS+ "$DMG" >/dev/null 2>&1
rm -rf "$DMG_ROOT"
echo "  $(du -h "$DMG" | cut -f1)  $DMG"

# ---------------------------------------------------------------- appcast

say "Signing the update and regenerating the appcast"
# generate_appcast signs every archive in the folder with the EdDSA private key from the login
# keychain, and emits enclosure URLs under the prefix. It reads previous entries so older
# versions stay in the feed.
"$SPARKLE_BIN/generate_appcast" --download-url-prefix "$DOWNLOAD_PREFIX" "$RELEASES_DIR"

APPCAST="$RELEASES_DIR/appcast.xml"
[[ -f "$APPCAST" ]] || die "generate_appcast did not produce $APPCAST"
grep -q 'edSignature' "$APPCAST" || die "appcast.xml has no EdDSA signatures — the private key was not found in the keychain."
echo "  $APPCAST"
echo "  versions in feed: $(grep -c '<item>' "$APPCAST")"

# ---------------------------------------------------------------- next steps

say "Built. Nothing has been published yet."
cat <<EOF

Upload every zip plus the appcast to the new release, because the feed points at
'releases/latest/download/…' — older versions must stay reachable from the newest release:

    gh release create v$VERSION \\
      --title "$APP_NAME $VERSION" \\
      --notes "..." \\
      "$RELEASES_DIR"/*.zip "$APPCAST" "$DMG"

Then confirm the feed is actually live before trusting it:

    curl -sI ${FEED_URL} | head -1        # expect 200
    curl -s ${FEED_URL} | head -20

EOF

if [[ "$DISTRIBUTABLE" -eq 0 ]]; then
    warn "Reminder: this build runs on your Macs only. See the signing warning above."
fi
