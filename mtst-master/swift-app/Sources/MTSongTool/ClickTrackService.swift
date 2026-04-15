import Foundation
import AVFoundation

// MARK: - Click Track Generator Service

/// Generates a click track preview to a temp file, then finalizes it on export.
/// Lives as a @StateObject inside EditView so it survives re-renders.
@MainActor
final class ClickTrackService: ObservableObject {

    enum Phase: Equatable {
        case idle
        case generating
        case ready           // preview WAV written to previewURL
        case failed(String)
    }

    @Published var phase: Phase = .idle
    /// URL of the temp preview WAV (nil until first successful generation).
    @Published var previewURL: URL?
    @Published var isPlayingPreview: Bool = false

    private var previewPlayer: AVPlayer?
    private var playerEndObserver: Any?

    // MARK: - Preview Generation

    /// Generate a click track to a temp file. Called automatically on BPM / time sig changes.
    func generatePreview(
        bpm: Double,
        timeSig: String,
        durationSeconds: Double,
        tempoEvents: [TempoEvent]
    ) {
        phase = .generating
        stopPreview()

        // Use a UUID subdirectory so the filename is "CLICK TRACK.wav" (used for sorting/display)
        let tmpSubdir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mtst-click-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tmpSubdir, withIntermediateDirectories: true)
        let outputPath = tmpSubdir.appendingPathComponent("CLICK TRACK.wav").path

        var cmd: [String: Any] = [
            "action":           "generate_click_track",
            "output_path":      outputPath,
            "bpm":              bpm,
            "time_sig":         timeSig,
            "duration_seconds": durationSeconds,
        ]
        if !tempoEvents.isEmpty {
            cmd["tempo_events"] = tempoEvents.map { ["beat": $0.beat, "bpm": $0.bpm] }
        }
        guard let data   = try? JSONSerialization.data(withJSONObject: cmd),
              let cmdStr = String(data: data, encoding: .utf8) else {
            phase = .failed("Failed to encode command")
            return
        }
        Task {
            let output = await ParserService.runSend(command: cmdStr)
            guard let respData = output.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: respData) as? [String: Any] else {
                phase = .failed("Invalid response from parser")
                return
            }
            if let err = json["error"] as? String {
                phase = .failed(err)
            } else if json["path"] != nil {
                previewURL = URL(fileURLWithPath: outputPath)
                phase = .ready
            } else {
                phase = .failed("Unexpected response")
            }
        }
    }

    // MARK: - Preview Playback

    func playPreview() {
        guard let url = previewURL else { return }
        stopPreview()
        let player = AVPlayer(url: url)
        previewPlayer = player
        isPlayingPreview = true
        playerEndObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: player.currentItem,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.isPlayingPreview = false
                self?.previewPlayer = nil
            }
        }
        player.play()
    }

    func stopPreview() {
        previewPlayer?.pause()
        previewPlayer = nil
        if let obs = playerEndObserver {
            NotificationCenter.default.removeObserver(obs)
            playerEndObserver = nil
        }
        isPlayingPreview = false
    }

    // MARK: - Reset

    func reset() {
        stopPreview()
        previewURL = nil
        phase = .idle
    }
}
