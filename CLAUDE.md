# MT Song Tool (MTST) — Claude Code Context

**Current version:** v1.7.1
**Platform:** macOS 13+, Swift/SwiftUI, Swift Package Manager
**Project root:** `/Volumes/MTEng0/claude-apps/mt-song-tool/`

---

## What the App Does

Internal macOS QA tool for MultiTracks.com staff. Given an Ableton Live `.als` session and a folder of `.wav` stems, it validates everything needed before publishing a song package:

1. **Parses `.als` files** — extracts locators (section markers) with accurate timestamps even across tempo automation changes. Uses a bundled Python parser (`parse_als.py` → PyInstaller binary) rather than Ableton's own script, which breaks on tempo changes.
2. **Locator validation** — checks each marker label against the approved MultiTracks sections list. Invalid labels shown in red. Double-click → dropdown picker writes corrections back to the `.als` file.
3. **Time Signatures panel** — extracted from the Ableton automation envelope (with fallback to static Numerator/Denominator for single-time-signature sessions).
4. **Song Data panel** — auto-populates Song Key, Time Sig, BPM, Preview Start/End from the session. All fields copyable. Key auto-detected via Krumhansl-Schmuckler on ORIGINAL SONG.wav after stem scan.
5. **Stem Check panel** — drop a `.wav` folder to batch-validate silence, stem name conformance (against ~200 approved names), and audio format (44.1 kHz / 16-bit).
6. **Session validation** — loop bracket vs audio clip alignment checks, barline checks that respect mid-song time signature changes.
7. **Quick Check Mode** — toggle that removes the requirement to have both an `.als` and stems before proceeding.
8. **MT Complete Mode** — toggle that suppresses the NEXT SONG missing-locator warning (for single-song sessions). Also reveals Song Duration and Display Duration copy fields.
9. **Jam Night Mode** — toggle (hidden by default; shown via Settings) that relaxes copy blocking for tempo ramps and loop/clip alignment issues; only ORIGINAL SONG required instead of full stem set. Shows Tempo panel in QA tab.
10. **Edit tab** — multi-stem timeline editor: region select/delete/move, per-stem gain/mute/solo, metronome, click track generation, ALS generation (Build Session), locator suggestion via Whisper, AudioShake integration, auto-align stems (Check Alignment + Correct via full-file FFT cross-correlation of summed collective stem bus vs ORIGINAL SONG). Single WAV files can be dragged from Finder and dropped anywhere in the Edit tab to add them alongside existing stems.
11. **AudioShake tab** — stem separation via AudioShake API. Upload a WAV file, select separation models, download results as named stems.
12. **Upload tab / Queue** — `UploadView.swift`, `QueueView.swift`, `BackOfficeService.swift`, `NolanRyanService.swift` are preserved in the codebase but **disconnected from the current UI**. The tab switcher only shows QA / Edit / AudioShake.

---

## Planned Features (TODO)

### Dynamic CLICK TRACK — SHIPPED (2026-05-12)
CLICK TRACK lane always visible in Edit tab. Auto-generates from session tempo/time-sig map. Ends at ENDING locator downbeat. Regenerates on BPM/time-sig edits (debounced 400ms). Exportable with stems. Does NOT inject into .als. GUIDE track deferred.

See memory file `project_click_track_generator.md` for full implementation details.

### GUIDE Track Builder
**Memory file:** `project_dynamic_click_guide_builder.md`

GUIDE (AudioTrack) injection into `.als` — deferred. CLICK TRACK portion already shipped above.

---

## Swift Sources (`mtst-master/swift-app/Sources/MTSongTool/`)

**QA tab:**
- `App.swift` — @main, window setup, font registration, Release Notes sheet, window frame persistence
- `ContentView.swift` — root view, all state, layout, copy blocking, tab switching
- `DesignSystem.swift` — colors, fonts, button styles, cardStyle()
- `UserSettings.swift` — UserDefaults-backed ObservableObject
- `LoginView.swift` — first-run name entry screen
- `AppLogger.swift` — file logger; writes to `~/Library/Logs/MT Song Tool/mtst-YYYY-MM-DD.log`
- `ParserService.swift` — `ParserProcess` (persistent Python process) + `ParserService` (SwiftUI-facing); also defines `ParsedResult`, `Marker`, `TimeSig`, `TempoEvent`
- `SongData.swift` — `SongDataOptions` (approved key/time sig lists)
- `Validation.swift` — `LocatorValidator`, `TimecodeHelper`
- `LocatorCheckView.swift` — Locators panel + auto-fix + NEXT SONG check
- `PanelComponents.swift` — `PanelView`, `RowView`, `DropZoneView`, pill shapes
- `PickerComponents.swift` — `SongDataPickerView` + search/keyboard nav
- `SongDataComponents.swift` — `SongDataCopyButton`, `HoverCheckbox`
- `TextFieldComponents.swift` — `SongDataNSTextField`, `ManagedNSTextField`
- `AudioAnalyzerService.swift` — stem scanning, validation, rename, convert, export
- `AudioAnalysisView.swift` — Stem Check UI, `AudioFileRow` (dropdown rename), `WaveformSeekView`
- `StemPlayerService.swift` — AVPlayer wrapper; per-stem playback + section playback with loop; publishes `PlayAnchor` for metronome sync
- `MetronomeService.swift` — beat-scheduled metronome via AVAudioEngine; `buildSchedule()` + `start(anchorHostTime:startSessionTime:)`; computes `beatSchedule: [BeatInfo]`
- `CredentialStore.swift` — Keychain wrapper (BackOffice, NR, AudioShake API key)

**Edit tab:**
- `EditView.swift` — multi-stem timeline editor (zoom, scroll, region select/delete/move, locator lane, tempo lane)
- `EditPlayerService.swift` — AVAudioEngine multi-stem playback with per-stem metering; `AudioSegment` / `StemState` multi-segment model
- `ClickTrackService.swift` — click track generation via `generate_click_track` parser action
- `ALSGeneratorService.swift` — `.als` generation from scratch via `generate_als` parser action (Build Session)
- `LocatorSuggesterService.swift` — Whisper-based locator suggestion via `suggest_locators` + `write_locators` parser actions
- `SuggestLocatorsSheet.swift` — sheet UI for lyric/chord sheet drop + locator review
- `AlignmentService.swift` — full-file FFT cross-correlation (`fftFullCorrelate`) + guided ±150 ms fine pass (`fineSweep`); reports session-time offset (positive = bus late). Two vDSP pitfalls: (1) negate decoded lag — `vDSP_fft_zrip` INVERSE convention is opposite of textbook ifft; (2) save/restore DC + Nyquist around `vDSP_zvmul` due to packed split-complex format

**AudioShake tab:**
- `AudioShakeService.swift` — AudioShake API client; upload → poll → download stem files
- `AudioShakeView.swift` — AudioShake tab UI

**Upload / Queue (preserved, disconnected):**
- `BackOfficeService.swift` — BackOffice login, song metadata fetch, `.als` + data upload
- `NolanRyanService.swift` — SMB mount check + stem file copy to NR Pitching share
- `UploadView.swift` — Upload tab UI (NR + BackOffice cards)
- `QueueService.swift` — upload queue model (pending/processing/success/failed)
- `QueueView.swift` — upload queue UI

Other key files: `parse_als.py` (Python parser), `make_swift_app.sh` (one-command build), `build_parser.sh` (PyInstaller step) — all in `mtst-master/`.

---

## How to Build

```bash
bash "/Volumes/MTEng0/claude-apps/mt-song-tool/mtst-master/swift-app/make_swift_app.sh"
```

**Flags:**
- `--skip-parser` — skip PyInstaller step (use existing `dist/parse_als` binary). Fast for Swift-only changes.
- `--no-relaunch` — skip the auto quit+reopen of a running `/Applications/MT Song Tool.app` at the end of the build. Default behavior gracefully quits via `osascript` (5s timeout → `pkill` fallback) and relaunches with `open -a`.

**What it does (4 steps + dev relaunch):**
1. Runs `build_parser.sh` — compiles `parse_als.py` into a standalone binary via PyInstaller (venv at `mtst-master/venv/`). Installs `lxml` and `hexdump` into the venv first.
2. Runs `swift build -c release`
3. Assembles `/Applications/MT Song Tool.app` (Swift binary + parser binary + fonts + icon + bundled FFmpeg)
   - Then (step 3b) quits + relaunches a currently-running `/Applications/MT Song Tool.app` so dev iterations test the fresh binary immediately. Skipped if the app isn't running, or if `--no-relaunch` is passed. Runs **before** the .pkg/.zip build so the relaunch happens during the slow packaging step.
4. Produces a `.pkg` installer, wraps it with `Release Notes.md` in a versioned `.zip` at `Versions/MT Song Tool vX.X.X.zip`

**No sudo required** — `/Applications` is group-writable for admin users. If the existing bundle is root-owned (from an older install), the script does a one-time `sudo chown` to take ownership.

### GitHub Releases (manual)

After each build, upload assets to the GitHub release at `https://github.com/dsoto1998/mt-song-tool/releases` (private repo). `gh` CLI is installed and authenticated as `dsoto1998` — preferred over curl:

```bash
# View / create / edit release
gh release view vX.X.X --repo dsoto1998/mt-song-tool
gh release upload vX.X.X "path/to/MT Song Tool X.X.X.pkg" --repo dsoto1998/mt-song-tool
gh release delete-asset vX.X.X "MT.Song.Tool.X.X.X.pkg" --repo dsoto1998/mt-song-tool --yes
gh release edit vX.X.X --repo dsoto1998/mt-song-tool --notes "$(cat notes.md)"

# Extract .pkg from versioned zip (build script doesn't leave a standalone copy)
unzip -p "Versions/MT Song Tool vX.X.X.zip" \
  "MT Song Tool vX.X.X/MT Song Tool X.X.X.pkg" > "/tmp/MT Song Tool X.X.X.pkg"
```

Legacy curl approach (only if `gh` is unavailable):

```bash
# 1. Get release ID for the tag
curl -s -H "Authorization: token <PAT>" \
  "https://api.github.com/repos/dsoto1998/mt-song-tool/releases/tags/vX.X.X" \
  | python3 -c "import sys,json; r=json.load(sys.stdin); print(r['id'])"

# 2. Extract .pkg from zip (build script doesn't leave a standalone copy)
unzip -p "Versions/MT Song Tool vX.X.X.zip" \
  "MT Song Tool vX.X.X/MT Song Tool X.X.X.pkg" > "/tmp/MT Song Tool X.X.X.pkg"

# 3. Upload .pkg asset
curl -H "Authorization: token <PAT>" \
  -H "Content-Type: application/octet-stream" \
  --data-binary @"/tmp/MT Song Tool X.X.X.pkg" \
  "https://uploads.github.com/repos/dsoto1998/mt-song-tool/releases/<RELEASE_ID>/assets?name=MT%20Song%20Tool%20X.X.X.pkg"
```

The `.zip` and release notes description are added manually via the GitHub web UI. Release notes have no Features section — Changelog only.

---

## Testing Parser Changes

`.als` files are gzipped XML — test against real files directly, no build required:

```python
import gzip, sys
sys.path.insert(0, "/Volumes/MTEng0/claude-apps/mt-song-tool/mtst-master")
from parse_als import _get_tempo_events, _check_tempo_ramps  # import any function directly

with gzip.open("/path/to/file.als", "rb") as f:
    raw = f.read()

print(_get_tempo_events(raw))
```

**Ask the user for a real `.als` file** when a parser feature needs validation — don't guess at XML structure.

---

## Architecture

### Parser protocol (`parse_als.py`)
The Python binary runs as a persistent server (stdin/stdout JSON). `ParserService.swift` sends one-line JSON commands and reads one-line JSON responses:

- `{"action": "parse", "path": "/path/to/file.als"}` → full parse result
- `{"action": "fix_locators", "path": "...", "fixes": [{"als_id": "3", "new_name": "CHORUS"}]}` → renames locators in-place
- `{"action": "validate", "path": "..."}` → session validation warnings + loop info
- `{"action": "downgrade_to_live11", "path": "..."}` → writes `<name>_Live11.als`, returns `{"new_path": "..."}`
- `{"action": "detect_key", "path": "/path/to/stem.wav"}` → `{"key": "Am"}` via Krumhansl-Schmuckler / librosa
- `{"action": "generate_click_track", "output_path": "...", "bpm": 120, "time_sig": "4/4", "duration_seconds": 180, "tempo_events": [...]}` → generates click track WAV
- `{"action": "generate_als", "output_path": "...", "clips": [...], "bpm": ..., "tempo_events": [...], "time_signatures": [...], "locators": [...], "loop_end_beat": ...}` → generates `.als` from scratch
- `{"action": "suggest_locators", "wav_path": "...", "lyric_text": "...", "als_path": "...", "bpm": ...}` → Whisper transcription + lyric alignment → `{"suggestions": [...]}`
- `{"action": "write_locators", "als_path": "...", "locators": [...]}` → writes confirmed locators into `.als`

### State ownership (`ContentView`)
```swift
@StateObject private var parser = ParserService()
@StateObject private var audioAnalyzer = AudioAnalyzerService()
@StateObject private var stemPlayer = StemPlayerService()        // QA tab playback
@StateObject private var editPlayer = EditPlayerService()        // Edit tab playback
@StateObject private var audioShakePlayer = StemPlayerService()  // AudioShake tab playback
@StateObject private var metronome = MetronomeService()
@ObservedObject private var userSettings = UserSettings.shared
@State private var stemCheckMinimized: Bool   // lifted so re-parses don't reset it
@State private var songDataMinimized: Bool
@State private var locatorsSigMinimized: Bool
```

### Copy blocking (`copyBlocked: Bool`)
```swift
private var copyBlocked: Bool {
    isLive12Session          // Live 12 .als loaded but not yet converted
    || isOldSession          // .als saved in Live < 11 — needs re-save in Live 11
    || hasInvalidLocators    // any locator fails LocatorValidator
    || hasOffBeatLocators    // any locator doesn't land on beat 1 of a bar
    || hasSessionWarnings    // warnings from validate_session in parse_als.py
    || stemCheckRequired     // no stem scan run yet (false in Quick Check Mode)
    || hasAudioIssues        // any stem result where !isClean
    || hasDataMissing        // any required Song Data field empty
    || hasMissingRequiredStems  // required stems missing (see Jam Night Mode for which)
}
```

Copy buttons are **never `.disabled`** — they always fire, but when `copyBlocked` they show a toast instead of copying.

Jam Night mode relaxes `hasSessionWarnings` (tempo ramps + certain loop/clip warnings allowed) and `hasMissingRequiredStems` (only ORIGINAL SONG required instead of CLICK TRACK + ORIGINAL SONG + GUIDE).

### `loadNewFile(path:)`
Central helper called whenever any new `.als` is loaded. Calls `resetSongData()`, `audioAnalyzer.reset()`, then `parser.parse(alsPath:)`. Always use this instead of calling `parser.parse()` directly.

### Live 12 / old version flow
- **Live 12:** parse completes → `showLive12Alert = true`. Convert → spinner overlay → `parser.downgradeToLive11` → `loadNewFile(newPath)` with `_Live11.als`. Cancel → `clearAll()`.
- **Live < 11:** parse completes → `clearAll()` + `showOldVersionAlert = true`. Alert offers "Open in Ableton 11" if Ableton 11 is found at `/Applications/Ableton Live 11*.app`.

### Locator fix flow
1. User selects fix in `LocatorCheckView` → `applyLocatorFixes()` in `ContentView`
2. Python renames original to `OLD_<name>.als`, writes patched content to original path
3. Re-parses; `stemCheckMinimized` survives because it's `@State` on `ContentView`

### Auto-detect key flow
After stem scan finishes (`audioAnalyzer.isScanning` → `false`): if `songKey` is empty and ORIGINAL SONG.wav exists, ContentView calls `parser.detectKey(stemPath:)` (async) and fills `songKey` on success.

### Folder drop flow
`handleFolderDrop(_:)` in ContentView:
1. Recursively finds `.als` files (skips `backups/` folder).
2. One `.als` → `loadNewFile` + `loadStemsFromFolder`. Multiple `.als` → shows `AlsPickerSheet`. None → stems only.
3. `loadStemsFromFolder` finds first subfolder containing `.wav` files and calls `audioAnalyzer.analyze(folder:)`.

### Single-stem drop (Edit tab)
`handleFolderDropProviders(_:)` in `EditView` handles drops on the whole Edit tab. When a `.wav` file is dropped and `editPlayer.stemURLs` is non-empty, it calls `editPlayer.addSyntheticStem(url:)` + sets `isSessionDirty = true` instead of loading a new session. Directory drops still trigger `onFolderDrop` as before. A "Drop WAV" hint row on the left column provides an additional drop target with hover highlight.

### MT Complete auto-enable
`populateSongData(from:)` — called once per file load — auto-enables `mtCompleteMode` when the locator set contains all three short codes V1, VS, and V4.

---

## Key Files in Detail

### `parse_als.py`
- `_downgrade_to_live11(path)` — converts Live 12 → Live 11, writes `<name>_Live11.als` alongside original (non-destructive). Returns error if file is not Live 12.
- `_extract_locator_data(path)` — reads raw gzipped XML, bypasses dawtool's `.strip()` to preserve leading/trailing spaces in locator names for validation.
- `_fix_locators(path, fixes)` — renames original to `OLD_<basename>.als`, patches XML, writes back to original path.
- `validate_session(path)` — loop/clip alignment, incomplete bars, tempo ramps. Uses `_ts_events_from_content()` + `_is_on_barline()` for mid-song time-sig changes.
- `_get_tempo_events(contents)` — **two critical gotchas:** (1) `<Tempo>` (with `AutomationTarget Id`) lives at `<LiveSet>` level — NOT inside `<MasterTrack>`. (2) Tempo keyframes are `<FloatEvent>`, NOT `<AutomationEvent>`.
- `_check_tempo_ramps(contents)` — flags consecutive tempo events where value differs and beat positions differ. Step changes (two events at same beat) are not flagged. Phantom event (beat < 0) excluded.
- `parse_time_signatures(proj)` — falls back to static `<Numerator>`/`<Denominator>` if envelope missing. For Live < 10 (`minorA < 10`), sets `track_candidates = ()` — do NOT `return []` or fallback is bypassed.
- **TIME END logic:** each locator's `time_end` = next locator's start. Last locator gets loop bracket end — except if it's `"NEXT SONG"`, which gets blank (NEXT SONG is placed at/after loop end in medley sessions).

### `ParserService.swift`
- `ParserProcess` — persistent Python process; `send(_ line: String) -> String` is the shared primitive. Auto-restarts if crashed.
- `ParserService.warmUp()` — static; called at app launch (before any view) to pre-start the process and avoid first-parse latency.
- **Binary resolution order:** (1) `Resources/parse_als_dir/parse_als` (current bundle location), (2) `MacOS/parse_als_dir/parse_als` (legacy), (3) dev fallback at `/Volumes/MTEng0/claude-apps/mt-song-tool/mtst-master/venv/bin/python3`.
- `detectKey(stemPath:)` — async; sends `detect_key` action; returns key string mapped to approved list (e.g. `"Am"`, `"C"`).
- "Parser not available" = binary crashed before `{"ready": true}` — usually a missing PyInstaller hidden import (`hexdump`). Test binary from Terminal to see crash output.
- `ParsedResult` struct fields: `file`, `bpm`, `markers: [Marker]`, `timeSignatures: [TimeSig]`, `warnings`, `expectedDuration`, `firstTempoChangeMarkerIndex`, `liveMajorVersion`, `tempoEvents: [TempoEvent]`.
- `Marker` fields: `time`, `timeEnd`, `text`, `alsId`, `offBeat: Bool`, `beat: Double?`.
- `TempoEvent` fields: `beat`, `bpm`, `time`, `isRampStart`, `isRampEnd`.

### `LocatorCheckView.swift`
- `autoFixedLocatorName(_:mtCompleteMode:)` — 3-pass: trim/uppercase/collapse whitespace → replace `-`/`_` with space → replace first space with `-`. Takes `mtCompleteMode` so short codes are not suggested as auto-fixes when off.
- `LocatorRowView` — double-click opens `PickerPopoverContent`. Picker options passed in as `pickerOptions` (filtered by `mtCompleteMode` — short codes excluded when off). Blank locators show "Fix In Session" badge (no picker).
- Column headers row at top: `#` | `TIME START` | `SECTION` | `TIME END`, followed by Fix All banner when present.
- NEXT SONG missing row: shown when no `"NEXT SONG"` marker exists and `mtCompleteMode` is off.
- Off-beat locators: shown in red; the `offBeat` flag on `Marker` is set by the parser.

### `StemPlayerService.swift`
- `@Published` properties: `playingStemURL`, `isPlaying`, `currentTime`, `duration`, `volume`, `activeSectionStart`, `activeSectionEnd`, `isLooping`, `playAnchor: PlayAnchor?`.
- `PlayAnchor` — `{ hostTime: UInt64, sessionTime: Double }`. Published when AVPlayer crosses a 1ms boundary marker past `startSessionTime`. ContentView uses this to anchor the metronome precisely.
- `play(url:)` — starts playback from the beginning; calls private `teardownPlayer()` (NOT `stop()`) so section state is preserved when called from `playSection()`.
- `playSection(url:start:end:)` — sets `activeSectionStart/End` and `isLooping = true` **before** calling `play()`, so the waveform renders in section mode from the first frame (no flash). Then seeks to `start`.
- `stop()` — calls `teardownPlayer()` then clears all section state.
- Loop enforcement: periodic time observer (10 Hz) checks `currentTime >= activeSectionEnd` and calls `seek(to: activeSectionStart)` when looping is on.
- **Critical ordering:** always set section state before calling `play()` — `play()` uses `teardownPlayer()` which does NOT clear section state, but `stop()` does.

### `MetronomeService.swift`
- `buildSchedule(tempoEvents:timeSigs:totalDuration:staticBPM:)` — pre-computes `beatSchedule: [BeatInfo]` from the parsed tempo map. Called in ContentView whenever parse completes.
- `start(anchorHostTime:startSessionTime:)` — schedules AVAudioEngine click buffers against `mach_absolute_time()` for sample-accurate playback relative to the anchor.
- `BeatInfo` fields: `timeSeconds`, `bar`, `beat`, `isDownbeat`, `isSubdivisionTick`, `isSecondaryAccent`, `absoluteBeat`.
- Uses its own `AVAudioEngine` for QA tab. Edit tab uses `EditPlayerService`'s engine for sample-accurate sync.
- Buffers: downbeat (full), medium accent (75%), subdivision (60%), subdivision tick (35%).

### `EditPlayerService.swift`
- `AudioSegment` — `{ sourceStart, sourceEnd, sessionStart }`. Segments are independently positioned pieces of a stem's audio in the session timeline.
- `StemState` — per-stem state: `isMuted`, `isSoloed`, `isExcluded`, `gain`, `peaks`, `duration`, `segments: [AudioSegment]`.
- `splitSegment(atSession:)`, `deleteRegion(lo:hi:)`, `moveRegion(lo:hi:to:)` — mutating `StemState` operations.
- Per-stem metering: lock-free `MeterAtom` (single-word Float) for audio-thread → main-thread dB values.
- `LocatorOverride` — `{ name: String?, beat: Double? }`. Keyed by `alsId` in `locatorOverrides: [String: LocatorOverride]`. `EditView` uses this when computing loop bracket beat (overrides the parsed beat if set).
- `TimeSigEvent` — `{ beat, numerator, denominator }`. User-edited time sig lane stored in `timeSigOverrides: [TimeSigEvent]`. Edit tab picker (`TimeSigPickerPopover` in `EditView.swift`) is restricted to the 19 approved sigs from `SongDataOptions.timeSignatures` — same list as the QA tab.
- `editableTempoEvents: [TempoEvent]` — user-edited tempo map; diverges from parsed result after edits. `EditView.rebuildBeatSchedule()` uses this when non-empty, falls back to `parsedResult.tempoEvents`.
- `seedTempoEvents(_:)` — deduplicates same-beat pairs, keeping the **last** event at each beat (Ableton step change = two events at same beat; the second is the target BPM).
- Beat-0 anchor event cannot be deleted: `deleteTempoEvent(at:)` and `deleteTimeSig(at:)` both guard `index > 0`.
- `isSessionDirty: Bool` — set by any locator/tempo/time-sig mutation; used to gate save prompts.
- `masterPeakDB: Float`, `meterLevels: [URL: Float]` — master and per-stem peak dBFS updated at ~43 Hz.
- `busAlignmentResult: AlignmentResult?`, `isCheckingAlignment: Bool` — alignment check state; `runAlignmentCheck()` triggers FFT correlation on `Task.detached`; `applyAllAlignmentCorrections()` shifts collective stems by `-samples/sr` (CLICK/GUIDE/OG locked).
- `invalidateAlignmentIfOG(url)` — clears `busAlignmentResult` when OG segments mutate (called from `deleteRegion`, `moveRegion`, `trim*`, `shiftAllSegments`). Forces re-check after OG drag.

### `AudioAnalysisView.swift`
- `WaveformSeekView` — Canvas-based waveform. In section mode (`sectionStart/sectionEnd/totalDuration` provided): dims entire waveform at `fgMid.opacity(0.15)`, renders section window at `fgMid.opacity(0.35)`, fills played portion blue from `sectionStart` to playhead. In normal mode: blue left of playhead, gray right.
- `playbackBar` — Loop button appears left of volume when `stemPlayer.activeSectionStart != nil`; toggles `stemPlayer.isLooping`; accent when on, dim when off.
- Locator play button (`LocatorRowView`) calls `stemPlayer.playSection(url:start:end:)` when `timeEnd` is available; falls back to plain `play + seek` for markers with no `timeEnd` (e.g. NEXT SONG).

### `AudioAnalyzerService.swift`
- `approvedStems: Set<String>` — ~200 uppercase entries, source of truth for valid stem names.
- `validateStemName()` — checks Extra Space, Special Chars, Check Stem Name, Wrong Caps (`name != name.uppercased()`).
- `fixNamingIssues()` / `renameStem()` — both use two-step rename (UUID temp) for case-only changes on APFS.
- `convertNonConforming()` — FFmpeg conversion to `<folder>_44.1kHz_16bit/` sibling; renames original to `<folder> - DO NOT USE`.
- `stemURLs: [URL]` — computed from `lastScannedFolder` + `results`; empty if no folder loaded.

### `AppLogger.swift`
- Writes to `~/Library/Logs/MT Song Tool/mtst-YYYY-MM-DD.log`.
- Global shorthand: `Log("message", "ComponentName")`. Mirrors to `NSLog` for Xcode console.

### `UserSettings.swift`
| Key | Type | Default | Purpose |
|---|---|---|---|
| `mtst_first_name` / `mtst_last_name` | String | `""` | Login name |
| `mtst_theme` | String | `"system"` | Light / Dark / System |
| `mtst_show_copy_all` | Bool | `false` | Show/hide Copy All buttons |
| `mtst_quick_check_mode` | Bool | `false` | Stems/session optional; resets on Clear All |
| `mtst_mt_complete_mode` | Bool | `false` | Suppresses NEXT SONG warning; resets on Clear All |
| `mtst_jam_night_mode` | Bool | `false` | Relaxed validation mode; resets on Clear All |
| `mtst_show_jam_night_toggle` | Bool | `false` | Shows/hides Jam Night toggle in top bar |
| `mtst_bo_username` | String | `""` | BackOffice username |
| `mtst_bo_has_creds` | Bool | `false` | Password stored in Keychain flag |
| `mtst_nr_volume` | String | `"Pitching"` | NR share volume name |
| `mtst_use_keychain` | Bool | `true` | Keychain vs. UserDefaults password storage |
| `mtst_auto_fade_cuts` | Bool | `true` | 10ms fade-in on audio cuts in Edit tab |
| `mtst_as_has_key` | Bool | `false` | AudioShake API key saved in Keychain |

### `CredentialStore.swift`
- Service: `com.multitracks.MTSongTool`, keys: `mtst.backoffice.password`, `mtst.nolanryan.password`, `mtst.audioshake.apikey`.
- `SecAccessCreate` with `trustedApplications = nil` — allows any app to read without prompting (binary hash changes on every rebuild). Users must re-save credentials once after this ACL is first applied.

### `BackOfficeService.swift` (disconnected)
- `ensureLoggedIn()` — probes `/songs/` via `loadPage()`. If cookie valid, returns immediately. Do NOT call `login()` unconditionally — posting to a non-login page fails silently.
- `loadPage(path:)` — auto-logins if redirected to login page; passes redirected URL as `startURL` to avoid extra round-trip.
- `formFields(from:)` — extracts all form field name→value pairs: `<input>`, `<select>` (selected option), `<textarea>`. Title field may be `<input>` or `<textarea>` depending on song status.
- `uploadSession()` — captures all ~70 form fields, overrides 6 (bpm, originalKey, timesignature, previewBegin, previewEnd, rehearsalMixOnly), discovers submit button dynamically, POSTs as multipart/form-data with `.als` attached.
- All async methods have `catch is CancellationError { }` before generic catch — prevents task cancellations (e.g. from MTID changes) from surfacing as UI errors.

---

## Quick Check Mode

Toggle in top bar. Persisted in UserDefaults, reset to `false` on Clear All.

- Stem Check panel visible from launch (no `.als` required)
- `stemCheckRequired` always `false` → stems don't block copy
- Actual stem issues (silent files, wrong names, missing required stems) still block
- Song Key, Preview Start/End not required when active

---

## MT Complete Mode

Toggle in top bar. Persisted in UserDefaults, reset to `false` on Clear All. Auto-enabled when V1 + VS + V4 locators all present in session.

- Suppresses NEXT SONG missing/misspelled placeholder row
- Enables short code locator labels (V1, VS, V4, VC, VB, VV, VP, E1, E4) — these are invalid and shown red when MT Complete is off
- Short codes also hidden from the rename picker unless MT Complete is on
- Reveals **Song Duration** (loop bracket length in seconds) and **Display Duration** (time of V1 marker in seconds) as read-only copyable fields in Song Data
- All other locator validation still applies

---

## Jam Night Mode

Toggle in top bar, hidden by default. Show/hide via Settings popover → Jam Night → Show. Persisted in UserDefaults, reset to `false` on Clear All.

- Relaxes `hasSessionWarnings`: tempo ramps and loop/clip alignment issues no longer block copy
- Relaxes `hasMissingRequiredStems`: only ORIGINAL SONG required (CLICK TRACK and GUIDE not required)
- Shows **Tempo panel** as a third column in the QA panels row (alongside Locators + Time Signatures)
- All other copy-blocking still applies

---

## BackOffice Reference (for future reconnection)

- **Base URL:** `https://backoffice.multitracks.com`
- **Edit page:** `POST /songs/edit.aspx?id={songID}` — multipart/form-data
- **Shell page:** `GET /songs/details.aspx?id={songID}`
- **Auth:** ASP.NET WebForms session cookie. Login page at `/default.aspx`. Unauthenticated requests redirect to `/default.aspx?ReturnUrl=...`.
- **ViewState encoding critical:** `urlFormEncode()` (alphanumerics + `-._~` only) — NOT `.urlQueryAllowed`, which leaves `+`, `/`, `=` unencoded and silently corrupts base64 ViewState tokens.
- **Key/time sig/status dropdown mappings:** see `keyID()`, `timeSigID()`, `statusLabel()` in `BackOfficeService.swift`.
- **Preview:** `previewBegin` / `previewEnd` — integer seconds string. **BPM:** `bpm` — `"140.00"` format.
- **"Upload Stems" trigger:** `<a id="btnEngineering">` on shell page — POST `__EVENTTARGET=btnEngineering`. Only present when engineering status allows it.

## Nolan Ryan Reference (for future reconnection)

- Server hostname: `nolanryan`. Share/volume name: `Pitching` → mounts at `/Volumes/Pitching/`.
- `isMounted()` checks `/Volumes` directory listing (NOT `mountedVolumeURLs` — triggers network volume permission prompts on Ventura+).
- BackOffice creates `{MTID} - {SongName}/` folder when "Upload Stems" is triggered. MTST only copies stems into it.
- Keychain entries: `mtst.backoffice.password`, `mtst.nolanryan.password` (service: `com.multitracks.MTSongTool`)

---

## Design System

Colors via `Color` extensions in `DesignSystem.swift`. Light/dark pairs:

| Token | Dark | Light |
|---|---|---|
| `bg` | `#181818` | `#f5f5f7` |
| `bgCard` | `#252525` | `#ffffff` |
| `accent` | `#60a5fa` | `#2563eb` |
| `accent2` | `#a78bfa` | `#7c3aed` |
| `fgBright` | `#e5e7eb` | `#1f2937` |
| `fgMid` | `#9ca3af` | `#6b7280` |
| `border` | `#333333` | `#d1d5db` |
| `red` | `#f87171` | `#b91c1c` |

Fonts: `.horizon(size:)` uses the bundled `Horizon-Bold.otf` custom font. `.lato(size:weight:)` returns `.system(size:weight:design:)` — it does **not** use the bundled Lato `.ttf` files (those are registered but `.lato()` calls `.system()`).

Full color token list is in `DesignSystem.swift`. The table above covers the most-used tokens; additional semantic tokens include `fgDim`, `bgCardHov`, `inputBg`, `redLight`, `redBg`, `green`, `greenLight`, `dropHovBg`, `toastComingBg`, `pressedBg`, and others.

Button styles: `CompactSecondaryButtonStyle`, `SecondaryButtonStyle`, `FixedHeightSecondaryButtonStyle` — all have `.hoverable()` modifier variant.

---

## Gotchas & Edge Cases

- **All Swift files are in one SPM target** — no imports needed between them.
- **`@StateObject` instances live in `ContentView`** — `parser`, `audioAnalyzer`, `stemPlayer`, `editPlayer`, `audioShakePlayer`, `metronome`. `copyBlocked` reads from these directly. No `boService` in current UI.
- **`stemCheckMinimized`, `songDataMinimized`, `locatorsSigMinimized` are `@State` on `ContentView`** — prevents re-parses from resetting collapse state.
- **dawtool strips locator names** — `ableton.py` calls `.strip()` on locator values. We bypass with `_extract_locator_data()` reading raw XML.
- **Time sig changes and barline checks** — `validate_session` uses `_ts_events_from_content()` (regex) rather than ET-based parsing. ET-based approach silently failed to find `PointeeId` in some versions.
- **Tempo ramp check** — step changes are two events at the same beat position; a ramp is a non-step pair where value differs. Phantom event (beat < 0) excluded.
- **Case-only renames on APFS** — macOS case-insensitive FS treats `eg 1.wav` → `EG 1.wav` as a collision. Route through a UUID temp file.
- **FFmpeg** — binary + dylibs in `Contents/Frameworks/`. `xattr -cr` must run on Frameworks dir during build or macOS silently blocks FFmpeg at runtime.
- **`hexdump` must be in venv** — `dawtool/daw/flstudio_core.py` imports it at startup. Missing = parser crashes before `{"ready": true}`. `build_parser.sh` installs it automatically.
- **`LocatorValidator.sortedSections`** — manually ordered array (grouped by song structure: Verse → Chorus → … → Count/Intro/Outro → NEXT SONG → Short Codes) used to populate the rename picker. `acceptedSections` (the validation set) is private. `shortCodes` is a public `Set<String>` used to filter the picker and gate `isValid()` based on `mtCompleteMode`.
- **`LocatorValidator.isValid` returns `false` for empty string** — the docstring on `Validation.swift` line 4 says "Empty string is also valid" but the implementation on line 106 explicitly returns `false`. Blank locators are shown as invalid in the UI with a "Fix In Session" badge.
- **`SuggestLocatorsSheet` supports PDF, txt, rtf, docx** — `extractText(from:)` handles `.pdf` via PDFKit and `.txt/.rtf/.docx` via `NSAttributedString`. This is live; memory file `project_suggest_locators_pdf_support.md` marked it deferred but it's implemented.
- **EditView stem sort order** — CLICK TRACK (0) → GUIDE (1) → ORIGINAL SONG (2) pinned top; rest alphabetical. Stems where `stemStates[$0]?.isExcluded == true` are filtered out of the canvas entirely.
- **EditView canvas width** — `totalDuration + (lastBarSeconds × 10) + canvasRightPadding`. `lastBarSeconds` = duration of the last bar in the beat schedule. `canvasRightPadding` grows as user scrolls right. Beat schedule is built twice: once to get accurate `lastBarSeconds`, then again to cover `canvasDuration`.
- **EditPlayerService beat-0 anchor** — `editableTempoEvents[0]` and `timeSigOverrides[0]` are the beat-0 anchors. `deleteTempoEvent(at:)` and `deleteTimeSig(at:)` guard `index > 0` to prevent deletion.
- **`StatusBadge` uses `.fixedSize(horizontal: true, vertical: false)`** — required to prevent text wrap; removing causes row height instability.
- **Silence threshold** `1e-4` (-80 dBFS) — intentionally above 16-bit dither noise floor (~6e-5) to avoid false positives on dithered-silent files.
- **Stem duration tolerance** — 5 samples at native sample rate (~0.113ms at 44.1kHz) — absorbs ~2.63-sample float rounding offset in Ableton WAV exports.
- **`ManagedNSTextField.acceptsFirstResponder`** returns `allowFocus || mouseInside` — prevents auto-focus race conditions when tabbing between pickers.
- **NEXT SONG TIME END is blank by design** — NEXT SONG is placed at/after loop bracket end; showing loop end as its `time_end` would be earlier than its start.
- **Time Signatures fallback** — all intermediate failure paths in `parse_time_signatures()` use nested `if` blocks (not `return []`) so execution always reaches the `if not deduped:` fallback.
- **BackOffice POST sends ALL form fields** — `formFields()` captures ~70 fields, then 6 are overridden. ASP.NET ViewState preserves everything else server-side.
- **Keychain prompts on unsigned builds** — `SecAccessCreate` with `trustedApplications = nil` fixes this. Users must re-save credentials once after this ACL change.
- **Section waveform flash** — `play()` calls `teardownPlayer()` (not `stop()`) so it doesn't clear `activeSectionStart/End`. `playSection()` sets section state before calling `play()` — by the time `playingStemURL` is published (making the waveform visible), section state is already set. If you ever refactor playback, preserve this ordering or the waveform will flash gray on section play.
- **Metronome anchor** — `stemPlayer.playAnchor` is published from a boundary time observer 1ms past the playback start. ContentView's `.onChange(of: stemPlayer.playAnchor)` calls `metronome.start(...)`. Don't start the metronome from `isPlaying` — that fires before the anchor is measured.
- **`hasPopulatedSongData` gate** — `populateSongData(from:)` only runs once per file load. Subsequent re-parses (locator fixes) skip it so user-entered fields are not clobbered.
- **Window frame persistence** — `AppDelegate.applicationWillTerminate` saves frame to `MTSongToolWindowFrame` in UserDefaults; `RootView.configureWindow()` restores it on launch.
- **Parser binary location** — now at `Resources/parse_als_dir/parse_als` (not `MacOS/parse_als_dir`). The legacy path is still checked as fallback. Don't change the resolution order in `ParserProcess.resolveParser()` without updating both paths.
- **Multiple `.als` in folder drop** — `AlsPickerSheet` is shown; user selects one or clicks "Load Stems Only". Stems are loaded after the sheet closes regardless of choice.
- **`clearAll()` resets modes** — also resets `jamNightMode` in addition to `quickCheckMode` and `mtCompleteMode`.
- **AlignmentService vDSP FFT pitfalls** — (1) `vDSP_fft_zrip` with `FFT_INVERSE` returns lag axis flipped vs textbook ifft — **negate the decoded lag** (`lagCoarse = -rawLag`). (2) Packed split-complex format stores DC in `realp[0]` and Nyquist in `imagp[0]` as REAL values; `vDSP_zvmul` treats element 0 as a complex pair and produces wrong results — **save DC*DC and Nyq*Nyq before the multiply, restore after**. Both verified empirically; without them the reported offset sign flips or magnitude is wrong. Don't regress.
- **NSScrollView.didLiveScrollNotification fires on layout changes** — Not just real user scrolls. When canvas content width grows (e.g., click track gen, segment edits), the scroll view re-fires `didLiveScrollNotification` even though the user didn't scroll. `WaveformScrollHost.Coordinator.handleLiveScroll` MUST guard with `abs(scrollX - lastLiveScrollX) > 0.5` to skip these synthetic fires. Without it, `onApproachingRightEdge` → `canvasRightPadding +=` → `rebuildBeatSchedule` → schedule publish → canvas relayout → didLiveScroll → infinite feedback loop (~11 Hz rebuilds, app freezes). Confirmed in logs 2026-05-13.
- **Async peaks task must merge, not replace** — `EditPlayerService.loadStems` and `addSyntheticStem` extract waveform peaks on a `Task.detached`. The completion handler must read `self.stemStates[url]` and merge (preserving `isExcluded`, `gain`, user-edited segments) rather than writing a fresh `StemState`. Replacing was the bug that allowed real `CLICK TRACK.wav` to re-appear in the timeline after `excludeRealClickTrackIfPresent()` had hidden it — causing stems to visually extend past the loop bracket.
- **Synthetic stems exported separately** — `exportStems` iterates `analyzer.results` (real stems from `lastScannedFolder`) by default. Synthetic stems (generated CLICK TRACK in `/tmp/`) must be passed via the `syntheticStems:` parameter; `openSavePanel` builds this list from `editPlayer.syntheticStemURLs`. Each synthetic stem runs through the same `-af apad -t durStr` FFmpeg truncation as real stems.
- **Alignment correction allows negative sessionStart** — `applyAllAlignmentCorrections` calls `shiftAllSegments(url, delta, clampToZero: false)`. After a positive bus-late correction, stems can sit before bar 1 (pre-roll). Both playback and FFmpeg export handle negative `sessionStart` via `preRoll = max(0, -sessionStart)`.
