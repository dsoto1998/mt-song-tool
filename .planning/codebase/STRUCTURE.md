# Codebase Structure

**Analysis Date:** 2026-03-25

## Directory Layout

```
MT Song Tool/
├── CLAUDE.md                        # Project instructions (overrides defaults)
├── Release Notes.md                 # Versioned changelog (included in every .zip)
├── dawtool-master/
│   ├── parse_als.py                 # Python parser for .als files (all parsing + validation)
│   ├── fonts/                       # Bundled font files (Lato, Horizon)
│   ├── sonic.icns                   # App icon
│   ├── venv/                        # Python virtual environment (created during build)
│   ├── swift-app/
│   │   ├── make_swift_app.sh        # One-command build script (builds parser + Swift + .pkg + .zip)
│   │   ├── build_parser.sh          # PyInstaller step for Python → binary conversion
│   │   ├── Package.swift            # Swift Package Manager configuration
│   │   ├── Sources/MTSongTool/      # All Swift source files (single target)
│   │   │   ├── App.swift                    # @main entry point, window setup, font registration
│   │   │   ├── ContentView.swift            # Root view, all state, layout, copy-blocking logic
│   │   │   ├── DesignSystem.swift           # Color/font extensions, button styles, cardStyle()
│   │   │   ├── UserSettings.swift           # UserDefaults-backed ObservableObject for preferences
│   │   │   ├── LoginView.swift              # First-run name entry screen
│   │   │   ├── ParserService.swift          # Manages Python parser process, JSON RPC
│   │   │   ├── SongData.swift               # SongDataOptions (approved keys, time sigs)
│   │   │   ├── Validation.swift             # LocatorValidator, approved section list, TimecodeHelper
│   │   │   ├── LocatorCheckView.swift       # Locators panel + inline edit + auto-fix + NEXT SONG check
│   │   │   ├── PanelComponents.swift        # Reusable: PanelView, RowView, DropZoneView, pill shapes
│   │   │   ├── PickerComponents.swift       # SongDataPickerView + search/keyboard nav
│   │   │   ├── SongDataComponents.swift     # SongDataCopyButton, HoverCheckbox
│   │   │   ├── TextFieldComponents.swift    # SongDataNSTextField, ManagedNSTextField
│   │   │   ├── AudioAnalyzerService.swift   # Stem scanning, validation, rename, FFmpeg convert
│   │   │   └── AudioAnalysisView.swift      # Stem Check UI, AudioFileRow (inline rename)
│   │   └── Resources/                       # Bundled assets (fonts, icon)
│   └── [dawtool library code]               # External library; not modified by this project
├── AudioConverter/
│   └── dist/Audio Converter.app/    # Bundled FFmpeg binary + dylibs (for format conversion)
├── Versions/                        # Output: generated .zips with versioned releases
└── .planning/codebase/              # This analysis directory
```

## Directory Purposes

**`dawtool-master/`:**
- Purpose: Build artifacts, source code, build scripts
- Contains: Python parser, Swift app, bundled binaries, fonts
- Key files: `parse_als.py`, `Package.swift`, `make_swift_app.sh`

**`dawtool-master/swift-app/Sources/MTSongTool/`:**
- Purpose: All application source code (single SPM target, no imports needed between files)
- Contains: Views, services, validation logic, design system
- Key files: `App.swift` (entry), `ContentView.swift` (root state), `ParserService.swift`, `AudioAnalyzerService.swift`

**`dawtool-master/venv/`:**
- Purpose: Python virtual environment (created during build via `build_parser.sh`)
- Contains: Python 3 interpreter, lxml, hexdump, and dawtool dependencies
- Generated: Yes
- Committed: No (built at build time)

**`AudioConverter/dist/`:**
- Purpose: Bundled FFmpeg binary for audio format conversion
- Contains: FFmpeg executable + dylibs
- Generated: No (pre-built, checked in)
- Committed: Yes (part of release artifacts)

**`Versions/`:**
- Purpose: Release output directory
- Contains: Versioned `.zip` files with app + Release Notes
- Generated: Yes (by `make_swift_app.sh`)
- Committed: No (output only)

**`dawtool-master/fonts/`:**
- Purpose: Bundled fonts for app UI
- Contains: `Lato-Regular.ttf`, `Lato-Bold.ttf`, `Lato-Light.ttf`, `Lato-Black.ttf`, `Horizon_Regular.otf`
- Copied to: `Contents/Resources/` during app assembly

## Key File Locations

**Entry Points:**
- `dawtool-master/swift-app/Sources/MTSongTool/App.swift` — @main struct, window setup, font registration, login check
- `dawtool-master/swift-app/Sources/MTSongTool/ContentView.swift` — root view with all state management, layout

**Configuration:**
- `dawtool-master/swift-app/Package.swift` — SPM target definition, minimum macOS version (13+)
- `dawtool-master/swift-app/make_swift_app.sh` — build orchestration (parser → binary → app → .pkg → .zip)
- `dawtool-master/swift-app/build_parser.sh` — PyInstaller build for `parse_als.py`

**Core Logic:**
- `dawtool-master/parse_als.py` — all .als parsing, locator extraction, time signature computation, session validation, Live 12→11 downgrade
- `dawtool-master/swift-app/Sources/MTSongTool/ParserService.swift` — manages Python process, JSON RPC, error handling
- `dawtool-master/swift-app/Sources/MTSongTool/AudioAnalyzerService.swift` — audio file scanning, format validation, FFmpeg conversion
- `dawtool-master/swift-app/Sources/MTSongTool/Validation.swift` — LocatorValidator, approved section list (~60 entries)

**UI/State:**
- `dawtool-master/swift-app/Sources/MTSongTool/ContentView.swift` — state aggregation, layout, copy-blocking logic, session validation
- `dawtool-master/swift-app/Sources/MTSongTool/UserSettings.swift` — UserDefaults persistence (theme, name, toggles)
- `dawtool-master/swift-app/Sources/MTSongTool/DesignSystem.swift` — colors, fonts, button styles (light/dark pairs)

**Views:**
- `dawtool-master/swift-app/Sources/MTSongTool/LocatorCheckView.swift` — Locators panel, inline editing, auto-fix, NEXT SONG missing detection
- `dawtool-master/swift-app/Sources/MTSongTool/AudioAnalysisView.swift` — Stem Check panel, file listing, required stem pinning
- `dawtool-master/swift-app/Sources/MTSongTool/LoginView.swift` — First-run name entry
- `dawtool-master/swift-app/Sources/MTSongTool/PanelComponents.swift` — Reusable card/row/drop-zone layout primitives
- `dawtool-master/swift-app/Sources/MTSongTool/PickerComponents.swift` — Key/Time Sig pickers with search

**Testing:**
- No test directory — all functionality tested manually via app UI
- Unit testing of parser logic: See TESTING.md notes

## Naming Conventions

**Files:**
- Views: PascalCase.swift (e.g., `ContentView.swift`, `LocatorCheckView.swift`)
- Services: PascalCaseService.swift (e.g., `ParserService.swift`, `AudioAnalyzerService.swift`)
- Single-purpose files: PascalCase.swift (e.g., `Validation.swift`, `DesignSystem.swift`, `UserSettings.swift`)
- Python scripts: snake_case.py (e.g., `parse_als.py`)
- Build scripts: snake_case.sh (e.g., `make_swift_app.sh`, `build_parser.sh`)

**Directories:**
- camelCase for organizational folders (e.g., `swift-app`)
- ALL_CAPS + hyphens for executable output (e.g., `AudioConverter/dist/Audio Converter.app`)
- Descriptive names for version output (e.g., `Versions/`)

**Structs/Classes:**
- PascalCase: `ContentView`, `ParserService`, `LocatorValidator`, `ParsedResult`
- Views: suffix with "View" (e.g., `LocatorCheckView`, `AudioAnalysisView`)
- Services: suffix with "Service" (e.g., `ParserService`, `AudioAnalyzerService`)
- Models: no suffix (e.g., `ParsedResult`, `Marker`, `AudioFileResult`)

**Functions:**
- camelCase: `loadNewFile()`, `applyLocatorFixes()`, `analyze()`
- Private functions: underscore prefix in Python (e.g., `_fix_locators()`, `_check_tempo_ramps()`)

**Variables:**
- camelCase for all locals and properties: `alsPath`, `stemName`, `expectedDuration`, `hasPopulatedSongData`
- @State/@Published properties: camelCase (e.g., `isLoading`, `songKey`, `showToast`)
- Constants/sets: camelCase or SCREAMING_CASE per Swift convention (e.g., `approvedStems`, `acceptedSections`)

## Where to Add New Code

**New Feature (e.g., new validation check):**
- Primary code: `dawtool-master/swift-app/Sources/MTSongTool/ContentView.swift` (add state/logic) or new view file if complex
- Validation rules: `dawtool-master/swift-app/Sources/MTSongTool/Validation.swift` (add to LocatorValidator or new enum)
- Parser backend: `dawtool-master/parse_als.py` (add validation function, return in warnings array)
- Tests: Manual testing via UI (see TESTING.md for parser testing approach)

**New Component/Module:**
- Implementation: `dawtool-master/swift-app/Sources/MTSongTool/[FeatureName]View.swift` (if UI) or `[FeatureName]Service.swift` (if logic)
- Import: No imports needed — all files in single SPM target
- Example: `AudioAnalysisView.swift` is a standalone view file, `AudioAnalyzerService.swift` is a standalone service

**Utilities/Helpers:**
- Shared extensions: `dawtool-master/swift-app/Sources/MTSongTool/DesignSystem.swift` (for UI helpers like `.cardStyle()`)
- Validation helpers: `dawtool-master/swift-app/Sources/MTSongTool/Validation.swift` (pure logic)
- Python helpers: `dawtool-master/parse_als.py` (add function, call from `main()` or action handlers)

**New UI Element:**
- Simple composable components: `dawtool-master/swift-app/Sources/MTSongTool/PanelComponents.swift` (reusable shapes/layouts)
- Pickers: `dawtool-master/swift-app/Sources/MTSongTool/PickerComponents.swift`
- Text inputs: `dawtool-master/swift-app/Sources/MTSongTool/TextFieldComponents.swift`
- Standalone panel: New file (e.g., `TimeSigPanel.swift`)

## Special Directories

**`dawtool-master/fonts/`:**
- Purpose: Bundled font files
- Generated: No (pre-built, checked in)
- Committed: Yes
- Build: Copied to `Contents/Resources/` during `swift build`, registered at app launch in `App.swift`

**`dawtool-master/venv/`:**
- Purpose: Python virtual environment
- Generated: Yes (by `build_parser.sh`)
- Committed: No
- Build: Created during `make_swift_app.sh`, installs lxml, hexdump, dawtool deps

**`AudioConverter/dist/Audio Converter.app/Contents/Frameworks/`:**
- Purpose: FFmpeg binary + dylibs
- Generated: No (pre-built, checked in)
- Committed: Yes
- Build: Copied to app's `Contents/Frameworks/` by `make_swift_app.sh`, xattr -cr is run to unquarantine

**`Versions/`:**
- Purpose: Release artifacts
- Generated: Yes (by `make_swift_app.sh`)
- Committed: No (output only, versioned outside of git)

## State Ownership Hierarchy

```
App
└── MTSongToolApp
    ├── UserSettings.shared (@ObservedObject singleton)
    └── WindowGroup
        ├── LoginView (if not logged in)
        └── ContentView (if logged in)
            ├── @StateObject parser: ParserService
            ├── @StateObject audioAnalyzer: AudioAnalyzerService
            ├── @State songKey, songTimeSig, bpmText, etc. (Song Data fields)
            ├── @State stemCheckMinimized: Bool (lifted so re-parses don't reset)
            ├── @State showToast, toastMessage (UI feedback)
            ├── LocatorCheckView (passed markers, onFix callback)
            └── AudioAnalysisView (passed analyzer, isMinimized binding)
```

- All state lifted to `ContentView` so child view re-creation (e.g. re-parse) doesn't reset it
- `ParserService` and `AudioAnalyzerService` are `@StateObject` (owned by ContentView, recreated on parent state change but wrapped)
- `UserSettings.shared` is a singleton, persisted across app lifetime

## Build Output

After running `make_swift_app.sh`:

```
/Applications/MT Song Tool.app/
└── Contents/
    ├── MacOS/
    │   ├── MTSongTool (compiled Swift binary)
    │   └── parse_als_dir/
    │       └── parse_als (PyInstaller binary)
    ├── Resources/
    │   ├── Horizon_Regular.otf
    │   ├── Lato-*.ttf (4 weights)
    │   └── AppIcon.icns
    ├── Frameworks/
    │   ├── ffmpeg (binary)
    │   └── *.dylib (FFmpeg dependencies)
    └── Info.plist

Versions/
└── MT Song Tool vX.X.X.zip
    ├── MT Song Tool.pkg (installer)
    ├── Release Notes.md
    └── [checksums if included]
```

---

*Structure analysis: 2026-03-25*
