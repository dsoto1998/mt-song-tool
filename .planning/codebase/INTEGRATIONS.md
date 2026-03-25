# External Integrations

**Analysis Date:** 2026-03-25

## APIs & External Services

**None Detected** - This is an internal QA tool with no external API integrations. All functionality is local-only.

## Data Storage

**Databases:**
- None - Tool operates entirely on user-provided files in memory

**File Storage:**
- **Local filesystem only** — reads/writes `.als` files and `.wav` stem folders from user's local disk
  - Input: User drops `.als` files and stem folders into the application
  - Output: Modified `.als` files written back to same location with `_Live11` suffix for converted files or `OLD_` prefix for backups
  - No cloud sync or remote storage

**Caching:**
- None - Each session starts fresh, no persistent cache

## Authentication & Identity

**Auth Provider:**
- **Custom local-only** — First-run login screen captures user's first/last name
  - Implementation: `LoginView.swift` with UserDefaults persistence in `UserSettings.swift`
  - Scope: Local machine only; name stored in UserDefaults with keys `mtst_first_name` and `mtst_last_name`
  - No server validation, no password, no external identity provider

## Monitoring & Observability

**Error Tracking:**
- None - No remote error reporting or analytics

**Logs:**
- **Local NSLog only** — parser process logs via `NSLog("[MTST] ...")` to macOS system log
  - Example: `NSLog("[MTST] Parser process ready (pid %d)", proc.processIdentifier)`
  - View with: `log stream --process "MT Song Tool"`
  - No log aggregation or external collection

## CI/CD & Deployment

**Hosting:**
- None - Desktop application only; no hosted backend

**CI Pipeline:**
- None - Build is manual via shell script (`make_swift_app.sh`)
- Produces `.pkg` installer + versioned `.zip` archive for distribution
- No GitHub Actions, no automated build/deploy

**Distribution:**
- Versioned `.zip` files stored at `Versions/MT Song Tool vX.X.X.zip`
- Includes `.pkg` installer and Release Notes.md
- Shared manually with users

## Environment Configuration

**Required Environment Variables:**
- None at runtime - all configuration is bundled or user-provided

**Optional Environment Variables:**
- `DAWTOOL_PATH` — Override location of dawtool module (used during development fallback only)

**Secrets Location:**
- None - No secrets, API keys, or credentials stored
- No `.env` files used

## File-Based Input/Output

**Input Formats:**
- `.als` files (Ableton Live sessions) - gzip-compressed XML format
- `.wav` files (audio stems) - WAV audio format (44.1 kHz / 16-bit required)

**Output Formats:**
- Modified `.als` files with corrected locators
- Converted `.wav` files (via FFmpeg) normalized to 44.1 kHz / 16-bit
- Backup `.als` files prefixed `OLD_<basename>.als` on fix operations
- `_Live11.als` conversions of Live 12 sessions

## Webhooks & Callbacks

**Incoming:**
- None - No listening server, no webhooks

**Outgoing:**
- None - No callbacks to external services

## Process Communication

**Internal Process Bridge:**
- **Parser subprocess** (`parse_als.py` via PyInstaller binary) communicates via stdin/stdout JSON protocol
  - Located at: `Contents/MacOS/parse_als_dir/parse_als` in bundled app
  - Dev fallback: `~/Documents/Claude Apps/MT Song Tool/dawtool-master/venv/bin/python3`
  - Protocol: Single-line JSON commands, single-line JSON responses
  - Persistent server model: Launched once at app start, stays alive for instant parsing
  - Commands:
    - `{"action": "parse", "path": "/path/to/file.als"}` → full parse result
    - `{"action": "fix_locators", "path": "...", "fixes": [...]}` → apply corrections
    - `{"action": "validate", "path": "..."}` → session validation checks
    - `{"action": "downgrade_to_live11", "path": "..."}` → convert to Live 11

## External Tools (Runtime Dependencies)

**FFmpeg:**
- **Purpose:** Audio format conversion (resample, bit-depth conversion)
- **Location:** Bundled at `Contents/Frameworks/ffmpeg` + audio codec dylibs
- **Source:** Copied from sibling AudioConverter project (`../AudioConverter/dist/...`)
- **Quarantine:** Cleared via `xattr -cr` during build (required for macOS Gatekeeper)
- **Failure:** If missing, audio conversion option shows warning but app still launches

**System Utilities:**
- `pkgbuild` - macOS native installer creation (no external dependency)
- `zip` - File archive creation (macOS native)
- `xattr` - macOS quarantine flag management (native)

---

*Integration audit: 2026-03-25*
