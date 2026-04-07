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
    @State private var selectedURLs: Set<URL> = []      // sidebar M/S/Gain group
    @State private var stemSelections: [URL: Range<Double>] = [:]  // per-stem region selections
    @State private var rowHeights: [URL: CGFloat] = [:]
    @State private var defaultRowHeight: CGFloat = 64
    @State private var hasFitZoom: Bool = false
    @State private var viewportWidth: CGFloat = 0

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
            } else if editPlayer.totalDuration == 0 {
                // Peaks still loading — show spinner instead of flashing empty canvases
                VStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Loading stems\u{2026}")
                        .font(.lato(size: 12))
                        .foregroundColor(Color.fgMid)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // Timeline
                timelineView
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        // When stems change while the Edit tab is already visible (e.g. user clears a file and
        // re-scans stems without leaving the tab), onAppear doesn't fire again, so loadStems
        // would never be called. This onChange handles that case.
        .onChange(of: editPlayer.totalDuration) { dur in
            guard dur > 0, !hasFitZoom, viewportWidth > 0 else { return }
            hasFitZoom = true
            let fitZoom = max(0.01, min(1.0, viewportWidth / (CGFloat(dur) * 80.0)))
            zoomScale = fitZoom
            zoomScaleAtGestureStart = fitZoom
        }
        .onChange(of: viewportWidth) { w in
            // GeometryReader fires after timelineView appears — if totalDuration is already
            // set (from the loading spinner phase), this triggers the fit-to-width that the
            // totalDuration onChange couldn't (because viewportWidth was 0 at that time).
            guard w > 0, !hasFitZoom, editPlayer.totalDuration > 0 else { return }
            hasFitZoom = true
            let fitZoom = max(0.01, min(1.0, w / (CGFloat(editPlayer.totalDuration) * 80.0)))
            zoomScale = fitZoom
            zoomScaleAtGestureStart = fitZoom
        }
        .onChange(of: stemURLs) { newURLs in
            guard !newURLs.isEmpty else { return }
            hasFitZoom = false
            zoomScale = 0.25
            zoomScaleAtGestureStart = 0.25
            editPlayer.loadStems(newURLs)
            if let result = parsedResult {
                metronome.buildSchedule(
                    tempoEvents: result.tempoEvents,
                    timeSigs: result.timeSignatures,
                    totalDuration: result.expectedDuration ?? editPlayer.totalDuration,
                    staticBPM: result.bpm
                )
            }
        }
        .onDeleteRegion {
            guard !stemSelections.isEmpty else { return }
            for (url, range) in stemSelections {
                editPlayer.deleteRegion(url, lo: range.lowerBound, hi: range.upperBound)
            }
            stemSelections = [:]
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
        VStack(spacing: 0) {
        ScrollView(.vertical) {
            HStack(alignment: .top, spacing: 0) {

                // Left column: track headers — anchored, never scrolls horizontally
                VStack(spacing: 0) {
                    Color.bgCard
                        .frame(width: 200, height: 24)
                    Divider().foregroundColor(Color.border)
                    ForEach(sortedStemURLs, id: \.self) { url in
                        let state = editPlayer.stemStates[url] ?? StemState()
                        let height = rowHeights[url] ?? defaultRowHeight
                        let isSelected = selectedURLs.contains(url)

                        EditTrackSidebar(
                            url: url,
                            state: state,
                            meterDB: editPlayer.meterLevels[url] ?? -96.0,
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
                ZStack(alignment: .topLeading) {
                    WaveformScrollHost(
                        stemURLs: sortedStemURLs,
                        stemStates: editPlayer.stemStates,
                        rowHeights: rowHeights,
                        defaultRowHeight: defaultRowHeight,
                        totalDuration: editPlayer.totalDuration,
                        zoomScale: $zoomScale,
                        zoomScaleAtGestureStart: $zoomScaleAtGestureStart,
                        editPlayer: editPlayer,
                        beatSchedule: metronome.beatSchedule,
                        isSnapEnabled: isSnapEnabled,
                        stemSelections: stemSelections,
                        onSeek: { editPlayer.seek(to: $0) },
                        onOffsetChange: { url, newClipStart in
                            let currentFirst = editPlayer.stemStates[url]?.segments
                                .min(by: { $0.sessionStart < $1.sessionStart })?.sessionStart ?? 0
                            let delta = newClipStart - currentFirst
                            if selectedURLs.contains(url) && selectedURLs.count > 1 {
                                for u in selectedURLs { editPlayer.shiftAllSegments(u, delta: delta) }
                            } else {
                                editPlayer.shiftAllSegments(url, delta: delta)
                            }
                        },
                        onTrimInChange: { editPlayer.setTrimIn($0, $1) },
                        onTrimOutChange: { editPlayer.setTrimOut($0, $1) },
                        onSelectionChange: { range in
                            if let range {
                                // Ruler-based: apply same range to all stems that have a selection,
                                // or all stems if none are selected
                                let targets = stemSelections.isEmpty ? sortedStemURLs : Array(stemSelections.keys)
                                stemSelections = Dictionary(uniqueKeysWithValues: targets.map { ($0, range) })
                            } else {
                                stemSelections = [:]
                            }
                        },
                        onSetStemSelection: { url, range in
                            if let range { stemSelections = [url: range] } else { stemSelections = [:] }
                        },
                        onAddStemSelection: { url, range in
                            if let range { stemSelections[url] = range } else { stemSelections.removeValue(forKey: url) }
                        }
                    )

                    // Name labels are rendered as CATextLayers inside waveformContainer (move with clip on drag)
                }
                .frame(maxWidth: .infinity)
                .frame(height: sortedStemURLs.reduce(CGFloat(0)) {
                    $0 + (rowHeights[$1] ?? defaultRowHeight) + 1
                } + 24)
                .background(GeometryReader { geo in
                    Color.clear
                        .onAppear { viewportWidth = geo.size.width }
                        .onChange(of: geo.size.width) { viewportWidth = $0 }
                })
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)

        // Global selection bar — outside ScrollView, always visible regardless of vertical scroll
        HStack(spacing: 0) {
            Color.bgCard.frame(width: 200)
            Divider().foregroundColor(Color.border)
            let globalRange: Range<Double>? = {
                guard !stemSelections.isEmpty else { return nil }
                let lo = stemSelections.values.map(\.lowerBound).min()!
                let hi = stemSelections.values.map(\.upperBound).max()!
                return lo..<hi
            }()
            GlobalSelectionBar(
                totalDuration: editPlayer.totalDuration,
                selectionRange: globalRange,
                onSelectionChange: { range in
                    if let range {
                        stemSelections = Dictionary(uniqueKeysWithValues: sortedStemURLs.map { ($0, range) })
                    } else {
                        stemSelections = [:]
                    }
                }
            )
        }
        .frame(height: 16)
        } // VStack
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

    // MARK: - Name Bar Overlay

    /// Semi-transparent name chips pinned to the left edge of the waveform area.
    /// Lives outside the NSScrollView so horizontal scroll doesn't carry them away.
    private var waveformNameOverlay: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: 24)  // ruler height spacer
            ForEach(sortedStemURLs, id: \.self) { url in
                let h = rowHeights[url] ?? defaultRowHeight
                Color.clear
                    .frame(height: h)
                    .overlay(alignment: .topLeading) {
                        Text(url.deletingPathExtension().lastPathComponent)
                            .font(.lato(size: 10, weight: .bold))
                            .foregroundColor(.white.opacity(0.9))
                            .padding(.horizontal, 7)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .frame(height: 18)
                            .background(Color(white: 0, opacity: 0.28))
                    }
                Color.border.frame(height: 1)
            }
        }
        .frame(maxWidth: .infinity)
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
    let meterDB: Float
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
                StemPeakMeter(peakDB: meterDB)
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
    let segments: [AudioSegment]    // multi-segment model (populated after peaks load)
    let clipSessionStart: Double    // session start of the first segment (for drag tracking)
    let stemDuration: Double        // actual file duration; may be < totalDuration
    let offset: Double              // legacy: only used when segments is empty
    let trimIn: Double
    let trimOut: Double?
    let cuts: [Double]
    let totalDuration: Double
    let zoomScale: CGFloat
    let beatSchedule: [BeatInfo]
    let isSnapEnabled: Bool
    let selectionRange: Range<Double>?   // nil if this track is not in the current selection scope

    let isLocked: Bool
    let onSeek: (Double) -> Void
    let onOffsetChange: (Double) -> Void     // new clip session start (first segment's new position)
    let onTrimInChange: (Double) -> Void
    let onTrimOutChange: (Double?) -> Void
    let onSetSelection: (Range<Double>?) -> Void   // no CMD: replace all stem selections
    let onAddSelection: (Range<Double>?) -> Void   // CMD: update just this stem's selection

    @State private var dragStartClipStart: Double? = nil
    @State private var optionDragStartTime: Double? = nil
    @State private var isDraggingForSelection: Bool = false
    @State private var isDraggingAdditive: Bool = false    // CMD held at drag start

    // Name bar zone height — no visual drawn here; overlay in EditView handles rendering.
    // Top 18px of the canvas acts as the drag-to-move zone; below = selection zone.
    private let nameBarHeight: CGFloat = 18

    private var effectiveDuration: Double { max(totalDuration, 1) }
    private static let pixelsPerSecondBase: CGFloat = 80.0

    var body: some View {
        let totalWidth = max(CGFloat(effectiveDuration) * Self.pixelsPerSecondBase * zoomScale, 400)
        let pixelsPerSecond = Self.pixelsPerSecondBase * zoomScale

        // Waveform fills + outlines are now rendered via CAShapeLayers (see updateNSView)
        // for pixel-accurate positioning at any zoom. This Canvas is a transparent gesture target.
        Color.clear
            .frame(width: totalWidth)
        .background(Color.bg.opacity(0.15))
        .gesture(
            SpatialTapGesture()
                .onEnded { event in
                    let time = Double(event.location.x / totalWidth) * effectiveDuration
                    let clamped = max(0, min(effectiveDuration, time))
                    // Tap inside an existing selection: seek but keep selection
                    // Tap outside (or no selection): seek + clear this track's selection
                    if let sel = selectionRange, sel.contains(clamped) {
                        onSeek(clamped)
                    } else {
                        onSeek(clamped)
                        onSetSelection(nil)
                    }
                }
        )
        .gesture(
            DragGesture(minimumDistance: 2)
                .onChanged { value in
                    let isOption = NSEvent.modifierFlags.contains(.option)

                    // First frame: decide mode.
                    // Top 18px (name bar zone) = move clip; waveform body = region select.
                    // Option overrides anywhere to select. CMD = additive selection.
                    if !isDraggingForSelection && dragStartClipStart == nil && optionDragStartTime == nil {
                        let inNameBar = value.startLocation.y <= nameBarHeight
                        if inNameBar && !isOption {
                            dragStartClipStart = clipSessionStart
                        } else {
                            isDraggingForSelection = true
                            isDraggingAdditive = NSEvent.modifierFlags.contains(.command)
                            let rawT = Double(value.startLocation.x / totalWidth) * effectiveDuration
                            let snapped = isSnapEnabled && !beatSchedule.isEmpty
                                ? snapToGrid(rawT, schedule: beatSchedule) : rawT
                            optionDragStartTime = max(0, min(effectiveDuration, snapped))
                        }
                    }

                    if isDraggingForSelection {
                        let t0 = optionDragStartTime ?? 0
                        let rawT1 = Double(value.location.x / totalWidth) * effectiveDuration
                        let t1 = isSnapEnabled && !beatSchedule.isEmpty
                            ? snapToGrid(rawT1, schedule: beatSchedule) : rawT1
                        let lo = min(t0, t1); let hi = max(t0, t1)
                        if hi - lo > 0.001 {
                            if isDraggingAdditive { onAddSelection(lo..<hi) } else { onSetSelection(lo..<hi) }
                        }
                    } else {
                        guard !isLocked else { return }
                        let deltaSeconds = Double(value.translation.width / pixelsPerSecond)
                        var newStart = (dragStartClipStart ?? clipSessionStart) + deltaSeconds
                        if isSnapEnabled && !beatSchedule.isEmpty {
                            newStart = snapToGrid(newStart, schedule: beatSchedule)
                        }
                        onOffsetChange(newStart)
                    }
                }
                .onEnded { value in
                    if isDraggingForSelection {
                        let t0 = optionDragStartTime ?? 0
                        let rawT1 = Double(value.location.x / totalWidth) * effectiveDuration
                        let t1 = isSnapEnabled && !beatSchedule.isEmpty
                            ? snapToGrid(rawT1, schedule: beatSchedule) : rawT1
                        let lo = min(t0, t1); let hi = max(t0, t1)
                        if hi - lo > 0.001 {
                            if isDraggingAdditive { onAddSelection(lo..<hi) } else { onSetSelection(lo..<hi) }
                        } else {
                            if isDraggingAdditive { onAddSelection(nil) } else { onSetSelection(nil) }
                        }
                    } else {
                        guard !isLocked else { return }
                        let deltaSeconds = Double(value.translation.width / pixelsPerSecond)
                        var newStart = (dragStartClipStart ?? clipSessionStart) + deltaSeconds
                        if isSnapEnabled && !beatSchedule.isEmpty {
                            newStart = snapToGrid(newStart, schedule: beatSchedule)
                        }
                        onOffsetChange(newStart)
                    }
                    dragStartClipStart = nil
                    optionDragStartTime = nil
                    isDraggingForSelection = false
                    isDraggingAdditive = false
                }
        )
        .onContinuousHover { phase in
            switch phase {
            case .active(let loc):
                if loc.y <= nameBarHeight {
                    NSCursor.openHand.set()
                } else {
                    NSCursor.crosshair.set()
                }
            case .ended:
                NSCursor.arrow.set()
            }
        }
    }
}

// MARK: - GlobalSelectionBar

/// Thin bar at the bottom of the arrangement — drag to select the same time range across ALL tracks.
struct GlobalSelectionBar: View {
    let totalDuration: Double
    let selectionRange: Range<Double>?   // union of all stem selections for display
    let onSelectionChange: (Range<Double>?) -> Void

    @State private var dragStartFraction: Double? = nil

    var body: some View {
        // Viewport-width bar — full width maps to full document range.
        // Floats at the bottom of the waveform area regardless of horizontal scroll.
        GeometryReader { geo in
            let w = geo.size.width
            let dur = max(totalDuration, 1)

            ZStack(alignment: .leading) {
                Color.bgCard

                if let range = selectionRange, totalDuration > 0 {
                    let sx = CGFloat(range.lowerBound / dur) * w
                    let ex = CGFloat(range.upperBound / dur) * w
                    Color.accent.opacity(0.30)
                        .frame(width: max(ex - sx, 1))
                        .offset(x: sx)
                    Color.accent.opacity(0.8).frame(width: 1.5).offset(x: sx)
                    Color.accent.opacity(0.8).frame(width: 1.5).offset(x: max(ex - 1.5, sx))
                }

                VStack(spacing: 0) {
                    Color.border.frame(height: 1)
                    Spacer()
                }

                Text("GLOBAL")
                    .font(.lato(size: 8, weight: .bold))
                    .foregroundColor(Color.fgMid.opacity(0.6))
                    .padding(.leading, 6)
            }
            .gesture(
                SpatialTapGesture()
                    .onEnded { _ in onSelectionChange(nil) }
            )
            .gesture(
                DragGesture(minimumDistance: 2)
                    .onChanged { value in
                        if dragStartFraction == nil {
                            dragStartFraction = max(0, min(1, Double(value.startLocation.x / w)))
                        }
                        let f0 = dragStartFraction ?? 0
                        let f1 = max(0, min(1, Double(value.location.x / w)))
                        let lo = min(f0, f1) * dur
                        let hi = max(f0, f1) * dur
                        if hi - lo > 0.001 { onSelectionChange(lo..<hi) }
                    }
                    .onEnded { value in
                        let f0 = dragStartFraction ?? 0
                        let f1 = max(0, min(1, Double(value.location.x / w)))
                        let lo = min(f0, f1) * dur
                        let hi = max(f0, f1) * dur
                        if hi - lo > 0.001 { onSelectionChange(lo..<hi) } else { onSelectionChange(nil) }
                        dragStartFraction = nil
                    }
            )
            .cursor(.crosshair)
        }
        .frame(height: 16)
    }
}

// MARK: - WaveformScrollHost

/// NSScrollView wrapper that gives programmatic scroll-position control for mouse-centered zoom.
struct WaveformScrollHost: NSViewRepresentable {
    let stemURLs: [URL]
    let stemStates: [URL: StemState]
    let rowHeights: [URL: CGFloat]
    let defaultRowHeight: CGFloat
    let totalDuration: Double

    @Binding var zoomScale: CGFloat
    @Binding var zoomScaleAtGestureStart: CGFloat
    let editPlayer: EditPlayerService   // used by coordinator to drive CALayer playhead

    let beatSchedule: [BeatInfo]
    let isSnapEnabled: Bool
    let stemSelections: [URL: Range<Double>]   // per-stem region selections

    let onSeek: (Double) -> Void
    let onOffsetChange: (URL, Double) -> Void
    let onTrimInChange: (URL, Double) -> Void
    let onTrimOutChange: (URL, Double?) -> Void
    let onSelectionChange: (Range<Double>?) -> Void  // ruler-based: applies globally
    let onSetStemSelection: (URL, Range<Double>?) -> Void  // canvas no-CMD: replace all
    let onAddStemSelection: (URL, Range<Double>?) -> Void  // canvas CMD: update this stem

    private let rulerHeight: CGFloat = 24

    // MARK: Coordinator

    class Coordinator: NSObject {
        var parent: WaveformScrollHost
        weak var scrollView: NSScrollView?
        var hostingView: NSHostingView<AnyView>?

        var gestureStartZoom: CGFloat = 1
        var gestureFocalFraction: CGFloat = 0

        var playheadLayer: CAShapeLayer?
        var gridDownbeatLayer: CAShapeLayer?
        var gridBeatLayer: CAShapeLayer?
        var gridSubdivLayer: CAShapeLayer?
        var rulerBarNumberLayer: CALayer?   // container for bar number CATextLayers
        var waveformContainer: CALayer?    // container for per-stem waveform + outline layers
        var lastContentVersion: Int = -1

        init(_ parent: WaveformScrollHost) { self.parent = parent }

        @objc func handleMagnification(_ r: NSMagnificationGestureRecognizer) {
            guard let sv = scrollView else { return }
            let clipView = sv.contentView

            switch r.state {
            case .began:
                gestureStartZoom = parent.zoomScale
                let focalX = r.location(in: clipView).x
                let contentW = clipView.documentRect.width
                gestureFocalFraction = contentW > 0 ? focalX / contentW : 0.5

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

    /// Hash of properties that require a full SwiftUI tree rebuild when they change.
    /// Excludes currentTime and masterPeakDB so 30–43 Hz ticks don't trigger rebuilds.
    private var contentVersion: Int {
        var h = Hasher()
        h.combine(stemURLs)
        h.combine(zoomScale)
        for (url, r) in stemSelections {
            h.combine(url); h.combine(r.lowerBound); h.combine(r.upperBound)
        }
        h.combine(beatSchedule.count)
        h.combine(totalDuration)
        for url in stemURLs {
            let s = stemStates[url]
            h.combine(s?.peaks.count ?? 0)
            h.combine(s?.cuts.count ?? 0)
            h.combine(s?.trimIn)
            h.combine(s?.trimOut)
            h.combine(rowHeights[url])
            h.combine(s?.isMuted)
            h.combine(s?.isSoloed)
            h.combine(s?.segments.count ?? 0)
            for seg in s?.segments ?? [] {
                h.combine(seg.sessionStart)
                h.combine(seg.sourceStart)
                h.combine(seg.sourceEnd)
            }
        }
        return h.finalize()
    }

    /// Explicit document size so NSHostingView is never undersized.
    /// Canvas has no intrinsic height, so sizingOptions = .intrinsicContentSize
    /// collapses the hosting view to only a couple of rows.
    private var documentSize: CGSize {
        let tracksH = stemURLs.reduce(CGFloat(0)) { $0 + (rowHeights[$1] ?? defaultRowHeight) + 1 }
        let w = max(CGFloat(totalDuration) * 80.0 * zoomScale, 400)
        return CGSize(width: w, height: max(tracksH + rulerHeight, 1))
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
        hv.wantsLayer = true
        sv.documentView = hv

        // Make the clip view layer-backed so it composites directly against NSHostingView's
        // CALayer via CoreAnimation. Without this, NSClipView uses a traditional drawRect:
        // bitmap cache that goes stale when SwiftUI renders new content into hv's layer — the
        // bitmap only refreshes on scroll (which is why the zoom gesture was "fixing" it).
        sv.contentView.wantsLayer = true

        // CALayer grid — 3 shape layers (downbeat, beat, subdivision) behind everything.
        // CAShapeLayer is vector-based: no backing-store texture, so no GPU size limit.
        let gridDownbeat = CAShapeLayer()
        gridDownbeat.strokeColor = NSColor(Color.fgMid).withAlphaComponent(0.45).cgColor
        gridDownbeat.lineWidth = 1
        gridDownbeat.fillColor = nil
        gridDownbeat.frame = CGRect(origin: .zero, size: documentSize)
        gridDownbeat.zPosition = -3
        hv.layer?.addSublayer(gridDownbeat)

        let gridBeat = CAShapeLayer()
        gridBeat.strokeColor = NSColor(Color.fgMid).withAlphaComponent(0.18).cgColor
        gridBeat.lineWidth = 0.5
        gridBeat.fillColor = nil
        gridBeat.frame = CGRect(origin: .zero, size: documentSize)
        gridBeat.zPosition = -2
        hv.layer?.addSublayer(gridBeat)

        let gridSubdiv = CAShapeLayer()
        gridSubdiv.strokeColor = NSColor(Color.fgMid).withAlphaComponent(0.08).cgColor
        gridSubdiv.lineWidth = 0.5
        gridSubdiv.fillColor = nil
        gridSubdiv.frame = CGRect(origin: .zero, size: documentSize)
        gridSubdiv.zPosition = -1
        hv.layer?.addSublayer(gridSubdiv)

        // CALayer ruler bar numbers — container layer holds one CATextLayer per downbeat
        let rulerBarNumbers = CALayer()
        rulerBarNumbers.frame = CGRect(x: 0, y: 0, width: documentSize.width, height: 24)
        rulerBarNumbers.zPosition = 5
        hv.layer?.addSublayer(rulerBarNumbers)

        // CALayer waveform container — per-stem waveform fills + segment outlines
        let waveformContainer = CALayer()
        waveformContainer.frame = CGRect(origin: .zero, size: documentSize)
        waveformContainer.zPosition = 0
        hv.layer?.addSublayer(waveformContainer)

        // CALayer playhead — single vertical line over all tracks, moved by Combine subscription
        let pl = CAShapeLayer()
        pl.backgroundColor = NSColor.white.withAlphaComponent(0.9).cgColor
        pl.frame = CGRect(x: 0, y: 0, width: 1.5, height: documentSize.height)
        pl.zPosition = 10
        hv.layer?.addSublayer(pl)

        let mag = NSMagnificationGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleMagnification(_:))
        )
        sv.addGestureRecognizer(mag)

        context.coordinator.scrollView = sv
        context.coordinator.hostingView = hv
        context.coordinator.playheadLayer = pl
        context.coordinator.gridDownbeatLayer = gridDownbeat
        context.coordinator.gridBeatLayer = gridBeat
        context.coordinator.gridSubdivLayer = gridSubdiv
        context.coordinator.rulerBarNumberLayer = rulerBarNumbers
        context.coordinator.waveformContainer = waveformContainer
        return sv
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.parent = self

        // Always update playhead CALayer position — fast, no SwiftUI rebuild
        if totalDuration > 0 {
            let totalWidth = max(CGFloat(totalDuration) * 80.0 * zoomScale, 400)
            let x = CGFloat(editPlayer.currentTime / totalDuration) * totalWidth
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            context.coordinator.playheadLayer?.frame.origin.x = x
            CATransaction.commit()
        }

        // Only rebuild SwiftUI tree when structural content changes (not on every time tick)
        let cv = contentVersion
        guard cv != context.coordinator.lastContentVersion else { return }
        context.coordinator.lastContentVersion = cv

        if let hv = context.coordinator.hostingView {
            // Frame must be set BEFORE rootView so SwiftUI lays out content
            // at the correct size. Setting rootView first causes SwiftUI to
            // compute layout against the stale (smaller) frame, leaving the
            // waveforms narrow until the next zoom gesture.
            let ds = documentSize
            hv.frame = CGRect(origin: .zero, size: ds)
            context.coordinator.playheadLayer?.frame.size.height = ds.height

            // Rebuild CALayer grid paths — vector-based, no texture size limits
            let gridRect = CGRect(x: 0, y: rulerHeight, width: ds.width, height: ds.height - rulerHeight)
            context.coordinator.gridDownbeatLayer?.frame = gridRect
            context.coordinator.gridBeatLayer?.frame = gridRect
            context.coordinator.gridSubdivLayer?.frame = gridRect

            if totalDuration > 0 {
                let downbeatPath = CGMutablePath()
                let beatPath = CGMutablePath()
                let subdivPath = CGMutablePath()
                let gridH = gridRect.height
                let gridW = gridRect.width

                for beat in beatSchedule {
                    let x = CGFloat(beat.timeSeconds / totalDuration) * gridW
                    if beat.isDownbeat {
                        downbeatPath.move(to: CGPoint(x: x, y: 0))
                        downbeatPath.addLine(to: CGPoint(x: x, y: gridH))
                    } else if beat.isSubdivisionTick {
                        subdivPath.move(to: CGPoint(x: x, y: 0))
                        subdivPath.addLine(to: CGPoint(x: x, y: gridH))
                    } else {
                        beatPath.move(to: CGPoint(x: x, y: 0))
                        beatPath.addLine(to: CGPoint(x: x, y: gridH))
                    }
                }

                CATransaction.begin()
                CATransaction.setDisableActions(true)
                context.coordinator.gridDownbeatLayer?.path = downbeatPath
                context.coordinator.gridBeatLayer?.path = beatPath
                context.coordinator.gridSubdivLayer?.path = subdivPath
                CATransaction.commit()

                // Rebuild ruler bar number text layers
                if let rulerContainer = context.coordinator.rulerBarNumberLayer {
                    rulerContainer.frame = CGRect(x: 0, y: 0, width: ds.width, height: rulerHeight)
                    rulerContainer.sublayers?.forEach { $0.removeFromSuperlayer() }

                    let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                    let textColor = NSColor(Color.fgMid)

                    for beat in beatSchedule where beat.isDownbeat {
                        let x = CGFloat(beat.timeSeconds / totalDuration) * ds.width
                        let tl = CATextLayer()
                        tl.string = "\(beat.bar)"
                        tl.font = NSFont(name: "Lato-Regular", size: 9) ?? NSFont.systemFont(ofSize: 9)
                        tl.fontSize = 9
                        tl.foregroundColor = textColor.cgColor
                        tl.contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0
                        tl.alignmentMode = .left
                        tl.frame = CGRect(x: x + 3, y: 4, width: 40, height: 14)
                        rulerContainer.addSublayer(tl)
                    }
                }
            }

            // Rebuild per-stem waveform CAShapeLayers — vector-based, no texture limit
            if let wfContainer = context.coordinator.waveformContainer {
                wfContainer.frame = CGRect(origin: .zero, size: ds)
                wfContainer.sublayers?.forEach { $0.removeFromSuperlayer() }

                let fgMidColor = NSColor(Color.fgMid)
                var yOff = rulerHeight

                for url in stemURLs {
                    let state = stemStates[url] ?? StemState()
                    let h = rowHeights[url] ?? defaultRowHeight
                    let mid = h / 2
                    let totalW = ds.width

                    // Waveform fill
                    let fillLayer = CAShapeLayer()
                    fillLayer.frame = CGRect(x: 0, y: yOff, width: totalW, height: h)
                    fillLayer.fillColor = fgMidColor.withAlphaComponent(0.30).cgColor
                    fillLayer.strokeColor = nil

                    let fillPath = CGMutablePath()
                    let effectiveDur = max(totalDuration, 1.0)

                    if !state.segments.isEmpty && totalDuration > 0 {
                        let stemDur = state.duration > 0 ? state.duration : effectiveDur
                        for segment in state.segments.sorted(by: { $0.sessionStart < $1.sessionStart }) {
                            let segX = CGFloat(segment.sessionStart / effectiveDur) * totalW
                            let segEnd = CGFloat(segment.sessionEnd / effectiveDur) * totalW
                            let segW = segEnd - segX
                            guard segW > 0.5, !state.peaks.isEmpty else { continue }

                            let pkStart = max(0, Int(segment.sourceStart / stemDur * Double(state.peaks.count)))
                            let pkEnd = min(state.peaks.count, Int(segment.sourceEnd / stemDur * Double(state.peaks.count)))
                            guard pkEnd > pkStart else { continue }
                            let sub = Array(state.peaks[pkStart..<pkEnd])
                            let count = sub.count

                            for i in 0..<count {
                                let x = segX + CGFloat(i) / CGFloat(count) * segW
                                let amp = CGFloat(sub[i]) * mid * 0.9
                                if i == 0 { fillPath.move(to: CGPoint(x: x, y: mid - amp)) }
                                else { fillPath.addLine(to: CGPoint(x: x, y: mid - amp)) }
                            }
                            for i in stride(from: count - 1, through: 0, by: -1) {
                                let x = segX + CGFloat(i) / CGFloat(count) * segW
                                let amp = CGFloat(sub[i]) * mid * 0.9
                                fillPath.addLine(to: CGPoint(x: x, y: mid + amp))
                            }
                            fillPath.closeSubpath()

                            // Segment outline
                            let outlineLayer = CAShapeLayer()
                            outlineLayer.frame = CGRect(x: 0, y: yOff, width: totalW, height: h)
                            let outlinePath = CGMutablePath()
                            outlinePath.addRoundedRect(in: CGRect(x: segX + 0.5, y: 0.5, width: segW - 1, height: h - 1), cornerWidth: 4, cornerHeight: 4)
                            outlineLayer.path = outlinePath
                            outlineLayer.fillColor = nil
                            outlineLayer.strokeColor = fgMidColor.withAlphaComponent(0.5).cgColor
                            outlineLayer.lineWidth = 1.5
                            wfContainer.addSublayer(outlineLayer)

                            // Clip header bar — full segment width, name left-justified (Ableton style)
                            let stemDisplayName = url.deletingPathExtension().lastPathComponent
                            let headerBg = CALayer()
                            headerBg.frame = CGRect(x: segX + 1, y: yOff + 1, width: segW - 2, height: 18)
                            headerBg.backgroundColor = NSColor(white: 0, alpha: 0.28).cgColor
                            headerBg.zPosition = 2
                            wfContainer.addSublayer(headerBg)

                            let headerLabel = CATextLayer()
                            headerLabel.string = stemDisplayName
                            headerLabel.font = NSFont(name: "Lato-Bold", size: 10) ?? NSFont.boldSystemFont(ofSize: 10)
                            headerLabel.fontSize = 10
                            headerLabel.foregroundColor = NSColor.white.withAlphaComponent(0.9).cgColor
                            headerLabel.contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0
                            headerLabel.alignmentMode = .left
                            headerLabel.masksToBounds = true
                            headerLabel.frame = CGRect(x: segX + 7, y: yOff + 3, width: max(segW - 14, 0), height: 14)
                            headerLabel.zPosition = 3
                            wfContainer.addSublayer(headerLabel)
                        }
                    } else if !state.peaks.isEmpty {
                        // Legacy single-clip path
                        let stemDur = state.duration > 0 ? state.duration : effectiveDur
                        let stemW = totalW * CGFloat(min(stemDur, effectiveDur) / effectiveDur)
                        let count = state.peaks.count
                        for i in 0..<count {
                            let x = CGFloat(i) / CGFloat(count) * stemW
                            let amp = CGFloat(state.peaks[i]) * mid * 0.9
                            if i == 0 { fillPath.move(to: CGPoint(x: x, y: mid - amp)) }
                            else { fillPath.addLine(to: CGPoint(x: x, y: mid - amp)) }
                        }
                        for i in stride(from: count - 1, through: 0, by: -1) {
                            let x = CGFloat(i) / CGFloat(count) * stemW
                            let amp = CGFloat(state.peaks[i]) * mid * 0.9
                            fillPath.addLine(to: CGPoint(x: x, y: mid + amp))
                        }
                        fillPath.closeSubpath()

                        // Clip outline
                        let outlineLayer = CAShapeLayer()
                        outlineLayer.frame = CGRect(x: 0, y: yOff, width: totalW, height: h)
                        let outlinePath = CGMutablePath()
                        outlinePath.addRoundedRect(in: CGRect(x: 1, y: 1, width: totalW - 2, height: h - 2), cornerWidth: 4, cornerHeight: 4)
                        outlineLayer.path = outlinePath
                        outlineLayer.fillColor = nil
                        outlineLayer.strokeColor = fgMidColor.withAlphaComponent(0.5).cgColor
                        outlineLayer.lineWidth = 1.5
                        wfContainer.addSublayer(outlineLayer)

                        // Clip header bar — full clip width, name left-justified (Ableton style)
                        let stemDisplayName = url.deletingPathExtension().lastPathComponent
                        let headerBg = CALayer()
                        headerBg.frame = CGRect(x: 1, y: yOff + 1, width: stemW - 2, height: 18)
                        headerBg.backgroundColor = NSColor(white: 0, alpha: 0.28).cgColor
                        headerBg.zPosition = 2
                        wfContainer.addSublayer(headerBg)

                        let headerLabel = CATextLayer()
                        headerLabel.string = stemDisplayName
                        headerLabel.font = NSFont(name: "Lato-Bold", size: 10) ?? NSFont.boldSystemFont(ofSize: 10)
                        headerLabel.fontSize = 10
                        headerLabel.foregroundColor = NSColor.white.withAlphaComponent(0.9).cgColor
                        headerLabel.contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0
                        headerLabel.alignmentMode = .left
                        headerLabel.masksToBounds = true
                        headerLabel.frame = CGRect(x: 7, y: yOff + 3, width: max(stemW - 14, 0), height: 14)
                        headerLabel.zPosition = 3
                        wfContainer.addSublayer(headerLabel)
                    }

                    fillLayer.path = fillPath
                    wfContainer.addSublayer(fillLayer)

                    // Region selection overlay
                    if let sel = stemSelections[url], totalDuration > 0 {
                        let accentColor = NSColor(Color.accent)
                        let sx = CGFloat(sel.lowerBound / totalDuration) * totalW
                        let ex = CGFloat(sel.upperBound / totalDuration) * totalW
                        let selW = ex - sx

                        let selFill = CALayer()
                        selFill.frame = CGRect(x: sx, y: yOff, width: selW, height: h)
                        selFill.backgroundColor = accentColor.withAlphaComponent(0.20).cgColor
                        selFill.zPosition = 4
                        wfContainer.addSublayer(selFill)

                        let leftEdge = CALayer()
                        leftEdge.frame = CGRect(x: sx, y: yOff, width: 1.5, height: h)
                        leftEdge.backgroundColor = accentColor.withAlphaComponent(0.7).cgColor
                        leftEdge.zPosition = 5
                        wfContainer.addSublayer(leftEdge)

                        let rightEdge = CALayer()
                        rightEdge.frame = CGRect(x: ex - 1.5, y: yOff, width: 1.5, height: h)
                        rightEdge.backgroundColor = accentColor.withAlphaComponent(0.7).cgColor
                        rightEdge.zPosition = 5
                        wfContainer.addSublayer(rightEdge)
                    }

                    yOff += h + 1  // +1 for Divider
                }
            }

            hv.rootView = AnyView(waveformContent())
            DispatchQueue.main.async { [weak nsView] in
                guard let sv = nsView else { return }
                sv.tile()
                let origin = sv.contentView.bounds.origin
                sv.contentView.scroll(to: origin)
                sv.reflectScrolledClipView(sv.contentView)
            }
        }
    }

    // MARK: Content builder

    private func waveformContent() -> some View {
        let tracksH = stemURLs.reduce(CGFloat(0)) { $0 + (rowHeights[$1] ?? defaultRowHeight) + 1 }
        return ZStack(alignment: .topLeading) {
            // Grid is now rendered via CAShapeLayers (see updateNSView) — no Canvas size limits.

            // Ruler + track rows on top
            VStack(spacing: 0) {
                let rulerRange: Range<Double>? = {
                    guard !stemSelections.isEmpty else { return nil }
                    let lo = stemSelections.values.map(\.lowerBound).min()!
                    let hi = stemSelections.values.map(\.upperBound).max()!
                    return lo..<hi
                }()
                TimeRulerView(
                    beatSchedule: beatSchedule,
                    totalDuration: totalDuration,
                    zoomScale: zoomScale,
                    isSnapEnabled: isSnapEnabled,
                    selectionRange: rulerRange,
                    onSelectionChange: onSelectionChange,
                    onMoveSelectionPreview: { newRange in onSelectionChange(newRange) },
                    onMoveSelectionCommit: { originalRange, finalRange in
                        onSelectionChange(finalRange)
                        let delta = finalRange.lowerBound - originalRange.lowerBound
                        let targets = stemSelections.isEmpty ? Set(stemURLs) : Set(stemSelections.keys)
                        for url in targets {
                            let lo = (stemSelections[url]?.lowerBound ?? originalRange.lowerBound)
                            let hi = (stemSelections[url]?.upperBound ?? originalRange.upperBound)
                            editPlayer.moveRegion(url, lo: lo, hi: hi, to: lo + delta)
                        }
                    }
                )
                ForEach(stemURLs, id: \.self) { url in
                    let state = stemStates[url] ?? StemState()
                    let height = rowHeights[url] ?? defaultRowHeight
                    let clipStart = state.segments.min(by: { $0.sessionStart < $1.sessionStart })?.sessionStart ?? 0

                    EditWaveformCanvas(
                        peaks: state.peaks,
                        segments: state.segments,
                        clipSessionStart: clipStart,
                        stemDuration: state.duration > 0 ? state.duration : totalDuration,
                        offset: state.offset,
                        trimIn: state.trimIn,
                        trimOut: state.trimOut,
                        cuts: state.cuts,
                        totalDuration: totalDuration,
                        zoomScale: zoomScale,
                        beatSchedule: beatSchedule,
                        isSnapEnabled: isSnapEnabled,
                        selectionRange: stemSelections[url],
                        isLocked: false,
                        onSeek: onSeek,
                        onOffsetChange: { newClipStart in onOffsetChange(url, newClipStart) },
                        onTrimInChange: { onTrimInChange(url, $0) },
                        onTrimOutChange: { onTrimOutChange(url, $0) },
                        onSetSelection: { range in onSetStemSelection(url, range) },
                        onAddSelection: { range in onAddStemSelection(url, range) }
                    )
                    .frame(height: height)

                    Divider().foregroundColor(Color.border)
                }

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

// MARK: - Snap utility

/// Returns the nearest beat time from the schedule to `time`.
private func snapToGrid(_ time: Double, schedule: [BeatInfo]) -> Double {
    guard !schedule.isEmpty else { return time }
    return schedule.min(by: { abs($0.timeSeconds - time) < abs($1.timeSeconds - time) })?.timeSeconds ?? time
}

// MARK: - GridBackgroundCanvas

/// Single shared grid Canvas drawn once behind all tracks. Replaces per-track grid drawing.
struct GridBackgroundCanvas: View {
    let beatSchedule: [BeatInfo]
    let totalDuration: Double
    let zoomScale: CGFloat
    let height: CGFloat

    var body: some View {
        let totalWidth = max(CGFloat(totalDuration) * 80.0 * zoomScale, 400)
        Canvas { ctx, size in
            guard totalDuration > 0 else { return }
            for beat in beatSchedule {
                let x = CGFloat(beat.timeSeconds / totalDuration) * size.width
                var line = Path()
                line.move(to: CGPoint(x: x, y: 0))
                line.addLine(to: CGPoint(x: x, y: size.height))
                if beat.isDownbeat {
                    ctx.stroke(line, with: .color(Color.fgMid.opacity(0.45)), lineWidth: 1)
                } else if beat.isSubdivisionTick {
                    ctx.stroke(line, with: .color(Color.fgMid.opacity(0.08)), lineWidth: 0.5)
                } else {
                    ctx.stroke(line, with: .color(Color.fgMid.opacity(0.18)), lineWidth: 0.5)
                }
            }
        }
        .frame(width: totalWidth, height: height)
        .allowsHitTesting(false)
    }
}

// MARK: - TempoGridView

/// Full-height Canvas that draws vertical grid lines for every beat in the schedule.
struct TempoGridView: View {
    let beatSchedule: [BeatInfo]
    let totalDuration: Double
    let zoomScale: CGFloat
    let height: CGFloat

    var body: some View {
        let totalWidth = max(CGFloat(totalDuration) * 80.0 * zoomScale, 400)
        Canvas { ctx, size in
            guard totalDuration > 0 else { return }
            for beat in beatSchedule {
                let x = CGFloat(beat.timeSeconds / totalDuration) * size.width
                var line = Path()
                line.move(to: CGPoint(x: x, y: 0))
                line.addLine(to: CGPoint(x: x, y: size.height))
                if beat.isDownbeat {
                    ctx.stroke(line, with: .color(Color.fgMid.opacity(0.45)), lineWidth: 1)
                } else if beat.isSubdivisionTick {
                    ctx.stroke(line, with: .color(Color.fgMid.opacity(0.08)), lineWidth: 0.5)
                } else {
                    ctx.stroke(line, with: .color(Color.fgMid.opacity(0.18)), lineWidth: 0.5)
                }
            }
        }
        .frame(width: totalWidth, height: height)
    }
}

// MARK: - TimeRulerView

/// 24 px ruler strip above the track area. Shows bar numbers at each downbeat.
/// Drag here to set a time-range selection; single tap clears it.
struct TimeRulerView: View {
    let beatSchedule: [BeatInfo]
    let totalDuration: Double
    let zoomScale: CGFloat
    let isSnapEnabled: Bool
    let selectionRange: Range<Double>?
    let onSelectionChange: (Range<Double>?) -> Void
    /// Called during drag when moving an existing selection — provides the in-progress (preview) range.
    let onMoveSelectionPreview: (Range<Double>) -> Void
    /// Called on drag end when moving an existing selection — provides (originalRange, finalRange).
    let onMoveSelectionCommit: (Range<Double>, Range<Double>) -> Void

    @State private var dragStartTime: Double? = nil
    @State private var isMoveMode: Bool = false
    @State private var moveDragStartSelection: Range<Double>? = nil
    @State private var moveDragStartX: CGFloat? = nil

    private func timeFor(x: CGFloat, in totalWidth: CGFloat) -> Double {
        guard totalWidth > 0, totalDuration > 0 else { return 0 }
        return max(0, min(totalDuration, Double(x / totalWidth) * totalDuration))
    }

    private func shiftedRange(_ range: Range<Double>, by delta: Double) -> Range<Double> {
        let len = range.upperBound - range.lowerBound
        let lo = max(0, range.lowerBound + delta)
        return lo..<(lo + len)
    }

    var body: some View {
        let totalWidth = max(CGFloat(totalDuration) * 80.0 * zoomScale, 400)

        Canvas { ctx, size in
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color.bgCard.opacity(0.9)))

            if let range = selectionRange, totalDuration > 0 {
                let sx = CGFloat(range.lowerBound / totalDuration) * size.width
                let ex = CGFloat(range.upperBound / totalDuration) * size.width
                ctx.fill(Path(CGRect(x: sx, y: 0, width: ex - sx, height: size.height)),
                         with: .color(Color.accent.opacity(0.25)))
                // Drag-handle indicator when selection is active
                var leftEdge = Path()
                leftEdge.move(to: CGPoint(x: sx, y: 0)); leftEdge.addLine(to: CGPoint(x: sx, y: size.height))
                ctx.stroke(leftEdge, with: .color(Color.accent.opacity(0.7)), lineWidth: 2)
                var rightEdge = Path()
                rightEdge.move(to: CGPoint(x: ex, y: 0)); rightEdge.addLine(to: CGPoint(x: ex, y: size.height))
                ctx.stroke(rightEdge, with: .color(Color.accent.opacity(0.7)), lineWidth: 2)
            }

            // Bar numbers are rendered via CATextLayers (see updateNSView) for pixel-accurate
            // positioning at any zoom level — Canvas backing store has GPU texture size limits.

            var border = Path()
            border.move(to: CGPoint(x: 0, y: size.height - 0.5))
            border.addLine(to: CGPoint(x: size.width, y: size.height - 0.5))
            ctx.stroke(border, with: .color(Color.border), lineWidth: 1)
        }
        .frame(width: totalWidth, height: 24)
        .cursor(isMoveMode ? .openHand : .arrow)
        .gesture(
            SpatialTapGesture()
                .onEnded { _ in onSelectionChange(nil) }
        )
        .gesture(
            DragGesture(minimumDistance: 2)
                .onChanged { value in
                    if !isMoveMode && dragStartTime == nil && moveDragStartSelection == nil {
                        // First frame — decide mode
                        let tapT = timeFor(x: value.startLocation.x, in: totalWidth)
                        if let existing = selectionRange, existing.contains(tapT) {
                            isMoveMode = true
                            moveDragStartSelection = existing
                            moveDragStartX = value.startLocation.x
                        } else {
                            let raw = timeFor(x: value.startLocation.x, in: totalWidth)
                            let snapped = isSnapEnabled && !beatSchedule.isEmpty
                                ? snapToGrid(raw, schedule: beatSchedule) : raw
                            dragStartTime = snapped
                        }
                    }

                    if isMoveMode, let startSel = moveDragStartSelection, let startX = moveDragStartX {
                        let dx = value.location.x - startX
                        let delta = Double(dx / totalWidth) * totalDuration
                        onMoveSelectionPreview(shiftedRange(startSel, by: delta))
                    } else if let t0 = dragStartTime {
                        let rawT1 = timeFor(x: value.location.x, in: totalWidth)
                        let t1 = isSnapEnabled && !beatSchedule.isEmpty
                            ? snapToGrid(rawT1, schedule: beatSchedule) : rawT1
                        let lo = min(t0, t1); let hi = max(t0, t1)
                        if hi - lo > 0.001 { onSelectionChange(lo..<hi) }
                    }
                }
                .onEnded { value in
                    if isMoveMode, let startSel = moveDragStartSelection, let startX = moveDragStartX {
                        let dx = value.location.x - startX
                        let delta = Double(dx / totalWidth) * totalDuration
                        let finalRange = shiftedRange(startSel, by: delta)
                        onMoveSelectionCommit(startSel, finalRange)
                    } else {
                        let t0 = dragStartTime ?? timeFor(x: value.startLocation.x, in: totalWidth)
                        let rawT1 = timeFor(x: value.location.x, in: totalWidth)
                        let t1 = isSnapEnabled && !beatSchedule.isEmpty
                            ? snapToGrid(rawT1, schedule: beatSchedule) : rawT1
                        let lo = min(t0, t1); let hi = max(t0, t1)
                        if hi - lo > 0.001 { onSelectionChange(lo..<hi) }
                        else { onSelectionChange(nil) }
                    }
                    dragStartTime = nil
                    isMoveMode = false
                    moveDragStartSelection = nil
                    moveDragStartX = nil
                }
        )
    }
}

// MARK: - SelectionOverlayView

/// Translucent overlay that fills the selected time range across the full track height.
struct SelectionOverlayView: View {
    let range: Range<Double>
    let totalDuration: Double
    let zoomScale: CGFloat
    let height: CGFloat

    var body: some View {
        let totalWidth = max(CGFloat(totalDuration) * 80.0 * zoomScale, 400)
        Canvas { ctx, size in
            guard totalDuration > 0 else { return }
            let sx = CGFloat(range.lowerBound / totalDuration) * size.width
            let ex = CGFloat(range.upperBound / totalDuration) * size.width
            let rect = CGRect(x: sx, y: 0, width: ex - sx, height: size.height)
            ctx.fill(Path(rect), with: .color(Color.accent.opacity(0.12)))
            // Left edge
            var left = Path()
            left.move(to: CGPoint(x: sx, y: 0))
            left.addLine(to: CGPoint(x: sx, y: size.height))
            ctx.stroke(left, with: .color(Color.accent.opacity(0.5)), lineWidth: 1)
            // Right edge
            var right = Path()
            right.move(to: CGPoint(x: ex, y: 0))
            right.addLine(to: CGPoint(x: ex, y: size.height))
            ctx.stroke(right, with: .color(Color.accent.opacity(0.5)), lineWidth: 1)
        }
        .frame(width: totalWidth, height: height)
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

// MARK: - Delete key helper (macOS 13+ compatible)

extension View {
    /// Fires `action` when the user presses the Delete key while this view is in focus.
    /// Uses `onKeyPress` on macOS 14+ and falls back to `onDeleteCommand` on macOS 13.
    @ViewBuilder
    func onDeleteRegion(perform action: @escaping () -> Void) -> some View {
        if #available(macOS 14.0, *) {
            self.onKeyPress(.delete) { action(); return .handled }
                .onKeyPress(.deleteForward) { action(); return .handled }
        } else {
            self.onDeleteCommand(perform: action)
        }
    }
}
