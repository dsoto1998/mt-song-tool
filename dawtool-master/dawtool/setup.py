"""
py2app setup — builds dawtool.app for macOS.

Usage:
    pip install py2app
    python setup.py py2app

The finished .app will be in ./dist/
"""

from setuptools import setup

APP       = ["dawtool_app.py"]
DATA_FILES = []

OPTIONS = {
    # Include the dawtool package that lives next to this script
    "packages": ["dawtool"],
    "includes": ["tkinter", "tkinter.ttk", "tkinter.filedialog"],
    # Optional: enable drag-and-drop if tkinterdnd2 is installed
    # "packages": ["dawtool", "tkinterdnd2"],
    "iconfile": "",          # swap in a .icns file path if you have one
    "plist": {
        "CFBundleName":             "dawtool",
        "CFBundleDisplayName":      "dawtool",
        "CFBundleShortVersionString": "1.0",
        "CFBundleVersion":          "1.0.0",
        "NSHumanReadableCopyright": "dawtool",
        "NSHighResolutionCapable":  True,
        # Accept drops of .als/.flp/.cue onto the Dock icon
        "CFBundleDocumentTypes": [
            {
                "CFBundleTypeName":       "Ableton Live Set",
                "CFBundleTypeExtensions": ["als"],
                "CFBundleTypeRole":       "Viewer",
            },
            {
                "CFBundleTypeName":       "FL Studio Project",
                "CFBundleTypeExtensions": ["flp"],
                "CFBundleTypeRole":       "Viewer",
            },
            {
                "CFBundleTypeName":       "Cue Sheet",
                "CFBundleTypeExtensions": ["cue"],
                "CFBundleTypeRole":       "Viewer",
            },
        ],
    },
    "argv_emulation": True,   # lets you double-click .als/.flp and it opens in the app
}

setup(
    name="dawtool",
    app=APP,
    data_files=DATA_FILES,
    options={"py2app": OPTIONS},
    setup_requires=["py2app"],
)
