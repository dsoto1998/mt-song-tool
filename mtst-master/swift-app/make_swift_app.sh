#!/bin/bash
# Builds a portable MT Song Tool.app with the parser bundled inside.
# Run from Terminal:
#   bash ~/Documents/"Claude Apps"/"MT Song Tool"/mtst-master/swift-app/make_swift_app.sh

set -e
cd "$(dirname "$0")"

VERSION="1.3.3"
APP_NAME="MT Song Tool"
BUNDLE_ID="com.multitracks.MTSongTool"
DAWTOOL_ROOT="$(cd .. && pwd)"

# ── Step 1: Build the Python parser into a standalone binary ─────────────────
echo "==> Step 1/4: Building parser binary (PyInstaller)…"
bash build_parser.sh

PARSER_DIR="dist/parse_als"
if [ ! -f "$PARSER_DIR/parse_als" ]; then
    echo "❌  Parser binary not found at $PARSER_DIR/parse_als"
    exit 1
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

# Parser directory (bundled alongside main executable)
cp -R "$PARSER_DIR" "$MACOS/parse_als_dir"

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

# Metronome sounds (AIF click files for Edit tab metronome)
METRO_SRC="$DAWTOOL_ROOT/metronome sounds"
METRO_DEST="$RESOURCES/metronome"
if [ -d "$METRO_SRC" ]; then
    mkdir -p "$METRO_DEST"
    cp "$METRO_SRC/"*.aif "$METRO_DEST/" 2>/dev/null || true
    echo "      Resources/metronome/      — metronome click sounds"
else
    echo "⚠️   Metronome sounds not found — metronome will use dev fallback path"
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
# Quit any running instance of MT Song Tool so the new version is used immediately
killall "MT Song Tool" 2>/dev/null || true

# Clear macOS quarantine flag — prevents Gatekeeper translocation which would
# cause the system to keep launching the old version from a randomized path
xattr -cr "/Applications/MT Song Tool.app"

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

# Wrap the .pkg + Release Notes in a versioned folder inside a zip
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
echo "      └── Release Notes.md"
echo ""
echo "    Share the zip — recipient unzips and double-clicks the .pkg to install."
echo "    No Python, no FFmpeg, no Homebrew required."
echo ""
echo "If macOS says the app is damaged after install, run:"
echo "  xattr -cr /Applications/\"$APP_NAME\".app"
echo ""
