import Foundation

// MARK: - Locator Suggester Service

/// Drives the two-action round-trip with the Python parser for lyric-based
/// locator suggestion:
///   1. `suggest_locators` — Whisper transcribes the ORIGINAL SONG wav and
///      aligns section labels from a lyric/chord sheet.
///   2. `write_locators`   — Writes the confirmed set of locators into the .als.
@MainActor
final class LocatorSuggesterService: ObservableObject {

    // MARK: - Types

    struct Suggestion: Identifiable {
        let id = UUID()
        var label: String
        var beat: Double?
        var timeString: String?        // "MM:SS:mmm" — nil when needs_manual
        var confidence: Double         // 0.0–1.0
        var needsManual: Bool

        var isLocated: Bool { beat != nil }
    }

    enum Phase {
        case idle
        case analyzing
        case done([Suggestion])
        case failed(String)
    }

    // MARK: - State

    @Published var phase: Phase = .idle

    // MARK: - Actions

    /// Transcribe `wavPath` with Whisper and align section labels from `lyricText`
    /// against the transcript. Barline-snaps results using tempo data from `alsPath`
    /// (or a flat `bpm` when no ALS is available, e.g. Build Session mode).
    func analyze(alsPath: String?, bpm: Double? = nil, wavPath: String, lyricText: String) {
        phase = .analyzing
        var cmd: [String: Any] = [
            "action":     "suggest_locators",
            "wav_path":   wavPath,
            "lyric_text": lyricText,
        ]
        if let als = alsPath { cmd["als_path"] = als }
        if let b   = bpm     { cmd["bpm"]      = b  }
        guard let data   = try? JSONSerialization.data(withJSONObject: cmd),
              let cmdStr = String(data: data, encoding: .utf8) else {
            phase = .failed("Failed to encode command")
            return
        }
        Task {
            let output = await ParserService.runSend(command: cmdStr)
            guard let respData = output.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: respData)
                                   as? [String: Any] else {
                phase = .failed("Invalid response from parser")
                return
            }
            if let err = json["error"] as? String {
                phase = .failed(err)
                return
            }
            guard let rawSugs = json["suggestions"] as? [[String: Any]] else {
                phase = .failed("No suggestions in response")
                return
            }
            let suggestions: [Suggestion] = rawSugs.compactMap { d in
                guard let label = d["label"] as? String else { return nil }
                return Suggestion(
                    label:       label,
                    beat:        d["beat"]        as? Double,
                    timeString:  d["time_string"] as? String,
                    confidence:  (d["confidence"] as? Double) ?? 0.0,
                    needsManual: (d["needs_manual"] as? Bool) ?? true
                )
            }
            phase = .done(suggestions)
        }
    }

    /// Write `locators` into the .als at `alsPath`, replacing any existing locators.
    /// Calls `completion(success, newPath, errorMessage)` on the main actor.
    func writeLocators(alsPath: String,
                       locators: [(beat: Double, name: String)],
                       completion: @escaping (Bool, String?, String?) -> Void) {
        let locDicts: [[String: Any]] = locators.map { ["beat": $0.beat, "name": $0.name] }
        let cmd: [String: Any] = [
            "action":   "write_locators",
            "path":     alsPath,
            "locators": locDicts,
        ]
        guard let data   = try? JSONSerialization.data(withJSONObject: cmd),
              let cmdStr = String(data: data, encoding: .utf8) else {
            completion(false, nil, "Failed to encode command")
            return
        }
        Task {
            let output = await ParserService.runSend(command: cmdStr)
            guard let respData = output.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: respData)
                                   as? [String: Any] else {
                completion(false, nil, "Invalid response from parser")
                return
            }
            if let err = json["error"] as? String {
                completion(false, nil, err)
            } else if let newPath = json["new_path"] as? String {
                completion(true, newPath, nil)
            } else {
                completion(false, nil, "Unexpected response format")
            }
        }
    }

    /// Fetch lyrics text from a URL (Genius.com and other lyric sites).
    /// Calls `completion(text, errorMessage)` on the main actor.
    func fetchLyricsURL(_ url: String, completion: @escaping (String?, String?) -> Void) {
        let cmd: [String: Any] = ["action": "fetch_lyrics_url", "url": url]
        guard let data   = try? JSONSerialization.data(withJSONObject: cmd),
              let cmdStr = String(data: data, encoding: .utf8) else {
            completion(nil, "Failed to encode command")
            return
        }
        Task {
            let output = await ParserService.runSend(command: cmdStr)
            guard let respData = output.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: respData) as? [String: Any] else {
                completion(nil, "Invalid response from parser")
                return
            }
            if let err = json["error"] as? String {
                completion(nil, err)
            } else if let text = json["text"] as? String {
                completion(text, nil)
            } else {
                completion(nil, "No lyrics text returned")
            }
        }
    }

    func reset() { phase = .idle }
}
