<p align="center">
<img width="400" src="https://github.com/user-attachments/assets/2920f29e-df79-4bb6-a151-a61f2e076d21" />
<img width="400" src="https://github.com/user-attachments/assets/9d60aa31-e278-40fc-95ea-c617743d92ad" />
</p>

**MT Song Tool**

- Internal macOS QA tool for MultiTracks.com Ableton Engineering.
- Validates Ableton Live sessions and WAV stem packages before publishing.

**Features**

- **AudioShake tab** — AI-powered stem separation via the AudioShake API. Drop any mixed audio file, pick from 15 stem models (vocals, lead/backing vocals, instrumental, drums, bass, guitar variants, piano, keys, strings, wind, other), choose an output folder, and download separated stems with inline playback.
- **Edit tab** — Multi-stem audio timeline with AVAudioEngine playback, transport controls, pinch-to-zoom, drag-to-nudge, region select/delete/move, cut/split, per-stem gain, peak metering, mute/solo, and FFmpeg bake-out. Includes:
  - **Interactive tempo lane** — drag BPM handles, add/delete events, beat-0 anchor is immovable; bar grid recalculates forward from every change
  - **Time signature lane** — flag at each time sig change; drag to reposition, tap to edit numerator/denominator, click empty space to add; bar grid recalculates through every change
  - **Locator lane** — drag locators to reposition (snaps to downbeats); loop bracket recalculates live as NEXT SONG moves
  - **Stem deletion** — right-click a clip or press ⌦ to remove; CLICK TRACK, GUIDE, ORIGINAL SONG are protected
  - **Gain lock** — CLICK TRACK, GUIDE, ORIGINAL SONG locked at 0 dB with per-stem peak-hold readout
  - **Master meter** — all-time peak hold with tick mark and dB readout; reflects mix stems only (excludes reference stems and metronome)
  - **Export Stems** — exports all stems to a chosen folder, padded/trimmed to loop bracket end, 44.1 kHz / 16-bit PCM
  - **Build Session** — generates a complete Ableton Live 11 `.als` from scratch (BPM, time sig, locators, click track, beat detection from ORIGINAL SONG)
  - **Suggest Locators** — drop a lyric sheet or paste a Genius/AZLyrics URL; Whisper aligns lyrics to timestamps and populates locators
  - **Metronome** — tempo-synced, compound time signature support, mute toggle, subdivision modes
- **Stem Check panel** — Batch-validates WAV stems for silence, name conformance (~200 approved names), audio format (44.1 kHz / 16-bit), and duration alignment. In-app FFmpeg conversion, per-stem waveform playback with section highlight and loop-within-section support. Smart stem name suggestions with confidence percentages.
- **Locator validation** — Parses `.als` files and checks every section marker against the approved MultiTracks sections list. Invalid labels shown in red; auto-fix and inline rename write corrections back to disk.
- **Session validation** — Checks loop bracket vs. audio clip alignment, incomplete bars, and tempo ramp usage.
- **Song Data panel** — Auto-populates Time Signature, BPM, and Preview Start/End from the session. Song Key auto-detected from ORIGINAL SONG stem via bass pitch tracking + CQT chroma analysis. All fields copyable.
- **Time Signatures panel** — Extracts time signature changes from the Ableton automation envelope, including mid-song changes.
- **Quick Check Mode** — Removes the requirement to have both an `.als` and a stem folder before proceeding. Stem issues still block copy.
- **MT Complete Mode** — Suppresses the NEXT SONG missing-marker warning, enables short-code locator labels, and unlocks Song Duration / Display Duration fields.

**Requirements**

- macOS 13 (Ventura) or later
- Xcode with Swift 5.9+
- Python 3 with PyInstaller (installed automatically into a local venv by the build script)

**Build**

```bash
bash "/Volumes/MTEng0/claude-apps/mt-song-tool/mtst-master/swift-app/make_swift_app.sh"
```

This compiles the Python parser via PyInstaller, builds the Swift app in release mode, assembles the `.app` bundle, and produces a versioned `.pkg` + `.zip` in `Versions/`.

No sudo required for a standard admin install. If the existing bundle is root-owned from an older install, the script performs a one-time `sudo chown` to take ownership.

**Architecture**

| Layer | Technology |
|---|---|
| UI | Swift / SwiftUI (macOS 13+) |
| Parser | Python 3 + PyInstaller (bundled binary) |
| Audio playback & editing | AVAudioEngine |
| Audio conversion | FFmpeg (bundled binary + dylibs) |
| Stem separation | AudioShake API |
| Parser IPC | Persistent subprocess — stdin/stdout JSON |
| Credentials | macOS Keychain |

The Python parser (`parse_als.py`) runs as a persistent server process. Swift sends one-line JSON commands and reads one-line JSON responses, keeping parse latency near-zero after the first call.

**Version**

- Current release: **v1.5.0**
- See Release Notes.md for full changelog.
