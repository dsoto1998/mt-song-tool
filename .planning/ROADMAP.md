# MT Song Tool — Roadmap

## Backlog

### Phase 999.1: Core ML audio classifier for stem name validation (BACKLOG)

**Goal:** Replace the hand-tuned spectral classifier with a CreateML AudioClassifier model trained on labeled MultiTracks stems.

**Context:**
- Current classifier uses hand-tuned FFT thresholds (centroid, ZCR, bass ratio) — only reliable for macro-category separation (transient vs. tonal)
- A trained model would enable fine-grained classification: guitar vs. keys vs. vocals vs. drums
- Primary benefit: better suggestions on invalid stem names ("this sounds like keys, here are your keys options")
- Secondary benefit: more precise Audio Mismatch detection beyond current macro-category approach

**Training (one-time, outside app):**
- Collect ~50–200 stems per category from existing MultiTracks catalog
- Train in Apple's CreateML app (drag-and-drop, no ML code needed)
- Export `.mlmodel` file

**App integration:**
- Replace `classifyCategory()` in `AudioAnalyzerService.swift` with `SNAudioFileAnalyzer` + `SNClassifySoundRequest(mlModel:)`
- Bundle `.mlmodel` in `Resources/`
- Analysis is async and file-based (restructure `analyzeFile` accordingly)

**Effort:** ~3–5 context resets to implement

**Requirements:** TBD
**Plans:** 0 plans

Plans:
- [ ] TBD (promote with /gsd-review-backlog when ready)
