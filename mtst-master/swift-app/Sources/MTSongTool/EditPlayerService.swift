import AVFoundation
import Accelerate
import Combine

// MARK: - AudioSegment

/// One independently-positioned piece of a stem's audio. `sessionStart` is absolute session time.
struct AudioSegment: Identifiable {
    var id: UUID = UUID()
    var sourceStart: Double     // seconds in the original file
    var sourceEnd: Double       // seconds in the original file
    var sessionStart: Double    // when this segment plays in the session timeline
    var sessionEnd: Double { sessionStart + (sourceEnd - sourceStart) }
}

// MARK: - StemState

struct StemState {
    var isMuted: Bool = false
    var isSoloed: Bool = false
    var gain: Float = 1.0          // live monitoring gain (non-destructive)
    var peaks: [Float] = []        // waveform peaks — 1 per 512 samples (~86/sec at 44.1kHz)
    var duration: Double = 0.0     // audio file duration in seconds
    var offset: Double = 0.0       // legacy nudge offset (used when segments is empty)
    var trimIn: Double = 0.0       // legacy trim in-point
    var trimOut: Double? = nil     // legacy trim out-point
    var cuts: [Double] = []        // legacy cut positions
    var segments: [AudioSegment] = []   // multi-segment model; populated after peaks load

    var hasEdits: Bool {
        gain != 1.0 || offset != 0.0 || trimIn != 0.0 ||
        trimOut != nil || !cuts.isEmpty
    }

    // MARK: Segment mutations

    mutating func initSegments(duration: Double) {
        segments = [AudioSegment(sourceStart: 0, sourceEnd: duration, sessionStart: 0)]
    }

    /// Splits the segment containing `sessionTime` at that point (no-op if time is at a boundary).
    mutating func splitSegment(atSession time: Double) {
        guard let idx = segments.firstIndex(where: {
            $0.sessionStart < time - 0.001 && $0.sessionEnd > time + 0.001
        }) else { return }
        let seg = segments[idx]
        let intoSeg = time - seg.sessionStart
        let splitSrc = seg.sourceStart + intoSeg
        let first  = AudioSegment(sourceStart: seg.sourceStart, sourceEnd: splitSrc,  sessionStart: seg.sessionStart)
        let second = AudioSegment(sourceStart: splitSrc,        sourceEnd: seg.sourceEnd, sessionStart: time)
        segments.remove(at: idx)
        segments.insert(contentsOf: [first, second], at: idx)
    }

    /// Silences (removes) the audio between `lo` and `hi` in session time, leaving a gap.
    mutating func deleteRegion(lo: Double, hi: Double) {
        splitSegment(atSession: lo)
        splitSegment(atSession: hi)
        segments.removeAll { $0.sessionStart >= lo - 0.001 && $0.sessionStart < hi - 0.001 }
    }

    /// Moves the audio region [lo, hi] so it starts at `newStart`, leaving a gap at the source.
    mutating func moveRegion(lo: Double, hi: Double, to newStart: Double) {
        splitSegment(atSession: lo)
        splitSegment(atSession: hi)
        guard let idx = segments.firstIndex(where: { abs($0.sessionStart - lo) < 0.01 }) else { return }
        segments[idx].sessionStart = max(0, newStart)
    }
}

// MARK: - EditPlayerService

@MainActor
class EditPlayerService: ObservableObject {
    @Published var isPlaying: Bool = false
    @Published var currentTime: Double = 0
    @Published var stemStates: [URL: StemState] = [:]
    @Published var masterPeakDB: Float = -96.0
    @Published var meterLevels: [URL: Float] = [:]   // per-stem peak dBFS — updated at ~43 Hz, separate from stemStates
    @Published var totalDuration: Double = 0
    /// Published whenever playback (re)starts — EditView observes this to re-anchor the metronome.
    @Published var playAnchor: PlayAnchor? = nil

    let engine = AVAudioEngine()   // internal — MetronomeService attaches its playerNode here
    private var playerNodes: [URL: AVAudioPlayerNode] = [:]
    private var stemMixers: [URL: AVAudioMixerNode] = [:]
    private var tapInstalled: [URL: Bool] = [:]
    private var engineStarted = false

    // Ordered stem list (for display)
    private(set) var stemURLs: [URL] = []

    // Time tracking — readable by MetronomeService to sync beat scheduling to same anchor
    private(set) var startHostTime: UInt64 = 0
    private(set) var startSessionTime: Double = 0
    private var timeTimer: Timer?

    // MARK: - Engine Setup

    private func startEngine() {
        guard !engineStarted else { return }
        do {
            try engine.start()
            engineStarted = true
        } catch {
            NSLog("[EditPlayer] Engine start failed: %@", error.localizedDescription)
        }
    }

    // MARK: - Load Stems

    func loadStems(_ urls: [URL]) {
        stop()
        teardownNodes()

        stemURLs = urls
        stemStates = [:]
        meterLevels = [:]
        totalDuration = 0

        for url in urls {
            let playerNode = AVAudioPlayerNode()
            let mixerNode = AVAudioMixerNode()

            engine.attach(playerNode)
            engine.attach(mixerNode)
            engine.connect(playerNode, to: mixerNode, format: nil)
            engine.connect(mixerNode, to: engine.mainMixerNode, format: nil)

            playerNodes[url] = playerNode
            stemMixers[url] = mixerNode

            var state = StemState()
            // Extract peaks asynchronously
            Task.detached(priority: .userInitiated) { [weak self] in
                let peaks = await Self.extractPeaks(from: url)
                let dur = await Self.fileDuration(url)
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    state.peaks = peaks
                    state.duration = dur
                    state.initSegments(duration: dur)
                    self.stemStates[url] = state
                    if dur > self.totalDuration { self.totalDuration = dur }
                }
            }

            stemStates[url] = state
        }

        startEngine()
        installMasterTap()
        for url in urls { installStemTap(url) }
    }

    private func teardownNodes() {
        engine.mainMixerNode.removeTap(onBus: 0)
        for (_, player) in playerNodes { engine.detach(player) }
        for (_, mixer) in stemMixers { engine.detach(mixer) }
        playerNodes = [:]
        stemMixers = [:]
        tapInstalled = [:]
        stemURLs = []
    }

    // MARK: - Transport

    func play() {
        guard !isPlaying, !stemURLs.isEmpty else { return }
        startPlayback(from: currentTime)
        isPlaying = true
        startTimeTimer()
    }

    func pause() {
        guard isPlaying else { return }
        for node in playerNodes.values { node.stop() }
        isPlaying = false
        timeTimer?.invalidate()
    }

    func stop() {
        isPlaying = false
        timeTimer?.invalidate()
        for node in playerNodes.values { node.stop() }
        currentTime = 0
    }

    func seek(to time: Double) {
        let wasPlaying = isPlaying
        timeTimer?.invalidate()
        for node in playerNodes.values { node.stop() }
        currentTime = time
        if wasPlaying {
            startPlayback(from: time)
            isPlaying = true
            startTimeTimer()
        }
    }

    /// Schedules all stems at a shared AVAudioTime anchor so they start sample-accurately together.
    private func startPlayback(from sessionTime: Double) {
        // Activate all nodes first (starts their internal clocks, no audio yet)
        for node in playerNodes.values { node.play() }

        // Pick a common start anchor 50ms in the future — enough for all nodes to be ready
        let anchorHostTime = ticksForSeconds(0.05) + mach_absolute_time()
        let soloActive = stemStates.values.contains { $0.isSoloed }

        for url in stemURLs {
            guard let player = playerNodes[url], let state = stemStates[url] else { continue }

            let effectiveMute = state.isMuted || (soloActive && !state.isSoloed)
            if let mixer = stemMixers[url] {
                mixer.outputVolume = effectiveMute ? 0 : state.gain
            }

            guard let audioFile = try? AVAudioFile(forReading: url) else { continue }
            let sampleRate = audioFile.processingFormat.sampleRate
            let format = audioFile.processingFormat

            if !state.segments.isEmpty {
                // Multi-segment path: schedule each segment with silence in gaps.
                let sorted = state.segments
                    .filter { $0.sessionEnd > sessionTime + 0.001 }
                    .sorted { $0.sessionStart < $1.sessionStart }

                var cursor = sessionTime
                var isFirst = true

                for segment in sorted {
                    let gapDuration = max(0, segment.sessionStart - cursor)

                    if gapDuration > 0.001 {
                        let frames = AVAudioFrameCount(gapDuration * sampleRate)
                        if let silentBuf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) {
                            silentBuf.frameLength = frames
                            if let ch = silentBuf.floatChannelData {
                                for c in 0..<Int(format.channelCount) {
                                    memset(ch[c], 0, Int(frames) * MemoryLayout<Float>.size)
                                }
                            }
                            if isFirst {
                                player.scheduleBuffer(silentBuf, at: AVAudioTime(hostTime: anchorHostTime))
                                isFirst = false
                            } else {
                                player.scheduleBuffer(silentBuf, at: nil)
                            }
                        }
                        cursor = segment.sessionStart
                    }

                    let intoSeg   = max(0, sessionTime - segment.sessionStart)
                    let srcStart  = segment.sourceStart + intoSeg
                    let startFrame = AVAudioFramePosition(srcStart * sampleRate)
                    let frameCount = AVAudioFrameCount((segment.sourceEnd - srcStart) * sampleRate)
                    guard frameCount > 0 else { cursor = segment.sessionEnd; continue }

                    if isFirst {
                        player.scheduleSegment(audioFile, startingFrame: startFrame,
                                               frameCount: frameCount,
                                               at: AVAudioTime(hostTime: anchorHostTime))
                        isFirst = false
                    } else {
                        player.scheduleSegment(audioFile, startingFrame: startFrame,
                                               frameCount: frameCount, at: nil)
                    }
                    cursor = segment.sessionEnd
                }
            } else {
                // Legacy path (segments not yet populated)
                if state.offset > 0 && sessionTime < state.offset {
                    let delay = state.offset - sessionTime
                    let when = AVAudioTime(hostTime: anchorHostTime + ticksForSeconds(delay))
                    player.scheduleSegment(audioFile, startingFrame: 0,
                                           frameCount: AVAudioFrameCount(audioFile.length),
                                           at: when)
                } else {
                    let fileStart = max(0, sessionTime - state.offset)
                    let startFrame = AVAudioFramePosition(fileStart * sampleRate)
                    let totalFrames = audioFile.length - startFrame
                    guard totalFrames > 0 else { continue }
                    player.scheduleSegment(audioFile, startingFrame: startFrame,
                                           frameCount: AVAudioFrameCount(totalFrames),
                                           at: AVAudioTime(hostTime: anchorHostTime))
                }
            }
        }

        // Publish anchor so EditView can re-sync the metronome on every play/seek.
        // AVAudioEngine scheduling is sample-accurate, so this hostTime is the real play time.
        playAnchor = PlayAnchor(hostTime: anchorHostTime, sessionTime: sessionTime)

        // Time tracking anchored to the same host time — timer guards against pre-roll
        startHostTime = anchorHostTime
        startSessionTime = sessionTime
    }

    private func startTimeTimer() {
        timeTimer?.invalidate()
        timeTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isPlaying else { return }
                let now = mach_absolute_time()
                guard now >= self.startHostTime else { return }  // pre-roll: audio hasn't started yet
                let elapsed = machTimeToSeconds(now - self.startHostTime)
                self.currentTime = self.startSessionTime + elapsed
            }
        }
    }

    // MARK: - Mute / Solo

    func setMuted(_ url: URL, _ muted: Bool) {
        stemStates[url]?.isMuted = muted
        applyMixerVolumes()
    }

    func setSoloed(_ url: URL, _ soloed: Bool) {
        stemStates[url]?.isSoloed = soloed
        applyMixerVolumes()
    }

    func clearAllMutes() {
        for url in stemURLs { stemStates[url]?.isMuted = false }
        applyMixerVolumes()
    }

    func clearAllSolos() {
        for url in stemURLs { stemStates[url]?.isSoloed = false }
        applyMixerVolumes()
    }

    func setMutedForURLs(_ urls: [URL], _ muted: Bool) {
        for url in urls { stemStates[url]?.isMuted = muted }
        applyMixerVolumes()
    }

    func setSoloedForURLs(_ urls: [URL], _ soloed: Bool) {
        for url in urls { stemStates[url]?.isSoloed = soloed }
        applyMixerVolumes()
    }

    private func applyMixerVolumes() {
        let soloActive = stemStates.values.contains { $0.isSoloed }
        for url in stemURLs {
            guard let mixer = stemMixers[url], let state = stemStates[url] else { continue }
            let effectiveMute = state.isMuted || (soloActive && !state.isSoloed)
            mixer.outputVolume = effectiveMute ? 0 : state.gain
        }
    }

    // MARK: - Gain

    func setGain(_ url: URL, _ gain: Float) {
        stemStates[url]?.gain = gain
        let soloActive = stemStates.values.contains { $0.isSoloed }
        if let mixer = stemMixers[url], let state = stemStates[url] {
            let effectiveMute = state.isMuted || (soloActive && !state.isSoloed)
            mixer.outputVolume = effectiveMute ? 0 : gain
        }
    }

    func setGainForSelected(_ urls: [URL], _ gain: Float) {
        for url in urls { setGain(url, gain) }
    }

    // MARK: - Edit State

    func setOffset(_ url: URL, _ offset: Double) {
        stemStates[url]?.offset = offset
    }

    func setTrimIn(_ url: URL, _ trimIn: Double) {
        stemStates[url]?.trimIn = max(0, trimIn)
    }

    func setTrimOut(_ url: URL, _ trimOut: Double?) {
        stemStates[url]?.trimOut = trimOut
    }

    func addCut(_ url: URL, at time: Double) {
        stemStates[url]?.cuts.append(time)
        stemStates[url]?.cuts.sort()
    }

    func removeCut(_ url: URL, at time: Double) {
        stemStates[url]?.cuts.removeAll { abs($0 - time) < 0.01 }
    }

    func deleteRegion(_ url: URL, lo: Double, hi: Double) {
        stemStates[url]?.deleteRegion(lo: lo, hi: hi)
    }

    func moveRegion(_ url: URL, lo: Double, hi: Double, to newStart: Double) {
        stemStates[url]?.moveRegion(lo: lo, hi: hi, to: newStart)
    }

    /// Shifts all segments of the given stem by `delta` seconds.
    func shiftAllSegments(_ url: URL, delta: Double) {
        guard var state = stemStates[url] else { return }
        for i in state.segments.indices {
            state.segments[i].sessionStart = max(0, state.segments[i].sessionStart + delta)
        }
        stemStates[url] = state
        // Grow totalDuration if this stem now ends past it — canvas extends automatically.
        let maxEnd = state.segments.map { $0.sessionEnd }.max() ?? 0
        if maxEnd > totalDuration { totalDuration = maxEnd }
    }

    var hasAnyEdits: Bool {
        stemStates.values.contains {
            $0.gain != 1.0 || $0.offset != 0.0 || $0.trimIn != 0.0 ||
            $0.trimOut != nil || !$0.cuts.isEmpty ||
            ($0.segments.count > 1) ||
            ($0.segments.first.map { $0.sessionStart != 0 } ?? false)
        }
    }

    // MARK: - Metering

    private func installMasterTap() {
        let masterMixer = engine.mainMixerNode
        let format = masterMixer.outputFormat(forBus: 0)
        masterMixer.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let channelData = buffer.floatChannelData else { return }
            var peak: Float = 0
            for ch in 0..<Int(buffer.format.channelCount) {
                var channelPeak: Float = 0
                vDSP_maxmgv(channelData[ch], 1, &channelPeak, vDSP_Length(buffer.frameLength))
                peak = max(peak, channelPeak)
            }
            let db = peak > 0 ? 20 * log10(peak) : -96.0
            Task { @MainActor [weak self] in self?.masterPeakDB = db }
        }
    }

    func installStemTap(_ url: URL) {
        guard let mixer = stemMixers[url], tapInstalled[url] != true else { return }
        let format = mixer.outputFormat(forBus: 0)
        mixer.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self, url] buffer, _ in
            guard let channelData = buffer.floatChannelData else { return }
            var peak: Float = 0
            for ch in 0..<Int(buffer.format.channelCount) {
                var channelPeak: Float = 0
                vDSP_maxmgv(channelData[ch], 1, &channelPeak, vDSP_Length(buffer.frameLength))
                peak = max(peak, channelPeak)
            }
            let db = peak > 0 ? 20 * log10(peak) : -96.0
            Task { @MainActor [weak self] in self?.meterLevels[url] = db }
        }
        tapInstalled[url] = true
    }

    // MARK: - Peak Extraction

    private static func extractPeaks(from url: URL) async -> [Float] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                guard let file = try? AVAudioFile(forReading: url) else {
                    continuation.resume(returning: [])
                    return
                }
                let frameCount = AVAudioFrameCount(file.length)
                guard frameCount > 0,
                      let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frameCount),
                      (try? file.read(into: buffer)) != nil,
                      let channelData = buffer.floatChannelData else {
                    continuation.resume(returning: [])
                    return
                }
                let frames = Int(buffer.frameLength)
                let channels = Int(buffer.format.channelCount)
                // 512 samples/peak ≈ 11.6ms each at 44.1kHz — ~86 peaks/sec.
                // Capped at 200K (covers ~38 min files). This is ~8× more detail than
                // the old fixed-2000 approach for a typical 3-min stem.
                let step = 512
                let count = min(200_000, max(1, Int(ceil(Double(frames) / Double(step)))))
                var peaks = [Float](repeating: 0, count: count)
                for i in 0..<count {
                    let start = i * step
                    let end = min(start + step, frames)
                    var peak: Float = 0
                    for ch in 0..<channels {
                        var chPeak: Float = 0
                        vDSP_maxmgv(channelData[ch].advanced(by: start), 1, &chPeak, vDSP_Length(end - start))
                        peak = max(peak, chPeak)
                    }
                    peaks[i] = peak
                }
                continuation.resume(returning: peaks)
            }
        }
    }

    private static func fileDuration(_ url: URL) async -> Double {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let asset = AVURLAsset(url: url)
                let duration = CMTimeGetSeconds(asset.duration)
                continuation.resume(returning: duration)
            }
        }
    }

    // MARK: - Helpers

    /// Converts seconds to mach_absolute_time ticks (does not add current time).
    private func ticksForSeconds(_ seconds: Double) -> UInt64 {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        let nanos = UInt64(seconds * 1_000_000_000)
        return nanos * UInt64(info.denom) / UInt64(info.numer)
    }
}

private func machTimeToSeconds(_ elapsed: UInt64) -> Double {
    var info = mach_timebase_info_data_t()
    mach_timebase_info(&info)
    let nanos = Double(elapsed) * Double(info.numer) / Double(info.denom)
    return nanos / 1_000_000_000
}
