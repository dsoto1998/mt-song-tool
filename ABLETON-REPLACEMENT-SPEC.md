# MT Song Tool — Ableton Replacement Feature Spec

**Purpose:** Define every feature needed so engineers can use the Edit tab exclusively — no Ableton required. Features must be at least as capable as Ableton for this workflow, and where possible should be functionally superior through automation and guardrails.

---

## Design Principles

- **Guardrails over freedom.** Anything that is always done the same way should be automated. Anything that can be done wrong should be blocked before export.
- **Automation over manual.** Loop bracket, GUIDE track, CLICK TRACK, and count-off assembly are fully deterministic from existing data — generate them, don't hand-craft them.
- **No distraction surface.** No effects, plugins, MIDI editing, automation lanes, or anything not relevant to this workflow.
- **Export is a gate, not a button.** Every blocking issue must be resolved before export runs.

---

## What's Already Built

| Feature | Status |
|---|---|
| Multi-stem AVAudioEngine playback | ✅ Built |
| Waveform display, zoom, scroll | ✅ Built |
| Clip cuts + auto-fades | ✅ Built |
| Clip drag/nudge + snap to beat/bar | ✅ Built |
| Clip trim (drag edges) | ✅ Built |
| Mute / Solo / Gain per stem | ✅ Built |
| Peak metering (per-stem + master) | ✅ Built |
| Metronome (synced to tempo map) | ✅ Built |
| Locator lane display | ✅ Built |
| Click track generator (partial — needs pattern verification) | ⚠️ Partial |
| Export Stems via FFmpeg (partial — needs full output scope) | ⚠️ Partial |
| Build Session / .als generator | ✅ Built |
| Tempo lane UI (interactive BPM automation) | ❌ Missing — needs build |
| `Marker.beat` field (locators lock to beats not wall-clock) | ❌ Missing — Marker struct has no beat field |
| `isGainLocked` for CLICK TRACK / GUIDE / ORIGINAL SONG | ❌ Missing — no lock property or UI |
| `additionalTempoEvents` on EditPlayerService | ⚠️ Partial — exists on BuildSessionStore only, needs moving to session layer |

---

## Session Model

The Edit tab operates as a **session** — all changes are held in memory until the engineer explicitly saves. No `.als` file is written during editing.

- **In-memory state:** `EditPlayerService` holds `locatorOverrides: [String: LocatorOverride]` (keyed by `als_id`) storing any name or beat-position changes made during the session. Other session state (stem offsets, cuts, gain) already lives there.
- **New locator IDs:** locators created in-session (before Save) use negative integer string keys (`"-1"`, `"-2"`, ...) in `locatorOverrides` — these never collide with real Ableton IDs (always non-negative). `save_session` assigns real IDs when writing the `.als`.
- **Dirty indicator:** toolbar shows unsaved-changes badge whenever session state diverges from the loaded `.als`
- **Save:** single `save_session` Python action, called only on explicit save. Builds a new `.als` from scratch (not a patch) containing: locators, tempo events, time sig events, loop bracket, and a single blank audio track matching the loop bracket duration. Clip-level audio edits (cuts, trims, stem offsets) are NOT written to the `.als` — those are baked into exported WAV files at Export time.
- **Save As:** `NSOpenPanel` to pick output path (new file or overwrite existing)
- **What the saved `.als` contains:**
  - All locators (with any name/position overrides applied)
  - Tempo automation (step changes only)
  - Time signature events
  - Loop bracket (start/end in beats)
  - One blank audio track whose clip length = loop bracket duration (strictly a placeholder — no real audio file required; if a file reference is needed by Ableton XML structure, write a silence WAV to the same folder as the `.als`)
  - Does NOT contain: references to the actual stem WAV files, clip edits, gains
- **Save action shape:**
  ```python
  {
    "action": "save_session",
    "source_path": "/path/to/original.als",  # template for XML structure
    "output_path": "/path/to/output.als",
    "locators": [
      {"als_id": "3", "name": "CHORUS", "beat": 128.0},
      ...
    ],
    "loop_start": 0.0,    # beats
    "loop_end":   512.0,  # beats
    "tempo_events": [
      {"beat": 0.0, "bpm": 120.0},
      {"beat": 64.0, "bpm": 125.0}
    ],
    "time_sig_events": [
      {"beat": 0.0, "numerator": 4, "denominator": 4},
      {"beat": 64.0, "numerator": 6, "denominator": 8}
    ]
  }
  ```
- **Clip edits are audio-only:** cuts, trims, stem offsets are baked into output WAVs at Export. The `.als` never knows about them.
- **No immediate file writes during an active session** — this applies to ALL tabs. While an Edit tab session is loaded and dirty, QA tab locator renames also route through `locatorOverrides` instead of writing to disk directly. The `.als` is never touched until explicit Save/Save As.
- Timeline always renders from in-memory override state, not raw parsed result
- **After Save:** `loadNewFile(savedPath)` runs automatically — QA tab re-parses. QA tab button flashes until engineer opens that tab.
- **After Save As:** app switches working file to the new path. Future Saves overwrite the new file.
- **Unsaved changes on quit / Clear All:** alert — "You have unsaved changes. Save before closing?"

#### Undo / Redo
- All session edits are undoable via Cmd+Z / Cmd+Shift+Z (standard `UndoManager`)
- Undoable actions: locator drag, locator rename (from Edit tab), tempo event add/move/delete, time sig event add/change/delete, stem drag/offset, clip cut, clip trim
- Undo stack clears on load of a new `.als`
- **Normalization** is registered as a single undo step — Cmd+Z reverts all affected stem gains simultaneously
- **Dirty state never auto-clears from undo** — `isSessionDirty` stays true until an explicit Save, even if all changes are undone back to original state

---

## Feature Specs

---

### 0. Edit Tab Lane Order (top to bottom)

```
Bar ruler
Locator lane
Time signature lane
Tempo lane
Track rows (CLICK TRACK → GUIDE → ORIGINAL SONG → alphabetical)
```

---

### 1. Locator Management

**Goal:** Engineers move locators as a core editing task. Today this is done in Ableton. Must be drag-based, bar-snapped, and foolproof.

#### Drag to Reposition
- Locators in the timeline lane are draggable horizontally
- Always snap to bar downbeats — cannot land mid-measure
- While dragging: show a vertical guide line through all tracks + a beat/bar tooltip
- On drop: updates `locatorOverrides` in memory; marks session dirty. No file write until Save.
- All locators including ENDING and NEXT SONG are draggable (NEXT SONG cannot be placed before the last non-NEXT-SONG locator)
- COUNT OFF: not draggable (always at beat 1)
- Locators can be **reordered** — dragging past another locator swaps their positions
- Right-click locator flag → context menu: **Rename**, **Delete**, **Add Locator Here**
- **Rename** opens the same approved section name picker (`PickerPopoverContent`) as the QA tab — no free-text entry ever
- Deleting COUNT OFF or NEXT SONG requires a confirmation dialog
- New locator from context menu: assigned a placeholder name, opens immediately into rename picker. Can be dismissed without naming — placeholder persists in session but **blocks Save** until all locators are named
- COUNT OFF: locked from rename. NEXT SONG: renameable via picker (in case of edge cases)
- Guide cue matching is always valid — locator names come from the approved list, which maps 1:1 to cue files

#### Locator Info
- Hovering a locator flag shows a small tooltip: section name, bar number, timestamp
- No separate panel needed — locator validation stays in the QA tab

---

### 2. Tempo & Time Signature Editing

**Goal:** Engineers set BPM automation and time signature changes directly in the Edit tab. No ramps, ever. Both lanes are interactive and save via the session model.

#### Tempo Lane (BPM Automation)

**Status:** Needs rebuild — previously implemented but may not be present in current build.

- Visual lane in the Edit tab timeline, above the track area (below the locator lane)
- Displays BPM as a staircase graph — horizontal line at current BPM, vertical step at each change point
- **Interaction:**
  - Drag breakpoint vertically → change BPM. Normal = 1 BPM snap. ⇧ = 0.01 BPM snap.
  - Drag breakpoint horizontally → reposition tempo event to a different beat. Always snaps to beats. Beat-0 event cannot be dragged horizontally.
  - Horizontal drag is **blocked** if it would pass another tempo event — events cannot cross each other
  - Click empty lane space → insert new tempo event at that beat (snapped to nearest beat when snap enabled)
  - × button on each non-beat-0 breakpoint → delete that event
  - Hint text at bottom of lane when idle: "click to add · drag to adjust · ⌫ removes"
- **Staircase enforcement (critical):** step changes are encoded as TWO `FloatEvent` entries at the same beat — `[beat, old_bpm]` then `[beat, new_bpm]`. A single entry creates a ramp in Ableton. The UI must enforce this by design — no ramp mode, no curve handles.
- **BPM format:** integers displayed as `%.0f`, fractional as `%.2f`. Max 2 decimal places.
- **Locators lock to beats** (not wall-clock time) — when BPM changes, locator positions recalculate from beat positions so they stay musically correct.
- **Session model:** tempo changes held in `buildStore.additionalTempoEvents` in memory. Written to `.als` via `save_session` `tempo_events` field on Save.

#### Time Signature Lane

**Status:** New feature — not yet in app.

- Visual lane in the Edit tab timeline, directly below the tempo lane
- Displays time sig changes as labeled flags at each change point (e.g. `4/4`, `6/8`)
- **Interaction:**
  - Click empty lane space → insert new time sig event at that bar boundary (snap to bar downbeat always). **Picker opens immediately** before placing — engineer selects numerator/denominator first, then event is placed. Default value pre-filled with prevailing time sig at that point.
  - Click existing flag → opens picker to change numerator / denominator
  - × button on each non-beat-0 flag → delete that change point
  - Beat 0 time sig is always present and cannot be deleted (only edited)
- **Valid values:** numerator 1–16, denominator 2 / 4 / 8 / 16
- **Effect on grid/ruler:** when a time sig change point is added or moved, the bar grid recalculates from that point forward. Locators remain locked to beats and slide with the grid.
- **Session model:** changes held in memory. Written to `.als` via `save_session` `time_sig_events` field on Save.

#### Pre-Save Validation
- Any tempo event sequence that would produce a ramp (two adjacent events at different beats with different BPM) is blocked — UI prevents creating ramps by design, but `save_session` must also validate and return an error if somehow a ramp is present.
- Time sig denominator must be a power of 2 (2, 4, 8, 16). Validated before save.

---

### 3. Loop Bracket

**Goal:** Always set correctly. Never a manual step.

#### Auto-Set Rule
- **Start:** Beat 1, bar 1 (always)
- **End:** Downbeat of the bar containing NEXT SONG minus 1 measure
  - Example: NEXT SONG at bar 33 → loop end = bar 32 downbeat
- Auto-calculated whenever a new `.als` is loaded or locators change in session
- **Always recalculated from NEXT SONG position on load** — saved loop bracket value in the `.als` XML is ignored
- Written to `.als` only on Save (via `save_session` — included in `loop_start`/`loop_end` fields)

#### UI Display
- Loop bracket start and end shown as readable timestamps + bar numbers in a small info strip above the timeline (e.g. `Loop: bar 1 (0:00.000) → bar 32 (3:14.250)`)
- Loop bracket rendered in the timeline ruler as a shaded region (like Ableton's bracket)
- Start/end handles visible but **not draggable** — bracket is always derived from NEXT SONG, not user-set

#### Export Constraint
- All exported stems are trimmed/padded to exactly the loop bracket duration
- Stems shorter than loop end → silence-padded to loop end
- Stems longer than loop end → hard-trimmed at loop end
- This is non-negotiable: loop bracket = stem length

---

### 4. Stem Editing

#### Clip Cuts (already built)
- Cmd+K cuts at region selection edges
- 10ms auto-fade applied on cut (configurable in settings)
- Cuts always snap to bar downbeats (not arbitrary beats)

#### Clip Trim (already built)
- Drag left/right edge of segment to trim in/out points

#### Drag/Nudge (already built)
- Top header bar of clip = drag zone
- Snap to beat/bar toggle in toolbar

#### Stem Deletion
- Right-click a stem row → "Remove from Session"
- Removes from timeline only; does not touch file on disk
- Confirmation dialog if stem is CLICK TRACK, GUIDE, or ORIGINAL SONG (protected stems)
- Undo supported (re-adds stem at previous position)

#### Alignment Checking
- Runs on demand via "Check Alignment" button in Edit tab toolbar
- **Session-aware:** checks stems as they currently exist in the session (with all offsets, cuts, trims applied) — not source files on disk
- **Implementation: Swift/Accelerate vDSP cross-correlation** — audio already in AVAudioEngine buffers with session edits applied; `vDSP_conv` performs the correlation. No Python, no temp files, no IPC. Runs entirely in memory.
- Compares each stem against ORIGINAL SONG using cross-correlation to find sample-level offset
- Works reliably on transient-heavy stems (drums, bass, guitar). Stems with no detectable correlation peak (pure pads, silence) show "Unable to determine — check manually."
- Reports per-stem offset in ms and samples (positive = late, negative = early), shown inline on each stem row: e.g. `+12.3ms (543 samples late)`
- "Auto-Correct" button per stem: applies needed shift to `StemState.offset`, registers with `UndoManager`
- "Auto-Correct All": corrects all determinable stems in one `UndoManager` step
- Zero-offset stems show nothing (clean)
- ORIGINAL SONG is the reference — not checked against itself

#### Time Stretch / Pitch Warp
- **Deferred.** Rare enough to not block Ableton replacement. Revisit if needed.

---

### 5. Stem Normalization

**Goal:** All exported stems hit consistent levels. Two separate operations triggered by one "Normalize Stems" button.

**Status:** Substantially built (`normalizeStems()` in `EditPlayerService.swift`, confirmed working 2026-04-11). Missing: gain lock UI for CLICK TRACK and GUIDE.

#### Operation 1 — Collective multitrack normalization (−0.01 dBFS)
- **Target:** all stems played simultaneously as a bus peak at −0.01 dBFS true peak
- **Stems included:** everything except CLICK TRACK, GUIDE, ORIGINAL SONG
- **Algorithm:** sum all included stems → scan true peak at 4× oversample → calculate single gain delta → apply identical gain to ALL included stems (preserves relative balance)
- **Result:** bus output peaks at −0.01 dBFS; individual stems may individually be quieter

#### Operation 2 — ORIGINAL SONG normalization (−6 dBFS)
- **Target:** ORIGINAL SONG played solo peaks at −6 dBFS
- **Algorithm:** scan ORIGINAL SONG raw file peak → apply gain to hit −6 dBFS
- **Independent of Operation 1** — ORIGINAL SONG is not in the collective mix

#### Fixed-level stems (CLICK TRACK, GUIDE)
- Volume is predetermined by the cue/click source files — must not be user-adjustable
- Gain slider replaced by lock icon + fixed dB label in `EditTrackSidebar`
- Excluded from both normalization operations
- Implemented via `isGainLocked` computed property (currently missing — see Phase 1f)

#### Non-destructive
- Normalization sets `StemState.gain` on each affected stem — same as manual gain adjustment
- Gain is baked into output WAVs on Export (not on button press)
- Can be re-run at any time; resets to the calculated value

#### UI
- "Normalize Stems" button in Edit tab toolbar
- Spinner replaces button while running (`isNormalizing`)
- No confirmation dialog — non-destructive (gain only, no file write)

---

### 6. Click Track Generation

**Goal:** Generate a CLICK TRACK stem that is byte-for-byte identical in character to the manually-created Ableton version.

#### Pattern Rules
- **4/4 pattern** used for: 4/4, 2/4, 3/4, 2/2, and all other time signatures not listed below
- **6/8 pattern** used for: 6/8, 9/8, 12/8

#### Source Files
- Click samples: `CLASSIC-4TH'S.aif` (downbeat accent) and `CLASSIC-8TH'S.aif` (subdivision)
- Exact beat placement defined by MIDI files:
  - `mt-click-guide/CLICK TRACKS/4-4 click midi.mid`
  - `mt-click-guide/CLICK TRACKS/6-8 click midi.mid`
- Reference level: `mt-click-guide/CLICK TRACKS/CLICK EXAMPLE.wav`
- Implementation must parse the MIDI files to extract note timings + velocities; do not hardcode the pattern

#### Generation
- Synthesized per-song from the tempo map (already parsed from `.als`)
- Output: single WAV file, 44.1kHz / 16-bit, duration = loop bracket length
- **Always live, never stale** — synthesized in real-time from tempo map + time sig, same as metronome
- Recalculates every frame as tempo/time sig changes — instant, no lag
- Lane is **not manually editable** — always reflects the computed pattern
- **Lane visualization:** tick marks at each click sound position (not a waveform). Accent tick (downbeat) visually distinct from subdivision ticks. Matches actual click placements exactly.
- **On Export:** synthesized and printed to `CLICK TRACK.wav` (44.1kHz / 16-bit)

#### Verification
- First implementation must be spot-checked against the reference MIDI files by playing back both simultaneously and confirming phase lock

---

### 7. Guide Track Generation

**Goal:** Auto-generate the GUIDE track from locators + cue audio files. Engineers currently do this manually in Ableton. Should be one-click.

#### Cue Library Location
- Base: `mt-click-guide/GUIDE CUES/{Language} Cues/`
- Song section cues: `Song Sections/{Language} Female - {Section Title Case}.wav`
  - Numbered variants: `{Section} 1.wav` through `{Section} 8.wav`
  - Locator name → file mapping: `VERSE 1` → `Verse 1`, `PRE-CHORUS` → `Pre Chorus`, `POST-CHORUS` → `Post Chorus` (hyphen stripped, title-cased)
- Dynamic cues: `Dynamic Cues/{Language} Female - {Cue Name}.wav`
- Count-off numbers: `Song Sections/{Language} Female - 1.wav` through `7.wav`

#### Language Support
- Language picker in Guide generation UI (default: English)
- Generates one GUIDE WAV per selected language
- All languages in the cue library are supported

#### Section Cue Placement
- Each locator (except COUNT OFF and NEXT SONG) gets a section name cue
- Cue placed at: **downbeat of the bar immediately before the locator**
  - Example: VERSE starts bar 5 → section cue placed at bar 4 downbeat
- If bar before is bar 1 (no room), cue is omitted

#### Dynamic Cue Placement
- Dynamic cues placed at the **midpoint of a measure** (beat 3 in 4/4, beat 4 in 6/8, etc.)
- **Exception: KEY CHANGE UP / KEY CHANGE DOWN** — placed on beat 1 of the measure before the key change. If that conflicts with a section cue, shifts 1 measure earlier (same collision rule as other dynamic cues)
- **Collision rule:** if a dynamic cue would land in the same bar as a section cue, the dynamic cue shifts 1 bar earlier (2 bars before the section)
- Dynamic cue assignment is manual (engineer selects which dynamic cues to add and at which sections) — UI TBD but likely a panel listing each section with a dynamic cue picker

#### Count-Off Assembly (COUNT OFF section)
- Count-off fills the COUNT OFF section bars (2 bars)
- Pattern per time signature, derived from reference `.als` projects:

| Time Sig | Bars | Pattern | Files Used |
|---|---|---|---|
| 4/4 | 2 | `1... 2... [silence silence] \| 1, 2, 3, 4` | 1–4 + Intro |
| 3/4 | 2 | `1... 2... [silence] \| 1, 2, 3` | 1–3 |
| 6/8 | 2 | see reference `.als` | 1–6 + Intro |
| 12/8 | 2 | see reference `.als` | 1–4 + Intro |

- Exact beat-level timing for each number clip extracted from the reference `.als` files at implementation time (do not hardcode — parse the Ableton projects)

#### Output
- Single stereo WAV, 44.1kHz / 16-bit, duration = loop bracket length
- Silence where no cue is placed
- Named `GUIDE.wav` regardless of language
- One language at a time — language picker in Guide generation UI (default: English). Regenerating with a different language replaces the existing GUIDE lane.
- Appears as a timeline lane in the Edit tab after generation
- **Always live, never stale** — recalculates every frame as locators or tempo change. Instant, no lag.
- **On Export:** rendered and printed to `GUIDE.wav` (44.1kHz / 16-bit)
- **Lane visualization:** colored labeled blocks — each cue shown as a colored rectangle with the cue name. No audio waveform.
- **Cue colors:** grouped by section family — all VERSE variants share a hue, all CHORUS variants share a hue, all BRIDGE variants share a hue, etc. Dynamic cues use a distinct color separate from section families. Exact palette TBD at implementation.
- **GUIDE lane is manually editable:** individual cues can be moved (snap to beat positions), added (right-click empty lane → "Add Dynamic Cue" → picker), or deleted (right-click cue → "Delete"). All edits register with `UndoManager`.
- **Manual override lifecycle:** a manually-moved cue stores an absolute beat position. When its parent locator moves, the auto-position recalculates and the manual override is discarded. **Undo of the locator move also restores the manual override** — each locator-move undo step snapshots the full GUIDE override state.
- **Language:** one language at a time. Language picker in Edit tab toolbar. Changing language re-generates all section and count-off cues; manual cue positions are discarded (confirmation prompt).

---

### 8. Build Session

**Goal:** Create a new `.als` session from scratch when no existing session is available. Distinct from Save Session (which saves in-memory edits to an existing session).

**Status:** Previously implemented (`_generate_als()` in `parse_als.py`, `ALSGeneratorService.swift`, Build Session panel in `EditView.swift`) but no longer present in current build — needs to be re-added.

**Use case:** engineer has stems but no `.als`. Build Session generates a valid `.als` with correct locators, tempo, time sigs, and loop bracket so the Edit tab session can begin.

**Inputs:**
- BPM (single value or tempo map with multiple events)
- Time signature (single value or multiple events)
- Locator list (names + bar positions, from approved section name list)
- Session duration / loop bracket end

**Output:** new `.als` file written to a user-selected path. After creation, the app loads it via `loadNewFile()` and enters the normal Edit tab session.

**Unsaved changes guard:** if an Edit tab session is active and dirty when Build Session is triggered, prompt "You have unsaved changes. Save before creating a new session?" before proceeding.

**Relationship to Save Session:** Build Session creates the initial `.als`; Save Session updates it. They use the same Python `save_session` action shape — Build Session simply has no `source_path` template (builds from a blank template instead).

---

### 9. Export

**Goal:** One action that produces a complete, validated stem folder ready for publishing.

**Export is independent from Save.** Unsaved `.als` session changes do not block or trigger Export. Export operates on in-memory session state (gains, cuts, trims, stem offsets) — it does not require a Save first and does not write the `.als`.

#### What Gets Exported
- All stems currently in the session (including CLICK TRACK, GUIDE, ORIGINAL SONG)
- If multiple GUIDE languages generated: one file per language, all included
- All files: 44.1kHz / 16-bit WAV
- All files trimmed/padded to exactly the loop bracket duration (hard rule — see Loop Bracket section)

#### Output Folder
- Engineer selects output folder via system open panel (`NSOpenPanel`)
- Panel shows "New Folder" button (standard macOS behavior)
- Default suggested location: sibling of the current stems folder
- Output files written flat into selected folder (no subfolders)
- **Filename:** each stem exported as `{APPROVED_STEM_NAME}.wav` — taken from the lane name (which is always from the approved stem name list), not the source WAV filename
- **Stem lane renaming** is an existing Edit tab feature — lane name changes affect the export filename and register with `UndoManager`
- **Output contains WAV stems only** — no `.als` file in the export folder. Engineer saves the `.als` separately via Save/Save As.
- **Per-stem operation order:** cuts/trims/offsets applied first → gain baked → loop bracket trim/pad applied last

#### Pre-Export Validation (blocking)
All of the following must pass before export runs:

| Check | Error Message |
|---|---|
| All locators valid (no red in QA tab) | "Fix invalid locators before export" |
| Loop bracket set (NEXT SONG locator exists) | "Add NEXT SONG locator to set loop bracket" |
| No muted stems | "Unmute all stems before export" |
| No soloed stems | "Unsolo all stems before export" |
| Any stem ends more than 500ms before loop bracket end (potential missing content) | Warning only — does not block export. "One or more stems may be missing content." |
| CLICK TRACK present | "Generate CLICK TRACK before export" |
| GUIDE track present (at least one language) | "Generate GUIDE track before export" |

If any blocking check fails, export is blocked and each failure is listed in a pre-export sheet. Warnings are shown but do not block.

**Note:** The 5-sample stem length tolerance check belongs in the QA tab (for sessions manually created in Ableton). Export pads/trims all stems to loop bracket duration automatically, so exact pre-export length matching is not required here.

#### Post-Export
- Success sheet: lists all exported files + output folder path with a "Show in Finder" button
- Original stems folder is NOT renamed or modified (non-destructive — unlike gain bake-out)

---

## Implementation Priority

### Phase 1 — Core editing parity with Ableton
1. Locator drag-to-reposition (bar-snapped)
2. Loop bracket auto-set + display
3. Stem deletion from session
4. Build Session re-add (previously removed from codebase)

### Phase 2 — Guardrails and alignment
4. Pre-export validation gate
5. Alignment checking + auto-correct

### Phase 3 — Automation that replaces manual Ableton work
6. Click track pattern verification + MIDI-derived generation
7. Guide track auto-generation (section cues + count-off)
8. Export with output folder picker + loop-bracket trim/pad

### Phase 4 — Guide track dynamic cues
9. Dynamic cue placement UI + anti-collision logic
10. Multi-language GUIDE generation

---

## Open Questions

- ~~**Key Change Up/Down cue placement:**~~ Resolved: beat 1 of measure before key change; shift 1 more measure if conflicts with section cue.
- ~~**GUIDE track in QA tab vs Edit tab:**~~ Resolved: Edit tab only. QA tab is for confirmation/simple tweaks, not creation.
- ~~**Alignment checking method:**~~ Resolved: Swift/Accelerate vDSP, session-aware, fully in-memory. No Python involvement.
