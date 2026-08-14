#!/bin/bash
#
# Build BeszelBar without Xcode.
#
# Upstream's build.sh drives XcodeGen and xcodebuild, which need a full Xcode
# install (~15 GB). This script builds the same sources with the Swift compiler
# that ships in the Command Line Tools and assembles the .app bundle by hand.
#
# The one thing it gives up is the compiled asset catalog: `actool` comes with
# Xcode, so the icon is built into an .icns with iconutil instead. For a menu bar
# app (LSUIElement) that icon is barely seen anyway.
#
# Use upstream's build.sh instead if you do have Xcode.
#
# Pass --install to copy the finished bundle into /Applications.

set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="BeszelBar"
BUNDLE_ID="com.nohitdev.BeszelBar"
VERSION="1.0.1"
BUILD_NUMBER="2"
# A dot directory, not build/, on purpose. Spotlight indexes app bundles
# wherever it finds them, so a visible copy here means "beszelbar" matches twice
# in search — once from /Applications and once from the build output. Spotlight
# skips dot directories, upstream's build/ is left to upstream's build.sh.
OUT_DIR=".dist"
APP_DIR="${OUT_DIR}/${APP_NAME}.app"

INSTALL=0
for arg in "$@"; do
    case "$arg" in
        --install) INSTALL=1 ;;
        *) echo "Unknown argument: $arg" >&2; exit 2 ;;
    esac
done

echo "==> Compiling (release)"
swift build -c release

BINARY="$(swift build -c release --show-bin-path)/${APP_NAME}"
if [[ ! -x "$BINARY" ]]; then
    echo "Build produced no executable at ${BINARY}" >&2
    exit 1
fi

echo "==> Assembling ${APP_NAME}.app"
rm -rf "$APP_DIR"
mkdir -p "${APP_DIR}/Contents/MacOS"
mkdir -p "${APP_DIR}/Contents/Resources"

cp "$BINARY" "${APP_DIR}/Contents/MacOS/${APP_NAME}"

# Build the icon from the same PNGs the asset catalog uses.
ICONSET="$(mktemp -d)/${APP_NAME}.iconset"
mkdir -p "$ICONSET"
APPICON_DIR="Resources/Assets.xcassets/AppIcon.appiconset"
if [[ -d "$APPICON_DIR" ]]; then
    for spec in "16 16x16" "32 16x16@2x" "32 32x32" "64 32x32@2x" \
                "128 128x128" "256 128x128@2x" "256 256x256" "512 256x256@2x" \
                "512 512x512" "1024 512x512@2x"; do
        set -- $spec
        size="$1"; target="$2"
        src=""
        case "$target" in
            *@2x) base="${target%@2x}"; src="${APPICON_DIR}/appicon_${base%%x*}@2x.png" ;;
            *)    src="${APPICON_DIR}/appicon_${target%%x*}.png" ;;
        esac
        if [[ -f "$src" ]]; then
            cp "$src" "${ICONSET}/icon_${target}.png"
        fi
    done

    if [[ -n "$(ls -A "$ICONSET" 2>/dev/null)" ]]; then
        iconutil -c icns "$ICONSET" -o "${APP_DIR}/Contents/Resources/${APP_NAME}.icns" 2>/dev/null \
            && echo "    icon built" \
            || echo "    icon skipped (iconutil declined the set)"
    fi
fi

# Concrete Info.plist. Upstream's copy is full of $(VAR) placeholders that only
# xcodebuild expands, so writing it out here is simpler than substituting.
cat > "${APP_DIR}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${BUILD_NUMBER}</string>
    <key>CFBundleIconFile</key>
    <string>${APP_NAME}</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.utilities</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHumanReadableCopyright</key>
    <string>Copyright © 2025 Loriage. MIT.</string>
</dict>
PLIST
echo "</plist>" >> "${APP_DIR}/Contents/Info.plist"

plutil -lint "${APP_DIR}/Contents/Info.plist" > /dev/null

# Ad-hoc signature. Not a Developer ID signature — Gatekeeper will still ask on
# first launch — but it gives the bundle a stable identity, which macOS needs to
# keep keychain access and accessibility grants attached across rebuilds.
echo "==> Signing (ad-hoc)"
codesign --force --deep --sign - "$APP_DIR" 2>/dev/null \
    && echo "    signed" \
    || echo "    signing skipped"

echo
echo "Built: ${APP_DIR}"

if [[ "$INSTALL" -eq 1 ]]; then
    DEST="/Applications/${APP_NAME}.app"
    echo "==> Installing to ${DEST}"
    # Replacing a bundle underneath a running process leaves it running on
    # deleted code, so stop it first.
    pkill -f "${APP_NAME}.app/Contents/MacOS/${APP_NAME}" 2>/dev/null && sleep 1 || true
    rm -rf "$DEST"
    cp -R "$APP_DIR" /Applications/
    echo "    installed"
    echo
    echo "Run:   open ${DEST}"
else
    echo "Run:   open ${APP_DIR}"
    echo "       ./build-spm.sh --install   # to put it in /Applications"
fi
