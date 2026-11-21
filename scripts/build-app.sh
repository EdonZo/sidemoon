#!/bin/sh
# Builds Sidemoon.app: release build of the SidemoonApp product, wrapped in a bundle whose Info.plist
# the binary prints from CompanionConstants.App (bundle id and versions are defined only there),
# plus the `sidemoon` CLI as a helper inside the bundle (the hooks and the channel run it) and the
# Sparkle framework (automatic updates), then signed.
# usage: scripts/build-app.sh [output-directory]   (default: ./dist)
# SIDEMOON_RELEASE=1 signs for notarization: hardened runtime and a secure timestamp (scripts/release.sh
# sets it). It needs a real certificate in SIDEMOON_SIGN_IDENTITY. Otherwise the signature is as before.
set -eu

PRODUCT=SidemoonApp
HELPER_PRODUCT=sidemoon
CONFIGURATION=release
PRINT_PLIST_FLAG=--print-info-plist
# Info.plist key naming the helper's path inside the bundle (CompanionConstants.App.helperPlistKey).
HELPER_PLIST_KEY=SidemoonHelperPath
HELPER_ID_SUFFIX=cli
# The icon, drawn in code and committed (regenerate with: SidemoonApp --render-icon <dir>).
ICON_SOURCE=Resources/AppIcon.icns
# Ad-hoc by default. Set SIDEMOON_SIGN_IDENTITY to a certificate name or hash for a stable signature,
# so macOS keeps permission grants (Screen Recording) across rebuilds.
SIGN_IDENTITY=${SIDEMOON_SIGN_IDENTITY:--}
AD_HOC_IDENTITY=-
RELEASE=${SIDEMOON_RELEASE:-0}
RELEASE_ON=1
# No entitlements: the app is not sandboxed, and nothing it does under the hardened runtime needs an
# exception (it starts processes, asks for Screen Recording, registers Carbon hotkeys, and loads Sparkle,
# which is signed here with the same identity, so library validation accepts it).
RELEASE_FLAGS="--options runtime --timestamp"
# A release runs on Apple Silicon and Intel Macs; a development build is for this Mac only (faster).
UNIVERSAL_FLAGS="--arch arm64 --arch x86_64"
DEV_FLAGS=--timestamp=none
# Sparkle, embedded from the build products and found by the binary through this runpath.
SPARKLE_FRAMEWORK=Sparkle.framework
SPARKLE_VERSION_DIR=Versions/B
FRAMEWORKS_DIR=Contents/Frameworks
FRAMEWORKS_RPATH=@executable_path/../Frameworks

ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT_DIR=${1:-"$ROOT/dist"}

if [ "$RELEASE" = "$RELEASE_ON" ]; then
    if [ "$SIGN_IDENTITY" = "$AD_HOC_IDENTITY" ]; then
        echo "SIDEMOON_RELEASE=$RELEASE_ON needs SIDEMOON_SIGN_IDENTITY set to a Developer ID Application certificate" >&2
        exit 1
    fi
    SIGN_FLAGS=$RELEASE_FLAGS
    ARCH_FLAGS=$UNIVERSAL_FLAGS
else
    SIGN_FLAGS=$DEV_FLAGS
    ARCH_FLAGS=
fi

# Signs one piece of code; SIGN_FLAGS is split on purpose, the identity is not.
sign() {
    # shellcheck disable=SC2086
    codesign --force --sign "$SIGN_IDENTITY" $SIGN_FLAGS "$@"
}

cd "$ROOT"
# ARCH_FLAGS is split on purpose.
# shellcheck disable=SC2086
swift build -c "$CONFIGURATION" $ARCH_FLAGS --product "$PRODUCT"
# shellcheck disable=SC2086
swift build -c "$CONFIGURATION" $ARCH_FLAGS --product "$HELPER_PRODUCT"
# shellcheck disable=SC2086
BIN_DIR=$(swift build -c "$CONFIGURATION" $ARCH_FLAGS --show-bin-path)
BINARY="$BIN_DIR/$PRODUCT"
HELPER_BINARY="$BIN_DIR/$HELPER_PRODUCT"
SPARKLE_SOURCE="$BIN_DIR/$SPARKLE_FRAMEWORK"
[ -d "$SPARKLE_SOURCE" ] || { echo "no $SPARKLE_FRAMEWORK in $BIN_DIR" >&2; exit 1; }

PLIST=$(mktemp)
trap 'rm -f "$PLIST"' EXIT
# The binary loads Sparkle on launch; before it sits in a bundle, the framework is next to it.
DYLD_FRAMEWORK_PATH="$BIN_DIR" "$BINARY" "$PRINT_PLIST_FLAG" > "$PLIST"
NAME=$(/usr/libexec/PlistBuddy -c "Print :CFBundleName" "$PLIST")
EXECUTABLE=$(/usr/libexec/PlistBuddy -c "Print :CFBundleExecutable" "$PLIST")
BUNDLE_ID=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$PLIST")
HELPER_PATH=$(/usr/libexec/PlistBuddy -c "Print :$HELPER_PLIST_KEY" "$PLIST")
ICON_FILE=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIconFile" "$PLIST")

APP="$OUT_DIR/$NAME.app"
if [ -e "$APP" ]; then
    if command -v trash > /dev/null 2>&1; then trash "$APP"; else rm -rf "$APP"; fi
fi
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/$(dirname "$HELPER_PATH")" "$APP/$FRAMEWORKS_DIR"
cp "$PLIST" "$APP/Contents/Info.plist"
cp "$BINARY" "$APP/Contents/MacOS/$EXECUTABLE"
install_name_tool -add_rpath "$FRAMEWORKS_RPATH" "$APP/Contents/MacOS/$EXECUTABLE"
# ditto keeps the framework's symlinks and permissions.
ditto "$SPARKLE_SOURCE" "$APP/$FRAMEWORKS_DIR/$SPARKLE_FRAMEWORK"
cp "$HELPER_BINARY" "$APP/$HELPER_PATH"
printf 'APPL????' > "$APP/Contents/PkgInfo"
cp "$ROOT/$ICON_SOURCE" "$APP/Contents/Resources/$ICON_FILE"

# Nested code is signed before the bundle that contains it. Sparkle's pieces go in the order its
# documentation gives (Installer.xpc, Downloader.xpc keeping its entitlements, Autoupdate, Updater.app,
# then the framework), never with --deep.
SPARKLE="$APP/$FRAMEWORKS_DIR/$SPARKLE_FRAMEWORK"
SPARKLE_VERSION="$SPARKLE/$SPARKLE_VERSION_DIR"
sign --identifier "$BUNDLE_ID.$HELPER_ID_SUFFIX" "$APP/$HELPER_PATH"
sign "$SPARKLE_VERSION/XPCServices/Installer.xpc"
sign --preserve-metadata=entitlements "$SPARKLE_VERSION/XPCServices/Downloader.xpc"
sign "$SPARKLE_VERSION/Autoupdate"
sign "$SPARKLE_VERSION/Updater.app"
sign "$SPARKLE"
sign "$APP"
codesign --verify --strict "$APP/$HELPER_PATH"
codesign --verify --strict "$SPARKLE"
codesign --verify --strict "$APP"
echo "built $APP"
