# Normalization & Metering Handoff

## What was built this session

### Architecture
- `collectiveStemBusMixer` — hidden AVAudioMixerNode. Collective stems (everything except CLICK TRACK, GUIDE, ORIGINAL SONG) route through this before `stemBusMixer`. Tapped with 4x oversampling → `collectiveAllTimePeak` (live peak during playback).
- Master bus tap (`stemBusMixer`) — also 4x oversampled → `masterPeakDB` / `allTimeMasterPeak`.
- Both taps pre-allocate converter + buffer at install time. Zero allocation on the real-time thread.
- `StemState.truePeak` was added then removed — do not re-add.
- `truePeakAmplitude()` static function was added then removed — do not re-add.

### Normalize Stems button
- Async. Clicking triggers `normalizeStems()` → sets `isNormalizing = true` → button shows spinner + "Scanning…"
- Calls `scanCollectiveMixTruePeak(urls:gains:)` on a background thread.
- On completion: applies multiplier to collective stems, normalizes ORIGINAL SONG to −6 dBFS from `peaks.max()`, sets `isNormalizing = false`.
- Button disabled when `isNormalizing` or no collective stems loaded. No "play first" requirement.

### scanCollectiveMixTruePeak
- Reads all collective stem files in 4096-frame chunks using AVAudioFile.
- Mixes chunks using vDSP (`vDSP_vsma` for gain-scaled accumulation, `vDSP_vclr` to zero).
- 4x upsamples each mixed chunk via AVAudioConverter before measuring peak.
- Returns linear peak amplitude (not dB).

## The one remaining bug — FIX THIS NEXT

**The caveat:** `scanCollectiveMixTruePeak` signals `.endOfStream` to the converter after each 4096-frame chunk. This flushes the polyphase FIR filter's state. The next chunk starts as if silence preceded it. The first ~64 output frames of each upsampled chunk have incorrect interpolated values.

**Risk:** If the true inter-sample peak falls within ~64 frames of a chunk boundary, the scan under-measures it. Under-measuring → multiplier too large → mix normalizes hotter than −0.01 dBFS after playback. Magnitude: up to 1–3 dB miss for typical audio.

**Fix:** Restructure `scanCollectiveMixTruePeak` so the converter runs in streaming mode — a single persistent `convert(to: dstChunk, error: nil) { inputBlock }` loop where the `inputBlock` mixes and returns one chunk at a time, only signaling `.endOfStream` when `framesProcessed >= totalFrames`. The converter keeps its filter state alive across all chunks.

This is the same streaming pattern used in the (now-removed) `truePeakAmplitude` function. The key: the `inputBlock` is called by the converter whenever it needs more input — do the mix work inside the inputBlock, not in the outer loop.

Rough shape:
```swift
var framesProcessed: Int64 = 0
while true {
    dstChunk.frameLength = 0
    let status = converter.convert(to: dstChunk, error: nil) { _, outStatus in
        guard framesProcessed < totalFrames else {
            outStatus.pointee = .endOfStream; return nil
        }
        let toProcess = AVAudioFrameCount(min(Int64(chunkFrames), totalFrames - framesProcessed))
        // zero mixChunk, accumulate stems, set mixChunk.frameLength = toProcess
        framesProcessed += Int64(toProcess)
        outStatus.pointee = .haveData
        return mixChunk
    }
    // measure peak of dstChunk
    if status != .haveData { break }
}
```

Note: `framesProcessed` is captured by reference in the closure — use `var` and capture carefully to avoid Swift closure capture issues. May need a wrapper class or `inout`-style workaround.

## Files changed this session
- `EditPlayerService.swift` — all normalization + metering logic
- `EditView.swift` — Normalize Stems button (spinner, disabled logic, tooltip)

## What was NOT changed / still works
- `extractPeaks` — unchanged, still used for waveform display and ORIGINAL SONG auto-normalize on load
- `fileDuration` — unchanged
- ORIGINAL SONG auto-normalize on load uses `peaks.max()` (raw file peak, ~0.3 dB SRC error acceptable at −6 dBFS)
- All undo/redo logic unchanged
- Metronome, click track, AudioShake — untouched
