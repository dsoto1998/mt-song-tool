import AVFoundation
import Accelerate
import Combine
import SwiftUI

// MARK: - Types

enum MetronomeSubdivision: String, CaseIterable, Identifiable {
    case quarters = "4th's"
    case eighths  = "8th's"
    var id: String { rawValue }
    var label: String { rawValue }
}

struct BeatInfo {
    let timeSeconds: Double
    let bar: Int
    let beat: Int       // 1-based within bar
    let isDownbeat: Bool
    var isSubdivisionTick: Bool = false   // true for eighth-note "and" positions
    var isSecondaryAccent: Bool = false   // true for group-downbeat beats (e.g. beat 4 in 6/8, beat 3 in 4/4)
    var absoluteBeat: Double = 0          // Ableton beat position (cumulative from session start)
}

// MARK: - MetronomeService

@MainActor
class MetronomeService: ObservableObject {
    @Published var isPlaying: Bool = false
    @Published var bar: Int = 1
    @Published var beat: Int = 1
    @Published var isDownbeat: Bool = false
    @Published var beatFlash: Bool = false
    @Published var volume: Float = 0.7
    @Published var subdivision: MetronomeSubdivision = .quarters
    @Published var isMuted: Bool = false

    // Beat schedule computed from the parsed tempo map + time signatures
    @Published var beatSchedule: [BeatInfo] = []

    // Audio engine — own engine used for QA tab; edit engine used for Edit tab (sample-accurate)
    private let ownEngine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let gainNode = AVAudioMixerNode()
    private var clickBuffer: AVAudioPCMBuffer?            // downbeat: full volume
    private var downbeatBuffer: AVAudioPCMBuffer?         // same as clickBuffer
    private var mediumAccentBuffer: AVAudioPCMBuffer?     // scaled to 75% for secondary group accents (e.g. beat 4 in 6/8)
    private var subdivisionBuffer: AVAudioPCMBuffer?      // scaled to 60% for off-beat quarter notes
    private var subdivisionTickBuffer: AVAudioPCMBuffer?  // scaled to 35% for eighth-note ticks
    private var loadedBufferFormat: AVAudioFormat?        // set by loadSounds(); used for engine connections

    // Cached build params — used to rebuild schedule on subdivision change
    private var cachedBuildParams: (tempoEvents: [TempoEvent], timeSigs: [TimeSig], totalDuration: Double, staticBPM: Double?)?
    private var engineStarted = false
    private var isAttachedToExternalEngine = false

    // Playback anchor — set when scheduling; used by beat tracker for accurate display
    private var playbackAnchorHostTime: UInt64 = 0
    private var playbackAnchorSessionTime: Double = 0

    // Beat tracker timer
    private var beatTracker: Timer?

    // MARK: - Engine Setup

    /// Attach the metronome's playerNode to an external engine (EditPlayerService.engine).
    /// After this call, the metronome shares the edit engine's render cycle — sample-accurate.
    /// Safe to call multiple times; no-op if already attached.
    func attachToEngine(_ engine: AVAudioEngine) {
        guard !isAttachedToExternalEngine else { return }
        if engineStarted {
            ownEngine.detach(playerNode)
            ownEngine.detach(gainNode)
        }
        // Load sounds first if not yet loaded, so we have a format to connect with.
        // AVAudioPlayerNode requires buffer format == connection format; nil picks
        // hardware (stereo) which breaks if click files are mono.
        if loadedBufferFormat == nil { loadSounds() }
        engine.attach(playerNode)
        engine.attach(gainNode)
        engine.connect(playerNode, to: gainNode, format: loadedBufferFormat)
        engine.connect(gainNode, to: engine.mainMixerNode, format: loadedBufferFormat)
        gainNode.outputVolume = isMuted ? 0 : volume
        isAttachedToExternalEngine = true
        Log("attachToEngine — playerNode moved to external engine, format=\(loadedBufferFormat?.description ?? "nil")", "Metronome")
    }

    /// Returns true if the own engine is running and ready to play.
    /// `format` must match the buffer format used in scheduleBuffer — mismatches throw.
    @discardableResult
    private func startOwnEngine(format: AVAudioFormat? = nil) -> Bool {
        guard !isAttachedToExternalEngine else { return true }
        if engineStarted { return ownEngine.isRunning }
        Log("startOwnEngine — attaching playerNode, format=\(format?.description ?? "nil")", "Metronome")
        ownEngine.attach(playerNode)
        ownEngine.attach(gainNode)
        ownEngine.connect(playerNode, to: gainNode, format: format)
        ownEngine.connect(gainNode, to: ownEngine.mainMixerNode, format: format)
        do {
            try ownEngine.start()
            engineStarted = true
            gainNode.outputVolume = isMuted ? 0 : volume
            Log("startOwnEngine — engine started OK", "Metronome")
            return true
        } catch {
            Log("startOwnEngine — FAILED to start engine: \(error.localizedDescription)", "Metronome")
            return false
        }
    }

    // MARK: - Sound Loading

    /// Synthesizes a short 880 Hz sine beep with exponential decay.
    /// Called at play time and whenever volume changes.
    func loadSounds() {
        let sampleRate: Double = 44100
        let frameCount = AVAudioFrameCount(sampleRate * 0.025)   // 25 ms
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return }
        buffer.frameLength = frameCount
        let data = buffer.floatChannelData![0]
        for i in 0..<Int(frameCount) {
            let t = Double(i) / sampleRate
            let env = exp(-t / 0.006)   // ~6 ms decay
            data[i] = Float(env * sin(2 * .pi * 880 * t)) * 4.0  // +12 dB headroom; volume applied via gainNode
        }

        clickBuffer           = buffer
        downbeatBuffer        = buffer
        subdivisionBuffer     = applyVolume(0.6,  to: buffer) ?? buffer
        subdivisionTickBuffer = applyVolume(0.35, to: buffer) ?? buffer
        mediumAccentBuffer    = applyVolume(0.75, to: buffer) ?? buffer
        loadedBufferFormat    = buffer.format
        gainNode.outputVolume = isMuted ? 0 : volume   // real-time volume control
        Log("loadSounds — 880 Hz beep, volume=\(String(format: "%.2f", volume))", "Metronome")
    }

    /// Returns a new AVAudioPCMBuffer with all samples scaled by `gain`.
    private func applyVolume(_ gain: Float, to source: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let dest = source.copy() as? AVAudioPCMBuffer,
              let data = dest.floatChannelData else { return nil }
        var g = gain
        for ch in 0..<Int(dest.format.channelCount) {
            vDSP_vsmul(data[ch], 1, &g, data[ch], 1, vDSP_Length(dest.frameLength))
        }
        return dest
    }

    // MARK: - Beat Schedule

    /// Build the full beat schedule from tempo events and time signatures.
    func buildSchedule(tempoEvents: [TempoEvent], timeSigs: [TimeSig], totalDuration: Double, staticBPM: Double? = nil) {
        cachedBuildParams = (tempoEvents, timeSigs, totalDuration, staticBPM)
        Log("buildSchedule — tempoEvents=\(tempoEvents.count) timeSigs=\(timeSigs.count) totalDuration=\(String(format: "%.2f", totalDuration))s staticBPM=\(staticBPM.map { String($0) } ?? "nil")", "Metronome")
        guard totalDuration > 0 else { beatSchedule = []; Log("buildSchedule — skipped: totalDuration=0", "Metronome"); return }

        var parsedTimeSigs: [(beat: Double, num: Int, den: Int)] = []
        for ts in timeSigs {
            guard let (num, den) = parseTimeSigString(ts.sig) else { continue }
            let beatPos = ts.beat ?? {
                // Fallback for legacy data without beat positions: convert time to approximate beat
                guard let secs = timeSigTimeToSeconds(ts.time), secs > 0 else { return 0.0 }
                return secs  // imprecise fallback; only used if parser doesn't send beat field
            }()
            parsedTimeSigs.append((beatPos, num, den))
        }
        if parsedTimeSigs.isEmpty { parsedTimeSigs = [(0.0, 4, 4)] }
        parsedTimeSigs.sort { $0.beat < $1.beat }

        var effectiveTempoEvents = tempoEvents
        if effectiveTempoEvents.isEmpty, let bpm = staticBPM, bpm > 0 {
            Log("buildSchedule — no tempo events; using staticBPM=\(bpm)", "Metronome")
            effectiveTempoEvents = [TempoEvent(beat: 0, bpm: bpm, time: "00:00:000")]
        }
        // Stable sort preserving XML order for equal beat positions, then
        // deduplicate step changes (two events at the same beat) by keeping only
        // the last event — which is Ableton's "new BPM" for that position.
        let sortedTempo: [TempoEvent] = {
            let indexed = effectiveTempoEvents.enumerated().sorted {
                $0.element.beat != $1.element.beat
                    ? $0.element.beat < $1.element.beat
                    : $0.offset < $1.offset
            }
            var result: [TempoEvent] = []
            for (_, evt) in indexed {
                if let last = result.last, last.beat == evt.beat {
                    result[result.count - 1] = evt
                } else {
                    result.append(evt)
                }
            }
            return result
        }()
        if sortedTempo.isEmpty {
            Log("buildSchedule — no tempo events and no staticBPM, beatSchedule empty", "Metronome")
            beatSchedule = []
            return
        }

        func beatToTime(_ targetBeat: Double) -> Double {
            var accTime = 0.0
            var accBeat = 0.0
            for i in 0..<sortedTempo.count {
                let segBeat = sortedTempo[i].beat
                let segBPM  = sortedTempo[i].bpm
                let nextBeat = (i + 1 < sortedTempo.count) ? sortedTempo[i + 1].beat : Double.infinity
                if targetBeat <= nextBeat {
                    accTime += (targetBeat - max(accBeat, segBeat)) * 60.0 / segBPM
                    return accTime
                } else {
                    let segEnd = min(nextBeat, targetBeat)
                    accTime += (segEnd - max(accBeat, segBeat)) * 60.0 / segBPM
                    accBeat = segEnd
                }
            }
            return accTime
        }

        func timeSigAt(beat: Double) -> (num: Int, den: Int) {
            var current = parsedTimeSigs[0]
            for ts in parsedTimeSigs {
                if ts.beat <= beat { current = ts } else { break }
            }
            return (current.num, current.den)
        }

        var result: [BeatInfo] = []
        var beatNumber = 0.0
        var bar = 1
        var beatInBar = 1
        // isOnQuarterBeat alternates only for /4 time sigs in 8th's subdivision mode
        var isOnQuarterBeat = true
        var prevTs = (num: parsedTimeSigs[0].num, den: parsedTimeSigs[0].den)
        // Cache secondary accent positions so we don't recompute them on every beat
        var cachedSecAccentBeats: Set<Int> = secondaryAccentBeats(num: parsedTimeSigs[0].num, den: parsedTimeSigs[0].den)

        while true {
            let realTime = beatToTime(beatNumber)
            if realTime > totalDuration + 1.0 { break }

            let ts = timeSigAt(beat: beatNumber)

            // Reset beatInBar and accent cache on time signature change.
            if ts.num != prevTs.num || ts.den != prevTs.den {
                beatInBar = 1
                isOnQuarterBeat = true
                prevTs = (ts.num, ts.den)
                cachedSecAccentBeats = secondaryAccentBeats(num: ts.num, den: ts.den)
            }

            // For /8 time sigs the natural pulse IS the eighth note — no subdivision ticks.
            // For /4 time sigs in 8th's mode, odd steps are subdivision ticks.
            let currentStep: Double = ts.den == 8 ? 0.5 : (subdivision == .eighths ? 0.5 : 1.0)
            let isSubTick = ts.den != 8 && !isOnQuarterBeat

            let isDownbeat = !isSubTick && beatInBar == 1
            let isSecAcc   = !isSubTick && !isDownbeat && cachedSecAccentBeats.contains(beatInBar)
            result.append(BeatInfo(
                timeSeconds: realTime,
                bar: bar,
                beat: beatInBar,
                isDownbeat: isDownbeat,
                isSubdivisionTick: isSubTick,
                isSecondaryAccent: isSecAcc,
                absoluteBeat: beatNumber
            ))

            if !isSubTick {
                beatInBar += 1
                // stepsPerBar must use the real-beat step (not the subdivision step) because
                // beatInBar only increments on non-tick beats.
                // For /8: real beat = 0.5 (eighth note). For /4: real beat = 1.0 (quarter note),
                // even in 8ths mode where currentStep=0.5 and half the steps are subdivision ticks.
                let realBeatStep: Double = ts.den == 8 ? 0.5 : 1.0
                let stepsPerBar = max(1, Int(round(Double(ts.num) * 4.0 / (Double(ts.den) * realBeatStep))))
                if beatInBar > stepsPerBar {
                    beatInBar = 1
                    bar += 1
                }
            }
            beatNumber += currentStep
            if ts.den != 8 && subdivision == .eighths { isOnQuarterBeat.toggle() }
        }

        beatSchedule = result
        Log("buildSchedule — built \(result.count) beats", "Metronome")
    }

    /// Returns the set of 1-based beat positions within a bar that should receive a secondary accent.
    /// Groups are in denominator-note units (e.g. eighth notes for /8, quarter notes for /4).
    private func secondaryAccentBeats(num: Int, den: Int) -> Set<Int> {
        let groups: [Int]
        switch (num, den) {
        case (4, 4):  groups = [2, 2]
        case (5, 4):  groups = [3, 2]
        case (6, 4):  groups = [3, 3]
        case (7, 4):  groups = [2, 2, 3]
        case (9, 4):  groups = [3, 3, 3]
        case (10, 4): groups = [3, 3, 2, 2]
        case (11, 4): groups = [3, 3, 3, 2]
        case (12, 4): groups = [3, 3, 3, 3]
        case (13, 4): groups = [3, 3, 3, 2, 2]
        case (6, 8):  groups = [3, 3]
        case (7, 8):  groups = [2, 2, 3]
        case (9, 8):  groups = [3, 3, 3]
        case (10, 8): groups = [3, 3, 2, 2]
        case (11, 8): groups = [3, 3, 3, 2]
        case (12, 8): groups = [3, 3, 3, 3]
        case (13, 8): groups = [3, 3, 3, 2, 2]
        default:      return []   // 2/4, 3/4, 3/8 — no secondary accent
        }
        var positions = Set<Int>()
        var cum = 0
        for (i, g) in groups.enumerated() {
            if i > 0 { positions.insert(cum + 1) }
            cum += g
        }
        return positions
    }

    // MARK: - Playback Control

    /// Edit tab: sample-accurate start using the shared engine anchor from EditPlayerService.
    /// Call AFTER editPlayer.play() so startHostTime/startSessionTime are written.
    func start(anchorHostTime: UInt64, startSessionTime: Double) {
        guard !beatSchedule.isEmpty else {
            Log("start(anchor) — aborted: beatSchedule empty", "Metronome")
            return
        }
        loadSounds()
        guard let connectionFormat = clickBuffer?.format else {
            Log("start(anchor) — aborted: buffers not loaded", "Metronome")
            return
        }
        if !isAttachedToExternalEngine {
            guard startOwnEngine(format: connectionFormat) else {
                Log("start(anchor) — aborted: engine failed to start", "Metronome")
                return
            }
        }
        isPlaying = true
        scheduleAllBeats(anchorHostTime: anchorHostTime, startSessionTime: startSessionTime)
        startBeatTracker()
        Log("start(anchor) — anchor=\(anchorHostTime) sessionTime=\(String(format: "%.3f", startSessionTime))", "Metronome")
    }

    /// QA tab / fallback: self-anchored start. No drift after play begins;
    /// one-time bounded startup offset vs AVPlayer (~10–50ms, irreducible).
    func start(atSessionTime sessionTime: Double = 0) {
        guard !beatSchedule.isEmpty else {
            Log("start(selfAnchor) — aborted: beatSchedule empty", "Metronome")
            return
        }
        // Load sounds first so we have a buffer format to pass to startOwnEngine.
        // AVAudioPlayerNode requires the buffer format to exactly match the output
        // connection format — connecting with nil picks hardware (stereo) but a
        // format mismatch throws NSInvalidArgumentException from scheduleBuffer.
        loadSounds()
        guard let connectionFormat = clickBuffer?.format else {
            Log("start(selfAnchor) — aborted: buffers not loaded", "Metronome")
            return
        }
        guard startOwnEngine(format: connectionFormat) else {
            Log("start(selfAnchor) — aborted: engine failed to start", "Metronome")
            return
        }
        isPlaying = true
        // 50ms pre-roll matches typical AVPlayer startup latency
        let anchor = mach_absolute_time() + ticksForSeconds(0.05)
        scheduleAllBeats(anchorHostTime: anchor, startSessionTime: sessionTime)
        startBeatTracker()
        Log("start(selfAnchor) — sessionTime=\(String(format: "%.3f", sessionTime))", "Metronome")
    }

    func toggleMute() {
        isMuted.toggle()
        gainNode.outputVolume = isMuted ? 0 : volume
    }

    func stop() {
        Log("stop()", "Metronome")
        isPlaying = false
        beatTracker?.invalidate()
        playerNode.stop()
    }

    func seek(to sessionTime: Double) {
        guard isPlaying else { return }
        stop()
        start(atSessionTime: sessionTime)
    }

    // MARK: - Beat Scheduling

    /// `filterFrom` separates the playback filter from the anchor reference.
    /// When rescheduling mid-playback, pass the original anchor pair plus `filterFrom: currentTime`
    /// so beat host-times stay at their original positions (no timing drift).
    private func scheduleAllBeats(anchorHostTime: UInt64, startSessionTime: Double, filterFrom: Double? = nil) {
        guard let downbeatBuf    = downbeatBuffer ?? clickBuffer,
              let mediumAccBuf  = mediumAccentBuffer ?? subdivisionBuffer ?? clickBuffer,
              let subdivBuf     = subdivisionBuffer ?? clickBuffer,
              let subdivTickBuf = subdivisionTickBuffer ?? clickBuffer else {
            Log("scheduleAllBeats — aborted: buffers not loaded", "Metronome")
            return
        }
        let engineRunning = isAttachedToExternalEngine ? true : ownEngine.isRunning
        guard engineRunning else {
            Log("scheduleAllBeats — aborted: engine not running", "Metronome")
            return
        }

        playerNode.stop()   // cancels all previously queued buffers

        playbackAnchorHostTime    = anchorHostTime
        playbackAnchorSessionTime = startSessionTime

        let filterTime = filterFrom ?? startSessionTime
        var scheduled = 0
        for beatInfo in beatSchedule where beatInfo.timeSeconds >= filterTime - 0.01 {
            let offsetSecs   = max(0.0, beatInfo.timeSeconds - startSessionTime)
            let beatHostTime = anchorHostTime + ticksForSeconds(offsetSecs)
            let when = AVAudioTime(hostTime: beatHostTime)
            let buf: AVAudioPCMBuffer
            if beatInfo.isSubdivisionTick {
                buf = subdivTickBuf
            } else if beatInfo.isDownbeat {
                buf = downbeatBuf
            } else if beatInfo.isSecondaryAccent {
                buf = mediumAccBuf
            } else {
                buf = subdivBuf
            }
            playerNode.scheduleBuffer(buf, at: when, options: [], completionHandler: nil)
            scheduled += 1
        }

        playerNode.play()
        Log("scheduleAllBeats — \(scheduled) beats scheduled from t=\(String(format: "%.3f", filterTime))", "Metronome")
    }

    /// Rebuild beat schedule and reschedule playback after a subdivision change.
    /// Passes the original anchor pair unchanged and uses filterFrom to skip past beats,
    /// so every beat keeps its exact original host-time position (no timing drift).
    func subdivisionChanged() {
        guard let params = cachedBuildParams, params.totalDuration > 0 else { return }
        let wasPlaying = isPlaying
        // Snapshot anchor values before buildSchedule overwrites cachedBuildParams
        let anchorHost = playbackAnchorHostTime
        let anchorSession = playbackAnchorSessionTime
        var currentTime: Double = anchorSession
        if wasPlaying, anchorHost > 0 {
            let now = mach_absolute_time()
            if now >= anchorHost {
                currentTime = anchorSession + machTimeToSeconds(now - anchorHost)
            }
        }
        buildSchedule(tempoEvents: params.tempoEvents, timeSigs: params.timeSigs,
                      totalDuration: params.totalDuration, staticBPM: params.staticBPM)
        if wasPlaying {
            // Original anchor pair → beat host-times unchanged; filterFrom skips past beats
            scheduleAllBeats(anchorHostTime: anchorHost, startSessionTime: anchorSession,
                             filterFrom: currentTime)
        }
    }

    // MARK: - Beat Tracker (UI display only — reads from audio clock)

    private func startBeatTracker() {
        beatTracker?.invalidate()
        beatTracker = Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isPlaying else { return }

                // Derive current session time directly from the audio anchor — no polling error
                let now = mach_absolute_time()
                guard now >= self.playbackAnchorHostTime else { return }
                let elapsed = self.machTimeToSeconds(now - self.playbackAnchorHostTime)
                let t = self.playbackAnchorSessionTime + elapsed

                if let current = self.beatSchedule.last(where: { $0.timeSeconds <= t && !$0.isSubdivisionTick }) {
                    if current.bar != self.bar || current.beat != self.beat {
                        self.bar = current.bar
                        self.beat = current.beat
                        self.isDownbeat = current.isDownbeat
                        withAnimation(.easeOut(duration: 0.15)) {
                            self.beatFlash = true
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                            withAnimation(.easeIn(duration: 0.1)) {
                                self.beatFlash = false
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    /// Converts seconds to mach_absolute_time ticks (offset only — does NOT add current time).
    private func ticksForSeconds(_ seconds: Double) -> UInt64 {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        let nanos = UInt64(seconds * 1_000_000_000)
        return nanos * UInt64(info.denom) / UInt64(info.numer)
    }

    /// Converts a mach_absolute_time tick delta to seconds.
    private func machTimeToSeconds(_ ticks: UInt64) -> Double {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        let nanos = ticks * UInt64(info.numer) / UInt64(info.denom)
        return Double(nanos) / 1_000_000_000
    }

    private func timeSigTimeToSeconds(_ timeStr: String) -> Double? {
        let parts = timeStr.split(separator: ":").map { String($0) }
        guard parts.count == 3,
              let minutes = Double(parts[0]),
              let seconds = Double(parts[1]),
              let millis  = Double(parts[2]) else { return nil }
        return minutes * 60 + seconds + millis / 1000
    }

    private func parseTimeSigString(_ sig: String) -> (Int, Int)? {
        let parts = sig.split(separator: "/").map { String($0) }
        guard parts.count == 2, let n = Int(parts[0]), let d = Int(parts[1]) else { return nil }
        return (n, d)
    }
}

// MARK: - MetronomeView

struct MetronomeView: View {
    @ObservedObject var metronome: MetronomeService
    @State private var showPopover = false
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 8) {
            // Bar:beat counter
            if metronome.isPlaying {
                Text("\(metronome.bar) | \(metronome.beat)")
                    .font(.lato(size: 13, weight: .bold))
                    .foregroundColor(metronome.beatFlash ? Color.white : Color.fgMid)
                    .monospacedDigit()
                    .animation(.easeOut(duration: 0.15), value: metronome.beatFlash)
                    .frame(minWidth: 52, alignment: .trailing)
            }

            // Metronome icon — left-click mutes/unmutes, right-click opens settings
            Image(systemName: "metronome")
                .font(.system(size: 14, weight: .regular))
                .foregroundColor(
                    hovered ? Color.fgBright :
                    (metronome.isPlaying && !metronome.isMuted ? Color.accent : Color.fgMid)
                )
                .animation(.easeOut(duration: 0.12), value: hovered)
                .frame(width: 36, height: 36)
                .overlay(ClickOverlay(
                    onLeftClick: { metronome.toggleMute() },
                    onRightClick: { showPopover.toggle() },
                    onHover: { hovered = $0 }
                ))
                .popover(isPresented: $showPopover, arrowEdge: .top) {
                    MetronomePopoverView(metronome: metronome)
                }
        }
    }
}

private struct ClickOverlay: NSViewRepresentable {
    let onLeftClick: () -> Void
    let onRightClick: () -> Void
    let onHover: (Bool) -> Void

    func makeNSView(context: Context) -> ClickNSView {
        ClickNSView(onLeftClick: onLeftClick, onRightClick: onRightClick, onHover: onHover)
    }
    func updateNSView(_ nsView: ClickNSView, context: Context) {
        nsView.onLeftClick = onLeftClick
        nsView.onRightClick = onRightClick
        nsView.onHover = onHover
    }

    class ClickNSView: NSView {
        var onLeftClick: () -> Void
        var onRightClick: () -> Void
        var onHover: (Bool) -> Void
        init(onLeftClick: @escaping () -> Void, onRightClick: @escaping () -> Void, onHover: @escaping (Bool) -> Void) {
            self.onLeftClick = onLeftClick
            self.onRightClick = onRightClick
            self.onHover = onHover
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError() }
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach { removeTrackingArea($0) }
            addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow], owner: self))
        }
        override func mouseEntered(with event: NSEvent) { onHover(true); NSCursor.pointingHand.set() }
        override func mouseExited(with event: NSEvent)  { onHover(false); NSCursor.arrow.set() }
        override func mouseDown(with event: NSEvent) { onLeftClick() }
        override func rightMouseDown(with event: NSEvent) { onRightClick() }
    }
}

struct MetronomePopoverView: View {
    @ObservedObject var metronome: MetronomeService

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Metronome")
                .font(.lato(size: 13, weight: .semibold))
                .foregroundColor(Color.fgBright)

            // Subdivision picker
            VStack(alignment: .leading, spacing: 6) {
                Text("Subdivision")
                    .font(.lato(size: 11, weight: .regular))
                    .foregroundColor(Color.fgMid)
                Picker("", selection: $metronome.subdivision) {
                    ForEach(MetronomeSubdivision.allCases) { sub in
                        Text(sub.label).tag(sub)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: metronome.subdivision) { _ in
                    metronome.subdivisionChanged()
                }
            }

            // Volume slider
            VStack(alignment: .leading, spacing: 6) {
                Text("Volume")
                    .font(.lato(size: 11, weight: .regular))
                    .foregroundColor(Color.fgMid)
                HStack(spacing: 8) {
                    Image(systemName: "speaker.fill")
                        .font(.system(size: 10))
                        .foregroundColor(Color.fgMid)
                    Slider(value: $metronome.volume, in: 0...1)
                        .frame(width: 140)
                        .onChange(of: metronome.volume) { _ in
                            metronome.loadSounds()
                        }
                    Image(systemName: "speaker.wave.3.fill")
                        .font(.system(size: 10))
                        .foregroundColor(Color.fgMid)
                }
            }
        }
        .padding(16)
        .frame(width: 220)
    }
}
