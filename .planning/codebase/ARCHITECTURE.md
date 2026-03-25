# Architecture

**Analysis Date:** 2026-03-25

## Pattern Overview

**Overall:** Client-Server with UI-driven validation pipeline

**Key Characteristics:**
- **Persistent backend process** — Python parser runs as a long-lived server, not spawned per-file
- **Request-response protocol** — Swift sends JSON commands via stdin, reads JSON responses from stdout
- **State-driven UI** — SwiftUI `@StateObject` services manage parser state, audio analysis, and user preferences
- **Validation-blocking UI** — Copy/submit buttons fire but show toast when data is invalid, never `.disabled`
- **Two-stage file processing** — Parse → extract metadata; optionally Validate → inspect audio

## Layers

**Presentation Layer:**
- Purpose: Render UI, manage user interactions, display results
- Location: `dawtool-master/swift-app/Sources/MTSongTool/`
- Contains: View components, UI state, user settings persistence
- Depends on: ParserService, AudioAnalyzerService, UserSettings, Validation
- Used by: App entry point

**Service Layer:**
- Purpose: Manage external processes (parser, FFmpeg), expose data to UI
- Location: `dawtool-master/swift-app/Sources/MTSongTool/ParserService.swift`, `AudioAnalyzerService.swift`
- Contains: ParserProcess (stdin/stdout communication), audio file scanning, validation status
- Depends on: Python parser binary, FFmpeg binary, system file APIs
- Used by: ContentView, AudioAnalysisView

**Validation Layer:**
- Purpose: Enforce business rules for locator names, audio formats, session structure
- Location: `dawtool-master/swift-app/Sources/MTSongTool/Validation.swift`
- Contains: LocatorValidator (approved section list), TimecodeHelper, audio validation rules
- Depends on: None (pure Swift)
- Used by: LocatorCheckView, AudioAnalyzerService

**Backend/Parser Layer:**
- Purpose: Parse .als files (gzipped XML), extract metadata, validate sessions
- Location: `dawtool-master/parse_als.py`
- Contains: Ableton Live session parsing, time signature extraction, locator validation, Live 12 downgrade
- Depends on: dawtool library (from `dawtool-master/`), lxml/ElementTree for XML parsing
- Used by: ParserService via JSON RPC

## Data Flow

**Parsing Flow:**

1. User drops `.als` file on drop zone or selects via file dialog
2. `ContentView.loadNewFile(path:)` resets state and calls `ParserService.parse(alsPath:)`
3. `ParserService` sends `{"action": "parse", "path": "..."}` to Python process via stdin
4. `parse_als.py:main()` reads the gzipped XML, extracts:
   - `markers` — locator data with raw names (leading/trailing spaces preserved)
   - `timeSignatures` — from automation envelope or static fields
   - `bpm` — from session header
   - `expectedDuration` — loop bracket length
   - `liveMajorVersion` — version detection (11 vs 12)
   - `warnings` — validation issues (incomplete bars, tempo ramps, loop misalignment)
5. Python returns `{"file": "...", "markers": [...], "time_signatures": [...], "bpm": ...}` to stdout
6. `ParserService` decodes JSON and updates `@Published var result: ParsedResult`
7. `ContentView` observes result change, populates Song Data, shows Locators panel

**Validation Flow:**

1. Parser returns `markers` with raw names from XML
2. `LocatorCheckView` receives markers, runs `LocatorValidator.isValid(label)` on each
3. Invalid marker → shown in red, auto-fix normalized name shown inline
4. User accepts auto-fix or edits manually → triggers `applyLocatorFixes()`
5. `ParserService.fixLocators(fixes:)` sends `{"action": "fix_locators", "path": "...", "fixes": [{"als_id": "3", "new_name": "CHORUS"}]}`
6. `parse_als.py:_fix_locators()` rewrites XML in-place, renames original to `OLD_<name>.als` as backup
7. On success, returns new path → `ContentView` calls `loadNewFile(newPath)` to re-parse
8. Locator panels re-render with corrected names

**Audio Analysis Flow:**

1. User drops `.wav` folder on Stem Check drop zone
2. `AudioAnalyzerService.analyze(folderURL:)` scans all `.wav` files in parallel
3. For each file:
   - Load with `AVAudioFile`, extract format (sample rate, bit depth)
   - Validate: 44.1 kHz, 16-bit (else add issue)
   - Scan for silence: RMS < 1e-4 (-80 dBFS), check first 10ms + last 10ms
   - Extract stem name: filename without extension, uppercase
   - Check against `AudioAnalyzerService.approvedStems` set (~200 entries)
   - Validate duration against `expectedDuration` ± 5-sample tolerance
4. Results sorted: required stems pinned (CLICK TRACK, GUIDE, ORIGINAL SONG), then issues A–Z, then clean A–Z
5. User can inline-rename stems (double-click) or batch-convert format (FFmpeg)

**Session Validation:**

1. `parse_als.py:validate_session(path)` runs after parse to check:
   - **Loop bracket alignment** — audio clip start/end matches loop bracket within tolerance
   - **Barline conformance** — loop bracket ends on a barline (respects mid-song time sig changes)
   - **Incomplete bars** — sections between time signature changes that don't end on a barline
   - **Tempo ramps** — detects linear changes in tempo automation, filters out Ableton step changes
2. Returns warning strings, shown in red at top of result
3. Warnings block copy/submit until resolved (user must fix in Ableton)

**Copy Blocking Logic:**

```
copyBlocked = true if ANY of:
  • Live 12 session (not yet converted)
  • Invalid locators detected
  • Session warnings returned
  • Stem Check required but not run (false in Quick Check Mode)
  • Audio issues found (silent, corrupted, wrong format, duration)
  • Required Song Data missing
  • Required stems missing (CLICK TRACK, GUIDE, ORIGINAL SONG)
```

When `copyBlocked = true`, copy buttons still fire but show toast: "Fix errors before copying"

**State Management:**

- `@StateObject parser: ParserService` — owns parser process, result, loading state
- `@StateObject audioAnalyzer: AudioAnalyzerService` — owns scan results, conversion state
- `@ObservedObject userSettings: UserSettings.shared` — singleton, persisted to UserDefaults
- `@State songKey`, `@State songTimeSig`, etc. — lifted to ContentView so re-parses don't reset
- `@State stemCheckMinimized: Bool` — lifted from AudioAnalysisView to survive re-parses
- `@Binding` passed into child views for two-way state updates (e.g., toggles)

## Key Abstractions

**ParserService:**
- Purpose: Manage Python parser process lifecycle and JSON communication
- Examples: `dawtool-master/swift-app/Sources/MTSongTool/ParserService.swift`
- Pattern: `@StateObject` singleton (per ContentView instance). Uses `ParserProcess` wrapper for process management. `resolveParser()` checks bundled binary first, falls back to dev venv. `warmUp()` pre-launches at app startup. Commands: `parse`, `fix_locators`, `validate`, `downgrade_to_live11`

**AudioAnalyzerService:**
- Purpose: Scan and validate audio files, manage format conversion
- Examples: `dawtool-master/swift-app/Sources/MTSongTool/AudioAnalyzerService.swift`
- Pattern: `@StateObject` with `@Published` properties for results, scanning state, conversion progress. `approvedStems` is a `Set<String>` (case-insensitive lookup). Scanning runs in background thread via DispatchQueue. Conversion uses `Process` to invoke bundled FFmpeg

**LocatorValidator:**
- Purpose: Enforce business rules for locator names
- Examples: `dawtool-master/swift-app/Sources/MTSongTool/Validation.swift`
- Pattern: Enum with static methods. `isValid(label)` checks: not empty, no leading/trailing spaces, ALL CAPS, recognized section. `acceptedSections` is hardcoded `Set<String>` (~60 entries)

**UserSettings:**
- Purpose: Persist user preferences and profile across sessions
- Examples: `dawtool-master/swift-app/Sources/MTSongTool/UserSettings.swift`
- Pattern: `ObservableObject` singleton (`UserSettings.shared`). Each `@Published` property syncs to UserDefaults on change via `didSet`. Keys: `mtst_first_name`, `mtst_last_name`, `mtst_theme`, `mtst_quick_check_mode`, `mtst_mt_complete_mode`, `mtst_show_mtid`, `mtst_show_copy_all`

**ParsedResult:**
- Purpose: Container for all data extracted from a single .als file
- Examples: `dawtool-master/swift-app/Sources/MTSongTool/ParserService.swift`
- Pattern: Struct with optional fields. `file`, `bpm`, `markers`, `timeSignatures`, `warnings`, `expectedDuration`, `firstTempoChangeMarkerIndex`, `liveMajorVersion`

## Entry Points

**App Launch:**
- Location: `dawtool-master/swift-app/Sources/MTSongTool/App.swift`
- Triggers: User opens MT Song Tool.app
- Responsibilities:
  - Register bundled fonts (Lato, Horizon) from Contents/Resources
  - Call `ParserService.warmUp()` to pre-launch Python process
  - Check UserDefaults for login; show LoginView or ContentView

**File Drop:**
- Location: `dawtool-master/swift-app/Sources/MTSongTool/ContentView.swift` → `dropZoneOrResults` property
- Triggers: User drags .als or .wav folder onto drop zone
- Responsibilities:
  - .als drop → call `loadNewFile(path:)`
  - .wav folder drop → call `audioAnalyzer.analyze(folderURL:)`

**User Settings Change:**
- Location: `dawtool-master/swift-app/Sources/MTSongTool/ContentView.swift` → `.onChange(of: userSettings.theme)`
- Triggers: User toggles Theme, Quick Check Mode, MT Complete Mode via settings popover
- Responsibilities:
  - Theme → apply to NSApp.appearance
  - Toggles → persist to UserDefaults, trigger re-render

## Error Handling

**Strategy:** Errors are surfaced via toast messages and red UI elements, not exceptions

**Patterns:**

1. **Parser Error:**
   - If Python binary not found or crashes before sending `{"ready": true}` → toast: "Parser not available"
   - If parse JSON is invalid → log, show toast: "Failed to parse session"
   - If locator fix fails → restore backup, show toast: "Could not save changes"

2. **File Operation Error:**
   - Drop file not found → toast: "File not accessible"
   - No read permission → toast: "Cannot access file"
   - Write-back fails (e.g. file locked) → toast: "Could not save locator changes"

3. **Audio Analysis Error:**
   - AVAudioFile load fails → status = `.corrupted("...reason...")`, shown in red
   - FFmpeg convert fails → add error to `conversionErrors` array, shown in popup
   - No stems found in folder → toast: "No .wav files in folder"

4. **Validation Error:**
   - Locator name is blank → red badge "Fix In Session", can't auto-fix
   - Incomplete bar detected → warning added to `parser.result.warnings`, blocks copy

## Cross-Cutting Concerns

**Logging:** Console logs via `NSLog("[MTST] ...")` for parser process events, error conditions. No persistent log file.

**Validation:**
- Locator names: `LocatorValidator.isValid()` checks format before copy
- Audio format: 44.1 kHz / 16-bit required (user can batch-convert via FFmpeg)
- Stem names: ~200 approved names hardcoded in `AudioAnalyzerService.approvedStems`
- Session structure: `parse_als.py:validate_session()` checks loop alignment, barlines, tempo ramps

**Authentication:** Login screen (first-run) asks for first/last name, stored in UserDefaults. No server auth; purely local profile.

**File Operations:**
- Reads: `.als` (gzipped XML) via Python, `.wav` (audio) via AVAudioFile
- Writes: Locator fixes write back to `.als` via Python, audio conversion writes new files to `<folder>_44.1kHz_16bit/`
- Backups: Original `.als` renamed to `OLD_<name>.als` before writing fixes

---

*Architecture analysis: 2026-03-25*
