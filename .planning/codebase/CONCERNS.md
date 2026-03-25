# Codebase Concerns

**Analysis Date:** 2026-03-25

## Tech Debt

**Monolithic ContentView file:**
- Issue: `ContentView.swift` is 951 lines — nearly 23% of all Swift code. Contains state management, UI layout, parsing logic, song data population, locator fixes, validation checks, all in one file.
- Files: `dawtool-master/swift-app/Sources/MTSongTool/ContentView.swift`
- Impact: Difficult to test individual features, state mutations scattered throughout, navigation order logic intertwined with rendering. Changes to any panel affect multiple dependencies.
- Fix approach: Extract song data validation + population into separate module. Move copy-blocking logic to computed property collection. Extract Live 12 conversion flow into dedicated handler.

**Regex-based XML parsing in Python:**
- Issue: `parse_als.py` uses regex patterns (not DOM) to extract time signatures, tempo events, locators, and apply Live 12 fixes. Regex includes magic patterns like `r'<TimeSignature>.*?<AutomationTarget Id="(\d+)"'` and `r'<Locator\s+Id="{als_id}".*?</Locator>'` with `re.DOTALL` flag.
- Files: `dawtool-master/parse_als.py` (lines 200–474)
- Impact: Fragile to variations in XML formatting (extra whitespace, attribute order changes). Silent failures if Ableton changes XML structure. DOTALL flag makes `.` match newlines, increasing risk of over-matching. Locator ID matching with `re.escape()` is defensive but still regex-based.
- Fix approach: Use XML DOM parser (`lxml.etree` already imported as fallback) for all structural operations, reserve regex only for encoder escaping (name → XML entities). Document which Ableton versions have been tested.

**Ad-hoc CLI protocol between Swift and Python:**
- Issue: `ParserService.swift` (lines 103–137) implements a raw line-based JSON protocol: sends file path → reads one line of JSON response. No framing, no error recovery, no version negotiation.
- Files: `dawtool-master/swift-app/Sources/MTSongTool/ParserService.swift`
- Impact: If Python outputs multiple lines or partial JSON, Swift reads only the first line and misses the rest. Parser process crashes are silently retried (line 108–109) with no state reset. If the parser dies mid-command, the read buffer remains corrupted for the next request.
- Fix approach: Add newline length prefix or use JSON Lines format (one complete JSON object per line). Add "ready" handshake after parser start. Implement read timeout + process restart on timeout.

**Hardcoded dev fallback path:**
- Issue: `ParserService.swift` (line 54) has hardcoded home directory path: `"\(home)/Documents/Claude Apps/MT Song Tool/dawtool-master"`. Project directory path is known to be prone to moves and renames.
- Files: `dawtool-master/swift-app/Sources/MTSongTool/ParserService.swift` (line 54)
- Impact: App breaks silently if project is moved or renamed. No error message — user sees "Parser not available" which looks like a build failure, not a path issue.
- Fix approach: Add `MTST_DAWTOOL_PATH` environment variable check before falling back to hardcoded path. Document the requirement in CLAUDE.md. Add diagnostic logging: print the attempted paths on failure.

## Known Bugs

**Parser binary dependency on hexdump (silent failure):**
- Symptoms: App shows "Parser not available" error toast at launch, even though `venv/bin/python3` exists and `parse_als.py` file is present.
- Files: `dawtool-master/build/lib/dawtool/daw/flstudio_core.py` (imports `hexdump` at module load time), `dawtool-master/parse_als.py` (imports dawtool)
- Trigger: Run `make_swift_app.sh` after a directory move that invalidates the venv, or manually delete the venv without reinstalling dependencies.
- Workaround: Rebuild with `make_swift_app.sh` which runs `pip install hexdump`. Direct `pip install hexdump` into existing venv also works.
- Note: CLAUDE.md warns of this, but the error message is cryptic. `build_parser.sh` now installs it automatically.

**Live 12 conversion reads/modifies XML in memory (unvalidated):**
- Symptoms: Conversion completes but `_Live11.als` file is corrupted or missing features after opening in Ableton.
- Files: `dawtool-master/parse_als.py` (lines 252–328, `_downgrade_to_live11`)
- Trigger: Live 12 sessions with custom automation envelopes, plugin state, or rare XML nesting patterns.
- Root cause: 13 separate regex substitutions, some of which overlap or interact. No structural validation after patching — the resulting gzipped XML is never parsed to verify well-formedness.
- Current mitigation: Writes to `_Live11.als` (non-destructive), original `.als` is preserved. Manual testing has covered common cases.
- Recommendation: Add XML parsing round-trip validation after all substitutions: decompress, parse with lxml, re-serialize, compare byte-for-byte with original to catch malformed XML before writing.

**Silence threshold tuned specifically for 44.1kHz 16-bit:**
- Symptoms: Audio files at 48kHz/24-bit may false-positive as "Silent" even if they contain content.
- Files: `dawtool-master/swift-app/Sources/MTSongTool/AudioAnalyzerService.swift` (lines 388, threshold `1e-4`)
- Issue: Threshold is absolute amplitude value (`-80 dBFS`), not relative to bit depth. 24-bit PCM has ~48dB headroom over 16-bit, so 24-bit files at the same dBFS level will have proportionally lower sample values.
- Current mitigation: All stems are expected to be 44.1kHz / 16-bit; 48kHz/24-bit files surface as format issues ("48kHz", "24-bit") before silence check is run.
- Recommendation: If 48kHz/24-bit support is added, scale threshold to `1e-4 * (bit_depth / 16)` or use relative threshold like `max_sample * 0.001`.

**Incomplete bars detection doesn't check the final section:**
- Symptoms: A session with a time signature change near the end might pass validation even if the final bar is incomplete.
- Files: `dawtool-master/parse_als.py` (lines 477–507, `_check_incomplete_bars`)
- Issue: Function only checks sections *between* consecutive time sig changes (loop at lines 492–506). The final section (last time sig change → loop end) is checked separately by `validate_session` calling `_is_on_barline(loop_end)`, but `_is_on_barline` uses the *first* time signature in the session, not the *last one* (if a change occurred).
- Current mitigation: `_is_on_barline` passes the final timestamp + last time signature from `_ts_events_from_content()` — needs verification that the ordering is correct.
- Recommendation: Add unit test with a session that has a time sig change in the final 2 bars, verify the warning is triggered.

## Security Considerations

**Process spawning without argument validation (AudioAnalyzerService):**
- Risk: `AudioAnalyzerService` spawns FFmpeg with user-supplied file paths directly in the argument array. If file paths contain shell metacharacters, they are still safe (FFmpeg receives them as literal arguments, not via shell expansion).
- Files: `dawtool-master/swift-app/Sources/MTSongTool/AudioAnalyzerService.swift` (lines 508–516)
- Current mitigation: `Process` API does not invoke shell, paths are passed as-is. Good safety.
- Recommendation: Validate all URLs are file URLs and not exotic schemes. Verify `FileManager` operations handle symlinks safely (they do by default, but document it).

**Parser process stdin/stdout no length framing:**
- Risk: Malicious or corrupted `.als` file could cause Python parser to output multiple JSON objects or a very large single object, saturating the read buffer.
- Files: `dawtool-master/swift-app/Sources/MTSongTool/ParserService.swift` (lines 127–137, `readLine`)
- Current mitigation: Only reads one line (stops at `\n`). JSON output is single-line, so this is safe for normal operation.
- Recommendation: Add maximum line length check (e.g., 1MB) and close the process if exceeded. Document the assumption that output is always single-line JSON.

**Locator name escaping for XML write-back:**
- Risk: User edits a locator name to something like `VERSE"2` or `CHORUS&BRIDGE`. The fix code (lines 216–217) escapes `&` and `"` but regex then replaces the entire match. If the regex pattern is broader than intended, escaping might not protect.
- Files: `dawtool-master/parse_als.py` (lines 215–231, `_fix_locators`)
- Current mitigation: Escaping is done *before* regex substitution. Regex pattern is specific: `rf'<Locator\s+Id="{als_id}".*?</Locator>'` with `re.DOTALL`. The closure `patch_block` replaces only the `<Name Value="...">` part, not the entire locator.
- Recommendation: Switch to XML DOM parsing for this operation. Use `lxml.etree` to set element attributes directly, eliminating regex and escaping risk.

**File path traversal in audio conversion output:**
- Risk: If a stem folder path is `../../../etc/` or contains symlinks, `convertNonConforming()` writes output to an attacker-controlled location.
- Files: `dawtool-master/swift-app/Sources/MTSongTool/AudioAnalyzerService.swift` (lines 535–570)
- Current mitigation: User selects folder via UI drag-and-drop or file picker. NSOpenPanel resolves symlinks. Output is written to sibling of the input folder (controlled by user's choice).
- Recommendation: Validate that the output folder path is not a symlink or hard link to a sensitive directory. Use `URLResourceValues` to check `isSymbolicLink` and `isAliasFile`.

## Performance Bottlenecks

**Linear silence check reads entire audio file:**
- Problem: Audio files are scanned frame-by-frame (line 390–398) to detect silence. For a 3-minute 44.1kHz file, this is ~8 million samples → ~1000 iterations of the inner loop.
- Files: `dawtool-master/swift-app/Sources/MTSongTool/AudioAnalyzerService.swift` (lines 390–398)
- Cause: AVAudioFile reading is fast, but amplitude check is done in Swift (not native code). No early exit for silent-heavy files.
- Improvement path: Add a fast first-pass using FFmpeg to compute peak amplitude in 1ms chunks, early-exit if peak > threshold. Only do sample-level scan if needed.

**FFmpeg fallback to system PATH via "which" subprocess:**
- Problem: `ffmpegPath()` spawns a `which ffmpeg` subprocess every time it's called. Conversion happens in a loop (one Process per file).
- Files: `dawtool-master/swift-app/Sources/MTSongTool/AudioAnalyzerService.swift` (lines 488–497)
- Cause: Path lookup is not cached. Called once per convert operation, but should be cached after first discovery.
- Improvement path: Cache the result in a static property. Pre-compute at app launch.

**Stem folder analysis re-scans entire folder after each edit:**
- Problem: Renaming a single stem calls `analyze(folder:)` which re-scans all files. For 50+ stems, this is slow.
- Files: `dawtool-master/swift-app/Sources/MTSongTool/AudioAnalyzerService.swift` (lines 331, after rename)
- Cause: Easiest implementation; avoids state sync issues.
- Improvement path: Add `updateFile(url: URL)` method that analyzes only the changed file and updates the results array in-place.

## Fragile Areas

**Time signature extraction fallback logic:**
- Files: `dawtool-master/parse_als.py` (lines 459–465, fallback in `_ts_events_from_content`)
- Why fragile: If Live version detection fails and minor_a defaults to 12, the code looks for `<MainTrack` tags. But if the session is Live 10, those tags don't exist — the fallback to static `<Numerator>/<Denominator>` is never reached because `if not events:` check happens after the loop, but only if no track was found. The version check uses `>= 10` but earlier versions use `<10` — off-by-one error risk.
- Safe modification: Add explicit version logging and trace the track_candidates selection. Add unit test with a Live 9 session (if available) to verify fallback is reached.
- Test coverage: No tests for time sig extraction across Ableton versions. Tested manually against Live 11/12 sessions only.

**Copy blocking depends on parse result state consistency:**
- Files: `dawtool-master/swift-app/Sources/MTSongTool/ContentView.swift` (lines 496–498, `copyBlocked` computed property)
- Why fragile: Six independent boolean checks (isLive12Session, hasInvalidLocators, hasSessionWarnings, stemCheckRequired, hasAudioIssues, hasDataMissing, hasMissingRequiredStems). If any one check has a latency (e.g., audio analyzer is still computing), copy buttons incorrectly show "blocked" even though data is valid. State mutations from different sources (parser, audioAnalyzer, userSettings) are not synchronized.
- Safe modification: Add a `@Published var readyToCopy: Bool` to a single source of truth. Use `Combine` to subscribe to all state changes and recompute once per update cycle.
- Test coverage: No tests for copy blocking logic. Manual testing covers common paths.

**Locator auto-fix normalization order:**
- Files: `dawtool-master/swift-app/Sources/MTSongTool/LocatorCheckView.swift` (lines 14–27, `autoFixedLocatorName`)
- Why fragile: Three normalization passes applied in order, first match wins. If a locator name is " VERSE - 1 " (spaces, hyphen, space), Pass 2 converts "-" to space → " VERSE   1 ", then collapses spaces → " VERSE 1 ", which may or may not match depending on `LocatorValidator.isValid()` behavior. If Pass 2 matches, Pass 3 is skipped. If Pass 2 doesn't match, Pass 3 tries to replace the *first* space with hyphen. This is order-dependent and fragile to adding new normalization rules.
- Safe modification: Document the pass order with examples. Add unit tests for each normalization pass and their interactions.
- Test coverage: No unit tests. Tested manually with ~10 malformed locator names.

**Live 12 conversion attribute stripping is global:**
- Files: `dawtool-master/parse_als.py` (lines 300–320, stripping of `SelectedToolPanel`, `SelectedTransformationName`, etc.)
- Why fragile: Uses global `re.sub()` to remove attributes from ANY element in the document, not just the affected track types. If Ableton adds a new Live-12-specific attribute with a similar name, it might be over-stripped from unintended elements.
- Safe modification: Scope attribute removal to specific element types (e.g., only strip from `<AudioTrack>`, `<MidiTrack>`, etc.). Use DOM traversal instead of regex.
- Test coverage: Tested against 3 Live 12 sessions provided by QA team. No coverage for edge cases like custom plugins with Live-12 metadata.

## Scaling Limits

**Single-threaded parser process bottleneck:**
- Current capacity: Parses a typical 4-minute session in ~200ms. Can handle 1 parse every 200ms = 5 parses/second.
- Limit: If a session is very complex (1000+ locators, dense automation), parsing takes 500ms+. User perceives the app as unresponsive during locator inline edit + re-parse cycle.
- Scaling path: Profile with a 10-minute orchestral arrangement. Consider multi-process parser pool or async parsing with progress updates. Add cancellation token for user-triggered re-parses.

**Stem folder analysis memory:**
- Current capacity: 200 stems × 8192-byte buffer chunks. Silence check reads all frames into memory during the loop; no peak detection before full scan.
- Limit: A 10-minute 44.1kHz stereo WAV is ~2.5GB when decompressed. Scanning it will consume that much RAM.
- Scaling path: Use fixed-size buffer and stream frames. Add timeout (e.g., max 30 seconds per file). For very large files, skip silence check or use FFmpeg's peak detection.

**Time signature automation regex search:**
- Current capacity: O(n) search through track XML for the time sig target ID, then O(m) regex search through automation envelopes.
- Limit: A session with 1000s of automation envelopes (e.g., one per bar with tempo/time-sig changes) will have a large automation block. Regex search with `re.DOTALL` can be slow.
- Scaling path: Use XML parsing to navigate the tree. Cache the time sig target ID.

## Dependencies at Risk

**PyInstaller venv as a single point of failure:**
- Risk: `build_parser.sh` creates a Python venv using `python3 -m venv`. If this venv is deleted, moved, or corrupted, the app cannot parse `.als` files. The venv path is absolute (not relocatable).
- Impact: Users cannot update the app to a new version if the build fails. CI/CD pipelines that move project directories will fail silently.
- Migration plan: Add `--copies` to venv creation so the venv is relocatable. Or use PyInstaller's one-file mode to embed Python entirely. Document the venv location in the build log.

**lxml fallback for broken system XML libraries:**
- Risk: `parse_als.py` (lines 19–30) monkey-patches `ElementTree` if the system `pyexpat` is broken. If both `pyexpat` and `lxml` fail, the import errors are silently caught and the app starts without XML parsing support.
- Impact: Parser crashes later with a cryptic error. No indication that XML parsing is unavailable.
- Migration plan: Raise an explicit error if the smoke test (line 21) fails and both fallbacks are missing. Provide a clear error message to rebuild with `pip install lxml`.

**Bundled FFmpeg binary (outdated or incompatible):**
- Risk: `make_swift_app.sh` copies FFmpeg from `AudioConverter/dist/.../Frameworks/`. FFmpeg versions 2+ may have changed command-line syntax or codec support.
- Impact: Users with unusual audio files (e.g., opus codec) will fail conversion with unclear error messages.
- Migration plan: Check FFmpeg version after discovery. Add a version compatibility check (`ffmpeg -version` parsing) and warn if the version is too old.

## Missing Critical Features

**No validation that loop bracket exists or is set correctly:**
- Problem: Parser computes `expectedDuration` from the loop bracket. If the user hasn't set a loop bracket in Ableton, `expectedDuration` is nil, and stem duration validation is skipped.
- Blocks: Stem duration validation is silently disabled. A 2-minute stem in a 4-minute song will not be flagged.
- Recommendation: Check if loop bracket is set. If not, show a warning in the Locators panel: "No loop bracket — stem duration validation disabled."

**No undo/redo for locator edits or stem renames:**
- Problem: User edits 5 locator names, realizes one was wrong, has no undo button. Manual re-editing or re-opening the session required.
- Blocks: Multi-step editing workflows are slow and error-prone.
- Recommendation: Maintain an edit history stack. Add Undo/Redo buttons. Persist history for current session only (clear on Clear All).

**No preview playback of audio files:**
- Problem: User sees "Too Long" on a stem and has no way to check if it's actually silent padding or content.
- Blocks: Stem debugging requires opening files in a separate DAW.
- Recommendation: Add a preview icon for each stem. Click to play first 3 seconds via AVAudioEngine. Add scrubber for seeking.

## Test Coverage Gaps

**Time signature extraction:**
- What's not tested: Extraction across Ableton versions (Live 9, 10, 11, 12). Fallback to static Numerator/Denominator. Multi-timeig sessions with automation envelopes.
- Files: `dawtool-master/parse_als.py` (lines 44–120, `parse_time_signatures`)
- Risk: Silent failures if Ableton changes XML structure. Fallback is never exercised in testing.
- Priority: **High** — time sigs are core to locator time_end calculation.

**Incomplete bar detection:**
- What's not tested: Sessions with time sig changes. Sessions where the final bar is incomplete. Sessions with both tempo and time sig changes.
- Files: `dawtool-master/parse_als.py` (lines 477–507, `_check_incomplete_bars`)
- Risk: False negatives (incomplete bars not flagged). Session validation warnings are hidden in a list.
- Priority: **High** — copy is blocked if warnings exist.

**Locator auto-fix normalization:**
- What's not tested: All combinations of spacing, hyphens, underscores in locator names. Edge case: name that partially matches after Pass 1 but fully matches after Pass 3.
- Files: `dawtool-master/swift-app/Sources/MTSongTool/LocatorCheckView.swift` (lines 14–27)
- Risk: Incorrect fixes silently applied, user doesn't notice until Ableton opens the file.
- Priority: **Medium** — affects UX but failures are visible (wrong name in locator panel).

**Live 12 conversion:**
- What's not tested: Sessions with custom plugins, unusual automation blocks, pre-Live-10 sessions (should error). Sessions with both Live 12-specific attributes and multi-version compatibility plugins.
- Files: `dawtool-master/parse_als.py` (lines 252–328)
- Risk: Corrupted or incomplete `_Live11.als` files. Silent failures during regex substitutions.
- Priority: **High** — corrupted files are non-recoverable without manual re-export.

**Copy blocking logic:**
- What's not tested: All combinations of `copyBlocked` conditions. Interactions between stem analysis state and song data state. Copy button behavior when `copyBlocked` is true (should not copy and show toast).
- Files: `dawtool-master/swift-app/Sources/MTSongTool/ContentView.swift` (lines 496–498, and copy button implementations)
- Risk: Buttons behave unexpectedly. Conditions are missed and copy is allowed when it shouldn't be.
- Priority: **High** — core app requirement.

**FileManager race conditions:**
- What's not tested: Concurrent file operations (stem rename while audio conversion is running). File deletions between scan and rename. Symlinks in stem folder.
- Files: `dawtool-master/swift-app/Sources/MTSongTool/AudioAnalyzerService.swift` (lines 270–294, 300–333)
- Risk: Crashes or data loss if two operations conflict.
- Priority: **Medium** — users would need to trigger unusual timing.

---

*Concerns audit: 2026-03-25*
