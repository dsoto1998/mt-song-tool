#!/bin/bash
# Builds MT Song Tool.app as a self-contained native Mac app using PyInstaller.
# Run once from Terminal: bash ~/Documents/dawtool-master/make_app.sh

set -e
cd ~/Documents/dawtool-master

echo "==> Installing PyInstaller…"
venv/bin/pip install pyinstaller --quiet

echo "==> Building MT Song Tool.app…"
venv/bin/pyinstaller \
  --windowed \
  --name "MT Song Tool" \
  --icon "sonic.icns" \
  --add-data "sonic.icns:." \
  --add-data "Horizon_Regular.otf:." \
  --noconfirm \
  --clean \
  dawtool_app.py

echo "==> Moving to Applications…"
rm -rf ~/Applications/"MT Song Tool".app
mv dist/"MT Song Tool".app ~/Applications/"MT Song Tool".app

echo ""
echo "✅  Done! MT Song Tool.app is in ~/Applications"
echo ""
echo "To launch:  open ~/Applications/"MT Song Tool".app"
echo ""
echo "To start at login: System Settings → General → Login Items → add MT Song Tool.app"
