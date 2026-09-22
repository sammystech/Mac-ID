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

# Resolved after the build, since SwiftPM checks Sparkle out into whichever derived-data
# directory built the app — and this script builds into its own.
find_sparkle_bin() {
    find "$BUILD_DIR" ~/Library/Developer/Xcode/DerivedData \
        -path '*artifacts/sparkle/Sparkle/bin' -type d 2>/dev/null | head -1
}

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
# -allowProvisioningUpdates: the Mac Development profile is short-lived and Xcode silently lets it
# go stale, which fails the build with "profile doesn't include signing certificate". This renews it.
xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Release \
    -derivedDataPath "$BUILD_DIR" -allowProvisioningUpdates build > "$BUILD_DIR.log" 2>&1 \
    || { tail -40 "$BUILD_DIR.log"; die "Build failed. Full log: $BUILD_DIR.log"; }

APP="$BUILD_DIR/Build/Products/Release/$APP_NAME.app"
[[ -d "$APP" ]] || die "Built app not found at $APP"

# ---------------------------------------------------------------- distribution signing
#
# The build above is signed with an Apple Development certificate and carries a Mac Team
# provisioning profile. That profile lists the UDIDs of registered Macs, and macOS refuses to launch
# a Development-signed app on a machine that is not in it — which is why a shipped DMG opened with
# "the application cannot be opened" on someone else's Mac. It was not Gatekeeper and no amount of
# right-clicking fixed it.
#
# So the app is re-signed here for distribution: profile removed, and signed ad-hoc. That is not as
# good as a Developer ID certificate plus notarization, which is the only way to get a clean
# double-click. It needs a paid Apple Developer account. Until then, ad-hoc at least runs everywhere
# after the user approves it once in System Settings.

SPARKLE_BIN=$(find_sparkle_bin)
[[ -n "$SPARKLE_BIN" ]] || die "Built the app but still can't find Sparkle's tools under $BUILD_DIR."

say "Re-signing for distribution"

# Re-sign a COPY, never the built app itself. The Development-signed original is what belongs on
# your own Macs: it keeps the keychain-access-group (so it can still read the password you already
# stored) and a certificate-based designated requirement (so the Accessibility grant survives a
# rebuild). Installing the ad-hoc distributable locally breaks both — it lands in a different
# keychain group and its DR is the binary hash, which is exactly how "it won't unlock, something
# about permissions" happens.
LOCAL_APP="$APP"
APP="$BUILD_DIR/dist-app/$APP_NAME.app"
rm -rf "$BUILD_DIR/dist-app"; mkdir -p "$BUILD_DIR/dist-app"
cp -R "$LOCAL_APP" "$APP"
echo "  local (Development-signed) build kept at:"
echo "    $LOCAL_APP"

rm -f "$APP/Contents/embedded.provisionprofile"
echo "  removed the device-locked provisioning profile"

# Camera only. The build inherits keychain-access-groups (needs a profile to be valid) and
# get-task-allow (lets any process attach a debugger — never ship it). The app is not sandboxed and
# never sets kSecAttrAccessGroup, so its keychain items live in the default group and need no
# entitlement at all.
DIST_ENTITLEMENTS="$BUILD_DIR/dist.entitlements"
cat > "$DIST_ENTITLEMENTS" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>com.apple.security.device.camera</key>
	<true/>
</dict>
</plist>
PLIST

# Strictly deepest-first. Signing a bundle seals a hash of everything inside it, so anything signed
# afterwards invalidates its parent — which shows up later as "code object is not signed at all" or
# a bare "file modified" from codesign --verify.
SPK="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
for target in \
    "$SPK/XPCServices/Downloader.xpc" \
    "$SPK/XPCServices/Installer.xpc" \
    "$SPK/Updater.app" \
    "$SPK/Autoupdate" \
    "$APP/Contents/Frameworks/Sparkle.framework" ; do
    [[ -e "$target" ]] || continue
    codesign --force --sign - --timestamp=none "$target" >/dev/null 2>&1 \
        || die "Failed to re-sign $(basename "$target")"
    echo "  signed $(basename "$target")"
done
codesign --force --sign - --entitlements "$DIST_ENTITLEMENTS" --timestamp=none "$APP" >/dev/null 2>&1 \
    || die "Failed to re-sign the app."
echo "  signed $APP_NAME.app"

codesign --verify --deep --strict "$APP" || die "Signature does not verify after re-signing."

# dyld refuses to load an embedded framework whose Team ID differs from the host's. Ad-hoc signing
# leaves both unset, which matches — but only if Sparkle really was re-signed above. When it was not,
# the app dies in dyld before main, which is exactly the crash that shipped once already.
SIGINFO=$(codesign -d --verbose=2 "$APP" 2>&1 || true)
APP_TEAM=$(printf '%s\n' "$SIGINFO" | grep TeamIdentifier | head -1 | cut -d= -f2)
FW="$APP/Contents/Frameworks/Sparkle.framework"
if [[ -d "$FW" ]]; then
    FW_INFO=$(codesign -d --verbose=2 "$FW" 2>&1 || true)
    FW_TEAM=$(printf '%s\n' "$FW_INFO" | grep TeamIdentifier | head -1 | cut -d= -f2)
    [[ "$APP_TEAM" == "$FW_TEAM" ]] \
        || die "Sparkle Team ID ($FW_TEAM) != app Team ID ($APP_TEAM). The app would crash in dyld at launch."
    echo "  team ids match: ${APP_TEAM:-<ad-hoc, unset>}"
fi

[[ ! -e "$APP/Contents/embedded.provisionprofile" ]] \
    || die "A provisioning profile is still embedded — this build would not launch on other Macs."

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
# No spaces in the filename: GitHub's release-asset upload API rejects them with HTTP 400,
# and a space-free name also keeps the download URL clean.
DMG="$DIST_DIR/Mac-ID-$VERSION.dmg"
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

Install YOUR OWN copy from the Development-signed build, not the DMG:

    rm -rf "$HOME/mac-id/$APP_NAME.app"
    cp -R "$LOCAL_APP" "$HOME/mac-id/$APP_NAME.app"

Then confirm the feed is actually live before trusting it:

    curl -sI ${FEED_URL} | head -1        # expect 200
    curl -s ${FEED_URL} | head -20

EOF

warn "This build is ad-hoc signed, so Gatekeeper will block it on first launch. Everyone
  installing it has to approve it once:
      System Settings -> Privacy & Security -> scroll down -> Open Anyway

  Removing that step needs a paid Apple Developer account:
      1. Create a 'Developer ID Application' certificate
      2. Sign with it instead of ad-hoc here
      3. xcrun notarytool submit --wait, then xcrun stapler staple"
