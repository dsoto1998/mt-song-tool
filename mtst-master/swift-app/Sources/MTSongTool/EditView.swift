import SwiftUI
import AppKit
import AVFoundation

// MARK: - EditView (root)

struct EditView: View {
    @ObservedObject var editPlayer: EditPlayerService
    @ObservedObject var metronome: MetronomeService
    let stemURLs: [URL]
    @ObservedObject var analyzer: AudioAnalyzerService
    let parsedResult: ParsedResult?

    @ObservedObject private var userSettings = UserSettings.shared

    // Timeline state
    @State private var zoomScale: CGFloat = 0.25       // horizontal zoom multiplier
    @State private var zoomScaleAtGestureStart: CGFloat = 0.25
    @State private var isSnapEnabled: Bool = true
    @State private var selectedURLs: Set<URL> = []
    @State private var rowHeights: [URL: CGFloat] = [:]
    @State private var defaultRowHeight: CGFloat = 64

    // Commit state
    @State private var isCommitting: Bool = false

    @State private var commitError: String? = nil
    @State private var showCommitError: Bool = false

    // MARK: - Computed helpers

    /// CLICK TRACK → GUIDE → ORIGINAL SONG pinned to top; remainder alphabetical.
    private var sortedStemURLs: [URL] {
        let priority: [String: Int] = ["CLICK TRACK": 0, "GUIDE": 1, "ORIGINAL SONG": 2]
        return stemURLs.sorted { a, b in
            let aKey = a.deletingPathExtension().lastPathComponent.uppercased()
            let bKey = b.deletingPathExtension().lastPathComponent.uppercased()
            let ap = priority[aKey] ?? Int.max
            let bp = priority[bKey] ?? Int.max
            if ap != bp { return ap < bp }
            return aKey < bKey
        }
    }

    private var playheadFraction: Double {
        editPlayer.totalDuration > 0 ? editPlayer.currentTime / editPlayer.totalDuration : 0
    }

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            editToolbar
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.bgCard)
                .overlay(alignment: .bottom) {
                    Divider().foregroundColor(Color.border)
                }

            if stemURLs.isEmpty {
                emptyState
            } else {
                // Timeline
                timelineView
            }
        }
        .background(Color.bg)
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.border, lineWidth: 1)
        )
        .onAppear {
            // Share edit engine with metronome for sample-accurate click sync
            metronome.attachToEngine(editPlayer.engine)

            if editPlayer.stemURLs.isEmpty || editPlayer.stemURLs != stemURLs {
                editPlayer.loadStems(stemURLs)
            }
            // Build metronome beat schedule from parsed session
            if let result = parsedResult {
                metronome.buildSchedule(
                    tempoEvents: result.tempoEvents,
                    timeSigs: result.timeSignatures,
                    totalDuration: result.expectedDuration ?? editPlayer.totalDuration,
                    staticBPM: result.bpm
                )
            }
        }
        .onChange(of: editPlayer.playAnchor) { anchor in
            guard let anchor else { return }
            metronome.start(anchorHostTime: anchor.hostTime, startSessionTime: anchor.sessionTime)
        }
        .onChange(of: editPlayer.isPlaying) { playing in
            if !playing { metronome.stop() }
        }
        .alert("Commit Error", isPresented: $showCommitError) {
            Button("OK") {}
        } message: {
            Text(commitError ?? "Unknown error")
        }
    }

    // MARK: - Toolbar

    private var editToolbar: some View {
        HStack(spacing: 10) {
            // Transport
            Button {
                if editPlayer.isPlaying {
                    editPlayer.pause()
                    metronome.stop()
                } else {
                    editPlayer.play()
                    // metronome.start is driven by .onChange(of: editPlayer.playAnchor) below
                }
            } label: {
                Image(systemName: editPlayer.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 13))
                    .foregroundColor(Color.fgBright)
            }
            .buttonStyle(.plain)
            .frame(width: 28, height: 28)
            .keyboardShortcut(.space, modifiers: [])

            Button {
                editPlayer.stop()
                metronome.stop()
            } label: {
                Image(systemName: "stop.fill")
                    .font(.system(size: 13))
                    .foregroundColor(Color.fgMid)
            }
            .buttonStyle(.plain)
            .frame(width: 28, height: 28)

            Divider().frame(height: 18)

            // Snap toggle
            Button {
                isSnapEnabled.toggle()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "grid")
                        .font(.system(size: 12))
                    Text("Snap")
                        .font(.lato(size: 11, weight: .medium))
                }
                .foregroundColor(isSnapEnabled ? Color.accent : Color.fgMid)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(isSnapEnabled ? Color.accent.opacity(0.12) : Color.clear)
                .cornerRadius(5)
            }
            .buttonStyle(.plain)

            Divider().frame(height: 18)

            // Clear Mute / Clear Solo
            Button("Clear Mute") {
                editPlayer.clearAllMutes()
            }
            .font(.lato(size: 11, weight: .regular))
            .foregroundColor(Color.fgMid)
            .buttonStyle(.plain)

            Button("Clear Solo") {
                editPlayer.clearAllSolos()
            }
            .font(.lato(size: 11, weight: .regular))
            .foregroundColor(Color.fgMid)
            .buttonStyle(.plain)

            Divider().frame(height: 18)

            // Cut at playhead (Cmd+K) — requires at least one stem selected
            Button {
                for url in selectedURLs {
                    editPlayer.addCut(url, at: editPlayer.currentTime)
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "scissors")
                        .font(.system(size: 11))
                    Text("Cut")
                        .font(.lato(size: 11, weight: .regular))
                }
                .foregroundColor(!selectedURLs.isEmpty ? Color.fgBright : Color.fgMid)
            }
            .buttonStyle(.plain)
            .disabled(selectedURLs.isEmpty)
            .keyboardShortcut("k", modifiers: .command)

            Spacer()

            // Master peak meter
            MasterPeakMeter(peakDB: editPlayer.masterPeakDB)
                .frame(width: 100, height: 10)

            Divider().frame(height: 18)

            // Commit Changes
            if isCommitting {
                ProgressView()
                    .scaleEffect(0.7)
                    .tint(Color.accent)
            } else {
                Button("Commit Changes") {
                    commitChanges()
                }
                .font(.lato(size: 11, weight: .semibold))
                .foregroundColor(editPlayer.hasAnyEdits ? Color.accent : Color.fgMid)
                .buttonStyle(.plain)
                .disabled(!editPlayer.hasAnyEdits)
            }
        }
    }

    // MARK: - Timeline

    private var timelineView: some View {
        ScrollView(.vertical) {
            HStack(alignment: .top, spacing: 0) {

                // Left column: track headers — anchored, never scrolls horizontally
                VStack(spacing: 0) {
                    ForEach(sortedStemURLs, id: \.self) { url in
                        let state = editPlayer.stemStates[url] ?? StemState()
                        let height = rowHeights[url] ?? defaultRowHeight
                        let isSelected = selectedURLs.contains(url)

                        EditTrackSidebar(
                            url: url,
                            state: state,
                            isSelected: isSelected,
                            height: height,
                            onToggleMute: {
                                if isSelected && selectedURLs.count > 1 {
                                    editPlayer.setMutedForURLs(Array(selectedURLs), !state.isMuted)
                                } else {
                                    editPlayer.setMuted(url, !state.isMuted)
                                }
                            },
                            onToggleSolo: {
                                if isSelected && selectedURLs.count > 1 {
                                    editPlayer.setSoloedForURLs(Array(selectedURLs), !state.isSoloed)
                                } else {
                                    editPlayer.setSoloed(url, !state.isSoloed)
                                }
                            },
                            onGainChange: { newGain in
                                if isSelected && selectedURLs.count > 1 {
                                    editPlayer.setGainForSelected(Array(selectedURLs), newGain)
                                } else {
                                    editPlayer.setGain(url, newGain)
                                }
                            },
                            onSelect: {
                                if selectedURLs.contains(url) {
                                    selectedURLs.remove(url)
                                } else {
                                    selectedURLs.insert(url)
                                }
                            },
                            onResizeRow: { newHeight in
                                rowHeights[url] = max(40, newHeight)
                            }
                        )

                        Divider().foregroundColor(Color.border)
                    }
                }
                .frame(width: 200)

                Divider().foregroundColor(Color.border)

                // Right column: waveforms — NSScrollView host for mouse-centered zoom
                WaveformScrollHost(
                    stemURLs: sortedStemURLs,
                    stemStates: editPlayer.stemStates,
                    selectedURLs: selectedURLs,
                    rowHeights: rowHeights,
                    defaultRowHeight: defaultRowHeight,
                    currentTime: editPlayer.currentTime,
                    totalDuration: editPlayer.totalDuration,
                    zoomScale: $zoomScale,
                    zoomScaleAtGestureStart: $zoomScaleAtGestureStart,
                    playheadFraction: playheadFraction,
                    onSeek: { editPlayer.seek(to: $0) },
                    onOffsetChange: { url, newOffset in
                        let anchorOffset = editPlayer.stemStates[url]?.offset ?? 0
                        if selectedURLs.contains(url) && selectedURLs.count > 1 {
                            let delta = newOffset - anchorOffset
                            for u in selectedURLs {
                                let cur = editPlayer.stemStates[u]?.offset ?? 0
                                editPlayer.setOffset(u, cur + delta)
                            }
                        } else {
                            editPlayer.setOffset(url, newOffset)
                        }
                    },
                    onTrimInChange: { editPlayer.setTrimIn($0, $1) },
                    onTrimOutChange: { editPlayer.setTrimOut($0, $1) }
                )
                .frame(maxWidth: .infinity)
                .frame(height: sortedStemURLs.reduce(CGFloat(0)) {
                    $0 + (rowHeights[$1] ?? defaultRowHeight) + 1
                })
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "waveform")
                .font(.system(size: 28))
                .foregroundColor(Color.fgMid)
            Text("No stems loaded")
                .font(.lato(size: 13))
                .foregroundColor(Color.fgMid)
            Text("Run a Stem Check in the QA tab first.")
                .font(.lato(size: 11))
                .foregroundColor(Color.fgDim)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Commit

    private func commitChanges() {
        isCommitting = true
        editPlayer.stop()
        metronome.stop()
        analyzer.applyEdits(
            stemStates: editPlayer.stemStates,
            autoFadeCuts: userSettings.autoFadeCuts
        ) { error in
            isCommitting = false
            if let error {
                commitError = error
                showCommitError = true
            } else {
                // Reload the edit player with the new folder
                editPlayer.loadStems(analyzer.stemURLs)
            }
        }
    }
}

// MARK: - EditTrackSidebar

struct EditTrackSidebar: View {
    let url: URL
    let state: StemState
    let isSelected: Bool
    let height: CGFloat

    let onToggleMute: () -> Void
    let onToggleSolo: () -> Void
    let onGainChange: (Float) -> Void
    let onSelect: () -> Void
    let onResizeRow: (CGFloat) -> Void

    @State private var resizeStartHeight: CGFloat? = nil
    @State private var isEditingGain = false
    @State private var gainEditText = ""

    var stemName: String { url.deletingPathExtension().lastPathComponent }

    private func linearToDb(_ v: Float) -> Float { v > 0 ? 20 * log10(v) : -96 }
    private func dbToLinear(_ db: Float) -> Float { pow(10, db / 20) }

    private func commitGainEdit() {
        if let db = Float(gainEditText) {
            onGainChange(dbToLinear(max(-60, min(60, db))))
        }
        isEditingGain = false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Row header — tap to select
            Button {
                onSelect()
            } label: {
                HStack(spacing: 4) {
                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(Color.accent)
                    }
                    Text(stemName)
                        .font(.lato(size: 11, weight: .medium))
                        .foregroundColor(Color.fgBright)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .buttonStyle(.plain)

            HStack(spacing: 6) {
                // Mute
                Button("M") { onToggleMute() }
                    .font(.lato(size: 10, weight: .bold))
                    .foregroundColor(state.isMuted ? .white : Color.fgMid)
                    .frame(width: 20, height: 18)
                    .background(state.isMuted ? Color.red.opacity(0.8) : Color.border.opacity(0.4))
                    .cornerRadius(3)
                    .buttonStyle(.plain)

                // Solo
                Button("S") { onToggleSolo() }
                    .font(.lato(size: 10, weight: .bold))
                    .foregroundColor(state.isSoloed ? .white : Color.fgMid)
                    .frame(width: 20, height: 18)
                    .background(state.isSoloed ? Color.accent.opacity(0.9) : Color.border.opacity(0.4))
                    .cornerRadius(3)
                    .buttonStyle(.plain)

                // Peak dBFS meter
                StemPeakMeter(peakDB: state.peakDB)
                    .frame(width: 50, height: 8)

                Spacer()
            }

            // Gain (dB: -60 to +60, 0 dB = neutral)
            HStack(spacing: 4) {
                Text("Gain")
                    .font(.lato(size: 10))
                    .foregroundColor(Color.fgMid)
                Slider(value: Binding(
                    get: { Double(max(-60, min(60, linearToDb(state.gain)))) },
                    set: { onGainChange(dbToLinear(Float($0))) }
                ), in: -60...60)
                .frame(width: 70)
                if isEditingGain {
                    TextField("", text: $gainEditText)
                        .font(.lato(size: 10))
                        .foregroundColor(Color.fgBright)
                        .monospacedDigit()
                        .frame(width: 46)
                        .textFieldStyle(.plain)
                        .background(Color.border.opacity(0.3))
                        .cornerRadius(3)
                        .onSubmit { commitGainEdit() }
                        .onExitCommand { isEditingGain = false }
                } else {
                    let db = linearToDb(state.gain)
                    Text(db >= 0 ? String(format: "+%.1f", db) : String(format: "%.1f", db))
                        .font(.lato(size: 10))
                        .foregroundColor(db == 0 ? Color.fgMid : Color.accent)
                        .monospacedDigit()
                        .frame(width: 46)
                        .onTapGesture(count: 2) {
                            gainEditText = String(format: "%.1f", db)
                            isEditingGain = true
                        }
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(width: 200, height: height, alignment: .topLeading)
        .background(isSelected ? Color.accent.opacity(0.08) : Color.bgCard)
        .overlay(alignment: .bottom) {
            // Resize drag handle
            Color.border.opacity(0.01)
                .frame(height: 6)
                .cursor(.resizeUpDown)
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { v in
                            if resizeStartHeight == nil { resizeStartHeight = height }
                            onResizeRow((resizeStartHeight ?? height) + v.translation.height)
                        }
                        .onEnded { v in
                            onResizeRow((resizeStartHeight ?? height) + v.translation.height)
                            resizeStartHeight = nil
                        }
                )
        }
    }
}

// MARK: - EditWaveformCanvas

struct EditWaveformCanvas: View {
    let peaks: [Float]
    let offset: Double
    let trimIn: Double
    let trimOut: Double?
    let cuts: [Double]
    let currentTime: Double
    let totalDuration: Double
    let zoomScale: CGFloat

    let isLocked: Bool
    let onSeek: (Double) -> Void           // tap anywhere to seek to that time
    let onOffsetChange: (Double) -> Void   // receives absolute new offset
    let onTrimInChange: (Double) -> Void
    let onTrimOutChange: (Double?) -> Void

    @State private var dragStartOffset: Double? = nil

    private var effectiveDuration: Double { max(totalDuration, 1) }
    /// Base pixels per second at zoom 1.0 — gives a 3-min song ~14 400px of width by default.
    private static let pixelsPerSecondBase: CGFloat = 80.0

    var body: some View {
        let totalWidth = max(CGFloat(effectiveDuration) * Self.pixelsPerSecondBase * zoomScale, 400)
        let pixelsPerSecond = Self.pixelsPerSecondBase * zoomScale

        Canvas { ctx, size in
            let w = size.width
            let h = size.height
            guard !peaks.isEmpty, w > 0, h > 0 else { return }

            let mid = h / 2

            // Draw waveform
            var path = Path()
            let count = peaks.count
            for i in 0..<count {
                let x = CGFloat(i) / CGFloat(count) * w
                let amp = CGFloat(peaks[i]) * mid * 0.9
                if i == 0 { path.move(to: CGPoint(x: x, y: mid - amp)) }
                else { path.addLine(to: CGPoint(x: x, y: mid - amp)) }
            }
            for i in stride(from: count - 1, through: 0, by: -1) {
                let x = CGFloat(i) / CGFloat(count) * w
                let amp = CGFloat(peaks[i]) * mid * 0.9
                path.addLine(to: CGPoint(x: x, y: mid + amp))
            }
            path.closeSubpath()
            ctx.fill(path, with: .color(Color.fgMid.opacity(0.35)))

            // Clip boundary outline — shows where audio begins and ends
            var clipRect = Path()
            clipRect.addRoundedRect(in: CGRect(x: 1, y: 1, width: w - 2, height: h - 2),
                                    cornerSize: CGSize(width: 4, height: 4))
            ctx.stroke(clipRect, with: .color(Color.fgMid.opacity(0.5)), lineWidth: 1.5)

            // Playhead
            let playheadX = CGFloat(currentTime / effectiveDuration) * w
            var playhead = Path()
            playhead.move(to: CGPoint(x: playheadX, y: 0))
            playhead.addLine(to: CGPoint(x: playheadX, y: h))
            ctx.stroke(playhead, with: .color(.white.opacity(0.9)), lineWidth: 1.5)

            // Cut markers
            for cut in cuts {
                let cx = CGFloat(cut / effectiveDuration) * w
                var cutPath = Path()
                cutPath.move(to: CGPoint(x: cx, y: 0))
                cutPath.addLine(to: CGPoint(x: cx, y: h))
                ctx.stroke(cutPath, with: .color(Color.red.opacity(0.8)), lineWidth: 1)
            }

            // Trim handles
            if trimIn > 0 {
                let tx = CGFloat(trimIn / effectiveDuration) * w
                var trimPath = Path()
                trimPath.move(to: CGPoint(x: tx, y: 0))
                trimPath.addLine(to: CGPoint(x: tx, y: h))
                ctx.stroke(trimPath, with: .color(Color.accent2.opacity(0.8)), lineWidth: 2)
            }
            if let tOut = trimOut {
                let tx = CGFloat(tOut / effectiveDuration) * w
                var trimPath = Path()
                trimPath.move(to: CGPoint(x: tx, y: 0))
                trimPath.addLine(to: CGPoint(x: tx, y: h))
                ctx.stroke(trimPath, with: .color(Color.accent2.opacity(0.8)), lineWidth: 2)
            }
        }
        .frame(width: totalWidth)
        .background(Color.bg.opacity(0.3))
        .gesture(
            SpatialTapGesture()
                .onEnded { event in
                    let time = Double(event.location.x / totalWidth) * effectiveDuration
                    onSeek(max(0, min(effectiveDuration, time)))
                }
        )
        .gesture(
            DragGesture(minimumDistance: 2)
                .onChanged { value in
                    guard !isLocked else { return }
                    if dragStartOffset == nil { dragStartOffset = offset }
                    let deltaSeconds = Double(value.translation.width / pixelsPerSecond)
                    onOffsetChange((dragStartOffset ?? offset) + deltaSeconds)
                }
                .onEnded { value in
                    guard !isLocked else { return }
                    let deltaSeconds = Double(value.translation.width / pixelsPerSecond)
                    onOffsetChange((dragStartOffset ?? offset) + deltaSeconds)
                    dragStartOffset = nil
                }
        )
    }
}

// MARK: - WaveformScrollHost

/// NSScrollView wrapper that gives programmatic scroll-position control for mouse-centered zoom.
struct WaveformScrollHost: NSViewRepresentable {
    let stemURLs: [URL]
    let stemStates: [URL: StemState]
    let selectedURLs: Set<URL>
    let rowHeights: [URL: CGFloat]
    let defaultRowHeight: CGFloat
    let currentTime: Double
    let totalDuration: Double

    @Binding var zoomScale: CGFloat
    @Binding var zoomScaleAtGestureStart: CGFloat
    let playheadFraction: Double

    let onSeek: (Double) -> Void
    let onOffsetChange: (URL, Double) -> Void
    let onTrimInChange: (URL, Double) -> Void
    let onTrimOutChange: (URL, Double?) -> Void

    // MARK: Coordinator

    class Coordinator: NSObject {
        var parent: WaveformScrollHost
        weak var scrollView: NSScrollView?
        var hostingView: NSHostingView<AnyView>?

        var gestureStartZoom: CGFloat = 1
        var gestureFocalFraction: CGFloat = 0

        init(_ parent: WaveformScrollHost) { self.parent = parent }

        @objc func handleMagnification(_ r: NSMagnificationGestureRecognizer) {
            guard let sv = scrollView else { return }
            let clipView = sv.contentView

            switch r.state {
            case .began:
                gestureStartZoom = parent.zoomScale
                let focalX = r.location(in: clipView).x
                let contentW = clipView.documentRect.width
                gestureFocalFraction = contentW > 0
                    ? focalX / contentW
                    : CGFloat(parent.playheadFraction)

            case .changed, .ended:
                let newZoom = max(0.01, min(100, gestureStartZoom * (1 + r.magnification)))
                parent.zoomScale = newZoom
                if r.state == .ended { parent.zoomScaleAtGestureStart = newZoom }

                // Recompute content width using the same formula as EditWaveformCanvas
                let newContentW = max(CGFloat(parent.totalDuration) * 80.0 * newZoom, 400)
                let focalAbsNew = gestureFocalFraction * newContentW
                let gestureViewX = r.location(in: sv).x
                let newScrollX = max(0, focalAbsNew - gestureViewX)

                DispatchQueue.main.async { [weak sv] in
                    guard let sv else { return }
                    sv.contentView.scroll(to: NSPoint(x: newScrollX, y: 0))
                    sv.reflectScrolledClipView(sv.contentView)
                }

            default: break
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    // MARK: NSViewRepresentable

    /// Explicit document size so NSHostingView is never undersized.
    /// Canvas has no intrinsic height, so sizingOptions = .intrinsicContentSize
    /// collapses the hosting view to only a couple of rows.
    private var documentSize: CGSize {
        let h = stemURLs.reduce(CGFloat(0)) { $0 + (rowHeights[$1] ?? defaultRowHeight) + 1 }
        let w = max(CGFloat(totalDuration) * 80.0 * zoomScale, 400)
        return CGSize(width: w, height: max(h, 1))
    }

    func makeNSView(context: Context) -> NSScrollView {
        let sv = NSScrollView()
        sv.hasHorizontalScroller = true
        sv.hasVerticalScroller = false
        sv.autohidesScrollers = true
        sv.drawsBackground = false

        let hv = NSHostingView(rootView: AnyView(waveformContent()))
        hv.sizingOptions = []                                   // manual sizing — no intrinsic size
        hv.frame = CGRect(origin: .zero, size: documentSize)
        sv.documentView = hv

        let mag = NSMagnificationGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleMagnification(_:))
        )
        sv.addGestureRecognizer(mag)

        context.coordinator.scrollView = sv
        context.coordinator.hostingView = hv
        return sv
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        if let hv = context.coordinator.hostingView {
            hv.rootView = AnyView(waveformContent())
            hv.frame = CGRect(origin: .zero, size: documentSize)
        }
    }

    // MARK: Content builder

    private func waveformContent() -> some View {
        VStack(spacing: 0) {
            ForEach(stemURLs, id: \.self) { url in
                let state = stemStates[url] ?? StemState()
                let height = rowHeights[url] ?? defaultRowHeight

                EditWaveformCanvas(
                    peaks: state.peaks,
                    offset: state.offset,
                    trimIn: state.trimIn,
                    trimOut: state.trimOut,
                    cuts: state.cuts,
                    currentTime: currentTime,
                    totalDuration: totalDuration,
                    zoomScale: zoomScale,
                    isLocked: false,
                    onSeek: onSeek,
                    onOffsetChange: { newOffset in onOffsetChange(url, newOffset) },
                    onTrimInChange: { onTrimInChange(url, $0) },
                    onTrimOutChange: { onTrimOutChange(url, $0) }
                )
                .frame(height: height)

                Divider().foregroundColor(Color.border)
            }
        }
    }
}

// MARK: - Peak Meters

struct StemPeakMeter: View {
    let peakDB: Float
    private var fraction: CGFloat {
        CGFloat(max(0, (peakDB + 60) / 60))  // maps -60…0 dBFS to 0…1
    }
    private var meterColor: Color {
        if peakDB > -3 { return .red }
        if peakDB > -6 { return Color(red: 1, green: 0.8, blue: 0) }
        return Color(red: 0.2, green: 0.8, blue: 0.3)
    }
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2).fill(Color.border.opacity(0.4))
                RoundedRectangle(cornerRadius: 2).fill(meterColor)
                    .frame(width: geo.size.width * fraction)
            }
        }
    }
}

struct MasterPeakMeter: View {
    let peakDB: Float
    private var fraction: CGFloat {
        CGFloat(max(0, (peakDB + 60) / 60))
    }
    private var meterColor: Color {
        if peakDB > -3 { return .red }
        if peakDB > -6 { return Color(red: 1, green: 0.8, blue: 0) }
        return Color(red: 0.2, green: 0.8, blue: 0.3)
    }
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2).fill(Color.border.opacity(0.4))
                RoundedRectangle(cornerRadius: 2).fill(meterColor)
                    .frame(width: geo.size.width * fraction)
            }
        }
    }
}

// MARK: - Cursor helper

extension View {
    func cursor(_ cursor: NSCursor) -> some View {
        self.onHover { hovering in
            if hovering { cursor.set() } else { NSCursor.arrow.set() }
        }
    }
}
