# MT Song Tool (MTST) — Claude Code Context

**Current version:** v1.2.1
**Platform:** macOS 13+, Swift/SwiftUI, Swift Package Manager
**Project root:** `/Volumes/MTEng0/claude-apps/mt-song-tool/`

---

## What the App Does

Internal macOS QA tool for MultiTracks.com staff. Given an Ableton Live `.als` session and a folder of `.wav` stems, it validates everything needed before publishing a song package:

1. **Parses `.als` files** — extracts locators (section markers) with accurate timestamps even across tempo automation changes. Uses a bundled Python parser (`parse_als.py` → PyInstaller binary) rather than Ableton's own script, which breaks on tempo changes.
2. **Locator validation** — checks each marker label against the approved MultiTracks sections list. Invalid labels shown in red. Double-click → dropdown picker writes corrections back to the `.als` file.
3. **Time Signatures panel** — extracted from the Ableton automation envelope (with fallback to static Numerator/Denominator for single-time-signature sessions).
4. **Song Data panel** — auto-populates Song Key, Time Sig, BPM, Preview Start/End from the session. All fields copyable.
5. **Stem Check panel** — drop a `.wav` folder to batch-validate silence, stem name conformance (against ~200 approved names), and audio format (44.1 kHz / 16-bit).
6. **Session validation** — loop bracket vs audio clip alignment checks, barline checks that respect mid-song time signature changes.
7. **Quick Check Mode** — toggle that removes the requirement to have both an `.als` and stems before proceeding.
8. **MT Complete Mode** — toggle that suppresses the NEXT SONG missing-locator warning (for single-song sessions).
9. **Upload tab** — copy stems to Nolan Ryan SMB share; upload `.als` + metadata to BackOffice.

---

## Swift Sources (`mtst-master/swift-app/Sources/MTSongTool/`)

- `App.swift` — @main, window setup
- `ContentView.swift` — root view, all state, layout, copy blocking
- `DesignSystem.swift` — colors, fonts, button styles, cardStyle()
- `UserSettings.swift` — UserDefaults-backed ObservableObject
- `LoginView.swift` — first-run name entry screen
- `ParserService.swift` — communicates with bundled Python parser
- `SongData.swift` — SongDataOptions (approved key/time sig lists)
- `Validation.swift` — LocatorValidator, TimecodeHelper
- `LocatorCheckView.swift` — Locators panel + auto-fix + NEXT SONG check
- `PanelComponents.swift` — PanelView, RowView, DropZoneView, pill shapes
- `PickerComponents.swift` — SongDataPickerView + search/keyboard nav
- `SongDataComponents.swift` — SongDataCopyButton, HoverCheckbox
- `TextFieldComponents.swift` — SongDataNSTextField, ManagedNSTextField
- `AudioAnalyzerService.swift` — stem scanning, validation, rename, convert
- `AudioAnalysisView.swift` — Stem Check UI, AudioFileRow (dropdown rename), WaveformSeekView
- `StemPlayerService.swift` — AVPlayer wrapper; per-stem playback + section playback with loop
- `CredentialStore.swift` — Keychain wrapper (BackOffice + NR passwords)
- `NolanRyanService.swift` — SMB mount check + stem file copy to NR Pitching share
- `BackOfficeService.swift` — BackOffice login, song metadata fetch, .als + data upload
- `UploadView.swift` — Upload tab UI (NR + BackOffice cards)

Other key files: `parse_als.py` (Python parser), `make_swift_app.sh` (one-command build), `build_parser.sh` (PyInstaller step) — all in `mtst-master/`.

---

## Current Status (v1.0.6)

Upload pipeline complete: QA/Upload tab switcher, NR SMB stem copy, BackOffice `.als` + metadata upload, credential storage (Keychain), stem rename dropdown picker.

Per-stem waveform playback complete: Canvas-based `WaveformSeekView` with 500-peak extraction, section highlight mode (triggered from Locators panel), and loop-within-section support.

### BackOffice reference

- **Base URL:** `https://backoffice.multitracks.com`
- **Edit page:** `POST /songs/edit.aspx?id={songID}` — multipart/form-data
- **Shell page:** `GET /songs/details.aspx?id={songID}`
- **Auth:** ASP.NET WebForms session cookie. Login page at `/default.aspx`. Unauthenticated requests redirect to `/default.aspx?ReturnUrl=...`.
- **ViewState encoding critical:** `urlFormEncode()` (alphanumerics + `-._~` only) — NOT `.urlQueryAllowed`, which leaves `+`, `/`, `=` unencoded and silently corrupts base64 ViewState tokens.
- **Key/time sig/status dropdown mappings:** see `keyID()`, `timeSigID()`, `statusLabel()` in `BackOfficeService.swift`.
- **Preview:** `previewBegin` / `previewEnd` — integer seconds string. **BPM:** `bpm` — `"140.00"` format.
- **"Upload Stems" trigger:** `<a id="btnEngineering">` on shell page — POST `__EVENTTARGET=btnEngineering`. Only present when engineering status allows it.

### Nolan Ryan reference

- Server hostname: `nolanryan`. Share/volume name: `Pitching` → mounts at `/Volumes/Pitching/`.
- `isMounted()` checks `/Volumes` directory listing (NOT `mountedVolumeURLs` — triggers network volume permission prompts on Ventura+).
- BackOffice creates `{MTID} - {SongName}/` folder when "Upload Stems" is triggered. MTST only copies stems into it.
- Keychain entries: `mtst.backoffice.password`, `mtst.nolanryan.password` (service: `com.multitracks.MTSongTool`)

---

## How to Build

```bash
bash "/Volumes/MTEng0/claude-apps/mt-song-tool/mtst-master/swift-app/make_swift_app.sh"
```

**What it does (4 steps):**
1. Runs `build_parser.sh` — compiles `parse_als.py` into a standalone binary via PyInstaller (venv at `mtst-master/venv/`). Installs `lxml` and `hexdump` into the venv first.
2. Runs `swift build -c release`
3. Assembles `/Applications/MT Song Tool.app` (Swift binary + parser binary + fonts + icon + bundled FFmpeg)
4. Produces a `.pkg` installer, wraps it with `Release Notes.md` in a versioned `.zip` at `Versions/MT Song Tool vX.X.X.zip`

**No sudo required** — `/Applications` is group-writable for admin users. If the existing bundle is root-owned (from an older install), the script does a one-time `sudo chown` to take ownership.

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

### State ownership (`ContentView`)
```swift
@StateObject private var parser = ParserService()
@StateObject private var audioAnalyzer = AudioAnalyzerService()
@StateObject private var boService = BackOfficeService()  // lifted so submitRow + UploadView share one instance
@ObservedObject private var userSettings = UserSettings.shared
@State private var stemCheckMinimized: Bool   // lifted here so re-parses don't reset it
```

### Copy blocking (`copyBlocked: Bool`)
```swift
private var copyBlocked: Bool {
    isLive12Session             // Live 12 .als loaded but not yet converted
    || hasInvalidLocators       // any locator fails LocatorValidator
    || hasSessionWarnings       // warnings from validate_session in parse_als.py
    || stemCheckRequired        // no stem scan run yet (false in Quick Check Mode)
    || hasAudioIssues           // any stem result where !isClean
    || hasDataMissing           // any required Song Data field empty
    || hasMissingRequiredStems  // CLICK TRACK / ORIGINAL SONG / GUIDE missing
}
```

Copy buttons are **never `.disabled`** — they always fire, but when `copyBlocked` they show a toast instead of copying.

### `loadNewFile(path:)`
Central helper called whenever any new `.als` is loaded. Resets parser result, error, song data, audio analyzer, then calls `parser.parse(alsPath:)`. Always use this instead of calling `parser.parse()` directly.

### Live 12 conversion flow
1. Parse completes → if `liveMajorVersion == 12`, `showLive12Alert = true`
2. **Convert** → spinner overlay → `parser.downgradeToLive11` → `loadNewFile(newPath)` with `_Live11.als`
3. **Cancel** → `clearAll()` resets app to empty state

### Locator fix flow
1. User selects fix in `LocatorCheckView` → `applyLocatorFixes()` in `ContentView`
2. Python renames original to `OLD_<name>.als`, writes patched content to original path
3. Re-parses; `stemCheckMinimized` survives because it's `@State` on `ContentView`

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

### `LocatorCheckView.swift`
- `autoFixedLocatorName(_:mtCompleteMode:)` — 3-pass: trim/uppercase/collapse whitespace → replace `-`/`_` with space → replace first space with `-`. Takes `mtCompleteMode` so short codes are not suggested as auto-fixes when off.
- `LocatorRowView` — double-click opens `PickerPopoverContent`. Picker options passed in as `pickerOptions` (filtered by `mtCompleteMode` — short codes excluded when off). Blank locators show "Fix In Session" badge (no picker).
- Column headers row at top: `#` | `TIME START` | `SECTION` | `TIME END`, followed by Fix All banner when present.
- NEXT SONG missing row: shown when no `"NEXT SONG"` marker exists and `mtCompleteMode` is off.

### `StemPlayerService.swift`
- `@Published` properties: `playingStemURL`, `isPlaying`, `currentTime`, `duration`, `volume`, `activeSectionStart`, `activeSectionEnd`, `isLooping`.
- `play(url:)` — starts playback from the beginning; calls private `teardownPlayer()` (NOT `stop()`) so section state is preserved when called from `playSection()`.
- `playSection(url:start:end:)` — sets `activeSectionStart/End` and `isLooping = true` **before** calling `play()`, so the waveform renders in section mode from the first frame (no flash). Then seeks to `start`.
- `stop()` — calls `teardownPlayer()` then clears all section state.
- Loop enforcement: periodic time observer (10 Hz) checks `currentTime >= activeSectionEnd` and calls `seek(to: activeSectionStart)` when looping is on.
- **Critical ordering:** always set section state before calling `play()` — `play()` uses `teardownPlayer()` which does NOT clear section state, but `stop()` does.

### `AudioAnalysisView.swift`
- `WaveformSeekView` — Canvas-based waveform. In section mode (`sectionStart/sectionEnd/totalDuration` provided): dims entire waveform at `fgMid.opacity(0.15)`, renders section window at `fgMid.opacity(0.35)`, fills played portion blue from `sectionStart` to playhead. In normal mode: blue left of playhead, gray right.
- `playbackBar` — Loop button appears left of volume when `stemPlayer.activeSectionStart != nil`; toggles `stemPlayer.isLooping`; accent when on, dim when off.
- Locator play button (`LocatorRowView`) calls `stemPlayer.playSection(url:start:end:)` when `timeEnd` is available; falls back to plain `play + seek` for markers with no `timeEnd` (e.g. NEXT SONG).

### `AudioAnalyzerService.swift`
- `approvedStems: Set<String>` — ~200 uppercase entries, source of truth for valid stem names.
- `validateStemName()` — checks Extra Space, Special Chars, Check Stem Name, Wrong Caps (`name != name.uppercased()`).
- `fixNamingIssues()` / `renameStem()` — both use two-step rename (UUID temp) for case-only changes on APFS.
- `convertNonConforming()` — FFmpeg conversion to `<folder>_44.1kHz_16bit/` sibling; renames original to `<folder> - DO NOT USE`.

### `UserSettings.swift`
| Key | Type | Default | Purpose |
|---|---|---|---|
| `mtst_first_name` / `mtst_last_name` | String | `""` | Login name |
| `mtst_theme` | String | `"system"` | Light / Dark / System |
| `mtst_show_copy_all` | Bool | `false` | Show/hide Copy All buttons |
| `mtst_quick_check_mode` | Bool | `false` | Stems/session optional; resets on Clear All |
| `mtst_mt_complete_mode` | Bool | `false` | Suppresses NEXT SONG warning; resets on Clear All |
| `mtst_bo_username` | String | `""` | BackOffice username |
| `mtst_bo_has_creds` | Bool | `false` | Password stored in Keychain flag |
| `mtst_nr_volume` | String | `"Pitching"` | NR share volume name |

### `ParserService.swift`
- Looks for bundled binary at `MacOS/parse_als_dir/parse_als` first. Dev fallback: `/Volumes/MTEng0/claude-apps/mt-song-tool/mtst-master/venv/bin/python3` + `parse_als.py --server`.
- "Parser not available" = binary crashed before `{"ready": true}` — usually a missing PyInstaller hidden import (`hexdump`). Test binary from Terminal to see crash output.

### `CredentialStore.swift`
- Service: `com.multitracks.MTSongTool`, keys: `mtst.backoffice.password`, `mtst.nolanryan.password`.
- `SecAccessCreate` with `trustedApplications = nil` — allows any app to read without prompting (binary hash changes on every rebuild). Users must re-save credentials once after this ACL is first applied.

### `BackOfficeService.swift`
- `ensureLoggedIn()` — probes `/songs/` via `loadPage()`. If cookie valid, returns immediately. Do NOT call `login()` unconditionally — posting to a non-login page fails silently.
- `loadPage(path:)` — auto-logins if redirected to login page; passes redirected URL as `startURL` to avoid extra round-trip.
- `formFields(from:)` — extracts all form field name→value pairs: `<input>`, `<select>` (selected option), `<textarea>`. Title field may be `<input>` or `<textarea>` depending on song status.
- `uploadSession()` — captures all ~70 form fields, overrides 6 (bpm, originalKey, timesignature, previewBegin, previewEnd, rehearsalMixOnly), discovers submit button dynamically, POSTs as multipart/form-data with `.als` attached.
- All async methods have `catch is CancellationError { }` before generic catch — prevents task cancellations (e.g. from MTID changes) from surfacing as UI errors.

### `UploadView.swift`
- `boService` is `@ObservedObject` (lifted to `ContentView` as `@StateObject`) so Submit row and UploadView share one instance.
- `.task { ensureLoggedIn() }` on tab appear; `.task(id: mtidText)` re-fetches song title/status on MTID change.
- NR folder watch: `.task(id: mtidText)` polls `folderExists()` every 3s; sets `isFolderReady = true` when found; auto-cancels on MTID change.
- Submit is the only upload trigger — no Upload button in the BackOffice card.
- `.onChange(of: boService.uploadComplete)` coordinates NR folder creation after upload: if `nrService.isFolderReady` (folder already exists), sets `uploadStemsComplete = true` directly and skips BackOffice; otherwise calls `triggerUploadStems()`. This prevents a false "Can't Create Folder" error when the song shell shows "Process Stems" but the folder was already created by a prior upload.

---

## Quick Check Mode

Toggle pill top-right. Persisted in UserDefaults, reset to `false` on Clear All.

- Stem Check panel visible from launch (no `.als` required)
- `stemCheckRequired` always `false` → stems don't block copy/submit
- Actual stem issues (silent files, wrong names, missing required stems) still block

---

## MT Complete Mode

Toggle pill top-right. Persisted in UserDefaults, reset to `false` on Clear All.

- Suppresses NEXT SONG missing/misspelled placeholder row
- Enables short code locator labels (V1, VS, V4, VC, VB, VV, VP, E1, E4) — these are invalid and shown red when MT Complete is off
- Short codes also hidden from the rename picker unless MT Complete is on
- All other locator validation still applies

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

Fonts: `.lato(size:weight:)` and `.horizon(size:)` extensions. Font files bundled in `Resources/`.

Button styles: `CompactSecondaryButtonStyle`, `SecondaryButtonStyle` — both have `.hoverable()` modifier variant.

---

## Gotchas & Edge Cases

- **All Swift files are in one SPM target** — no imports needed between them.
- **`@StateObject` for `audioAnalyzer` and `boService` live in `ContentView`** — so `copyBlocked` can read stem results and Submit shares the same service instance as UploadView.
- **`stemCheckMinimized` is lifted to `ContentView`** as `@State` and passed as `@Binding` — prevents re-parses (which destroy/recreate `AudioAnalysisView`) from resetting collapse state.
- **dawtool strips locator names** — `ableton.py` calls `.strip()` on locator values. We bypass with `_extract_locator_data()` reading raw XML.
- **Time sig changes and barline checks** — `validate_session` uses `_ts_events_from_content()` (regex) rather than ET-based parsing. ET-based approach silently failed to find `PointeeId` in some versions.
- **Tempo ramp check** — step changes are two events at the same beat position; a ramp is a non-step pair where value differs. Phantom event (beat < 0) excluded.
- **Case-only renames on APFS** — macOS case-insensitive FS treats `eg 1.wav` → `EG 1.wav` as a collision. Route through a UUID temp file.
- **FFmpeg** — binary + dylibs in `Contents/Frameworks/`. `xattr -cr` must run on Frameworks dir during build or macOS silently blocks FFmpeg at runtime.
- **`hexdump` must be in venv** — `dawtool/daw/flstudio_core.py` imports it at startup. Missing = parser crashes before `{"ready": true}`. `build_parser.sh` installs it automatically.
- **`LocatorValidator.sortedSections`** — manually ordered array (grouped by song structure: Verse → Chorus → … → Count/Intro/Outro → NEXT SONG → Short Codes) used to populate the rename picker. `acceptedSections` (the validation set) is private. `shortCodes` is a public `Set<String>` used to filter the picker and gate `isValid()` based on `mtCompleteMode`.
- **`StatusBadge` uses `.fixedSize(horizontal: true, vertical: false)`** — required to prevent text wrap; removing causes row height instability.
- **Silence threshold** `1e-4` (-80 dBFS) — intentionally above 16-bit dither noise floor (~6e-5) to avoid false positives on dithered-silent files.
- **Stem duration tolerance** — 5 samples at native sample rate (~0.113ms at 44.1kHz) — absorbs ~2.63-sample float rounding offset in Ableton WAV exports.
- **`ManagedNSTextField.acceptsFirstResponder`** returns `allowFocus || mouseInside` — prevents auto-focus race conditions when tabbing between pickers.
- **NEXT SONG TIME END is blank by design** — NEXT SONG is placed at/after loop bracket end; showing loop end as its `time_end` would be earlier than its start.
- **Time Signatures fallback** — all intermediate failure paths in `parse_time_signatures()` use nested `if` blocks (not `return []`) so execution always reaches the `if not deduped:` fallback.
- **BackOffice POST sends ALL form fields** — `formFields()` captures ~70 fields, then 6 are overridden. ASP.NET ViewState preserves everything else server-side.
- **Keychain prompts on unsigned builds** — `SecAccessCreate` with `trustedApplications = nil` fixes this. Users must re-save credentials once after this ACL change.
- **Section waveform flash** — `play()` calls `teardownPlayer()` (not `stop()`) so it doesn't clear `activeSectionStart/End`. `playSection()` sets section state before calling `play()` — by the time `playingStemURL` is published (making the waveform visible), section state is already set. If you ever refactor playback, preserve this ordering or the waveform will flash gray on section play.

