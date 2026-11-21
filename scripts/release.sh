#!/bin/sh
# Builds the notarized direct download: Sidemoon.app signed for release (hardened runtime, secure
# timestamp) by scripts/build-app.sh, notarized and stapled, then dist/Sidemoon-<version>.dmg (the app
# and an /Applications link), signed, notarized and stapled. Prints the DMG's sha256 and the Sparkle
# appcast steps (not run).
# usage: env SIDEMOON_SIGN_IDENTITY="Developer ID Application: <name> (<team>)" \
#            SIDEMOON_NOTARY_PROFILE=<profile> scripts/release.sh
#
# Credentials come only from a notarytool profile in the Keychain, never from the environment or a file.
# Store it once (it asks for an app-specific password from appleid.apple.com and keeps it in the Keychain):
#   xcrun notarytool store-credentials <profile> --apple-id <apple-id> --team-id <team-id>
set -eu

# The certificate kind Apple notarizes for distribution outside the App Store.
REQUIRED_CERTIFICATE="Developer ID Application"
RELEASE_ON=1
PRODUCT=SidemoonApp
CONFIGURATION=release
PRINT_PLIST_FLAG=--print-info-plist
# The architectures scripts/build-app.sh builds a release for (its UNIVERSAL_FLAGS).
UNIVERSAL_FLAGS="--arch arm64 --arch x86_64"
APPLICATIONS_LINK=/Applications
DMG_FORMAT=UDZO
DMG_EXTENSION=dmg
ZIP_EXTENSION=zip
CHECKSUM_BITS=256
# Sparkle's tools as SwiftPM unpacks them (swift build puts them there).
SPARKLE_BIN=.build/artifacts/sparkle/Sparkle/bin

fail() {
    echo "release: $*" >&2
    exit 1
}

# Checked before anything is built.
[ -n "${SIDEMOON_SIGN_IDENTITY:-}" ] || fail "set SIDEMOON_SIGN_IDENTITY to your \"$REQUIRED_CERTIFICATE: <name> (<team>)\" certificate (name or SHA-1 hash)"
[ -n "${SIDEMOON_NOTARY_PROFILE:-}" ] || fail "set SIDEMOON_NOTARY_PROFILE to a notarytool Keychain profile (see the header of $0 for the one-time store-credentials command)"
IDENTITY=$SIDEMOON_SIGN_IDENTITY
PROFILE=$SIDEMOON_NOTARY_PROFILE
# The identity must be a valid code-signing identity in the Keychain, and a Developer ID Application one.
IDENTITY_LINE=$(security find-identity -v -p codesigning | grep -F -- "$IDENTITY" | grep -F "\"$REQUIRED_CERTIFICATE: " || true)
[ -n "$IDENTITY_LINE" ] || fail "\"$IDENTITY\" is not a valid \"$REQUIRED_CERTIFICATE\" certificate in your Keychain (security find-identity -v -p codesigning lists them)"
xcrun --find notarytool > /dev/null 2>&1 || fail "notarytool not found (install Xcode or its command line tools)"

ROOT=$(cd "$(dirname "$0")/.." && pwd)
DIST="$ROOT/dist"
cd "$ROOT"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

move_to_trash() {
    if command -v trash > /dev/null 2>&1; then trash "$1"; else rm -rf "$1"; fi
}

notarize() {
    xcrun notarytool submit "$1" --keychain-profile "$PROFILE" --wait
}

# 1. The app, signed for release.
env SIDEMOON_RELEASE="$RELEASE_ON" SIDEMOON_SIGN_IDENTITY="$IDENTITY" "$ROOT/scripts/build-app.sh" "$DIST"
# The bundle's name, as build-app.sh takes it from the binary.
# shellcheck disable=SC2086
BIN_DIR=$(swift build -c "$CONFIGURATION" $UNIVERSAL_FLAGS --show-bin-path)
DYLD_FRAMEWORK_PATH="$BIN_DIR" "$BIN_DIR/$PRODUCT" "$PRINT_PLIST_FLAG" > "$WORK/Info.plist"
NAME=$(/usr/libexec/PlistBuddy -c "Print :CFBundleName" "$WORK/Info.plist")
APP="$DIST/$NAME.app"
[ -d "$APP" ] || fail "build-app.sh did not produce $APP"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
codesign --verify --deep --strict "$APP"

# 2. The app notarized and stapled first, so the copy inside the DMG carries its own ticket and opens
#    offline too. notarytool takes a zip of it.
APP_ZIP="$WORK/$NAME.$ZIP_EXTENSION"
ditto -c -k --keepParent "$APP" "$APP_ZIP"
notarize "$APP_ZIP"
xcrun stapler staple "$APP"

# 3. The DMG: the stapled app and a link to /Applications, signed, notarized and stapled.
DMG="$DIST/$NAME-$VERSION.$DMG_EXTENSION"
[ -e "$DMG" ] && move_to_trash "$DMG"
STAGING="$WORK/staging"
mkdir -p "$STAGING"
ditto "$APP" "$STAGING/$NAME.app"
ln -s "$APPLICATIONS_LINK" "$STAGING/$(basename "$APPLICATIONS_LINK")"
hdiutil create -volname "$NAME" -srcfolder "$STAGING" -format "$DMG_FORMAT" -ov "$DMG"
codesign --force --sign "$IDENTITY" --timestamp "$DMG"
notarize "$DMG"
xcrun stapler staple "$DMG"

# 4. What Gatekeeper will see.
spctl --assess --type execute --verbose=2 "$APP"
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
xcrun stapler validate "$APP"
xcrun stapler validate "$DMG"

echo "released $DMG"
shasum -a "$CHECKSUM_BITS" "$DMG"

# 5. Optional, not run here: publish the DMG as a Sparkle update.
SU_KEY=$(/usr/libexec/PlistBuddy -c "Print :SUPublicEDKey" "$APP/Contents/Info.plist" 2>/dev/null || true)
FEED=$(/usr/libexec/PlistBuddy -c "Print :SUFeedURL" "$APP/Contents/Info.plist" 2>/dev/null || true)
echo
echo "Sparkle update (optional, run by hand):"
if [ -z "$SU_KEY" ]; then
    echo "  This build has no SUPublicEDKey (CompanionConstants.Updates.publicEDKey is empty), so it cannot"
    echo "  update itself. Run $SPARKLE_BIN/generate_keys once, put the public key it prints in that constant,"
    echo "  and release again before publishing an appcast."
fi
echo "  Sign one archive (prints the sparkle:edSignature and length for its appcast item):"
echo "    $SPARKLE_BIN/sign_update \"$DMG\""
echo "  Or write the whole appcast from a folder of releases (signs them with the key in the Keychain):"
echo "    mkdir -p <updates-folder> && cp \"$DMG\" <updates-folder>/ && $SPARKLE_BIN/generate_appcast <updates-folder>"
echo "  Then upload the DMG and appcast.xml so that ${FEED:-the feed URL} serves the appcast."
