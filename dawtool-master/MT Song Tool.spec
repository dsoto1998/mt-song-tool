# -*- mode: python ; coding: utf-8 -*-


a = Analysis(
    ['dawtool_app.py'],
    pathex=[],
    binaries=[],
    datas=[('sonic.icns', '.'), ('Horizon_Regular.otf', '.')],
    hiddenimports=[],
    hookspath=[],
    hooksconfig={},
    runtime_hooks=[],
    excludes=[],
    noarchive=False,
    optimize=0,
)
pyz = PYZ(a.pure)

exe = EXE(
    pyz,
    a.scripts,
    [],
    exclude_binaries=True,
    name='MT Song Tool',
    debug=False,
    bootloader_ignore_signals=False,
    strip=False,
    upx=True,
    console=False,
    disable_windowed_traceback=False,
    argv_emulation=False,
    target_arch=None,
    codesign_identity=None,
    entitlements_file=None,
    icon=['sonic.icns'],
)
coll = COLLECT(
    exe,
    a.binaries,
    a.datas,
    strip=False,
    upx=True,
    upx_exclude=[],
    name='MT Song Tool',
)
app = BUNDLE(
    coll,
    name='MT Song Tool.app',
    icon='sonic.icns',
    bundle_identifier=None,
)
