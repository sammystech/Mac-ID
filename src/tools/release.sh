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
#   * Xcode signed in to the team in DEVELOPMENT_TEAM, with its Developer ID Application
#     certificate in the login keychain. Notarization goes through that same Xcode sign-in, so no
#     app-specific password or notarytool profile is needed.
#
set -euo pipefail

VERSION="${1:-}"
# --resume: carry on from a build already submitted to Apple, instead of re-archiving and uploading
# again. A new team's first notarization can take hours; starting over puts it back in the queue.
RESUME=0
[[ "${2:-}" == "--resume" ]] && RESUME=1
# Minutes to wait for Apple before giving up (the build stays submitted; --resume picks it up).
NOTARIZE_WAIT_MIN="${NOTARIZE_WAIT_MIN:-30}"
if [[ -z "$VERSION" ]]; then
    echo "usage: ./tools/release.sh <version> [--resume]    e.g. ./tools/release.sh 1.3" >&2
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
    # `|| true` matters: find exits non-zero when any search root is missing or unreadable, and under
    # `pipefail` that killed the script silently, straight after a successful archive.
    { find "$BUILD_DIR" ~/Library/Developer/Xcode/DerivedData \
        -path '*artifacts/sparkle/Sparkle/bin' -type d 2>/dev/null || true; } | head -1
}

say "Releasing $APP_NAME $VERSION"
echo "  feed:     $FEED_URL"
echo "  download: ${DOWNLOAD_PREFIX}"
echo "  pub key:  $PUB_KEY"

# ---------------------------------------------------------------- version

CURRENT_BUILD=$(grep 'CURRENT_PROJECT_VERSION = ' "$PROJECT/project.pbxproj" | head -1 | sed -E 's/.*= ([0-9]+);/\1/')
if [[ $RESUME -eq 1 ]]; then
    # The earlier run already bumped the numbers; bumping again would describe a build that doesn't exist.
    CURRENT_MARKETING=$(grep 'MARKETING_VERSION = ' "$PROJECT/project.pbxproj" | head -1 | sed -E 's/.*= ([^;]+);/\1/')
    [[ "$CURRENT_MARKETING" == "$VERSION" ]] \
        || die "--resume: the project is at $CURRENT_MARKETING, not $VERSION."
    NEXT_BUILD=$CURRENT_BUILD
    say "Resuming version $VERSION, build $NEXT_BUILD"
else
    NEXT_BUILD=$((CURRENT_BUILD + 1))
    say "Version $VERSION, build $NEXT_BUILD (was build $CURRENT_BUILD)"
    sed -i '' -E "s/MARKETING_VERSION = [^;]+;/MARKETING_VERSION = $VERSION;/g" "$PROJECT/project.pbxproj"
    sed -i '' -E "s/CURRENT_PROJECT_VERSION = [0-9]+;/CURRENT_PROJECT_VERSION = $NEXT_BUILD;/g" "$PROJECT/project.pbxproj"
fi

# ---------------------------------------------------------------- build, sign, notarize
#
# archive -> export with Developer ID -> Apple notarizes -> export the stapled app. One build for
# everyone, the developer's own Mac included: a Developer ID signature stays the same across
# releases, so the Accessibility grant survives updates, and its provisioning profile covers every
# Mac, so the keychain group that keeps the stored password behind Touch ID works everywhere.

TEAM_ID=$(grep -o 'DEVELOPMENT_TEAM = [A-Z0-9]*;' "$PROJECT/project.pbxproj" | head -1 | sed -E 's/.*= ([A-Z0-9]+);/\1/')
[[ -n "$TEAM_ID" ]] || die "No DEVELOPMENT_TEAM in the project."
SIGN_IDENTITY=$(security find-identity -v -p codesigning | grep "Developer ID Application:.*($TEAM_ID)" | head -1 | sed -E 's/.*"(.+)"/\1/')
[[ -n "$SIGN_IDENTITY" ]] || die "No 'Developer ID Application' certificate for team $TEAM_ID in the login keychain.
  Xcode -> Settings -> Accounts -> (the team) -> Manage Certificates -> + -> Developer ID Application"
echo "  signing as: $SIGN_IDENTITY"

ARCHIVE="$BUILD_DIR/MacID.xcarchive"
if [[ $RESUME -eq 1 ]]; then
    [[ -d "$ARCHIVE" ]] || die "--resume: no archive at $ARCHIVE to resume from."
    ARCHIVED_BUILD=$(/usr/libexec/PlistBuddy -c "Print :ApplicationProperties:CFBundleVersion" "$ARCHIVE/Info.plist" 2>/dev/null || echo "")
    [[ "$ARCHIVED_BUILD" == "$NEXT_BUILD" ]] || die "--resume: the archive is build $ARCHIVED_BUILD, expected $NEXT_BUILD."
    say "Resuming from the submitted archive (build $ARCHIVED_BUILD)"
else
say "Archiving"
rm -rf "$BUILD_DIR"; mkdir -p "$BUILD_DIR"
xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Release \
    -archivePath "$ARCHIVE" -derivedDataPath "$BUILD_DIR/dd" -allowProvisioningUpdates archive \
    > "$BUILD_DIR/archive.log" 2>&1 \
    || { grep -E "error:" "$BUILD_DIR/archive.log" | sort -u | head -20; die "Archive failed. Full log: $BUILD_DIR/archive.log"; }

say "Signing with Developer ID and submitting to Apple for notarization"
cat > "$BUILD_DIR/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
    <key>method</key><string>developer-id</string>
    <key>destination</key><string>upload</string>
    <key>signingStyle</key><string>automatic</string>
    <key>teamID</key><string>$TEAM_ID</string>
</dict></plist>
PLIST
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportOptionsPlist "$BUILD_DIR/ExportOptions.plist" \
    -exportPath "$BUILD_DIR/upload-receipt" -allowProvisioningUpdates > "$BUILD_DIR/export.log" 2>&1 \
    || { grep -iE "error" "$BUILD_DIR/export.log" | sort -u | head -20; die "Export/upload failed. Full log: $BUILD_DIR/export.log"; }
echo "  uploaded; waiting for Apple (usually a few minutes)"
fi   # end of the non-resume archive + upload

SPARKLE_BIN=$(find_sparkle_bin)
[[ -n "$SPARKLE_BIN" ]] || die "Can't find Sparkle's tools under $BUILD_DIR."

NOTARIZED="$BUILD_DIR/notarized"
rm -rf "$NOTARIZED"
POLLS=$(( NOTARIZE_WAIT_MIN * 60 / 25 ))
for attempt in $(seq 1 $POLLS); do
    if xcodebuild -exportNotarizedApp -archivePath "$ARCHIVE" -exportPath "$NOTARIZED" \
            > "$BUILD_DIR/notarize.log" 2>&1; then
        echo "  notarized after ~$((attempt * 25))s"
        break
    fi
    # Checked before the rejection test: this failure mentions "Invalid credentials", and matching
    # "invalid" first reported a signed-out Xcode as Apple rejecting the app.
    if grep -qE "No Accounts|missing Xcode-Username|DVTDeveloperAccountCredentialsError" "$BUILD_DIR/notarize.log"; then
        die "Xcode has lost its sign-in, so it can't ask Apple for the result. Nothing was rejected.
  Xcode -> Settings -> Accounts -> sign in to the team, then:
      ./tools/release.sh $VERSION --resume"
    fi
    if grep -qiE "rejected|not accepted|status: invalid|The software asset has an invalid" "$BUILD_DIR/notarize.log"; then
        grep -iE "error|invalid|reject" "$BUILD_DIR/notarize.log" | head -10
        die "Apple rejected the submission. Details: Xcode -> Window -> Organizer -> this archive."
    fi
    [[ $attempt -eq $POLLS ]] && die "Still not notarized after $NOTARIZE_WAIT_MIN minutes. It stays submitted; pick it up with:
      ./tools/release.sh $VERSION --resume"
    sleep 25
done

APP="$NOTARIZED/$APP_NAME.app"
[[ -d "$APP" ]] || die "Notarized app not found at $APP"

say "Checking what Gatekeeper will see"
codesign --verify --deep --strict "$APP" || die "Signature does not verify."
xcrun stapler validate "$APP" >/dev/null 2>&1 || die "No notarization ticket stapled to the app."
ASSESS=$(spctl -a -t exec -vv "$APP" 2>&1 || true)
echo "$ASSESS" | sed 's/^/  /'
echo "$ASSESS" | grep -q "source=Notarized Developer ID" \
    || die "Gatekeeper does not accept this as a notarized Developer ID app."
[[ -e "$APP/Contents/embedded.provisionprofile" ]] \
    || die "No provisioning profile embedded: the keychain group would be refused and the app killed at launch."
security cms -D -i "$APP/Contents/embedded.provisionprofile" 2>/dev/null | grep -q "<key>ProvisionsAllDevices</key>" \
    || die "The embedded profile is limited to specific Macs - it would refuse to launch everywhere else."
echo "  profile provisions every Mac"

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
# Deliberately NOT signed. Measured with a quarantined copy: an unsigned DMG is simply not judged
# ("no usable signature") and mounts, while a Developer-ID-signed DMG that isn't itself notarized is
# rejected outright ("Unnotarized Developer ID"). Signing it would only help if it were notarized
# too, which needs notarytool credentials this setup doesn't have. The app inside carries its own
# stapled ticket, and that is what Gatekeeper checks when it's first opened.
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

# ---------------------------------------------------------------- upload staging
#
# What actually goes to GitHub, prepared here so none of it is done by hand:
#   * Delta files come out of generate_appcast named "Mac ID10-9.delta". GitHub's asset upload API
#     rejects spaces with HTTP 400, so they are copied without them and the appcast URLs rewritten
#     to match. Safe: each edSignature covers the file's contents, not its name, and the feed as a
#     whole is not signed. RELEASES_DIR itself is left alone, since generate_appcast reads it back.
#   * An unversioned Mac-ID.dmg alongside the versioned one. The website links to
#     releases/latest/download/<file>, and "latest" moves on every release — a versioned filename
#     404s the moment the next version ships.

UPLOAD_DIR="$BUILD_DIR/upload"
rm -rf "$UPLOAD_DIR"; mkdir -p "$UPLOAD_DIR"
cp "$ZIP" "$DMG" "$UPLOAD_DIR/"
cp "$DMG" "$UPLOAD_DIR/Mac-ID.dmg"
NEW_BUILD_DELTAS=0
for delta in "$RELEASES_DIR"/*"$NEXT_BUILD"-*.delta; do
    [[ -e "$delta" ]] || continue
    name=$(basename "$delta")
    from=$(echo "$name" | sed -E 's/.*-([0-9]+)\.delta$/\1/')
    # A delta from the previous identity can never be applied (see FIRST_NEW_ID_BUILD below).
    [[ "$from" -ge 12 ]] || continue
    cp "$delta" "$UPLOAD_DIR/${name// /}"
    NEW_BUILD_DELTAS=$((NEW_BUILD_DELTAS + 1))
done
sed 's/Mac%20ID\([0-9]*-[0-9]*\.delta\)/MacID\1/g' "$APPCAST" > "$UPLOAD_DIR/appcast.xml"

# Builds below FIRST_NEW_ID_BUILD are the app's previous identity (com.samuelmittman.macid). Sparkle
# refuses to install an update with a different bundle ID ("Failed to match host bundle identifiers"),
# so for those copies every newer release is marked informational: they're told a new version exists
# and sent to the website, instead of being offered an install that fails. Copies on the current
# identity see ordinary updates. Applied to the staged copy only; generate_appcast keeps its own file.
FIRST_NEW_ID_BUILD=12
python3 - "$UPLOAD_DIR/appcast.xml" "$FIRST_NEW_ID_BUILD" <<'INFORMATIONAL'
import re, sys
path, first = sys.argv[1], int(sys.argv[2])
feed = open(path).read()
def mark(match):
    item = match.group(0)
    build = re.search(r"<sparkle:version>(\d+)</sparkle:version>", item)
    if not build or int(build.group(1)) < first or "informationalUpdate" in item:
        return item
    extra = ("    <link>https://nmx.net</link>\n"
             "            <sparkle:informationalUpdate>\n"
             f"                <sparkle:belowVersion>{first}</sparkle:belowVersion>\n"
             "            </sparkle:informationalUpdate>\n        ")
    return item.replace("</item>", extra + "</item>")
open(path, "w").write(re.sub(r"<item>.*?</item>", mark, feed, flags=re.S))
INFORMATIONAL
grep -q "belowVersion>$FIRST_NEW_ID_BUILD<" "$UPLOAD_DIR/appcast.xml" \
    || die "Couldn't mark the release informational for the old identity - old copies would try an install that fails."
echo "  staged $(ls "$UPLOAD_DIR" | wc -l | tr -d ' ') files ($NEW_BUILD_DELTAS deltas) in $UPLOAD_DIR"

# ---------------------------------------------------------------- next steps

say "Built. Nothing has been published yet."
cat <<EOF

Upload the staged folder. Everything the newest feed entry points at is in it:

    gh release create v$VERSION \\
      --title "$APP_NAME $VERSION" \\
      --notes "..." \\
      "$UPLOAD_DIR"/*

The website links to .../releases/latest/download/Mac-ID.dmg, so it follows automatically.

The same notarized build is the one for this Mac too:

    ditto "$APP" "$HOME/mac-id/$APP_NAME.app"

Then confirm the feed is actually live before trusting it:

    curl -sI ${FEED_URL} | head -1        # expect 200
    curl -s ${FEED_URL} | head -20

EOF
