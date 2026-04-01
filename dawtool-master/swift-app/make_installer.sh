#!/bin/bash
# Builds a macOS .pkg installer for MT Song Tool, then packages it
# with Release Notes into a versioned .zip for distribution.
#
# Prerequisite: run make_swift_app.sh first so the .app bundle exists.
#
# Usage:
#   bash ~/Documents/"MT Song Tool"/dawtool-master/swift-app/make_installer.sh
#
# Output: ~/Desktop/MT Song Tool v{VERSION}.zip
#   containing:
#     MT Song Tool v{VERSION}/
#       MT Song Tool Installer.pkg
#       Release Notes.md

set -e
cd "$(dirname "$0")"

APP_NAME="MT Song Tool"
IDENTIFIER="com.multitracks.MTSongTool"
APP_SOURCE="/Applications/$APP_NAME.app"

if [ ! -d "$APP_SOURCE" ]; then
    echo "❌  $APP_NAME.app not found in /Applications."
    echo "    Run make_swift_app.sh first to build the app."
    exit 1
fi

# Read version from the installed app's Info.plist
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP_SOURCE/Contents/Info.plist" 2>/dev/null || echo "0.0.0")

RELEASE_DIR="$HOME/Desktop/$APP_NAME v${VERSION}"
OUTPUT_PKG="$RELEASE_DIR/$APP_NAME Installer.pkg"
OUTPUT_ZIP="$HOME/Desktop/$APP_NAME v${VERSION}.zip"
RELEASE_NOTES="release_notes/v${VERSION}.md"

# Check that release notes exist for this version
if [ ! -f "$RELEASE_NOTES" ]; then
    echo "❌  Release notes not found: $RELEASE_NOTES"
    echo "    Create the file before building the installer."
    exit 1
fi

# ── Create a temporary payload root ──────────────────────────────────────────
PAYLOAD="$(mktemp -d)"
mkdir -p "$PAYLOAD/$APP_NAME.app"
cp -R "$APP_SOURCE/" "$PAYLOAD/$APP_NAME.app/"

# ── Build the .pkg ───────────────────────────────────────────────────────────
echo "==> Building installer package…"
rm -rf "$RELEASE_DIR"
mkdir -p "$RELEASE_DIR"

pkgbuild \
    --root "$PAYLOAD" \
    --scripts "installer/scripts" \
    --identifier "$IDENTIFIER" \
    --version "$VERSION" \
    --install-location "/Applications" \
    "$OUTPUT_PKG"

rm -rf "$PAYLOAD"

# ── Copy release notes ───────────────────────────────────────────────────────
cp "$RELEASE_NOTES" "$RELEASE_DIR/Release Notes.md"

# ── Zip the folder ───────────────────────────────────────────────────────────
echo "==> Creating release zip…"
cd "$HOME/Desktop"
rm -f "$OUTPUT_ZIP"
zip -r "$OUTPUT_ZIP" "$APP_NAME v${VERSION}"
rm -rf "$RELEASE_DIR"

echo ""
echo "✅  Release ready: ~/Desktop/$APP_NAME v${VERSION}.zip"
echo ""
echo "    Contents:"
echo "      $APP_NAME Installer.pkg"
echo "      Release Notes.md"
echo ""
echo "Share the .zip — everything the recipient needs is inside."
echo ""
