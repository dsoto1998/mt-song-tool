<p align="center">
<img width="400" src="https://github.com/user-attachments/assets/2920f29e-df79-4bb6-a151-a61f2e076d21" />
<img width="400" src="https://github.com/user-attachments/assets/9d60aa31-e278-40fc-95ea-c617743d92ad" />
</p>

**MT Song Tool**

- Internal macOS QA tool for MultiTracks.com Ableton Engineering.
- Validates Ableton Live sessions and WAV stem packages before publishing.

**Features**

- **AudioShake tab** — AI-powered stem separation via the AudioShake API. Drop any mixed audio file, pick from 15 stem models (vocals, lead/backing vocals, instrumental, drums, bass, guitar variants, piano, keys, strings, wind, other), choose an output folder, and download the separated stems directly into the app.
- **Edit tab** — Multi-stem audio timeline with AVAudioEngine playback, per-stem gain control, VU metering, a click track metronome (with compound time signature support), region selection, and segment-level editing backed by FFmpeg.
- **Stem Check panel** — Batch-validates a folder of WAV stems for silence, stem name conformance (~200 approved names), audio format (44.1 kHz / 16-bit), and duration alignment with the loop bracket. Includes in-app audio conversion via bundled FFmpeg and per-stem waveform playback with section highlight mode and loop-within-section support.
- **Locator validation** — Parses `.als` files and checks every section marker against the approved MultiTracks sections list. Invalid labels shown in red; auto-fix and inline rename write corrections back to disk.
- **Session validation** — Checks loop bracket vs. audio clip alignment, incomplete bars, and tempo ramp usage.
- **Song Data panel** — Auto-populates Song Key, Time Signature, BPM, and Preview Start/End from the session. All fields are copyable.
- **Time Signatures panel** — Extracts time signature changes from the Ableton automation envelope, including mid-song changes.
- **Quick Check Mode** — Removes the requirement to have both an `.als` and a stem folder loaded before proceeding. Stem issues still block copy/submit.
- **MT Complete Mode** — Suppresses the NEXT SONG missing-marker warning and enables short-code locator labels for single-song (non-medley) sessions.

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

- Current release: **v1.2.6**
- See Release Notes.md for full changelog.
