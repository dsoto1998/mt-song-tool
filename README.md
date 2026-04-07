<p align="center">
<img width="500" src="https://github.com/user-attachments/assets/2920f29e-df79-4bb6-a151-a61f2e076d21" />
<img width="500" src="https://github.com/user-attachments/assets/9d60aa31-e278-40fc-95ea-c617743d92ad" />
</p>

**MT Song Tool**

- Internal macOS QA tool for MultiTracks.com Ableton Engineering. 
- Validates Ableton Live sessions and WAV stem packages before publishing.

**Features**

- **Locator validation** — Parses `.als` files and checks every section marker against the approved MultiTracks sections list. Invalid labels shown in red; auto-fix and inline rename write corrections back to disk.
- **Time Signatures panel** — Extracts time signature changes from the Ableton automation envelope, including mid-song changes.
- **Song Data panel** — Auto-populates Song Key, Time Signature, BPM, and Preview Start/End from the session. All fields are copyable.
- **Stem Check panel** — Batch-validates a folder of WAV stems for silence, stem name conformance (~200 approved names), audio format (44.1 kHz / 16-bit), and duration alignment with the loop bracket. Includes in-app audio conversion via bundled FFmpeg and per-stem waveform playback.
- **Session validation** — Checks loop bracket vs. audio clip alignment, incomplete bars, and tempo ramp usage.

<p align="center">
<img width="400" alt="MTST - Upload Tab" src="https://github.com/user-attachments/assets/d62721ad-6a0d-441e-ad25-041220858694" />
<img width="400" alt="MTST - Queue Tab" src="https://github.com/user-attachments/assets/34f9ca61-68a3-4d04-8444-7666d96bd470" />
</p>

**Requirements**

- macOS 13 (Ventura) or later
- Xcode with Swift 5.9+
- Python 3 with PyInstaller (installed automatically into a local venv by the build script)

**Build**

```bash
bash ~/Documents/"Claude Apps"/"MT Song Tool"/mtst-master/swift-app/make_swift_app.sh
```

This compiles the Python parser via PyInstaller, builds the Swift app in release mode, assembles the `.app` bundle, and produces a versioned `.pkg` + `.zip` in `Versions/`.

No sudo required for a standard admin install. If the existing bundle is root-owned from an older install, the script performs a one-time `sudo chown` to take ownership.

**Architecture**

| Layer | Technology |
|---|---|
| UI | Swift / SwiftUI (macOS 13+) |
| Parser | Python 3 + PyInstaller (bundled binary) |
| Audio conversion | FFmpeg (bundled binary + dylibs) |
| Parser IPC | Persistent subprocess — stdin/stdout JSON |
| Credentials | macOS Keychain |

The Python parser (`parse_als.py`) runs as a persistent server process. Swift sends one-line JSON commands and reads one-line JSON responses, keeping parse latency near-zero after the first call.

**Version**

- Current release: **v1.0.6**
- See Release Notes.md for full changelog.
