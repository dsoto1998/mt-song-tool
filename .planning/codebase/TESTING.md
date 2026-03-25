# Testing Patterns

**Analysis Date:** 2026-03-25

## Test Framework

**Runner:**
- No automated test framework detected (no XCTest, Swift Testing, pytest, unittest)
- No test configuration files found (no `Package.swift` test targets, `pytest.ini`, `conftest.py`)
- No test files in codebase (searched for `*Test*`, `*test*`, `*spec*` in source directories)

**Assertion Library:**
- Not applicable; no unit tests present

**Run Commands:**
```bash
# No test runner configured
# Manual testing only via:
swift run                   # Build and run app
bash make_swift_app.sh      # Full build with parser compilation
```

## Test Organization

**Approach:**
- Manual integration testing via the running application
- User-driven QA: test against real `.als` files from MultiTracks staff workflows
- Parser validation: direct invocation of `parse_als.py` with test `.als` files (see CLAUDE.md for approach)

**Testing Parser Changes:**
The codebase includes direct Python parser testing capability without requiring a full build:

```python
# Direct import and test in Python REPL or script
import gzip, sys
sys.path.insert(0, "/Users/mtengineeringtemp/Documents/Claude Apps/MT Song Tool/dawtool-master")
from parse_als import _get_tempo_events, _check_tempo_ramps

with gzip.open("/path/to/file.als", "rb") as f:
    raw = f.read()

print(_get_tempo_events(raw))
```

**Location:**
- No dedicated test directories
- Parser functions are individually callable from Python with gzip-decompressed `.als` content
- Example: `_extract_locator_data(path)` returns raw locator ID + name pairs; can be tested against live files

## Test Structure

**Real `.als` Files as Fixtures:**
The CLAUDE.md memory documents that parser features should be validated against real `.als` files rather than mocked data:

> "If a parser feature needs validation, ask the user to provide a path to a suitable `.als` file (e.g. one with tempo ramps, a specific time signature, etc.) rather than guessing at the XML structure."

**Example Test Patterns from Code:**

**1. Tempo Event Extraction** (`parse_als.py`):
```python
def _get_tempo_events(contents):
    """Extract tempo automation keyframes from raw .als XML.

    Returns [(beat, bpm_value), ...] sorted by beat.
    Falls back to manual BPM if no automation found.
    """
    try:
        # Find <Tempo> block at <LiveSet> level (NOT in MasterTrack)
        target_m = re.search(r'<Tempo>.*?<AutomationTarget Id="(\d+)"', contents, re.DOTALL)
        if not target_m:
            # Fallback: return static BPM
            return [(0.0, manual_bpm)]

        target_id = target_m.group(1)
        # Find matching <AutomationEnvelope> with <FloatEvent> entries
        # Note: NOT <AutomationEvent> — that will return zero results
        ...
    except (ValueError, TypeError):
        return [(0.0, manual_bpm)]
```

**Validation logic** typically includes:
- Null/empty checks with sensible defaults
- Try/except with fallback paths (e.g., automation parsing fails → use static field)
- Regex-based extraction with HTML unescaping: `html.unescape(name_m.group(1))`

**2. Locator Name Validation** (`LocatorCheckView.swift`):
```swift
private func autoFixedLocatorName(_ text: String) -> String? {
    guard !LocatorValidator.isValid(text) else { return nil }
    // Pass 1: trim + uppercase + collapse spaces
    let base = text.trimmingCharacters(in: .whitespaces).uppercased()
        .components(separatedBy: .whitespaces).filter { !$0.isEmpty }.joined(separator: " ")
    if LocatorValidator.isValid(base) { return base }

    // Pass 2: replace - and _ with spaces
    let noSeparator = base.replacingOccurrences(of: "-", with: " ")...
    if LocatorValidator.isValid(noSeparator) { return noSeparator }

    // Pass 3: replace first space with hyphen
    if let spaceRange = noSeparator.range(of: " ") {
        let firstHyphen = noSeparator.replacingCharacters(in: spaceRange, with: "-")
        if LocatorValidator.isValid(firstHyphen) { return firstHyphen }
    }
    return nil
}
```

**3. Audio Validation** (`AudioAnalyzerService.swift`):
```swift
struct AudioFileStatus {
    case ok
    case silent       // Detected via amplitude analysis
    case corrupted(String)
}

// Silence detection: amplitude < 1e-4 (-80 dBFS)
// Tolerance: 5 samples at file's native sample rate (~0.113ms at 44.1kHz)
// Duration validation: expected ± 5-sample tolerance
```

## Mocking

**Framework:**
- No mocking framework used (no Mock, Testable, etc.)

**Service Testing in App:**
Services are tested via their observable properties:

```swift
class AudioAnalyzerService: ObservableObject {
    @Published var results: [AudioFileResult] = []
    @Published var isScanning = false
    @Published var errorMessage: String? = nil
}
```

**Manual Testing Pattern:**
1. Drop a folder of `.wav` files via UI
2. Observe `isScanning` → `results` population → check results
3. View error state via `errorMessage` string

**What to Mock:**
- Not applicable; no mocking infrastructure

**What NOT to Mock:**
- Real `.als` file parsing (use actual files)
- Stem audio analysis (use real WAV files)
- File I/O and rename operations (tested via UI interactions)

## Fixtures and Factories

**Test Data:**
- Static approved lists stored as `Set<String>` in code:

```swift
// Validation.swift
static let acceptedSections: Set<String> = [
    "COUNT OFF", "INTRO", "VERSE", "VERSE 1", ..., "NEXT SONG"
]

// AudioAnalyzerService.swift
static let approvedStems: Set<String> = [
    "CLICK TRACK", "GUIDE", "ORIGINAL SONG", "GUITARS", ...
]
```

- Enum cases for test scenarios: `AudioFileStatus.ok`, `.silent`, `.corrupted("reason")`

**Location:**
- `Validation.swift`: locator section labels
- `AudioAnalyzerService.swift`: stem name whitelist (~200 entries)
- `SongData.swift`: song key and time signature picker lists

**No Factory Pattern:**
- Static data is preferred over factories
- Services initialized as singletons: `UserSettings.shared`
- Test fixtures are real data files, not generated

## Coverage

**Requirements:**
- No coverage target enforced
- No coverage reporting configured

**View Coverage:**
- All major UI paths tested manually:
  - File drop → parse → display locators ✓
  - Inline locator edit → fix → re-parse ✓
  - Stem folder drop → validate → show issues ✓
  - Copy operations (blocked until valid) ✓
  - Live 12 conversion flow ✓
  - Quick Check Mode toggle ✓
  - MT Complete Mode toggle ✓

**Parser Coverage:**
- Time signature automation parsing (including Live 12 changes)
- Tempo ramp detection
- Locator name extraction (preserving whitespace)
- Incomplete bar detection across time signature changes
- Live 12 → Live 11 downgrade conversion
- Session validation (loop bracket, clip alignment, tempo changes)

## Test Types

**Manual Integration Tests:**

1. **Locator Validation:**
   - Load `.als` with mixed valid/invalid/blank/misspelled locators
   - Verify invalid rows show red highlight
   - Verify auto-fix suggestions appear for fixable names
   - Apply fix → re-parse → verify write-back

2. **Stem Checking:**
   - Drop folder with mixed format stems
   - Verify all stems listed with issues highlighted (format, silence, unknown name)
   - Test "Fix Names" batch rename
   - Test "Fix Format" conversion to 44.1 kHz / 16-bit
   - Verify required stems (CLICK TRACK, GUIDE, ORIGINAL SONG) pinned at top

3. **Song Data Population:**
   - Load `.als` → verify BPM, Key, Time Sig auto-populated
   - Load single-time-sig session → verify fallback to static `<Numerator>/<Denominator>`
   - Load multi-time-sig session → verify all changes extracted from automation
   - Change a field → re-parse via locator fix → verify field preserved (not clobbered)

4. **Copy Operations:**
   - Verify copy button disabled until all validations pass
   - Verify copy button enabled with valid session + stems
   - Verify paste shows expected data format

5. **Error States:**
   - Load corrupted `.als` → verify parse error shown
   - Drop non-WAV folder for stem check → verify "no audio files found" message
   - Load Live 12 `.als` → verify conversion prompt, successful conversion

## Common Patterns

**Optional Chaining with Fallback:**
```swift
if let result = parser.result, let bpm = result.bpm {
    // Use bpm
} else {
    // Show placeholder or skip
}
```

**Conditional Display:**
```swift
// Show red border only if no stems scanned AND not in Quick Check Mode
private var showAsMissing: Bool {
    !quickCheckMode && analyzer.results.isEmpty && !analyzer.isScanning
}
```

**Computed Property Filtering:**
```swift
// Stems with issues first, then clean stems, all A–Z within each group
private var remainingResults: [AudioFileResult] {
    let withIssues = nonPinned.filter { !$0.isClean }
        .sorted { $0.filename.lowercased() < $1.filename.lowercased() }
    let clean = nonPinned.filter { $0.isClean }
        .sorted { $0.filename.lowercased() < $1.filename.lowercased() }
    return withIssues + clean
}
```

**Service Callback Pattern:**
```swift
// View passes callback to let service communicate success/error
LocatorCheckView(
    markers: markers,
    onFix: { fixes in
        // ContentView receives fixes, applies write-back, re-parses
        applyLocatorFixes(fixes)
    }
)
```

**State Preservation Across Re-renders:**
```swift
// stemCheckMinimized lifted to ContentView as @State
// Passed as @Binding to AudioAnalysisView
// When parser re-parses, AudioAnalysisView is destroyed but
// @State in parent preserves collapse state
@State private var stemCheckMinimized: Bool = false
// ...
AudioAnalysisView(..., isMinimized: $stemCheckMinimized)
```

---

*Testing analysis: 2026-03-25*
