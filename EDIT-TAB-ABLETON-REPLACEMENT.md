# Edit Tab — Ableton Replacement Implementation Plan

**Full spec:** `ABLETON-REPLACEMENT-SPEC.md` (read this first for all rules and rationale)  
**Status:** Phase 1 complete — Phase 2 next

---

## Phase Order

| Phase | Goal | Status |
|---|---|---|
| 1 | Core editing parity (locator drag, loop bracket, stem deletion, tempo lane, time sig lane, gain lock) | ✅ Complete |
| 2 | Guardrails + alignment (pre-export validation gate, alignment check/auto-correct) | 🔲 Not started |
| 3 | Automation (click track MIDI-derived, guide track, export) | 🔲 Not started |
| 4 | Dynamic cues (placement UI, anti-collision, multi-language) | 🔲 Not started |

---

## Session Model (agreed architecture)

Edit tab is a **session** — no file writes during editing. All changes held in memory, flushed on explicit Save/Save As.

- `EditPlayerService` gains `locatorOverrides: [String: LocatorOverride]` (keyed by `als_id`)
- `LocatorOverride`: struct with optional `name: String?` and `beat: Double?`
- Session dirty state: `@Published var isSessionDirty: Bool` — set true on any override change
- Timeline renders from overrides (merged over parsed result), never directly from raw parse
- **`save_session` Python action** (new) — called only on Save. Builds a new `.als` from scratch (not a patch). Output `.als` contains: locators, tempo events, time sig events, loop bracket, one blank audio track of loop bracket duration. Does NOT contain stem clip references or audio edits.
  - Uses source `.als` as structural template (XML boilerplate, version info)
  - Clip-level edits (cuts, trims, offsets) are audio-only — baked via FFmpeg at Export, never written to `.als`
  - Writes to `output_path` (same as source = overwrite; different = Save As)
- **`performCommit` removed** — Export replaces it entirely as the single bake-out action
- **Undo/Redo:** all session edits register with `UndoManager`. Undoable: locator drag/rename, tempo add/move/delete, time sig add/change/delete, stem drag, clip cut, clip trim. Stack clears on new `.als` load.
- Save UI: "Save" button (overwrite) + "Save As" (NSOpenPanel) in Edit tab toolbar
- Dirty indicator: subtle dot or asterisk on Save button when `isSessionDirty`
- **After Save:** `loadNewFile(savedPath)` auto-runs. QA tab button flashes until engineer opens QA tab (clears on tab open). `isSessionDirty = false`.
- **After Save As:** app switches working `.als` to new path. Future Saves overwrite new file.
- **Unsaved changes on quit / Clear All:** alert — "You have unsaved changes. Save before closing?"

---

## Phase 1 — Core Editing Parity

### 1a. Locator Drag-to-Reposition

**Goal:** Drag locator flags in the timeline lane to reposition sections. Always snaps to bar downbeats.

**Rules:**
- Snap to bar downbeats only — no mid-measure landing
- While dragging: vertical guide line through all tracks + bar/timestamp tooltip
- On drop: write beat position to `locatorOverrides[als_id]`, set `isSessionDirty = true`. No Python call, no re-parse.
- All locators including ENDING draggable. NEXT SONG cannot move before last non-NEXT-SONG locator.
- COUNT OFF: not draggable (always beat 1)
- Locators can be reordered — drag past another locator to swap
- Right-click context menu: Rename, Delete, Add Locator Here
- Delete COUNT OFF / NEXT SONG: confirmation dialog required
- New locator: assigned placeholder name, rename picker opens immediately. Can be dismissed without naming — placeholder persists but **blocks Save** until all locators are named.
- COUNT OFF: locked from rename. NEXT SONG: renameable via picker.
- Rename always uses approved section name picker (`PickerPopoverContent`) — no free text
- Loop bracket auto-recalculates after any locator move (see 1b)
- All locator mutations register with `UndoManager`

**Key files:**
- `EditView.swift` — `WaveformScrollHost`, locator lane CALayer (`locatorLaneLayer`), drag gesture
- `parse_als.py` — `save_session` new action handles all locator changes on Save
- `ParserService.swift` — `Marker` struct needs `beat: Double?` field added

**Implementation notes:**
- **`Marker.beat` field is missing** — must be added to `Marker` struct in `ParserService.swift` and populated in `parse_als.py` before drag-to-reposition can use beat positions. Without it, pixel→beat→bar snap has no beat anchor for each locator.
- Locator lane is currently a CALayer displaying flags (read-only). Need to add drag hit-testing on flag regions.
- `WaveformScrollHost` already has mouse event handling for clip drags — locator drag follows same pattern but operates on the locator lane strip (top 20px of the ruler area).
- Beat-to-pixel and pixel-to-beat conversion already exist in `WaveformScrollHost` (used for grid/ruler).
- Bar snap: use existing `snapToBar()` helper — convert drag pixel position to seconds, then snap to nearest bar downbeat using `beatSchedule`.
- No Python call on drop. Python only involved at Save via `save_session` action (see Session Model above).
- `save_session` handles both renames and repositions in one pass — no need to extend `_fix_locators` or add a separate `move_locator` action.

---

### 1b. Loop Bracket Auto-Set + Display

**Goal:** Loop bracket always = bar 1 → 1 bar before NEXT SONG. Auto-calculated. Displayed in UI. Written to `.als`.

**Rules:**
- Start: beat 1, bar 1 (always)
- End: NEXT SONG bar − 1 measure (e.g. NEXT SONG at bar 33 → loop end at bar 32 downbeat)
- Auto-set whenever `.als` loaded or locators change
- Written back to `.als` (update `<LoopStart>` and `<LoopEnd>` in XML)
- Display: small info strip above timeline — `Loop: bar 1 (0:00.000) → bar 32 (3:14.250)`
- Timeline ruler shows shaded loop region
- Handles visible but NOT draggable

**Key files:**
- `parse_als.py` — new action `set_loop_bracket` that writes `<LoopStart>` / `<LoopEnd>` to the `.als` XML
- `ParserService.swift` — expose loop bracket start/end seconds from parse result (already parsed? check `ParsedResult`)
- `EditView.swift` — info strip UI + loop bracket shading in ruler CALayer
- `WaveformScrollHost` — add loop bracket overlay to ruler layer

**Implementation notes:**
- `ParsedResult` likely already contains loop bracket data from parse — verify in `parse_als.py` output.
- Loop end in beats: find NEXT SONG locator beat position, subtract `beatsPerMeasure` for that bar's time sig.
- `<LoopStart>` and `<LoopEnd>` in Ableton `.als` XML are in beats (not seconds). Use tempo map to convert.
- The loop bracket end also defines the export duration — this value must be accessible to the export pipeline.

---

### 1d. Tempo Lane (BPM Automation) — Rebuild

**Status:** Previously implemented but may not be present in current build. Verify first.

**Rules:**
- Staircase only — two FloatEvents at same beat per step change. No ramps.
- Drag vertically = change BPM (1 BPM snap normal, 0.01 BPM with ⇧)
- Drag horizontally = reposition to different beat (snaps to beats, blocked from passing other events, beat-0 immovable)
- Click empty space = add event (snapped to beat)
- × = delete (non-beat-0 only)
- CLICK TRACK lane synthesizes in real-time every frame — always live, never stale
- Lane visualization: tick marks at click positions, accent vs subdivision visually distinct

**Key files:**
- `EditView.swift` — tempo lane CALayer / canvas
- `EditPlayerService.swift` — `buildStore.additionalTempoEvents`, `TempoEvent` struct
- `parse_als.py` — `tempo_events` in parse response

**Session model:** `buildStore.additionalTempoEvents` is the in-memory store. `save_session` `tempo_events` field flushes on Save.

---

### 1e. Time Signature Lane — New

**Status:** Not in app. New feature.

**Rules:**
- Always snaps to bar boundary (time sigs can only change on a downbeat)
- Click empty space → picker opens first (default = prevailing time sig at that point) → place on confirm
- Click existing flag → picker opens to change value
- × = delete (beat-0 not deletable)
- Valid: numerator 1–16, denominator 2/4/8/16
- Bar grid recalculates forward from each change point
- Locators stay beat-locked through grid changes

**Key files:**
- `EditView.swift` — new time sig lane (similar pattern to tempo lane)
- `EditPlayerService.swift` — new `timeSigOverrides: [(beat: Double, numerator: Int, denominator: Int)]`
- `parse_als.py` — time sig events already parsed; `save_session` needs `time_sig_events` write support

**Session model:** held in `timeSigOverrides` in memory. Written via `save_session` `time_sig_events` on Save.

---

### 1g. Build Session — Re-add (previously removed from codebase)

**Status:** Was implemented (`_generate_als()`, `ALSGeneratorService.swift`, Build Session panel in `EditView.swift`) but no longer in current code. Needs to be re-added.

**Goal:** Create a new `.als` from scratch when engineer has stems but no existing session.

**Key files to recover/rebuild:**
- `parse_als.py` — `_generate_als()` function
- `ALSGeneratorService.swift` — Swift wrapper
- `EditView.swift` — Build Session panel UI

**Relationship to `save_session`:** same action shape, but `source_path` is a blank template (no existing .als). After creation, `loadNewFile()` loads it into the Edit tab session.

---

### 1f. Gain Lock for Protected Stems — Missing, Needs Build

**Status:** Not in app. Audit confirmed `isGainLocked` property and lock UI are absent.

**Rules:**
- CLICK TRACK, GUIDE, ORIGINAL SONG: gain slider replaced with lock icon + "0.0 dB" label
- `isGainLocked` computed from `stemName.uppercased()` — same names as click/guide/original song detection elsewhere
- No session state needed — purely UI enforcement

**Key files:**
- `EditView.swift` — `EditTrackSidebar`, gain slider section

---

### 1c. Stem Deletion from Session

**Goal:** Remove a stem from the Edit tab timeline without touching disk.

**Rules:**
- Right-click stem row → "Remove from Session"
- Confirmation dialog if stem is CLICK TRACK, GUIDE, or ORIGINAL SONG
- Disk file is NOT deleted or renamed
- Undo: re-add stem at previous position (standard undo stack or simple re-load)
- After removal: `sortedStemURLs` updates, timeline re-renders

**Key files:**
- `EditView.swift` — right-click context menu on `EditTrackSidebar`
- `EditPlayerService.swift` — `removeStem(url:)` method; tears down AVAudioPlayerNode + mixer node for that stem

**Implementation notes:**
- `EditPlayerService.stemStates` is the source of truth for which stems are loaded. Removing a stem = remove from `stemStates` dict + detach its audio nodes from the engine.
- Protected stems (CLICK TRACK, GUIDE, ORIGINAL SONG): check `stemName.uppercased()` same as `isGainLocked`.
- Undo: simplest approach is keep a `removedStems: [(URL, StemState)]` stack; "Undo Remove" re-adds via `loadStem(url:)`.
- No `.als` rewrite needed — stem deletion is a session-only edit (stems folder on disk unchanged).

---

## Phase 2 — Guardrails + Alignment

### 2a. Pre-Export Validation Gate

All checks must pass before export runs. Show failure list in a sheet.

| Check | Blocks export |
|---|---|
| All locators valid (no red) | Yes |
| NEXT SONG locator exists (loop bracket set) | Yes |
| No muted stems | Yes |
| No soloed stems | Yes |
| CLICK TRACK present in session | Yes |
| GUIDE track present | Yes |
| Any stem ends >500ms before loop bracket end | Warning only (does not block) |

### 2b. Alignment Check + Auto-Correct

- "Check Alignment" button in Edit tab toolbar
- **Swift/Accelerate vDSP cross-correlation** — fully in-memory, session-aware (uses AVAudioEngine buffers with all session edits applied)
- Compares each stem against ORIGINAL SONG. Reliable for transient-heavy stems; shows "Unable to determine" for soft pads/silence.
- Report per stem: `+12.3ms (543 samples late)` inline on stem row
- "Auto-Correct" button per stem + "Auto-Correct All" — both register with `UndoManager`
- ORIGINAL SONG not checked against itself

---

## Phase 3 — Automation

### 3a. Click Track (MIDI-Derived)

- Parse `4-4 click midi.mid` and `6-8 click midi.mid` for note timings + velocities
- 4/4 pattern: all time sigs except 6/8, 9/8, 12/8
- 6/8 pattern: 6/8, 9/8, 12/8
- Samples: `CLASSIC-4TH'S.aif` (accent/downbeat), `CLASSIC-8TH'S.aif` (subdivision)
- Reference level: `CLICK EXAMPLE.wav`
- Output: 44.1kHz / 16-bit WAV, duration = loop bracket length

### 3b. Guide Track Auto-Generation

- **Always live** — recalculates every frame as locators/tempo change. Same architecture as CLICK TRACK.
- Section cues: placed at downbeat of bar before each locator (except COUNT OFF, NEXT SONG)
- Count-off: 2 bars, pattern per time sig — extract beat timing from reference `.als` projects at implementation time
- **One language at a time.** Language picker in toolbar (default English). Change language → confirmation → regenerate.
- Cue library: `mt-click-guide/GUIDE CUES/{Language} Cues/`
- Section name → filename: `VERSE 1` → `Verse 1`, `PRE-CHORUS` → `Pre Chorus`
- Lane: colored labeled blocks per cue. Section cues colored by section family. Dynamic cues distinct color.
- Manual edits (move/add/delete) stored as overrides. Locator move discards moved-cue override; undo of locator move restores it.
- **On Export:** printed to `GUIDE.wav` (44.1kHz / 16-bit)

### 3c. Export

- Output folder: `NSOpenPanel` with "New Folder" support
- Exports all session stems (including CLICK, GUIDE, ORIGINAL SONG)
- All stems trimmed/padded to exact loop bracket duration
- Format: 44.1kHz / 16-bit WAV
- Post-export: success sheet + "Show in Finder"
- Original stems folder: untouched

---

## Phase 4 — Dynamic Cues

- Right-click GUIDE lane → "Add Dynamic Cue" → picker from dynamic cue list
- Placement: midpoint of measure (snaps to beat)
- KEY CHANGE UP/DOWN: beat 1 of measure before key change
- Collision rule: dynamic cue in same bar as section cue → shift 1 bar earlier
- All dynamic cue edits register with `UndoManager`

---

## Key Reference Paths

```
Spec:           ABLETON-REPLACEMENT-SPEC.md
Click MIDI:     mt-click-guide/CLICK TRACKS/4-4 click midi.mid
                mt-click-guide/CLICK TRACKS/6-8 click midi.mid
Click samples:  mt-click-guide/CLICK TRACKS/Samples/Imported/CLASSIC-4TH'S.aif
                mt-click-guide/CLICK TRACKS/Samples/Imported/CLASSIC-8TH'S.aif
Click ref:      mt-click-guide/CLICK TRACKS/CLICK EXAMPLE.wav
Guide cues:     mt-click-guide/GUIDE CUES/
Count-off ref:  mt-click-guide/COUNT OFF EXAMPLES/English/
Swift sources:  mtst-master/swift-app/Sources/MTSongTool/
Parser:         mtst-master/parse_als.py
```

---

## Start Here Next Session

**Read first:** `ABLETON-REPLACEMENT-SPEC.md` + this file + memory index. The spec is the authority — this file is the implementation breakdown.

**First task:** Phase 2a — pre-export validation gate. Before writing any code, read `EditView.swift` and `EditPlayerService.swift`.

**Key architectural decisions already made (do not re-discuss):**
- Session model: no file writes during editing. All changes in memory. `save_session` Python action on Save/Save As. QA tab renames also route through session while Edit tab session is active.
- `save_session` builds `.als` from scratch (not a patch). Contains: locators, tempo, time sigs, loop bracket, one blank audio track. No stem clip references.
- New locators get negative integer temp IDs (`"-1"`, `"-2"`) until `save_session` assigns real IDs.
- Alignment check: Swift/vDSP cross-correlation, session-aware, fully in-memory. No Python.
- CLICK TRACK + GUIDE: synthesized in real-time every frame. Printed to WAV on Export only.
- Export and Save are independent. Export outputs WAV stems only (no `.als`).
- Export order per stem: cuts/trims/offsets → gain → loop bracket trim/pad.
- `performCommit` removed — Export replaces it.
- Dirty state never auto-clears from undo — only clears on explicit Save.
- Loop bracket always recalculated from NEXT SONG on load — saved value in `.als` ignored.
- After Save: use `reparseAfterSave()` not `loadNewFile()` — skips `audioAnalyzer.reset()` so Edit stems survive.

**Phase 1 items — ALL COMPLETE (2026-05-08):**
1a. ✅ Locator drag-to-reposition — DONE 2026-04-18
1b. ✅ Loop bracket auto-set + display — DONE 2026-04-18
1c. ✅ Stem deletion from session — DONE 2026-05-07
1d. ✅ Tempo lane rebuild — DONE
1e. ✅ Time signature lane (new) — DONE 2026-05-07
1f. ✅ Gain lock for CLICK TRACK / GUIDE / ORIGINAL SONG — already implemented (isLockedStem passed at call site)
1g. ✅ Build Session re-add — DONE 2026-05-08
+ ✅ Save / Save As UI — DONE
+ ✅ Dirty indicator — dot badge overlay on Save button (7px accent circle, top-right, spring animation)
+ ✅ Post-save QA tab flash — accent dot on QA button, clears on tab visit
+ ✅ Unsaved-changes guard — Clear All + Cmd+Q both prompt Save/Discard/Cancel

**What was built in the 2026-04-18 session:**
- `Marker.beat: Double?` — Ableton beat position, populated from Python `locator_data[i][1]`
- `BeatInfo.absoluteBeat: Double` — cumulative beat in beatSchedule
- `LocatorOverride` struct + `locatorOverrides/isSessionDirty` in `EditPlayerService`
- `EditLocatorLane` drag: bar-snap, accent highlight, guide line, override rendering
- `loopBracket` computed property in `EditView` + loop info strip above timeline
- Parser note: `parse_als.py` outputs `"beat"` in markers but binary not rebuilt yet — Swift uses time-string fallback
