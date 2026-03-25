# Technology Stack

**Analysis Date:** 2026-03-25

## Languages

**Primary:**
- Swift - macOS 13+ native UI and application logic
- Python 3 (3.7+) - Ableton Live file parsing and validation (parse_als.py)

**Secondary:**
- Bash - Build automation and deployment scripting

## Runtime

**Environment:**
- macOS 13+ (Ventura or later)
- Swift runtime bundled with Xcode

**Package Manager:**
- Swift Package Manager (SPM) - Swift dependencies
- pip - Python dependencies (development and build-time only)
- Virtual environment (`venv`) - Python isolation at `dawtool-master/venv/`

## Frameworks

**Core UI:**
- SwiftUI - Modern declarative UI framework (built-in, no external dependency)
- AppKit - Native macOS window management and application delegate
- CoreText - Font management and registration

**Audio Processing:**
- AVFoundation - Audio file analysis and format detection
- FFmpeg (bundled binary) - Audio format conversion and resampling (copied from AudioConverter project)

**Python Parsing:**
- lxml - XML parsing with fallback handling for system pyexpat issues
- xml.etree.ElementTree (stdlib) - Primary XML parsing
- dawtool - Custom Ableton Live format library (internal, from dawtool-master/)
- gzip (stdlib) - Reading/writing compressed .als files
- json (stdlib) - JSON serialization for stdin/stdout protocol

## Key Dependencies

**Critical (Swift):**
- Foundation - Core runtime services (Process, UserDefaults, FileManager)
- AVFoundation 1.0+ - Audio file I/O and property inspection

**Critical (Python):**
- lxml - XML parsing for .als files (installed via pip during build)
- hexdump - Used by dawtool.daw.flstudio_core at startup (must be present in venv or parser crashes silently)
- scipy - Listed in dawtool setup.py (test dependency)
- dawtool - Ableton Live parsing library (internal package at `dawtool-master/`)

**Infrastructure:**
- PyInstaller - Builds parse_als.py into a standalone macOS binary (used during build, not runtime)
- pkgbuild - macOS package/installer creation (macOS native utility)
- zip - Distribution archive creation (macOS native utility)

## Configuration

**Environment Variables:**
- `DAWTOOL_PATH` - Optional override for dawtool location; set during dev fallback or parser startup
- No secrets or API keys configured

**Build Configuration:**
- `Package.swift` - Swift Package Manager manifest at `dawtool-master/swift-app/Package.swift`
- Platform requirement: `macOS(.v13)` minimum
- Single executableTarget: `MTSongTool` with bundled Resources (fonts, icon)

**Runtime Configuration:**
- `UserDefaults` - Persists user preferences (theme, login name, feature toggles)
- Key namespace: `mtst_*` (e.g., `mtst_quick_check_mode`, `mtst_mt_complete_mode`)
- No external configuration files required

## Platform Requirements

**Development:**
- Xcode 14+ (Swift 5.9+)
- Python 3.7+ installed locally
- PyInstaller (installed in venv via make_swift_app.sh)
- macOS 13+ (tested on Sonoma)

**Production:**
- macOS 13+ target (minimum deployment target in Info.plist)
- No external dependencies at runtime — all bundled in .app:
  - Parse binary: `Contents/MacOS/parse_als_dir/parse_als`
  - FFmpeg binary: `Contents/Frameworks/ffmpeg` + audio codec dylibs
  - Fonts: `Contents/Resources/` (Lato TTF, Horizon OTF)
  - Swift runtime: linked statically by default on modern macOS

## Version Lock

- Swift: Version fixed by Xcode toolchain (5.9 minimum from Package.swift)
- Python: 3.7+ minimum (dawtool setup.py requirement)
- PyInstaller: Installed fresh during each build (no version pinned; uses latest compatible)
- macOS Deployment Target: 13.0 (set in Info.plist)

---

*Stack analysis: 2026-03-25*
