import AVFoundation
import Accelerate
import Combine

// MARK: - MeterAtom

/// Lock-free Float storage for audio-thread → main-thread meter updates.
/// Float read/write is a single aligned instruction on ARM64 and x86_64 — safe without locks.
private final class MeterAtom: @unchecked Sendable {
    var value: Float = -96.0
}

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
    var isExcluded: Bool = false   // stem hidden from timeline and omitted from export
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

// MARK: - Session model

struct LocatorOverride {
    var name: String?
    var beat: Double?
}

@MainActor
class EditPlayerService: ObservableObject {
    @Published var isPlaying: Bool = false
    @Published var currentTime: Double = 0
    @Published var stemStates: [URL: StemState] = [:]
    @Published var masterPeakDB: Float = -96.0
    @Published var meterLevels: [URL: Float] = [:]   // per-stem peak dBFS — updated at ~43 Hz, separate from stemStates
    @Published var totalDuration: Double = 0
    @Published var isNormalizing: Bool = false
    /// Published whenever playback (re)starts — EditView observes this to re-anchor the metronome.
    @Published var playAnchor: PlayAnchor? = nil

    // MARK: - Session state
    @Published var locatorOverrides: [String: LocatorOverride] = [:]
    @Published var isSessionDirty: Bool = false

    func moveLocator(alsId: String, toBeat beat: Double) {
        var override = locatorOverrides[alsId] ?? LocatorOverride()
        override.beat = beat
        locatorOverrides[alsId] = override
        isSessionDirty = true
    }

    func renameLocator(alsId: String, to name: String) {
        var override = locatorOverrides[alsId] ?? LocatorOverride()
        override.name = name
        locatorOverrides[alsId] = override
        isSessionDirty = true
    }

    func clearSession() {
        locatorOverrides = [:]
        isSessionDirty = false
    }

    // MARK: - Undo / Redo
    @Published var canUndo: Bool = false
    @Published var canRedo: Bool = false
    private var undoStack: [[URL: StemState]] = []
    private var redoStack: [[URL: StemState]] = []
    private let maxUndoSteps = 30

    /// Call before any mutating edit operation to save a restorable snapshot.
    func saveUndoSnapshot() {
        undoStack.append(stemStates)
        if undoStack.count > maxUndoSteps { undoStack.removeFirst() }
        redoStack = []
        canUndo = true
        canRedo = false
    }

    func undo() {
        guard let snapshot = undoStack.popLast() else { return }
        if isPlaying { stop() }
        redoStack.append(stemStates)
        stemStates = snapshot
        canUndo = !undoStack.isEmpty
        canRedo = true
    }

    func redo() {
        guard let snapshot = redoStack.popLast() else { return }
        if isPlaying { stop() }
        undoStack.append(stemStates)
        stemStates = snapshot
        canUndo = true
        canRedo = !redoStack.isEmpty
    }

    let engine = AVAudioEngine()   // internal — MetronomeService attaches its playerNode here
    private var playerNodes: [URL: AVAudioPlayerNode] = [:]
    private var stemMixers: [URL: AVAudioMixerNode] = [:]
    private var tapInstalled: [URL: Bool] = [:]
    private var engineStarted = false

    // Atomic meter storage — audio tap writes here (no alloc), timer batch-reads to meterLevels
    private var meterAtomics: [URL: MeterAtom] = [:]
    private let masterAtom = MeterAtom()

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
        meterAtomics = Dictionary(uniqueKeysWithValues: urls.map { ($0, MeterAtom()) })
        masterAtom.value = -96.0
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
        meterAtomics = [:]
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
        // 60 Hz — matches display refresh. Single Task per tick batches time + all meter reads
        // into one SwiftUI update, replacing the old N*43 Hz audio-thread Task allocations.
        timeTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isPlaying else { return }
                let now = mach_absolute_time()
                guard now >= self.startHostTime else { return }
                let elapsed = machTimeToSeconds(now - self.startHostTime)
                self.currentTime = self.startSessionTime + elapsed
                // Batch-read atomic meter values written by audio tap — one publish per frame
                var levels = [URL: Float]()
                for (url, atom) in self.meterAtomics { levels[url] = atom.value }
                self.meterLevels = levels
                self.masterPeakDB = self.masterAtom.value
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
            let effectiveMute = state.isExcluded || state.isMuted || (soloActive && !state.isSoloed)
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

    func removeStem(_ url: URL) {
        saveUndoSnapshot()
        stemStates[url]?.isExcluded = true
        applyMixerVolumes()
    }

    func moveRegion(_ url: URL, lo: Double, hi: Double, to newStart: Double) {
        stemStates[url]?.moveRegion(lo: lo, hi: hi, to: newStart)
    }

    // MARK: - Trim

    /// Trims the left (start) edge of a specific segment — moves sessionStart + sourceStart by delta.
    func trimSegmentLeft(id: UUID, delta: Double) {
        guard let url = stemURLs.first(where: { stemStates[$0]?.segments.contains(where: { $0.id == id }) == true }),
              var state = stemStates[url],
              let idx = state.segments.firstIndex(where: { $0.id == id }) else { return }
        let seg = state.segments[idx]
        let newSourceStart = max(0, seg.sourceStart + delta)
        let newSessionStart = max(0, seg.sessionStart + delta)
        guard newSourceStart < seg.sourceEnd - 0.01 else { return }
        state.segments[idx].sourceStart = newSourceStart
        state.segments[idx].sessionStart = newSessionStart
        stemStates[url] = state
    }

    /// Trims the right (end) edge of a specific segment — moves sourceEnd by delta.
    func trimSegmentRight(id: UUID, delta: Double) {
        guard let url = stemURLs.first(where: { stemStates[$0]?.segments.contains(where: { $0.id == id }) == true }),
              var state = stemStates[url],
              let idx = state.segments.firstIndex(where: { $0.id == id }) else { return }
        let seg = state.segments[idx]
        let newSourceEnd = min(state.duration, seg.sourceEnd + delta)
        guard newSourceEnd > seg.sourceStart + 0.01 else { return }
        state.segments[idx].sourceEnd = newSourceEnd
        stemStates[url] = state
    }

    /// Trims the left edge of every segment whose ID is in `ids` — for multi-clip simultaneous trim.
    func trimSegmentsLeft(ids: Set<UUID>, delta: Double) {
        for url in stemURLs {
            guard var state = stemStates[url] else { continue }
            var changed = false
            for idx in state.segments.indices {
                guard ids.contains(state.segments[idx].id) else { continue }
                let seg = state.segments[idx]
                let newSourceStart = max(0, seg.sourceStart + delta)
                let newSessionStart = max(0, seg.sessionStart + delta)
                guard newSourceStart < seg.sourceEnd - 0.01 else { continue }
                state.segments[idx].sourceStart = newSourceStart
                state.segments[idx].sessionStart = newSessionStart
                changed = true
            }
            if changed { stemStates[url] = state }
        }
    }

    /// Trims the right edge of every segment whose ID is in `ids` — for multi-clip simultaneous trim.
    func trimSegmentsRight(ids: Set<UUID>, delta: Double) {
        for url in stemURLs {
            guard var state = stemStates[url] else { continue }
            var changed = false
            for idx in state.segments.indices {
                guard ids.contains(state.segments[idx].id) else { continue }
                let seg = state.segments[idx]
                let newSourceEnd = min(state.duration, seg.sourceEnd + delta)
                guard newSourceEnd > seg.sourceStart + 0.01 else { continue }
                state.segments[idx].sourceEnd = newSourceEnd
                changed = true
            }
            if changed { stemStates[url] = state }
        }
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
        masterMixer.installTap(onBus: 0, bufferSize: 1024, format: format) { [masterAtom] buffer, _ in
            guard let channelData = buffer.floatChannelData else { return }
            var peak: Float = 0
            for ch in 0..<Int(buffer.format.channelCount) {
                var channelPeak: Float = 0
                vDSP_maxmgv(channelData[ch], 1, &channelPeak, vDSP_Length(buffer.frameLength))
                peak = max(peak, channelPeak)
            }
            // Write directly — Float assignment is atomic on ARM64/x86_64. No Task alloc.
            masterAtom.value = peak > 0 ? 20 * log10(peak) : -96.0
        }
    }

    func installStemTap(_ url: URL) {
        guard let mixer = stemMixers[url], tapInstalled[url] != true else { return }
        guard let atom = meterAtomics[url] else { return }
        let format = mixer.outputFormat(forBus: 0)
        mixer.installTap(onBus: 0, bufferSize: 1024, format: format) { [atom] buffer, _ in
            guard let channelData = buffer.floatChannelData else { return }
            var peak: Float = 0
            for ch in 0..<Int(buffer.format.channelCount) {
                var channelPeak: Float = 0
                vDSP_maxmgv(channelData[ch], 1, &channelPeak, vDSP_Length(buffer.frameLength))
                peak = max(peak, channelPeak)
            }
            // Write directly — Float assignment is atomic on ARM64/x86_64. No Task alloc.
            atom.value = peak > 0 ? 20 * log10(peak) : -96.0
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

    // MARK: - Normalization

    /// Stems excluded from collective normalization (reference / fixed-level stems).
    private static let lockedStemNames: Set<String> = ["CLICK TRACK", "GUIDE", "ORIGINAL SONG"]

    private var collectiveURLs: [URL] {
        stemURLs.filter { url in
            let name = url.deletingPathExtension().lastPathComponent.uppercased()
            return !Self.lockedStemNames.contains(name)
        }
    }

    var hasCollectiveStems: Bool { !collectiveURLs.isEmpty }

    /// Scans the mixed collective stems for true peak using 4x oversampling.
    /// Uses streaming AVAudioConverter so the polyphase FIR filter state stays warm across chunks.
    /// Returns linear peak amplitude (not dB).
    private static func scanCollectiveMixTruePeak(urls: [URL], gains: [URL: Float]) async -> Float {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let chunkFrames = AVAudioFrameCount(4096)
                let oversampleFactor = 4

                // Open all files; use format of first file as mix format.
                let files = urls.compactMap { try? AVAudioFile(forReading: $0) }
                guard let firstFile = files.first else { continuation.resume(returning: 0); return }

                let srcFormat = firstFile.processingFormat
                let sampleRate = srcFormat.sampleRate
                let channelCount = srcFormat.channelCount

                guard let dstFormat = AVAudioFormat(
                    standardFormatWithSampleRate: sampleRate * Double(oversampleFactor),
                    channels: channelCount
                ) else { continuation.resume(returning: 0); return }

                guard let converter = AVAudioConverter(from: srcFormat, to: dstFormat) else {
                    continuation.resume(returning: 0); return
                }

                let dstCapacity = chunkFrames * AVAudioFrameCount(oversampleFactor)
                guard let dstChunk = AVAudioPCMBuffer(pcmFormat: dstFormat, frameCapacity: dstCapacity),
                      let mixChunk = AVAudioPCMBuffer(pcmFormat: srcFormat, frameCapacity: chunkFrames)
                else { continuation.resume(returning: 0); return }

                let totalFrames = Int64(firstFile.length)
                var framesProcessed = Int64(0)
                var allTimePeak: Float = 0

                // Streaming convert: single converter instance, .endOfStream only when exhausted.
                while true {
                    dstChunk.frameLength = 0
                    var convError: NSError?
                    let status = converter.convert(to: dstChunk, error: &convError) { _, outStatus in
                        guard framesProcessed < totalFrames else {
                            outStatus.pointee = .endOfStream
                            return nil
                        }
                        let toProcess = AVAudioFrameCount(min(Int64(chunkFrames), totalFrames - framesProcessed))

                        // Zero mix buffer
                        mixChunk.frameLength = toProcess
                        if let ch = mixChunk.floatChannelData {
                            for c in 0..<Int(channelCount) {
                                vDSP_vclr(ch[c], 1, vDSP_Length(toProcess))
                            }
                        }

                        // Accumulate each stem (gain-scaled) into mix buffer
                        for (file, url) in zip(files, urls) {
                            let gain = gains[url] ?? 1.0
                            let framePos = Int64(Double(framesProcessed) * (file.processingFormat.sampleRate / srcFormat.sampleRate))
                            if let readBuf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: toProcess) {
                                file.framePosition = framePos
                                _ = try? file.read(into: readBuf, frameCount: toProcess)
                                if let src = readBuf.floatChannelData, let dst = mixChunk.floatChannelData {
                                    for c in 0..<Int(channelCount) {
                                        var g = gain
                                        vDSP_vsma(src[c], 1, &g, dst[c], 1, dst[c], 1, vDSP_Length(toProcess))
                                    }
                                }
                            }
                        }

                        framesProcessed += Int64(toProcess)
                        outStatus.pointee = .haveData
                        return mixChunk
                    }

                    // Measure peak of this upsampled chunk
                    if let ch = dstChunk.floatChannelData {
                        for c in 0..<Int(dstChunk.format.channelCount) {
                            var peak: Float = 0
                            vDSP_maxmgv(ch[c], 1, &peak, vDSP_Length(dstChunk.frameLength))
                            allTimePeak = max(allTimePeak, peak)
                        }
                    }

                    if status != .haveData { break }
                }

                continuation.resume(returning: allTimePeak)
            }
        }
    }

    /// Normalizes collective stems to −0.01 dBFS true peak and ORIGINAL SONG to −6 dBFS from file peak.
    func normalizeStems() {
        guard !isNormalizing else { return }
        let urls = collectiveURLs
        guard !urls.isEmpty else { return }

        isNormalizing = true
        let currentGains = stemURLs.reduce(into: [URL: Float]()) { $0[$1] = stemStates[$1]?.gain ?? 1.0 }

        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            let peak = await Self.scanCollectiveMixTruePeak(urls: urls, gains: currentGains)

            await MainActor.run { [weak self] in
                guard let self else { return }
                if peak > 0 {
                    let targetLinear: Float = pow(10, -0.01 / 20)   // −0.01 dBFS
                    let multiplier = targetLinear / peak
                    for url in urls {
                        let newGain = (self.stemStates[url]?.gain ?? 1.0) * multiplier
                        self.setGain(url, newGain)
                    }
                }

                // Normalize ORIGINAL SONG to −6 dBFS from raw file peak
                let ogName = "ORIGINAL SONG"
                if let ogURL = self.stemURLs.first(where: {
                    $0.deletingPathExtension().lastPathComponent.uppercased() == ogName
                }), let ogPeaks = self.stemStates[ogURL]?.peaks, let filePeak = ogPeaks.max(), filePeak > 0 {
                    let ogTarget: Float = pow(10, -6.0 / 20)
                    let ogMultiplier = ogTarget / filePeak
                    self.setGain(ogURL, (self.stemStates[ogURL]?.gain ?? 1.0) * ogMultiplier)
                }

                self.isNormalizing = false
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
