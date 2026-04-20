# Context: mt-song-section-detector — New Claude Code Session

## Projects
**mt-song-section-detector** — the new standalone project being built here.
Suggested root: `/Volumes/MTEng0/claude-apps/mt-song-section-detector/`

**mt-song-tool** — the parent app this integrates with.
App root: `/Volumes/MTEng0/claude-apps/mt-song-tool/`
Python parser: `mt-song-tool/mtst-master/parse_als.py`
Swift app: `mt-song-tool/mtst-master/swift-app/Sources/MTSongTool/`
Swift app: `mtst-master/swift-app/Sources/MTSongTool/`
Python parser: `mtst-master/parse_als.py`
All Swift files share one SPM target — no imports between them needed.

**IMPORTANT RULES:**
- Never run `make_swift_app.sh` or `build_parser.sh` without explicit user consent
- Don't ask permission before making code changes — just implement

---

## The Task

Build a 3-stage system to auto-detect MT section boundaries from audio alone — no chord chart needed.

```
ORIGINAL SONG.wav
    ↓  Whisper base (already in venv)
Timestamped word list
    ↓  silence gap detection  ← NEW
Lyric segments with start times
    ↓  fine-tuned DistilBERT  ← NEW (trained by user on their sessions)
Section labels (CHORUS, VERSE, BRIDGE …)
    ↓  barline snap (reuse existing code)
Locator suggestions
```

**Start with Stages 1 & 2 only** (training tools). Do not touch app code until user validates the tools produce good training data and a working model.

---

## Stage 1 — `collect_training_data.py` (CREATE in mt-song-section-detector/)

Scans a folder of processed MT sessions → `training_data.jsonl`

For each session subfolder:
1. Find the `.als` file and `ORIGINAL SONG.wav`
2. Extract locator timestamps + labels from the `.als` using `_extract_locator_data()` from `parse_als.py`
3. Run Whisper `base` on the audio (cache result as `ORIGINAL SONG.transcript.json` to avoid re-running)
4. For each locator: collect Whisper words where `start_time` is between this locator's start and next locator's start
5. Join words into text block
6. Skip sections with < 8 words (instrumentals — no lyric signal)
7. Write `{"text": "...", "label": "CHORUS"}` to output JSONL

Usage: `python collect_training_data.py ~/path/to/sessions/ --output training_data.jsonl`

**Label normalization**: Strip trailing numbers from labels before saving.
`CHORUS 2` → `CHORUS`, `VERSE 3` → `VERSE`, `PRE CHORUS 1` → `PRE CHORUS`
(Numbers are added back in post-processing at inference time.)

**Valid base labels** (from MT accepted sections):
INTRO, VAMP, COUNT OFF, VERSE, PRE CHORUS, CHORUS, BRIDGE,
TURNAROUND, BREAKDOWN, INSTRUMENTAL, OUTRO, ENDING, TAG,
REFRAIN, INTERLUDE, SOLO, POST-CHORUS, CHANNEL, EXHORTATION,
RAP, ACAPELLA, PAD

---

## Stage 2 — `train_classifier.py` (CREATE in mt-song-section-detector/)

Fine-tunes `distilbert-base-uncased` on the collected JSONL → `section_classifier/` folder.

```python
# Core flow:
from transformers import AutoTokenizer, AutoModelForSequenceClassification, Trainer, TrainingArguments
# 1. Load training_data.jsonl
# 2. Map labels to int IDs, save label_map.json
# 3. Tokenize with distilbert-base-uncased tokenizer
# 4. Fine-tune for 3 epochs (use MPS device on Apple Silicon)
# 5. Save model + tokenizer + label_map.json to output dir
```

Usage: `python train_classifier.py training_data.jsonl --output section_classifier/`

Output folder must contain: `config.json`, `model.safetensors` (or `pytorch_model.bin`), `tokenizer_config.json`, `label_map.json`

Runs in ~15–30 min on Apple Silicon M1/M2/M3 without GPU (uses MPS).

---

## Existing code to reuse (DO NOT rewrite these)

### `_extract_locator_data(path)` in `parse_als.py`
Reads a gzipped `.als` file, returns list of locator dicts with `time` (beat position) and `name`.

### `_get_tempo_events(content)` in `parse_als.py`  
Returns `[(beat, bpm), ...]` from ALS XML content string.

### `_ts_events_from_content(content)` in `parse_als.py`
Returns `[(beat, numerator, denominator), ...]`.

### `seconds_to_beat` / `beat_to_seconds` / `snap_to_barline` in `parse_als.py`
Defined as closures inside `_suggest_locators()` — copy the pattern when implementing `_suggest_locators_auto()` in Stage 3.

### Whisper transcription pattern (from `_suggest_locators`):
```python
# ffmpeg PATH fix (already in _suggest_locators — copy this block):
import shutil as _shutil
if not _shutil.which("ffmpeg"):
    _exe_dir = os.path.dirname(os.path.abspath(sys.executable))
    _candidates = [
        os.path.normpath(os.path.join(_exe_dir, "..", "..", "Frameworks")),
        "/opt/homebrew/bin", "/usr/local/bin",
    ]
    for _d in _candidates:
        if os.path.isfile(os.path.join(_d, "ffmpeg")):
            os.environ["PATH"] = _d + os.pathsep + os.environ.get("PATH", "")
            break

import whisper
model = whisper.load_model("base")
result = model.transcribe(wav_path, word_timestamps=True, language="en", verbose=False)

# Flatten words:
all_words = []
for seg in result.get("segments", []):
    for w in seg.get("words", []):
        raw = w["word"].strip().lower()
        raw = re.sub(r"[^a-z0-9'\-]", "", raw)
        if raw:
            all_words.append({"word": raw, "start": float(w["start"])})
```

### `fmt_time(seconds)` in `parse_als.py`
Formats seconds as `"MM:SS:mmm"` string — use for `time_string` in suggestions.

### Return shape for suggestions (must match exactly):
```python
{"ok": True, "suggestions": [
    {"label": "VERSE 1", "beat": 16.0, "time_string": "00:08:000",
     "confidence": 0.9, "needs_manual": False},
    {"label": "CHORUS",  "beat": None, "time_string": None,
     "confidence": 0.0, "needs_manual": True},
]}
```

### Server handler pattern (from `parse_als.py` ~line 2854):
```python
elif action == "suggest_locators":
    result = _suggest_locators(
        cmd.get("als_path"), cmd["wav_path"],
        cmd.get("lyric_text", ""), cmd.get("bpm")
    )
    print(json.dumps(result), flush=True)
```
New action `suggest_locators_auto` follows same pattern.

---

## Swift patterns (for Stage 3 — app integration, do later)

### `LocatorSuggesterService.swift` — existing `analyze()` method signature:
```swift
func analyze(alsPath: String?, bpm: Double? = nil, wavPath: String, lyricText: String)
```
New `analyzeAuto()` drops `lyricText`, sends `action: "suggest_locators_auto"`.
Pattern is identical — copy `analyze()`, change action name and remove lyric_text param.

### `ParserService.runSend(command:)` — async, returns String
All parser communication goes through this. Already handles the stdin/stdout JSON protocol.

### `SuggestLocatorsSheet.swift` — add below URL fetch row in `dropZoneSection`:
```swift
Divider().background(Color.border).padding(.vertical, 4)
Text("Or auto-detect sections from audio")
    .font(.system(size: 11)).foregroundColor(.fgMid)
Button("Auto-detect") { suggester.analyzeAuto(alsPath: alsPath, bpm: bpm, wavPath: ...) }
    .buttonStyle(CompactSecondaryButtonStyle().hoverable())
    .disabled(originalSongURL == nil || !modelIsInstalled)
```
`modelIsInstalled` = check if `section_classifier/` exists in app bundle Resources.

### `make_swift_app.sh` — bundle the model (add after line that copies `parse_als_dir`):
```bash
MODEL_SRC="$DAWTOOL_ROOT/section_classifier"
if [ -d "$MODEL_SRC" ]; then
    cp -r "$MODEL_SRC" "$RESOURCES/section_classifier"
    echo "  ✓ section_classifier bundled"
fi
```

### `build_parser.sh` — current pip install line (line ~36):
```bash
"$VENV/bin/pip" install lxml hexdump openai-whisper librosa numpy scipy soundfile -q
```
Add `transformers accelerate` to this line for Stage 3 inference in the bundled binary.

---

## venv location
`/Volumes/MTEng0/claude-apps/mt-song-tool/mtst-master/venv/`
Python 3.14. Currently has: torch, whisper, librosa, numpy, scipy, lxml, hexdump.
`transformers` and `accelerate` are NOT yet installed — add them when needed.

---

## What to build first
1. `collect_training_data.py` — user runs this, you inspect output together
2. `train_classifier.py` — user runs this ~30 min, you confirm model saves correctly
3. Stage 3 app integration — only after model is validated
