# MT Song Tool — v1.2.1

## Features

- Parse Ableton Live (.als) files to extract locators and time signature changes
- Drag-and-drop or click-to-browse file loading
- Copy individual timecodes or copy all at once
- Locator label validation — labels checked against accepted MultiTracks section list; invalid labels highlighted in red
- **Locator fix** — Auto-fix and manual inline editing for invalid locators; writes corrected names back to the .als file
- **Song Data panel** — Collects song metadata after parsing
- **Session validation** — Loop bracket vs audio clip alignment checks; submit blocked on issues
- **Login screen** — First/Last name saved permanently via UserDefaults
- **Settings menu** — Gear icon with theme toggle (Light/Dark/System) and Log Out
- **Lato font** — All UI text uses Lato (except MTST header which uses Horizon)
- **Toast notifications** — Status messages appear as centered pill overlay at highest z-layer
- **Stem Check panel** — Validates each .wav stem for silence, stem name conformance, and audio format (44.1 kHz / 16-bit)
- **In-app audio conversion** — "Fix Format" button converts non-conforming stems to 44.1 kHz / 16-bit WAV using bundled FFmpeg; auto-rescans output
- Native macOS app with transparent title bar and traffic lights
- Portable — no Python, FFmpeg, or other dependencies needed on target Mac
- .pkg installer wrapped in a versioned .zip for easy distribution

## Changelog

### v1.2.1 — April 7, 2026

#### Session Loading

- **Old Ableton version detection** — Loading an `.als` saved in Ableton 10 or earlier now shows an alert explaining the file must be opened and re-saved in Ableton 11 before use in MT Song Tool. If Ableton 11 is installed, an "Open in Ableton 11" button appears in the alert to launch the file directly.

### v1.2.0 — April 7, 2026

#### Edit tab

- **Waveform rendering overhaul** — Migrated all waveform, grid, and ruler rendering from SwiftUI Canvas to CAShapeLayers. Fixes coordinate scaling artifacts at high zoom on long sessions (Canvas GPU texture size limit ~16K px caused pixel positions to drift by 9+ seconds cumulatively on songs with multiple tempo changes). All rendering is now vector-based with no size limit.
- **Drag-to-nudge** — Drag any clip to shift it in time. The top 18 px of each track row is the move zone; the waveform body is used for region selection. Shift-click to select multiple stems and drag one to move them all together.
- **Region select / delete / move** — Option+drag on any waveform track draws a time-range selection (blue overlay). Delete key silences the selected region on all selected tracks, leaving a visible gap. Drag the selection in the time ruler to move that audio to a new position; a gap is left at the source. CMD+drag adds a selection on a second track without clearing the first.
- **Global selection bar** — A 16 px strip pinned at the bottom of the Edit tab (outside the scroll area) always shows the current selection. Drag it to set the same time range across all stems simultaneously.
- **Snap to grid** — Snap toggle in the Edit toolbar aligns clip drag and ruler selection to the nearest beat when on.

#### Metronome

- **Mute toggle fix** — Left-clicking the metronome icon was silently swallowed by the NSView overlay. Replaced with a plain Image + ClickOverlay so both left-click (mute/unmute) and right-click (settings popover) register correctly.
- **Tempo step-change drift fix** — On sessions with multiple tempo changes, Swift's unstable sort could order equal-beat events incorrectly, causing beat times to drift by up to 9.1 seconds cumulatively on long sessions. Fixed with a stable sort by (beat, original_index) and deduplication that keeps the last event per beat position.
- **Time signature change timing fix** — Time sig changes were detected one beat late due to sub-millisecond rounding differences between the parser's MM:SS:mmm output and the metronome's beat-to-time conversion. Parser now returns beat positions directly; matching is now integer-exact.

#### Stem Check

- **Smart stem name suggestions** — Stems flagged as "Check Stem Name" now show an inline suggestion chip for the best-matching approved name (≥80% confidence). Click the chip to rename with one click. The rename picker also shows a ranked suggestions section with confidence percentages. String similarity matches common abbreviations and separators (e.g. "eg-1" → EG 1, "lead voc" → LEAD VOX). Spectral analysis (FFT-based) categorizes unrecognized stems by frequency content to guide suggestions when the filename is a DAW default (e.g. "Track 01"). (LIVE) variants are only suggested when the filename contains "LIVE" or audio bleed detection exceeds threshold.
- **Fix suggestions for Extra Space / Special Chars** — Stems flagged with "Extra Space" or "Special Chars" now also show a suggestion chip with the cleaned name. Previously these issues showed no suggestion.

### v1.1.0 — April 1, 2026

#### Edit tab
- **Multi-stem timeline** — New Edit tab with a scrollable, zoomable multi-track timeline. All stems load simultaneously into a shared AVAudioEngine for sample-accurate synchronization.
- **Transport** — Play/pause and stop with a bar:beat counter driven by the metronome.
- **Zoom & scroll** — Pinch-to-zoom or scroll horizontally to navigate the timeline. Up to 100 stem rows supported.
- **Drag to nudge** — Drag any stem clip left or right to shift it in time.
- **Cut / split** — Place the playhead and press Cmd+K (or the Cut button) to split selected stems at the current position.
- **Trim** — Drag clip edges to trim the start or end of any stem.
- **Per-stem gain** — dB gain control per track with a peak dBFS meter. Master peak meter in the toolbar.
- **Mute / Solo** — Per-stem mute and solo with Clear Mute / Clear Solo buttons in the toolbar.
- **FFmpeg bake-out** — Commit Changes renders all edits (cuts, nudges, gain) to a new folder using the bundled FFmpeg engine; originals are not modified.
- **Auto fade-in on cuts** — A 10 ms fade-in is automatically applied at every cut point to eliminate clicks (toggleable in Settings).

#### Metronome
- **Mute toggle** — Left-click the metronome icon to mute/unmute the click track. The icon dims when muted. Right-click opens the settings popover (previously the left-click action).
- **+6 dB headroom** — Metronome click amplitude boosted by 6 dB so it cuts through at lower volume slider positions.
- **Real-time volume control** — The volume slider now adjusts click level instantly during playback. Previously changes only took effect on the next play.
- **Eighth-note subdivision** — Switching to "8th's" in metronome settings now generates eighth-note ticks between quarter beats. Ticks are slightly softer than quarter-beat clicks, which are in turn softer than the downbeat.
- **Subdivision change during playback** — Switching subdivision modes mid-playback no longer causes timing drift. The reschedule preserves the original host-time anchor so beats stay locked.
- **Single global metronome** — The metronome icon in the top-left corner is the canonical control, always visible across all tabs. The duplicate control that appeared in the Edit toolbar has been removed.

#### Removed
- **Upload and Queue tabs** — The BackOffice upload and NR processing queue tabs have been removed from this release. They will be reimplemented in a future version.

### v1.0.6 — March 27, 2026
- **Waveform seek control** — The scrub slider in each stem's playback bar is replaced with a per-stem waveform visualization. Waveform peaks are extracted during the existing stem scan (500 amplitude samples per file). The played portion renders in accent blue, the unplayed portion in dim gray, and a vertical white playhead line tracks the current position. Elapsed and remaining times are overlaid at the left and right edges of the waveform. Click anywhere on the waveform to seek, or drag to scrub.

### v1.0.5 — March 26, 2026
- **Locator section preview** — Each locator row in the Locators panel now has a play button (replaces the row number when ORIGINAL SONG is in the scanned stems folder). Click to play ORIGINAL SONG from that section's start time. Click the active row again to stop. Clicking a different row always jumps to that section's start — no resume. Active row tracks playhead position and shows a stop icon while that section is playing.

### v1.0.4 — March 26, 2026
- **Stem audio preview** — Single-click any stem row in the Stem Check panel to play it inline. A playback bar expands below the row with a play/pause button, a scrub slider with elapsed/total time, and a volume slider. Clicking a different row stops the current stem and starts the new one. Double-clicking the stem name still opens the rename picker (and stops playback). Switching to the Upload or Queue tab stops playback. Volume only affects in-app preview level — the .wav file on disk is never modified.

### v1.0.3 — March 26, 2026
- **MTID lookup on Enter** — Typing an MTID no longer triggers a BackOffice lookup on every keystroke. Press **Enter** to fetch the song title and status; press **Enter again** or click **Submit** to begin the upload. Changing the MTID clears the fetched data and requires a fresh Enter press.
- **"cancelled" error suppressed** — URLSession cancellations (e.g. a fetch interrupted by an MTID change) no longer appear as a red "cancelled" error in the BackOffice card.

### v1.0.2 — March 26, 2026
- **Per-row Process button** — Each pending or failed item in the NR Processing Queue now has a **Process** button that immediately runs that single song (copy stems → verify → trigger BackOffice), without waiting to batch with Process All.
- **Completed queue** — Songs that finish uploading to Nolan Ryan move to a new **Completed** box beneath the processing queue, keeping the active queue uncluttered. The Completed box has its own **Clear All** button, plus a per-row **Clear** button on each completed entry.
- **Per-row Retry button** — Failed queue items now show a **Retry** button that resets the item back to Pending (without immediately running it), so it can be included in the next Process All run.
- **Queue Stems button gating** — The "Queue Stems" button in the Upload tab (formerly "Copy Stems") is now greyed out until Submit has been pressed *and* the Nolan Ryan destination folder is confirmed present. Once both conditions are met, the button slowly pulses green to signal it's ready to click. Clicking it stops the pulse and keeps a steady green state.

### v1.0.1 — March 26, 2026
- **NR Processing Queue** — New third tab (QA · Upload · Queue) with a persistent processing queue for BackOffice "Process Stems". After stems are copied and verified on any song, two buttons appear in the Nolan Ryan card:
  - **Process Now** — immediately triggers the BackOffice Upload Stems action for the current song (same as the existing automatic trigger, but available on-demand after the copy step)
  - **Queue for Processing** — adds the current song (MTID + title) to the queue for batch processing later
- **Queue tab** — Shows all queued songs with live status badges (Pending / Processing / Done / Failed). Per-song **Clear** button to remove individual entries. **Process All** runs all pending/failed items sequentially using the shared BackOffice session. **Clear Queue** removes all items at once. Queue persists across app restarts (stored in UserDefaults).

### v1.0.0 — March 25, 2026
- **Upload tab — BackOffice + Nolan Ryan** — Full upload pipeline: copy stems to Nolan Ryan SMB share, upload `.als` + metadata (BPM, key, time sig, preview start/end) to BackOffice, and trigger NR folder creation. All three steps coordinate automatically after Submit.
- **Stem set overwrite protection** — Before uploading, MTST now checks whether the song already has stem sets published in BackOffice. If it does, a confirmation dialog appears before any data is written, preventing accidental overwrites of released songs.
- **BackOffice auto-login** — Credentials saved in Keychain are used to establish a BackOffice session automatically when the Upload tab opens. Session cookies persist across MTID changes.
- **Song shell pre-fetch** — MTID entry triggers a background fetch of the song title, status, and stem set state from BackOffice, so the Upload card shows live song info before submitting.
- **Credential storage** — BackOffice username/password and Nolan Ryan password stored in the system Keychain via a dedicated Credentials section in Settings.
- **NR folder watch** — After triggering "Upload Stems" in BackOffice, the app polls the Nolan Ryan volume every 3 seconds and updates the folder status automatically when the folder appears.

### v0.4.5 — March 25, 2026
- **Live 12 sessions require conversion** — Loading a Live 12 `.als` now immediately prompts "Convert to Ableton 11?" with Convert and Cancel options. All copy buttons are blocked until conversion is complete. After conversion, the `_Live11.als` is automatically loaded and ready to QA.
- **Conversion loading screen** — A spinner overlay appears during the Live 11 conversion so it's clear the app is working.
- **Auto-load after conversion** — After a successful "Convert to Live 11", the converted file is loaded automatically rather than requiring a manual re-open.
- **Version number auto-updates** — The version displayed in the Settings menu now reads from the app bundle rather than being hardcoded, so it will always match the build.
- **Convert to Live 11 bug fixes** — Fixed two issues where converted `_Live11.als` files were rejected by Ableton as corrupt:
  - `PreHearTrack` (the cue output track) was not having its Live 12-only attributes (`SelectedToolPanel`, `SelectedTransformationName`, `SelectedGeneratorName`) stripped, because only four track types were explicitly listed. The stripping now applies globally to any element, so no track type can be missed.
  - `ExpressionLanes` and `ContentLanes` blocks (MIDI editor lane layout data, including `MidiEditorLaneModel` entries) were not removed. These are Live 12-only and are now stripped, along with their companion `IsContentSplitterOpen` and `IsExpressionSplitterOpen` attributes.

### v0.4.4 — March 24, 2026
- **Convert to Live 11** — A "Convert to Live 11" button appears in the bottom bar whenever a Live 12 session is loaded. Clicking it writes a converted copy alongside the original (e.g. `My Song_Live11.als`) without modifying the source file. The conversion applies all schema differences between Live 12 and Live 11: renames `MainTrack` → `MasterTrack`, updates the version header, rewrites the `ViewStates` block, replaces `IsSongTempoLeader` with `IsSongTempoMaster`, removes Live-12-only elements (`NoteAlgorithms`, `TuningSystems`, `ScaleInformation`, `IsInKey`, `AutoWarpPending`, `WasMuted`), strips new track attributes, and reconstructs the `SongMasterValues` block. The button is hidden for non-Live-12 sessions.

### v0.4.3 — March 24, 2026
- **Tempo ramp detection** — Session validation now checks that tempo automation uses step changes (staircase shape) rather than linear ramps or bezier curves. Any pair of consecutive keyframes where the BPM value changes over a non-trivial time span is flagged (e.g. "Tempo ramp: 74 -> 80 BPM — use step changes (staircase) instead of ramps or curves"). Step changes — stored in Ableton as two events at the same beat position — are not flagged.
- **Incomplete bar detection** — Session validation now checks that each time-signature section contains a whole number of bars. If a time-signature change is placed at a position that would leave an incomplete bar (e.g. a 4/4 section with only 6 beats before a 3/4 change), a warning appears in the Session Issues panel and all copy buttons are blocked until fixed. The warning names the affected signatures and includes the timecode of the problematic change (e.g. "Incomplete bar: 4/4 section has 1.5 bars before 3/4 change at 00:06:857"). Sessions with a single unchanging time signature are unaffected.

### v0.4.2 — March 24, 2026
- **Persistent copy checkmarks** — Copy-to-clipboard buttons now hold their green checkmark state indefinitely after copying, rather than fading back after 1.5 seconds. A second click clears the checkmark (without copying again). Applies to all copy buttons: locator TIME START and TIME END, Time Signature rows, Song Data fields (BPM, Preview Start, Preview End), and Copy All buttons.
- **Faster copy checkmark animation** — The doc→checkmark icon swap on copy buttons now transitions in 0.1s instead of the default ~0.35s.
- **Song Data moved to persistent bottom strip** — The Song Data panel now sits permanently between the Locators/Time Signatures panels and the Stem Check, always visible once a file is loaded. Previously it was part of the scrollable results area.
- **Locators and Time Signatures are now independent scrollable boxes** — Each panel scrolls its own content independently. The outer page scroll that grouped them with Song Data has been removed.

### v0.4.1 — March 24, 2026
- **Tempo change divider in Locators panel** — Sessions with tempo automation now show a blue "1st Tempo Change" rule above the first locator that falls at or after the tempo change point. Hidden for single-tempo sessions. Only one divider is shown regardless of how many tempo changes exist.
- **Quick Check mode relaxes Song Data requirements** — When Quick Check is enabled, Song Key, Preview Start, and Preview End are no longer required to be filled before copy buttons unblock. Time Signature and BPM (auto-populated from the .als) are still required.

### v0.4.0 — March 24, 2026
- **Locator TIME END column** — Each locator row now displays a TIME END timecode alongside the existing TIME START, with its own copy button. For all locators except the last, TIME END is the next locator's start time. For the final locator (when NEXT SONG is not present), TIME END is the loop bracket end. The layout is symmetrical: TIME START and its copy button on the left, the locator name in the center, and TIME END with its copy button on the right.
- **NEXT SONG missing/misspelled detection** — If no locator named exactly "NEXT SONG" is present, a red placeholder row appears at the bottom of the Locators panel with an "Add In Session" badge. This fires for both missing and misspelled NEXT SONG locators (a misspelled row already shows red, and the placeholder also appears since the name doesn't match exactly). The placeholder clears automatically as soon as a correctly spelled NEXT SONG locator is detected.
- **MT Complete mode** — A new "MT Complete" toggle sits to the left of "Quick Check" in the top-right corner. When enabled, the NEXT SONG missing placeholder is suppressed — intended for single-song sessions where a NEXT SONG locator is not expected. Resets to off on Clear All.

### v0.3.9 — March 19, 2026
- **Quick Check Mode** — A "Quick Check" toggle appears beneath the settings gear (top-right) and persists across sessions. When enabled: the Stem Check panel is visible from launch (no .als required), its red "missing" border is suppressed, stem scanning is no longer required to unblock copy buttons or submit, and the MTID/Submit row is hidden until an .als is loaded. Useful for checking stems independently or reviewing a session without having the full package ready. Any stem issues found (silent files, wrong names, missing required stems) still block as normal — Quick Check only removes the requirement to have scanned at all.

### v0.3.8 — March 19, 2026
- **Time signature change support in session validation** — The "does not end on beat 1" check now correctly handles sessions with mid-song time signature changes (e.g. one bar of 3/8 inside a 6/8 session). Previously, only the initial time signature was used for barline math, causing false positives whenever a differently-sized bar shifted the total beat count. The validator now reads the full time signature automation envelope and walks the bar map section by section, so any combination of time signatures is handled correctly.

### v0.3.7 — March 18, 2026
- **Inline stem rename** — Double-click any stem name in the Stem Check list to rename it in place. The row switches to an editable text field pre-filled with the current name (without extension); press Enter to commit or click × to cancel. The new name is validated against the approved stem list (case-insensitive; committed as ALL CAPS) — if it doesn't match, a red inline error appears and the field stays open. On a successful rename the file is renamed on disk and the folder is automatically re-scanned.

### v0.3.6 — March 18, 2026
- **Locator auto-fix expanded** — Normalization now handles hyphens (`VERSE-1` → `VERSE 1`), underscores (`VERSE_2` → `VERSE 2`), multiple internal spaces (`VERSE  1` → `VERSE 1`), and reversed separators (`POST CHORUS` → `POST-CHORUS`). All fixable locators show a per-row Fix button and are included in Fix All.
- **Blank locator badge** — Locators with no name now show an inline orange "Fix In Session" badge instead of appearing empty, making it clear the label must be named in Ableton before the file can be processed.
- **Locator extra-space detection** — Leading/trailing spaces in locator names (e.g. `" CHORUS"`) are now correctly flagged as invalid. Previously, the parser silently stripped them before validation.
- **Persistent file bar** — The current filename and a drop-to-replace zone are now pinned above the results area (outside the scroll), so you can load a new file at any time without scrolling back to the top. Accepts drag-and-drop or click-to-browse.
- **Stem Check resets on new file** — Loading a new .als file (via drop or browse) now clears the Stem Check results. Previously, stems from the previous session remained visible until a new scan was run.
- **MTID + Submit moved to bottom bar** — When enabled in Settings, the MTID field and Submit button now appear in the bottom bar to the left of Clear All, rather than at the bottom of the scrollable results.
- **Stem names must be ALL CAPS** — "Wrong Caps" now flags any stem whose filename is not fully uppercase (e.g. `Bass.wav`, `Click Track.wav`). Previously only the first letter of each word was checked. Fix Names corrects to ALL CAPS automatically.
- **Double-space detection in stem names** — Internal runs of multiple spaces (e.g. `ORIGINAL  SONG.wav`) are now flagged as "Extra Space" and corrected by Fix Names. Previously they fell through to "Check Stem Name".
- **Locator fix backup naming** — When locator names are corrected, the original .als file is renamed to `OLD_<filename>.als` and the fixed version keeps the original name. Previously the fixed version was written to `NEW_<filename>.als`.

### v0.3.5 — March 18, 2026
- **Locator fix** — Invalid locator names can now be corrected directly from the app without opening Ableton. A "Fix All" orange banner appears when any locators can be auto-corrected (trim + uppercase only). Each invalid row shows a per-row "Fix" button if auto-fixable, and any invalid locator can be double-clicked to enter inline edit mode with free-text entry validated against the approved sections list. Fixes are written back to the .als file and the session is automatically re-parsed.
- **Stem duration tolerance** — Tolerance for stem length vs loop bracket comparison widened from 1 sample to 5 samples (~0.113ms at 44.1kHz), absorbing a consistent ~2.63-sample float rounding offset introduced by WAV export. Eliminates false "Too Short/Long" flags on correctly exported stems.
- **Locator ID ordering fix** — Fixed a bug where locator write-back applied fixes to the wrong locators. Ableton assigns XML IDs in creation order, which can differ from time order (e.g. a NEXT SONG marker placed at the end of the session may have Id="0"). The parser now sorts locator IDs by beat time before mapping them to dawtool's time-sorted marker list, ensuring indices always align.
- **Song Data preserved on re-parse** — Re-parsing the .als after a locator fix no longer clears the Song Data fields the user has already filled in.

### v0.3.4 — March 18, 2026
- **Duplicate stem detection** — Stem Check now flags stems that share the same name (case-insensitive, ignoring extension) as "Duplicate". Both copies are flagged red.
- **Fix Names button** — New "Fix Names" button in the Stem Check header auto-corrects stems flagged with Extra Space, Wrong Caps, or Special Chars. A confirmation dialog appears before any files are renamed. Special characters are replaced with spaces (so `EG-1` → `EG 1`, a recognized stem), unbalanced parentheses are stripped, and a two-step rename is used for case-only changes (e.g. `cLICK Track` → `CLICK Track`) to avoid false "file already exists" errors on macOS APFS.
- **Special character detection** — Stem name validation now flags names containing characters outside letters, digits, spaces, and balanced parentheses as "Special Chars". Parentheses are permitted because approved names like `DRUMS (LIVE)` use them, but unbalanced pairs (e.g. `EG 1(`) are flagged.

### v0.3.3 — March 18, 2026
- **Stem duration validation** — Stem Check now flags stems whose length doesn't match the session's loop bracket. After dropping an .als file, the expected stem duration is computed from the loop bracket using the session's full tempo map (so tempo-automated sessions are handled correctly). Each stem's actual duration is read from its WAV file and compared against this expected value. Stems that are off by more than 1 sample (1/44100s ≈ 0.023ms) are flagged with a red "Too Short" or "Too Long" badge. Requires an .als file to be loaded first — if no loop bracket is found the check is silently skipped.

### v0.3.2 — March 18, 2026
- **Scrollable Stem Check panel** — The Stem Check results list is now fixed at 8 visible rows with a scrollbar, so the window stays compact even with large stem sets. A minimize/expand toggle (chevron) sits above the list — click it to collapse the panel down to just the header, and click again to restore it.
- **Stem Check hidden until file is loaded** — The Stem Check panel no longer appears on launch. It shows only after an .als file has been successfully parsed, keeping the initial screen uncluttered.
- **Preview End auto-populates from manual Preview Start** — If Preview Start does not auto-populate from the session (no suitable chorus found), typing a value manually into Preview Start will now automatically fill Preview End as start + 45 seconds, matching the existing auto-populate behavior. Preview End is only auto-filled if it hasn't been manually edited.

### v0.3.1 — March 18, 2026
- **Time Signatures fix** — Fixed two bugs that caused the Time Signatures panel to appear empty. (1) The initial time signature (which Ableton stores as a ghost event at beat −63072000) was being silently skipped, so sessions with a single unchanging time signature (e.g. a plain 4/4 session) showed nothing at all. Fixed to display the initial event at 0:00:000. (2) Live 12 writes `<MainTrack Id="0">` with attributes, but the parser searched for `<MainTrack>` with a closing `>`, causing it to miss the track entirely. Fixed to match the tag regardless of attributes. Also made track name selection version-aware: Live 10/11 uses `MasterTrack`, Live 12+ uses `MainTrack`.
- **Updated approved stems list** — Stems list updated from the full PARTS source-of-truth report. Additions include Lead Vocal 1–3, Viola 1–3, Sax 1–3, Wurli, Rubab, 12 String, Tremolo, Piano FX, AG, and more. Corrections include CP 70 (was CP70) and Piano FX (was FX Piano). Functional/non-audio stems excluded (Subclick variants, Master, Left, Right, etc.).
- **PKG auto-update on install** — The installer now includes a `postinstall` script that automatically quits any running instance of MT Song Tool and clears the macOS quarantine flag. This ensures the newly installed version launches correctly without the user needing to manually quit the app or run any Terminal commands.

### v0.3.0 — March 17, 2026
- **In-app audio conversion** — New "Fix Format" button appears in the Stem Check panel whenever files are flagged with sample rate or bit depth issues (e.g. "48kHz", "24-bit"). Clicking it:
  - Shows a confirmation dialog listing how many files will be converted and confirming originals will not be touched
  - Converts only the non-conforming files to 44.1 kHz / 16-bit WAV using the bundled FFmpeg engine
  - Saves converted files to a new sibling folder named `<stems folder>_44.1kHz_16bit`
  - Automatically rescans the output folder so the Stem Check panel refreshes in place
  - If any files fail, an inline error banner appears showing the count and the specific error from FFmpeg
- **Bundled FFmpeg** — FFmpeg and its audio codec libraries are now included inside the app bundle; no external install (Homebrew, etc.) is required on the target machine
- **PKG installer + zip** — `make_swift_app.sh` now automatically produces a versioned `MT Song Tool vX.X.X.zip` on the Desktop at the end of every build, containing the `.pkg` installer and these release notes. Recipients unzip and double-click the `.pkg` — no manual steps needed

### v0.2.5 — March 17, 2026
- **Stem Check panel** — Renamed from "Audio Check"; panel now validates each .wav file on three dimensions:
  - **Silence detection** — files that are 100% silent (below -80 dBFS, safely above 16-bit dither noise floor) are flagged "Silent"
  - **Stem name validation** — filenames (without extension) are checked against the approved MultiTracks stem list (~200 entries); flags "Unknown Stem" for names not on the list, "Wrong Caps" if any word's first letter is not uppercase, and "Extra Space" if the name has leading or trailing whitespace
  - **Format validation** — flags files that are not 44.1kHz or not 16-bit (e.g. "48kHz", "24-bit")
  - Each file row shows per-issue badges; the header issue count now reflects any file that is not fully clean (audio + name + format)
  - Copy buttons remain blocked when any stem has issues, consistent with existing session-error behavior
- **Missing required stems** — CLICK TRACK, GUIDE, and ORIGINAL SONG are pinned to the top of the results list; if any are absent from the scanned folder they appear as red "Missing" rows and block copy
- **MTID toggle** — MTID field and Submit row are hidden by default; can be shown via Settings
- **Clear All** — resets the entire app state (parser result, song data, and stem check) in one click
- **Fixed row heights** — all stem rows are a consistent 32pt regardless of badge count; badges expand horizontally and never wrap

### v0.2.4 — March 17, 2026
- **Copy buttons always clickable** — Copy buttons are no longer disabled when there are session errors; clicking them now shows a "Fix errors before copying" toast instead of silently doing nothing
- **Code refactor** — ContentView.swift split into five focused files for easier future editing: `ContentView.swift` (root layout + state), `SongDataComponents.swift` (SongDataCopyButton, HoverCheckbox), `TextFieldComponents.swift` (SongDataTextFieldView, SongDataNSTextField), `PickerComponents.swift` (SongDataPickerView, PickerPopoverContent, PickerSearchField, PickerOptionRow), `PanelComponents.swift` (PanelView, RowView, DropZoneView, SettingsPillButton, LogOutButton, LeftPillShape, RightPillShape). No functional changes.

### v0.2.3 — March 17, 2026
- **Copy buttons disabled on errors** — All copy buttons (per-row in Locators/Time Signatures, Copy All, and BPM/Preview Start/Preview End) are disabled and dimmed when there are session errors or invalid locators; tooltip reads "Fix errors before copying"
- **Centered toast overlay** — Error/status toast pill now appears centered in the window at the highest z-layer, overlaying all content, instead of anchored to the bottom

### v0.2.2 — March 13, 2026
- **Full Tab-cycle through Song Data** — Tab now cycles through all 6 Song Data fields in a continuous loop: Song Key → Time Signature → BPM → Preview Start → Preview End → RehearsalMix Only → Song Key. Previously Tab skipped the popover pickers and checkbox.
- **AppKit text fields** — BPM, Preview Start, and Preview End converted from SwiftUI TextField to NSViewRepresentable (NSTextField) for reliable Tab key interception and programmatic focus control
- **Focusable checkbox** — RehearsalMix Only checkbox now participates in the Tab cycle with a focus glow indicator; Space toggles the value when focused
- **Popover focus fix** — Tabbing from Song Key to Time Signature no longer skips to BPM; fixed a race condition where macOS would auto-focus the first text field before the next popover could open
- **MTID in Tab cycle** — Tab order now includes the MTID field: Song Key → Time Signature → BPM → Preview Start → Preview End → RehearsalMix Only → MTID → Song Key. Enter in MTID triggers submit.
- **No focus flash on Tab transitions** — Text fields use a custom NSTextField subclass that refuses system auto-focus, eliminating the brief cursor flash in the wrong field when tabbing between pickers
- **Checkbox focus glow** — RehearsalMix Only focus indicator changed from a large border ring to a subtle glow and shadow on just the checkbox icon
- **Prefix-only popover search** — Typing in Song Key and Time Signature popover search fields now filters by the start of each option, not anywhere in the string (e.g. "B" shows "Bb" but not "Ab")
- **Music-theory sort order** — Song Key search results and main list sorted by modifier priority: plain → minor → flat → flat minor → sharp → sharp minor (e.g. typing "B" shows B, Bm, Bb, Bbm in that order)
- **Copy buttons on BPM, Preview Start, Preview End** — Each field now has an inline copy-to-clipboard button matching the Locators/Time Signatures style; dimmed when the field is empty, shows a checkmark confirmation on click

### v0.2.1 — March 13, 2026
- **Toast pill notifications** — Submit status messages (Data Missing, Check Locators, Session Issues, COMING SOON) now appear as a pill-shaped toast at the bottom center of the window instead of under the MTID input. Red pill for errors, purple pill for COMING SOON. Fades in/out.
- **Copy All toggle** — New setting to show/hide "Copy All" buttons on Locators and Time Signatures panels (off by default)
- **Full light mode support** — All UI colors now adapt to the active theme; previously only the settings popover responded to light mode
- **System theme default** — Theme now defaults to system setting instead of dark on fresh installs
- **Stronger red highlights in light mode** — Red borders, backgrounds, and text are more vivid against the white theme
- **Song Key always highlighted** — Song Key field stays red-bordered until a key is selected, rather than only flashing on submit
- **Compact Copy All button** — Copy All button is now smaller with a fixed-height panel header, so toggling it on/off causes no layout shift
- **Fixed System theme** — System theme option now properly syncs with macOS appearance by setting NSApp.appearance, so switching between system light/dark is reflected immediately
- **Hover effects on all interactive elements** — Settings gear, theme/copy-all toggle pills, Log Out, Load Another File, Copy All, Submit, Song Data pickers, Song Data text fields, RehearsalMix checkbox, Locator/Time Signature rows, and Login Continue button all brighten or highlight on hover with pointing hand cursor
- **Custom popover pickers** — Song Key and Time Signature dropdowns replaced with custom popover lists matching the app's card style, with per-row hover highlighting, checkmark for selected value, auto-focused type-to-search filtering, and full keyboard navigation (arrow keys to browse, Enter to select and close while staying on current field, Tab to select and advance horizontally to next field, Escape to close)

### v0.2.0b — March 13, 2026
- **Fixed time signature parsing** — Regex now matches `<AutomationEnvelope>` tags with attributes (e.g. `Id="0"`), resolving empty Time Signatures panel
- **Login screen** — App prompts for First/Last name on first launch; name persisted across sessions
- **Settings gear** — Top-right gear icon with popover: theme toggle (Light/Dark/System) and Log Out
- **Theme support** — Light, Dark, and System theme options saved to UserDefaults
- **Lato font** — All UI text (except MTST header) now uses Lato font family
- **Contextual submit status** — Status messages under MTID pill show specific issues (Check Locators, Data Missing, Session Issues, or combinations)

### v0.2.0 — March 13, 2026
- **Song Data panel** — New section below Locators/Time Signatures for entering song metadata
- **Auto-populated fields** — Time Signature, BPM, Preview Start, and Preview End are automatically filled from the parsed .als data
- **BPM extraction** — Parser now extracts the initial tempo from the Ableton session
- **Session validation** — Loop bracket and audio clip alignment checks block submit on issues

### v0.1.5b — March 13, 2026
- **Fixed macOS Sonoma compatibility** — Replaced pyexpat dependency with lxml fallback for XML parsing, fixing "No module named expat" error on older macOS versions

### v0.1.5 — March 13, 2026
- **Fixed macOS Sonoma compatibility** — Bundled missing `pyexpat` module (did not fully resolve the issue — see v0.1.5b)

### v0.1.4 — March 12, 2026
- **Locator label validation** — Invalid labels highlighted in red
- **MTID input** — Added "Send to Song Shell (MTID)" placeholder
- **Load Another File** — Now immediately opens the file picker

### v0.1.3 — March 12, 2026
- **Copy button hover glow** — Copy icons highlight on hover
- **Unified font** — Timecodes match marker label font
- **Row numbers** — Index numbers for each locator and time signature

### v0.1.2 — March 12, 2026
- **Faster parsing** — Pre-warmed parser for near-instant results
- **Faster startup** — Directory-based bundling, no extraction delay
- **Versioned releases** — Version labels and release notes in installer

### v0.1.1 — March 12, 2026
- Rebuilt front-end in Swift/SwiftUI
- Transparent title bar with native traffic lights
- Bundled parser as standalone binary

### v0.1.0 — March 12, 2026
- Initial release — PySide6 (Python) UI
