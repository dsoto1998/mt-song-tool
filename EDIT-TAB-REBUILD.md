# Edit Tab Rebuild — Phase Plan

Work lost in an uncommitted session. All foundational architecture is intact (CALayer rendering, segment model, region selection, metronome, grid, services). What's missing is UI wiring and the Build Session panel.

---

## Phase 1 — Clip Trim + Multi-Clip Select
**Effort:** Medium | **Value:** High

Basic editing ergonomics. Needed before the Build Session panel is useful.

### Clip Trim Handles
- Add `trimSegmentLeft(id:delta:)` + `trimSegmentRight(id:delta:)` to `EditPlayerService`
- 6px grip strip rendered at each segment edge in `EditWaveformCanvas` (via CALayer)
- 8px hit zone — `resizeLeftRight` cursor on hover
- Trim drag takes priority over name-bar move at first-frame detection
- Left edge: moves `sessionStart` + `sourceStart` by delta (clamp `sourceStart ≥ 0`)
- Right edge: moves `sourceEnd` (clamp to `state.duration`)

### Multi-Clip Selection (Cmd+click)
- `@State private var selectedClipIDs: Set<UUID>` in `EditView` (separate from `selectedURLs`)
- Click clip → seek + select only that clip; Cmd+click → seek + additive toggle
- Click empty canvas space → seek + clear all clip selections
- Selected clips: 25% accent fill tint + solid accent outline (2px) via CALayer in `updateNSView`
- `selectedClipIDs` cleared on `onChange(of: stemURLs)` and when `onSetStemSelection` receives nil
- Multi-trim: drag edge of selected clip → same delta to all `selectedClipIDs`

### WaveformScrollHost params added
- `selectedClipIDs`, `onSelectClip`, `onTrimLeftEdge`, `onTrimRightEdge`
- `contentVersion` hash includes `selectedClipIDs`

### EditWaveformCanvas additions
- `TrimEdge` enum (`.left`, `.right`) — file-level private
- `findTrimEdge(at:totalWidth:)` helper — 8px hit zone per segment edge
- `trimEdge` / `trimLastX` / `trimSegmentID` drag state

### Remaining gap
- **Multi-stem region drag** — clicking and dragging a selection band across multiple stems simultaneously is not yet wired. Currently Option+drag selects one track at a time; there is no cross-track swipe gesture.

---

## Phase 1.5 — Multi-Stem Region Drag
**Effort:** Small | **Value:** High

A single drag gesture that paints a region selection across all visible stems simultaneously — the primary way users mark a range for delete/move.

### Behavior
- Plain drag anywhere in the waveform area (not in name bar, not near a trim edge) → sets the same `Range<Double>` on all stems
- Replaces the current Option+drag (single-track) as the default selection gesture
- Option+drag on a specific track still works for single-track selection (additive)
- Click on empty canvas (no drag) → clears all selections

### Implementation
- Add a `DragGesture` overlay on `WaveformScrollHost` itself (outside `NSHostingView`, over the full waveform column) — captures drag before individual `EditWaveformCanvas` gestures when not in name bar or near trim edge
- On drag: compute time range from x-position, call `onSelectionChange(lo..<hi)` which already applies the range to all stems via the existing handler in `EditView`
- On tap (zero-distance): call `onSelectionChange(nil)` to clear

### Notes
- Must not interfere with clip move (name bar zone) or trim (edge zone) — check `WaveformScrollHost` hit test before firing
- `GlobalSelectionBar` at bottom already does full-canvas range selection; this mirrors it but in the track area itself

---

## Phase 2 — Click Track Preview Lane
**Effort:** Medium | **Value:** Medium

`ClickTrackService` is fully implemented. This phase wires it into the Edit tab UI.

### Toolbar feedback
- `ClickTrackService` as `@StateObject` in `EditView`
- Spinner + "Click Track…" while generating
- "✓ Click Track" checkmark when ready
- "Retry Click" button on failure

### Auto-generation triggers
- `onChange(of: stemURLs)` → `scheduleClickPreviewRegen()`
- `onChange(of: clickPreviewKey)` (BPM + time sig hash) → regen
- `.task` on appear if no preview yet

### Timeline integration
- Click track preview shown as a stem lane in the timeline (same row style as other stems)
- `clickTrackDurationSeconds` derived from ENDING locator or loop end
- Preview file URL passed into `editPlayer.loadStems` alongside real stems when available

---

## Phase 3 — Build Session Panel
**Effort:** Large | **Value:** High (core workflow)

The panel that generates a new `.als` from stems + user-defined session structure.

### State
```swift
@StateObject private var buildStore = BuildSessionStore()
```
`BuildSessionStore` holds: `bpm: String`, `timeSig: String`, `loopEndBeat: Double`, `locators: [BuildLocator]`, `additionalTempoEvents: [TempoEvent]`, `outputFolder: URL?`

### Population on load
- `.onChange(of: parsedResult?.file)` → `buildStore.reset()` → `populateBuildSession()`
- `populateBuildSession()`: BPM from `parsedResult?.bpm`, time sig from first time sig, seed locators from markers (skip NEXT SONG)
- Tempo map NOT auto-seeded into `additionalTempoEvents` (use parsed map for positioning only)

### Panel UI (collapsible, bottom of Edit tab)
- BPM text field (numeric only, onChange strips non-digit/period)
- Time sig picker
- Loop end beat field
- Editable locator list (add/delete rows)
- Output folder picker
- Build button (disabled when `!canBuild`)
- Build issues list (errors block, warnings don't)

### Validation (`buildIssues`)
- **Error (blocks):** missing COUNT OFF, missing ENDING — only when `parsedResult == nil`
- **Warning (non-blocking):** stem lengths differ by > 10ms; loop end < 2 bars after ENDING
- **canBuild:** `buildIssues.filter { $0.isError }.isEmpty && bpm > 0 && outputFolder != nil`

### `runBuildSession()`
- Calls `ALSGeneratorService.build()`
- Auto-injects NEXT SONG locator at `loopEndBeat + beatsPerMeasure` (not user-editable)
- `beatsPerMeasure` = `numerator * 4.0 / denominator`

### Locator lane in Build mode
- `Color.bgCard.opacity(0.6)` background always visible
- Hint text "right-click to add section" when both `parsedResult?.markers` and `buildStore.locators` are empty

---

## Phase 4 — Locator Delete + Build Locator Drag
**Effort:** Medium | **Value:** Medium

### Locator delete (existing ALS markers)
- `EditLocatorChip` gains `onDelete: (() -> Void)?` parameter
- Context menu: "Delete Locator" → chain through `EditLocatorLane` → `WaveformScrollHost` → `EditView` → `parser.deleteLocators([id])`
- `ParserService.deleteLocators(_ ids: [String])` → `{"action": "delete_locators", "path": ..., "ids": [...]}`
- `_delete_locators(path, ids)` in `parse_als.py` — rewrites XML sans those locator nodes, renames original to `OLD_<name>.als`

### Build locator drag (`BuildLocatorChip`)
- New struct: draggable chip in locator lane
- Drag snaps to bar (downbeats only, `snapToBar()`)
- Right-click on waveform area → add build locator at that beat position
- `EditLocatorLane` gains `buildLocators: [BuildLocator]`, `onMoveBuildLocator`, `onDeleteBuildLocator` params

---

## Phase 5 — Interactive Tempo Lane
**Effort:** Large | **Value:** Medium

New `EditTempoLane` struct. Renders between the locator lane and track waveforms.

- Breakpoints drawn as draggable diamonds; vertical drag = BPM change
- Tap empty area → add breakpoint at that beat (snapped)
- Delete key / × button removes selected breakpoint (beat-0 point protected)
- Step-change enforcement: each edit writes two FloatEvents at the same beat (Ableton step-change format)
- Locators reposition to same beat (not same second) when tempo changes
- Shift modifier: 0.01 BPM fine control
- BPM display: `"%.0f"` for integers, `"%.2f"` for fractional

---

## Phase 6 — CVDisplayLink Playhead (Polish)
**Effort:** Small | **Value:** Low

Replaces the 30Hz Timer with a vsync-locked CVDisplayLink for smoother playhead movement.

- `CVDisplayLink` + `CVDisplayLinkSetOutputHandler` in `WaveformScrollHost.Coordinator`
- `@MainActor func tickPlayhead()` — reads `editPlayer.currentTime`, updates CALayer x position
- `CVDisplayLinkStop()` in `deinit` (not `.invalidate()`)
- Output handler dispatches to `DispatchQueue.main`

---

## Phase 7 — Detect Tempo from ORIGINAL SONG
**Effort:** Small | **Value:** Medium (Build Session enhancement)

Python side (`analyze_beats` action using librosa) already exists.

### Swift additions
- `ParserService.analyzeBeatMap(alsPath:)` → calls `{"action": "analyze_beats", "path": ...}`
- Returns `[Double]` beat timestamps
- `tempoEventsFromBeats(_ beats: [Double]) -> [TempoEvent]` — converts to step-change TempoEvents

### EditView additions
- `@State private var isAnalyzingBeats: Bool`
- `@State private var beatAnalysisError: String?`
- "Detect Tempo from ORIGINAL SONG" button in Build Session panel
- Only visible when `originalSongURL != nil`
- On success: populates `buildStore.additionalTempoEvents`

---

## Status

| Phase | Feature | Status |
|---|---|---|
| 1 | Clip trim + multi-clip select | ✅ Done |
| 1.5 | Multi-stem region drag | ✅ Done |
| 2 | Click track preview lane | ⬜ Not started |
| 3 | Build Session panel | ⬜ Not started |
| 4 | Locator delete + Build locator drag | ⬜ Not started |
| 5 | Interactive tempo lane | ⬜ Not started |
| 6 | CVDisplayLink playhead | ⬜ Not started |
| 7 | Detect Tempo from ORIGINAL SONG | ⬜ Not started |
