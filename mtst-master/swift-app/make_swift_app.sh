#!/bin/bash
# Builds a portable MT Song Tool.app with the parser bundled inside.
# Run from Terminal:
#   bash ~/Documents/"Claude Apps"/"MT Song Tool"/mtst-master/swift-app/make_swift_app.sh

set -e
cd "$(dirname "$0")"

VERSION="1.5.0"
APP_NAME="MT Song Tool"
BUNDLE_ID="com.multitracks.MTSongTool"
DAWTOOL_ROOT="$(cd .. && pwd)"

# ── Flag parsing ─────────────────────────────────────────────────────────────
SKIP_PARSER=false
for arg in "$@"; do
    case "$arg" in
        --skip-parser) SKIP_PARSER=true ;;
    esac
done

# ── Step 1: Build the Python parser into a standalone binary ─────────────────
PARSER_DIR="dist/parse_als"
if [ "$SKIP_PARSER" = true ]; then
    echo "==> Step 1/4: Skipping parser build (--skip-parser)"
    if [ ! -f "$PARSER_DIR/parse_als" ]; then
        echo "❌  No existing parser binary at $PARSER_DIR/parse_als — cannot skip."
        echo "    Run without --skip-parser first to build the parser."
        exit 1
    fi
    echo "    Using existing binary: $PARSER_DIR/parse_als"
else
    echo "==> Step 1/4: Building parser binary (PyInstaller)…"
    bash build_parser.sh
    if [ ! -f "$PARSER_DIR/parse_als" ]; then
        echo "❌  Parser binary not found at $PARSER_DIR/parse_als"
        exit 1
    fi
fi

# ── Step 2: Build the Swift app ──────────────────────────────────────────────
echo ""
echo "==> Step 2/4: Building Swift app (release)…"
MACOSX_DEPLOYMENT_TARGET=13.0 swift build -c release 2>&1

SWIFT_BIN=".build/release/MTSongTool"
if [ ! -f "$SWIFT_BIN" ]; then
    echo "❌  Swift build failed — binary not found at $SWIFT_BIN"
    exit 1
fi

# ── Step 3: Assemble the .app bundle ────────────────────────────────────────
echo ""
echo "==> Step 3/4: Creating .app bundle…"

APP_BUNDLE="/tmp/mtst_app_build/$APP_NAME.app"
CONTENTS="$APP_BUNDLE/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"
FRAMEWORKS="$CONTENTS/Frameworks"

rm -rf "/tmp/mtst_app_build"
mkdir -p "$MACOS" "$RESOURCES" "$FRAMEWORKS"

# Swift binary (main executable)
cp "$SWIFT_BIN" "$MACOS/MTSongTool"

# Parser directory — in Resources (not MacOS) so codesign doesn't recurse into
# Python _internal/ and choke on .dist-info dirs / .py files
cp -R "$PARSER_DIR" "$RESOURCES/parse_als_dir"
# Strip pip metadata dirs — not needed at runtime, confuse codesign
find "$RESOURCES/parse_als_dir" -type d -name "*.dist-info" -exec rm -rf {} + 2>/dev/null || true

# Font resources (from shared fonts/ directory)
FONTS_DIR="$DAWTOOL_ROOT/fonts"
cp "$FONTS_DIR/Horizon_Regular.otf" "$RESOURCES/"
cp "$FONTS_DIR/Lato-Regular.ttf" "$RESOURCES/"
cp "$FONTS_DIR/Lato-Bold.ttf" "$RESOURCES/"
cp "$FONTS_DIR/Lato-Light.ttf" "$RESOURCES/"
cp "$FONTS_DIR/Lato-Black.ttf" "$RESOURCES/"

# App icon
ICNS="$DAWTOOL_ROOT/sonic.icns"
if [ -f "$ICNS" ]; then
    cp "$ICNS" "$RESOURCES/AppIcon.icns"
fi

# FFmpeg binary + dylibs (reused from AudioConverter build — enables audio conversion in MTST)
FFMPEG_SRC="$DAWTOOL_ROOT/../AudioConverter/dist/Audio Converter.app/Contents/Frameworks"
if [ -f "$FFMPEG_SRC/ffmpeg" ]; then
    cp "$FFMPEG_SRC/ffmpeg" "$FRAMEWORKS/ffmpeg"
    chmod +x "$FRAMEWORKS/ffmpeg"
    # Copy all real dylibs (skip symlinks — e.g. libavif which belongs to PIL, not FFmpeg)
    find "$FFMPEG_SRC" -maxdepth 1 -name "*.dylib" -not -type l -exec cp {} "$FRAMEWORKS/" \;
    # Remove macOS quarantine flag — without this, macOS silently blocks the binary at runtime
    xattr -cr "$FRAMEWORKS"
    echo "      Contents/Frameworks/ — FFmpeg binary + audio codec dylibs (quarantine cleared)"
else
    echo "⚠️   FFmpeg not found — audio conversion will not be available in this build."
    echo "    Expected: $FFMPEG_SRC/ffmpeg"
fi

# Info.plist
cat > "$CONTENTS/Info.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>MT Song Tool</string>
    <key>CFBundleDisplayName</key>
    <string>MT Song Tool</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key>
    <string>MTSongTool</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>ATSApplicationFontsPath</key>
    <string>.</string>
</dict>
</plist>
PLIST

echo ""
echo "✅  App built: $APP_BUNDLE"
echo ""
echo "    Contents:"
echo "      MacOS/MTSongTool          — Swift UI"
echo "      MacOS/parse_als           — Python parser (standalone)"
echo "      Resources/                — fonts + icon"
echo "      Contents/Frameworks/      — FFmpeg binary + audio codec dylibs"
echo ""

# ── Remove AppleDouble metadata files ────────────────────────────────────────
# cp creates ._* files (e.g. ._libvpx.11.dylib) when copying between volumes.
# These are physical files — NOT extended attributes — so xattr -cr doesn't
# remove them. codesign treats ._*.dylib as unsigned code objects → the bundle
# signature becomes invalid and Gatekeeper rejects with "not supported on Mac".
find "$APP_BUNDLE" -name "._*" -delete

# ── Ad-hoc re-sign the assembled bundle ─────────────────────────────────────
# SPM signs the binary as a standalone executable (no bundle resources). After
# we add Resources and Frameworks, that signature is invalid. Re-sign with an
# ad-hoc identity so macOS accepts it on all machines.
#
# Sign order: .so/.dylib extensions first, then main binary, then bundle.
# We avoid --deep because the PyInstaller _internal/ directory contains
# .dist-info dirs and .py files that confuse codesign's recursive checker.
# parse_als_dir lives in Resources/ (not MacOS/) so it is not recursively
# checked when signing the MacOS/MTSongTool executable.
echo "==> Signing bundle (ad-hoc)…"

# Sign dylibs inside Frameworks/
find "$FRAMEWORKS" -type f \( -name "*.dylib" -o -name "ffmpeg" \) | while read f; do
    codesign --force --sign - "$f" 2>/dev/null
done

# Sign Python extension modules inside parse_als_dir
find "$RESOURCES/parse_als_dir" -type f \( -name "*.so" -o -name "*.dylib" \) | while read f; do
    codesign --force --sign - "$f" 2>/dev/null
done

# Sign the parse_als executable
codesign --force --sign - "$RESOURCES/parse_als_dir/parse_als"

# Sign the main Swift binary, then the full bundle (no --deep)
codesign --force --sign - "$MACOS/MTSongTool"
codesign --force --sign - "$APP_BUNDLE"
echo "✅  Bundle signed"
echo ""

# ── Install directly to /Applications (no sudo needed for admin users) ────────
echo "==> Installing to /Applications…"
killall "MT Song Tool" 2>/dev/null || true
# If the existing bundle is root-owned (from a previous sudo install), take ownership once
if [ -d "/Applications/$APP_NAME.app" ] && [ ! -w "/Applications/$APP_NAME.app" ]; then
    echo "    Taking ownership of existing bundle (one-time, requires password)…"
    sudo chown -R "$(whoami)" "/Applications/$APP_NAME.app"
fi
rm -rf "/Applications/$APP_NAME.app"
cp -R "$APP_BUNDLE" "/Applications/"
xattr -cr "/Applications/$APP_NAME.app"
echo "✅  Installed: /Applications/$APP_NAME.app"
echo ""

# ── Step 4: Build the .pkg installer ─────────────────────────────────────────
echo "==> Step 4/4: Building .pkg installer…"

VERSIONS_DIR="/Volumes/MTEng0/claude-apps/mt-song-tool/Versions"
mkdir -p "$VERSIONS_DIR"
PKG_OUT="$VERSIONS_DIR/$APP_NAME $VERSION.pkg"
PKG_STAGING="/tmp/mtst_pkg_staging"
PKG_SCRIPTS="/tmp/mtst_pkg_scripts"

# postinstall script: force-quits any running instance, then clears the
# macOS quarantine flag so the updated app launches correctly every time.
rm -rf "$PKG_SCRIPTS"
mkdir -p "$PKG_SCRIPTS"
cat > "$PKG_SCRIPTS/postinstall" << 'POSTINSTALL'
#!/bin/bash
APP="/Applications/MT Song Tool.app"

# Quit any running instance so the new version is used immediately
killall "MT Song Tool" 2>/dev/null || true

# Clear macOS quarantine flag — the PKG carries the signed bundle; no re-signing
# needed. Re-signing in postinstall would corrupt the pre-signed bundle if any
# codesign step fails partway through (which is silent due to error suppression).
xattr -cr "$APP"

# Fix permissions — pkgbuild installs as root:wheel with 700, making binaries
# non-executable by the running user (causes "not supported on this Mac" on launch
# and parser fallback to dev python3 path).
chmod -R 755 "$APP"

exit 0
POSTINSTALL
chmod +x "$PKG_SCRIPTS/postinstall"

rm -rf "$PKG_STAGING"
mkdir -p "$PKG_STAGING/Applications"
cp -R "$APP_BUNDLE" "$PKG_STAGING/Applications/"

pkgbuild \
    --root "$PKG_STAGING" \
    --scripts "$PKG_SCRIPTS" \
    --identifier "$BUNDLE_ID" \
    --version "$VERSION" \
    --install-location "/" \
    "$PKG_OUT"

rm -rf "$PKG_STAGING" "$PKG_SCRIPTS"

# Wrap the .pkg + Release Notes + Install helper in a versioned folder inside a zip
RELEASE_FOLDER="$APP_NAME v$VERSION"
ZIP_STAGING="/tmp/mtst_zip_staging"
ZIP_OUT="$VERSIONS_DIR/$RELEASE_FOLDER.zip"
RELEASE_NOTES_SRC="$DAWTOOL_ROOT/swift-app/Sources/MTSongTool/Resources/Release Notes.md"
RELEASE_NOTES="$DAWTOOL_ROOT/../Release Notes.md"
# Keep root-level Release Notes in sync with the bundled source of truth
[ -f "$RELEASE_NOTES_SRC" ] && cp "$RELEASE_NOTES_SRC" "$RELEASE_NOTES"
rm -rf "$ZIP_STAGING"
mkdir -p "$ZIP_STAGING/$RELEASE_FOLDER"
mv "$PKG_OUT" "$ZIP_STAGING/$RELEASE_FOLDER/"
[ -f "$RELEASE_NOTES" ] && cp "$RELEASE_NOTES" "$ZIP_STAGING/$RELEASE_FOLDER/"

# Install helper script — handles AirDrop quarantine without needing Developer ID signing.
# macOS Gatekeeper blocks unsigned .pkg files received via AirDrop with no visible "Open Anyway".
# A .command file (shell script) shows a plain "are you sure?" dialog instead — user clicks Open,
# Terminal runs the script, quarantine is stripped from the .pkg, macOS Installer opens normally.
INSTALL_CMD="$ZIP_STAGING/$RELEASE_FOLDER/Install $APP_NAME.command"
cat > "$INSTALL_CMD" << 'INSTALLSCRIPT'
#!/bin/bash
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKG="$(ls "$DIR"/MT\ Song\ Tool*.pkg 2>/dev/null | head -1)"

if [ -z "$PKG" ]; then
    echo "Error: MT Song Tool .pkg not found next to this script."
    read -rsp $'Press Enter to close...\n'
    exit 1
fi

echo "Removing security quarantine from installer..."
xattr -d com.apple.quarantine "$PKG" 2>/dev/null || true

echo "Opening installer..."
open "$PKG"
INSTALLSCRIPT
chmod +x "$INSTALL_CMD"

cd "$ZIP_STAGING"
zip -r "$ZIP_OUT" "$RELEASE_FOLDER"
cd - > /dev/null
rm -rf "$ZIP_STAGING"
rm -rf "/tmp/mtst_app_build"

echo ""
echo "✅  Distribution zip ready: $ZIP_OUT"
echo ""
echo "    Contains: $RELEASE_FOLDER/"
echo "      ├── $APP_NAME $VERSION.pkg"
echo "      ├── Install $APP_NAME.command"
echo "      └── Release Notes.md"
echo ""
echo "    AirDrop the zip — recipient unzips, then:"
echo "      • Normal install:  double-click the .pkg"
echo "      • If blocked:      double-click 'Install $APP_NAME.command' instead"
echo "    No Python, no FFmpeg, no Homebrew required."
echo ""
