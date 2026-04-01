import Foundation
import AVFoundation

struct PlayAnchor: Equatable {
    let hostTime: UInt64
    let sessionTime: Double
}

class StemPlayerService: ObservableObject {
    @Published var playingStemURL: URL? = nil
    @Published var isPlaying: Bool = false
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    @Published var volume: Float = 1.0 {
        didSet { player.volume = volume }
    }
    @Published var activeSectionStart: Double? = nil
    @Published var activeSectionEnd: Double? = nil
    @Published var isLooping: Bool = false
    /// Published when AVPlayer is confirmed playing at a position; ContentView uses this to
    /// anchor the metronome precisely instead of guessing startup/seek latency.
    @Published var playAnchor: PlayAnchor? = nil

    private var player: AVPlayer = AVPlayer()
    private var timeObserver: Any? = nil
    private var endObserver: NSObjectProtocol? = nil
    private var syncObserver: Any? = nil

    // MARK: - Anchor helpers

    private func ticksForSeconds(_ seconds: Double) -> UInt64 {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return UInt64(seconds * 1_000_000_000) * UInt64(info.denom) / UInt64(info.numer)
    }

    private func removeSyncObserver() {
        if let obs = syncObserver { player.removeTimeObserver(obs); syncObserver = nil }
    }

    /// Installs a one-shot boundary observer 1 ms past `startSessionTime`. When AVPlayer
    /// crosses it, samples mach_absolute_time() and player.currentTime() to compute a
    /// real anchor, then publishes `playAnchor` for ContentView to pass to the metronome.
    private func installBoundaryAnchor(startSessionTime: Double) {
        removeSyncObserver()
        let boundary = CMTime(seconds: startSessionTime + 0.001, preferredTimescale: 44100)
        syncObserver = player.addBoundaryTimeObserver(
            forTimes: [NSValue(time: boundary)], queue: .main
        ) { [weak self] in
            guard let self else { return }
            let hostNow = mach_absolute_time()
            let avNow   = self.player.currentTime().seconds
            let delta   = max(0.0, avNow - startSessionTime)
            self.playAnchor = PlayAnchor(
                hostTime: hostNow - self.ticksForSeconds(delta),
                sessionTime: startSessionTime
            )
            self.removeSyncObserver()
        }
    }

    private func teardownPlayer() {
        player.pause()
        removeSyncObserver()
        if let obs = timeObserver { player.removeTimeObserver(obs); timeObserver = nil }
        if let obs = endObserver { NotificationCenter.default.removeObserver(obs); endObserver = nil }
        player.replaceCurrentItem(with: nil)
        playingStemURL = nil
        playAnchor = nil
        isPlaying = false
        currentTime = 0
        duration = 0
        volume = 1.0
    }

    func play(url: URL) {
        Log("play — \(url.lastPathComponent)", "StemPlayer")
        // Tear down previous item (preserves section state)
        teardownPlayer()

        let item = AVPlayerItem(url: url)
        player.replaceCurrentItem(with: item)
        player.volume = 1.0

        // Read duration once item is ready
        Task { @MainActor in
            // Wait briefly for asset to load duration
            let asset = item.asset
            do {
                let dur = try await asset.load(.duration)
                self.duration = dur.seconds.isFinite ? dur.seconds : 0
            } catch {
                self.duration = 0
            }
        }

        // Periodic time observer — 10 Hz
        let interval = CMTime(seconds: 0.1, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self else { return }
            self.currentTime = time.seconds
            if self.isLooping, let end = self.activeSectionEnd, let start = self.activeSectionStart,
               time.seconds >= end {
                self.seek(to: start)
            }
        }

        // End-of-file observer
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            self?.isPlaying = false
        }

        playingStemURL = url
        volume = 1.0
        currentTime = 0
        player.seek(to: .zero)
        player.play()
        installBoundaryAnchor(startSessionTime: 0)
        isPlaying = true
        Log("play — isPlaying=true, url=\(url.lastPathComponent)", "StemPlayer")
    }

    func togglePause() {
        guard playingStemURL != nil else { return }
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            player.play()
            isPlaying = true
        }
    }

    func seek(to seconds: Double) {
        currentTime = seconds  // optimistic update — prevents slingshot on binding switch
        let time = CMTime(seconds: seconds, preferredTimescale: 600)
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
        if isPlaying { installBoundaryAnchor(startSessionTime: seconds) }
    }

    func playSection(url: URL, start: Double, end: Double, knownDuration: Double = 0) {
        // Set section state BEFORE play() publishes playingStemURL so the waveform
        // renders in section mode from the very first frame (no gray flash).
        activeSectionStart = start
        activeSectionEnd = end
        isLooping = true
        play(url: url)
        // teardownPlayer() inside play() resets duration = 0. Restore it synchronously
        // so SwiftUI's next render sees totalDuration > 0 and draws section mode immediately.
        if knownDuration > 0 { duration = knownDuration }
        seek(to: start)
    }

    func stop() {
        Log("stop()", "StemPlayer")
        teardownPlayer()
        activeSectionStart = nil
        activeSectionEnd = nil
        isLooping = false
    }

    func exitSectionMode() {
        activeSectionStart = nil
        activeSectionEnd = nil
        isLooping = false
    }

    deinit {
        if let obs = syncObserver  { player.removeTimeObserver(obs) }
        if let obs = timeObserver  { player.removeTimeObserver(obs) }
        if let obs = endObserver   { NotificationCenter.default.removeObserver(obs) }
    }
}
