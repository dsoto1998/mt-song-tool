# Coding Conventions

**Analysis Date:** 2026-03-25

## Naming Patterns

**Files:**
- `PascalCase` for all Swift files: `ContentView.swift`, `ParserService.swift`, `DesignSystem.swift`
- Descriptive purpose-based names: views end in `View`, services end in `Service`, helpers are named by function: `Validation.swift`, `SongData.swift`
- Python module: `parse_als.py` (snake_case, underscore separators for private functions)

**Functions:**
- Swift: `camelCase` with lowercase first letter: `autoFixedLocatorName()`, `resolveParser()`, `validateStemName()`
- Python: `snake_case` with leading underscore for private/internal functions: `_extract_locator_data()`, `_get_tempo_events()`, `_check_tempo_ramps()`
- Public Python functions: `parse_file()`, `validate_session()`

**Variables & Properties:**
- Swift: `camelCase`: `isLoading`, `audioAnalyzer`, `hasValidLocators`, `bpmText`, `previewStartText`
- Swift state properties: descriptive names tracking intent: `copiedMarkers`, `hasPopulatedSongData`, `stemCheckMinimized`
- Swift @State/@Published properties: boolean-prefixed for flags: `isScanning`, `isHovered`, `showLive12Alert`, `isTargeted`
- Python: `snake_case`: `wav_files`, `raw_content`, `ts_events`

**Types:**
- `PascalCase` enums and structs: `AppTheme`, `AudioFileStatus`, `ParsedResult`, `Marker`, `TimeSig`
- Enum cases: `camelCase`: `.ok`, `.silent`, `.corrupted`, `.light`, `.dark`, `.system`
- Protocol-like sets/arrays storing uppercase constants: `approvedStems: Set<String>`, `acceptedSections: Set<String>` (all entries uppercase)

## Code Style

**Formatting:**
- No explicit formatter configured; style is consistent manual formatting
- Swift indentation: 4-space tabs
- Line length: typically 80-100 characters (respects readability on typical screens)
- Spacing: single blank line between logical sections, double blank line between `MARK:` sections

**Linting:**
- No linting configuration detected (no `.swiftlint.yml`, `eslint`, or similar)
- Code follows implicit style conventions via team adherence

**Swift Attributes & Organization:**
- `@main` on app entry point: `struct MTSongToolApp: App`
- `@StateObject` for service singletons and child view state: `parser`, `audioAnalyzer`
- `@ObservedObject` for shared settings: `userSettings = UserSettings.shared`
- `@State` for local view state and UI flags: `copiedMarkers`, `showSettings`, `mtidText`
- `@Published` on ObservableObject properties for persistence: `firstName`, `theme`, `isScanning`
- `@Binding` to receive state references from parent: `$isMinimized` in `AudioAnalysisView`
- `private` visibility by default for implementation details; `public` omitted (implicit for top-level)

## Import Organization

**Order:**
1. Standard library imports (SwiftUI, AppKit, Foundation, etc.)
2. Framework imports (AVFoundation, CoreText, UniformTypeIdentifiers)
3. Local module imports (none — single SPM target)

**Path Aliases:**
- None used; single executable target `MTSongTool` means all files are in the same namespace
- No import aliases needed

**Example:**
```swift
import SwiftUI
import AppKit
import AVFoundation
```

## Error Handling

**Swift Patterns:**
- `guard let` for nil unwrapping with early return: `guard let window = NSApplication.shared.windows.first else { return }`
- `if let` for optional chaining in complex logic paths
- `try?` for silent failures when default behavior is acceptable: `try proc.run()` wrapped in `do`
- `NSLog()` for critical errors and startup diagnostics: `NSLog("[MTST] Failed to start parser: %@", error.localizedDescription)`
- No exception throwing across views; parse errors are wrapped in `ParsedResult.errorMessage: String?`

**Python Patterns:**
- Broad `try/except Exception:` blocks with silent fallback: `except Exception: return []`
- Version-aware fallback: for Live < 10, skip automation parsing and fall back to static `<Numerator>/<Denominator>` fields
- XML parsing safety: `.decode("utf-8", errors="ignore")` to avoid crashes on malformed UTF-8
- Regex-based parsing with fallthrough: if automation envelope parsing fails, attempt static field extraction (same function)

**Service Error Communication:**
- `@Published var errorMessage: String?` on services (`ParserService`, `AudioAnalyzerService`)
- Error shown in UI via `if let err = analyzer.errorMessage { errorView(message: err) }`
- No throwing closures; errors are queued as property state

**Validation Pattern:**
- `static func isValid(_ label: String) -> Bool` returns true/false; no exceptions
- Validation rules are documented in comments above the function
- Invalid states shown via UI badges/highlighting, not errors

## Comments

**When to Comment:**
- `MARK:` sections divide major logical blocks in views and services: `// MARK: - Drop Zone`, `// MARK: Settings gear`
- Function documentation for non-obvious behavior: docstrings above public functions in services and helpers
- Inline comments explain **why** a pattern is needed, not **what** it does
- Example: `// Prevents populateSongData from clobbering user-entered fields on re-parse` explains state flag purpose

**JSDoc/TSDoc:**
- Not used; Swift uses standard doc comments (`///`) sparingly
- Swift doc comments appear on public types and key functions: `LocatorCheckView`, `parse_time_signatures()`
- Python docstrings at module and function level for major parsing logic

**Example from Code:**
```swift
// Prevents populateSongData from clobbering user-entered fields on re-parse
// (e.g. after a locator fix-and-re-parse).
@State private var hasPopulatedSongData = false

/// Attempts to automatically correct a locator name without losing meaning.
/// Returns the corrected name if one of the normalization passes produces a
/// recognized section label, or nil if the name cannot be auto-corrected.
private func autoFixedLocatorName(_ text: String) -> String?
```

## Function Design

**Size:**
- View body methods: 20-100 lines (view composition tends to be longer)
- Service methods: 10-50 lines (helpers focused on single task)
- Python helpers: 20-60 lines with nested functions for regex patterns

**Parameters:**
- Keep parameter count ≤ 5 for views (use callback closures instead): `onFix: ([(Marker, String)]) -> Void`
- Service methods pass context via `self` properties: `AudioAnalyzerService.analyze(folder:)` uses `self.expectedDuration` set by caller
- Boolean flags passed as named parameters: `quickCheckMode: Bool = false`, `rehearsalMixOnly: Bool = false`

**Return Values:**
- Optional returns for lookup/search: `autoFixedLocatorName() -> String?`, `_extract_locator_data() -> [(String, String)]?`
- Tuple returns for related values: `(id, name_raw)` from locator extraction
- `@Published` properties for async results rather than return values in services

**Computed Properties:**
- Used extensively for derived state: `private var copyBlocked: Bool`, `private var autoFixable: [(Marker, String)]`
- Prefer computed properties over methods when logic is declarative/stateless

## Module Design

**Exports:**
- All top-level types in a file are public by default (single target)
- `private` used for implementation details within a file
- `file-private enum` for views with internal state enums: `enum StemEditState` in `AudioAnalysisView.swift`

**Barrel Files:**
- None; each file is self-contained with `MARK:` sections for organization

**View Composition Pattern:**
- Large views (ContentView) use `private var` computed properties as sub-views: `private var headerView`, `private var songDataView`, `private var submitRow`
- Sub-view functions/properties are declared near their usage location
- Example from `ContentView`: settings button has its own `@State var gearHovered` locally scoped

**Service Architecture:**
- Stateful services are `class ObservableObject` with `@Published` properties
- Singleton pattern: `class UserSettings { static let shared = UserSettings() }`
- Parser wrapped in `ParserProcess` class for lifecycle management; exposed via `ParserService` wrapper

## Consistent Patterns

**State Lifting:**
- `stemCheckMinimized` is lifted to `ContentView` as `@State` and passed as `@Binding` to `AudioAnalysisView` so re-parses don't reset collapse state
- `parser` and `audioAnalyzer` are `@StateObject` in `ContentView` so they survive SwiftUI re-renders
- User preferences always live in `UserSettings.shared` singleton

**Copy Blocking Logic:**
```swift
private var copyBlocked: Bool {
    isLive12Session
    || hasInvalidLocators
    || hasSessionWarnings
    || stemCheckRequired
    || hasAudioIssues
    || hasDataMissing
    || hasMissingRequiredStems
}
```
Condition-based logic, not exception-based. All block conditions are recomputed on state change.

**Closure Callbacks:**
- Services communicate upward via callback closures: `onFix: ([(Marker, String)]) -> Void`
- Views do not throw or use Result types; all errors flow through `@Published var errorMessage: String?`

**Persistent Settings:**
- All user defaults use `"mtst_"` prefix: `"mtst_first_name"`, `"mtst_theme"`, `"mtst_quick_check_mode"`
- Settings keys are private constants in `UserSettings` class
- `didSet` observers write changes back immediately: `didSet { UserDefaults.standard.set(...) }`

---

*Convention analysis: 2026-03-25*
