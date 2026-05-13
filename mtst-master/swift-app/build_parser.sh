#!/bin/bash
# Builds parse_als.py into a standalone directory using PyInstaller (--onedir).
# Output: swift-app/dist/parse_als/  (folder with binary + libs, no extraction delay)

set -e

DAWTOOL_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$DAWTOOL_ROOT"

VENV="$DAWTOOL_ROOT/venv"
PYINSTALLER="$VENV/bin/pyinstaller"

if [ ! -f "$PYINSTALLER" ]; then
    echo "❌  PyInstaller not found. Install it first:"
    echo "    $VENV/bin/pip install pyinstaller"
    exit 1
fi

# Ensure dependencies are installed
"$VENV/bin/pip" install lxml hexdump librosa numpy -q 2>&1

echo "==> Building parse_als (onedir for fast startup)…"
"$PYINSTALLER" \
    --onedir \
    --name parse_als \
    --distpath "swift-app/dist" \
    --workpath "swift-app/build_pyinstaller" \
    --specpath "swift-app" \
    --noconfirm \
    --clean \
    --hidden-import dawtool \
    --hidden-import dawtool.daw \
    --hidden-import dawtool.daw.ableton \
    --hidden-import pyexpat \
    --hidden-import xml.parsers.expat \
    --hidden-import lxml \
    --hidden-import lxml.etree \
    --collect-all lxml \
    --hidden-import hexdump \
    --collect-all librosa \
    --hidden-import librosa \
    --collect-all numba \
    --hidden-import numba \
    --add-data "$DAWTOOL_ROOT/click-samples:click-samples" \
    --paths "$DAWTOOL_ROOT" \
    parse_als.py 2>&1

if [ ! -f "swift-app/dist/parse_als/parse_als" ]; then
    echo "❌  Build failed — binary not found"
    exit 1
fi

echo "✅  Parser ready: swift-app/dist/parse_als/"
