#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────
#  build_app.sh — one-shot build for dawtool.app
#  Run from inside the folder that contains dawtool_app.py
# ─────────────────────────────────────────────────────────────────
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

echo "==> Installing / upgrading dependencies…"
pip install --quiet --upgrade py2app

# Optional: install tkinterdnd2 for native drag-and-drop support
# pip install tkinterdnd2

echo "==> Cleaning previous build…"
rm -rf build dist

echo "==> Building dawtool.app…"
python setup.py py2app 2>&1

echo ""
echo "✅  Done! App is at:"
echo "    $SCRIPT_DIR/dist/dawtool.app"
echo ""
echo "Open it with:"
echo "    open dist/dawtool.app"
