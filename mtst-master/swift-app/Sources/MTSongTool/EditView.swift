import SwiftUI
import AppKit
import AVFoundation
import UniformTypeIdentifiers

// MARK: - EditView (root)

struct EditView: View {
    @ObservedObject var editPlayer: EditPlayerService
    @ObservedObject var metronome: MetronomeService
    let stemURLs: [URL]
    @ObservedObject var analyzer: AudioAnalyzerService
    let parsedResult: ParsedResult?
    var onLocatorFix: ([(Marker, String)]) -> Void = { _ in }
    var mtCompleteMode: Bool = false
    var onFolderDrop: ((URL) -> Void)? = nil

    @ObservedObject private var userSettings = UserSettings.shared

    // Timeline state
    @State private var zoomScale: CGFloat = 0.25       // horizontal zoom multiplier
    @State private var zoomScaleAtGestureStart: CGFloat = 0.25
    @State private var isSnapEnabled: Bool = true
    @State private var selectedURLs: Set<URL> = []      // sidebar M/S/Gain group
    @State private var stemSelections: [URL: Range<Double>] = [:]  // per-stem region selections
    @State private var selectedClipIDs: Set<UUID> = []             // per-segment clip selection for multi-trim
    @State private var rowHeights: [URL: CGFloat] = [:]
    @State private var defaultRowHeight: CGFloat = 64
    @State private var hasFitZoom: Bool = false
    @State private var viewportWidth: CGFloat = 0
    @State private var canvasRightPadding: Double = 0   // extra seconds grown when user scrolls near right edge
    @State private var isFolderDropTargeted: Bool = false

    // Commit state
    @State private var isCommitting: Bool = false

    @State private var commitError: String? = nil
    @State private var showCommitError: Bool = false
    @State private var showLargeOffsetWarning: Bool = false
    @State private var largeOffsetSeconds: Double = 0

    // MARK: - Computed helpers

    /// Loop bracket: bar 1 (beat 0) → 1 bar before NEXT SONG. Recalculates from NEXT SONG
    /// each time — ignores any saved value in the .als XML.
    private var loopBracket: (endBeat: Double, endSeconds: Double, bar: Int)? {
        let allMarkers = parsedResult?.markers ?? []
        guard let ns = allMarkers.first(where: { $0.text.uppercased() == "NEXT SONG" }) else { return nil }
        let nsBeat: Double
        if let ov = editPlayer.locatorOverrides[ns.alsId], let b = ov.beat {
            nsBeat = b
        } else if let b = ns.beat {
            nsBeat = b
        } else {
            // Fallback: derive beat from time string via beatSchedule (works without rebuilt parser)
            let schedule = metronome.beatSchedule
            guard let secs = markerTimeToSeconds(ns.time), !schedule.isEmpty else { return nil }
            let closest = schedule.min(by: { abs($0.timeSeconds - secs) < abs($1.timeSeconds - secs) })
            nsBeat = closest?.absoluteBeat ?? 0
        }

        let timeSigs = parsedResult?.timeSignatures ?? []
        let ts = timeSigs.filter { ($0.beat ?? 0) <= nsBeat }.last ?? timeSigs.first
        let parts = ts?.sig.split(separator: "/") ?? []
        let num = Double(parts.first.map(String.init) ?? "4") ?? 4
        let den = Double(parts.last.map(String.init)  ?? "4") ?? 4
        let beatsPerBar = num * (4.0 / den)

        let loopEndBeat = nsBeat - beatsPerBar
        guard loopEndBeat > 0 else { return nil }

        let schedule = metronome.beatSchedule
        let secs = editBeatToSeconds(loopEndBeat, schedule: schedule)
        let bar = schedule.filter { $0.isDownbeat && $0.absoluteBeat <= loopEndBeat + 0.01 }.last?.bar ?? 1
        return (loopEndBeat, secs, bar)
    }

    private func markerTimeToSeconds(_ time: String) -> Double? {
        let parts = time.split(separator: ":")
        if parts.count == 3, let m = Double(parts[0]), let s = Double(parts[1]), let ms = Double(parts[2]) {
            return m * 60 + s + ms / 1000
        }
        if parts.count == 2, let m = Double(parts[0]), let s = Double(parts[1]) {
            return m * 60 + s
        }
        return nil
    }

    private func editBeatToSeconds(_ beat: Double, schedule: [BeatInfo]) -> Double {
        guard !schedule.isEmpty else { return 0 }
        var prev = schedule[0]
        for info in schedule { if info.absoluteBeat > beat { break }; prev = info }
        return prev.timeSeconds
    }

    private func formatLoopTime(_ secs: Double) -> String {
        let m = Int(secs) / 60
        let s = Int(secs) % 60
        let ms = Int((secs - Double(Int(secs))) * 1000)
        return String(format: "%d:%02d.%03d", m, s, ms)
    }

    private static let protectedStemNames: Set<String> = ["CLICK TRACK", "GUIDE", "ORIGINAL SONG"]

    private func isProtectedStemURL(_ url: URL) -> Bool {
        Self.protectedStemNames.contains(url.deletingPathExtension().lastPathComponent.uppercased())
    }

    /// CLICK TRACK → GUIDE → ORIGINAL SONG pinned to top; remainder alphabetical.
    /// Excludes stems marked isExcluded (deleted via Delete key, restorable via undo).
    private var sortedStemURLs: [URL] {
        let priority: [String: Int] = ["CLICK TRACK": 0, "GUIDE": 1, "ORIGINAL SONG": 2]
        return stemURLs
            .filter { editPlayer.stemStates[$0]?.isExcluded != true }
            .sorted { a, b in
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

    /// Duration of one bar at end of session — used to compute canvas padding.
    private var lastBarSeconds: Double {
        let db = metronome.beatSchedule.filter { $0.isDownbeat }
        guard db.count >= 2 else { return 2.0 }
        return max(0.25, db[db.count - 1].timeSeconds - db[db.count - 2].timeSeconds)
    }

    /// Build the beat schedule and extend it to cover the full canvas (audio + 10 empty bars).
    /// Called whenever the session or stems change so the grid fills the entire scrollable area.
    private func rebuildBeatSchedule() {
        guard let result = parsedResult else { return }
        let audioDur = result.expectedDuration ?? editPlayer.totalDuration
        guard audioDur > 0 else { return }
        // First pass: build up to audio end so lastBarSeconds is accurate.
        metronome.buildSchedule(
            tempoEvents: result.tempoEvents,
            timeSigs: result.timeSignatures,
            totalDuration: audioDur,
            staticBPM: result.bpm
        )
        // Second pass: extend to cover the full canvas (10-bar tail + any scroll padding).
        let extendedDur = canvasDuration
        guard extendedDur > audioDur else { return }
        metronome.buildSchedule(
            tempoEvents: result.tempoEvents,
            timeSigs: result.timeSignatures,
            totalDuration: extendedDur,
            staticBPM: result.bpm
        )
    }

    /// Canvas width = totalDuration + 10 bars of empty space + any dynamic right padding grown from scrolling.
    /// The 10-bar tail keeps end-of-session markers visible; canvasRightPadding grows as the user
    /// scrolls or drags stems further right, giving effectively infinite rightward space.
    private var canvasDuration: Double {
        guard editPlayer.totalDuration > 0 else { return 0 }
        return editPlayer.totalDuration + lastBarSeconds * 10 + canvasRightPadding
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
                .stroke(isFolderDropTargeted ? Color.accent : Color.border, lineWidth: isFolderDropTargeted ? 2 : 1)
                .animation(.easeOut(duration: 0.12), value: isFolderDropTargeted)
        )
        .onDrop(of: [UTType.fileURL, .folder], isTargeted: $isFolderDropTargeted) { providers in
            guard let onFolderDrop, let provider = providers.first else { return false }
            let typeId = provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
                ? UTType.fileURL.identifier : "public.folder"
            provider.loadItem(forTypeIdentifier: typeId, options: nil) { item, _ in
                DispatchQueue.main.async {
                    var url: URL?
                    if let data = item as? Data { url = URL(dataRepresentation: data, relativeTo: nil) }
                    else if let u = item as? NSURL { url = u as URL }
                    else if let u = item as? URL { url = u }
                    guard let url else { return }
                    var isDir: ObjCBool = false
                    FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
                    if isDir.boolValue { onFolderDrop(url) }
                }
            }
            return true
        }
        .onAppear {
            // Share edit engine with metronome for sample-accurate click sync
            metronome.attachToEngine(editPlayer.engine)

            if editPlayer.stemURLs.isEmpty || editPlayer.stemURLs != stemURLs {
                editPlayer.loadStems(stemURLs)
            }
            // Build metronome beat schedule from parsed session
            rebuildBeatSchedule()
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
            guard dur > 0 else { return }
            // Rebuild so grid covers any new space created by dragging a stem right.
            rebuildBeatSchedule()
            guard !hasFitZoom, viewportWidth > 0 else { return }
            hasFitZoom = true
            let fitZoom = max(0.01, min(1.0, viewportWidth / (CGFloat(dur) * 80.0)))
            zoomScale = fitZoom
            zoomScaleAtGestureStart = fitZoom
        }
        .onChange(of: canvasRightPadding) { _ in
            rebuildBeatSchedule()
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
            canvasRightPadding = 0
            selectedClipIDs = []
            editPlayer.loadStems(newURLs)
            rebuildBeatSchedule()
        }
        .alert("Commit Error", isPresented: $showCommitError) {
            Button("OK") {}
        } message: {
            Text(commitError ?? "Unknown error")
        }
        .alert("Large Stem Offset", isPresented: $showLargeOffsetWarning) {
            Button("Commit Anyway", role: .destructive) { performCommit() }
            Button("Cancel", role: .cancel) {}
        } message: {
            let mins = Int(largeOffsetSeconds) / 60
            let secs = Int(largeOffsetSeconds) % 60
            let formatted = mins > 0 ? "\(mins)m \(secs)s" : "\(secs)s"
            Text("One or more stems are offset by \(formatted). Committing will prepend that much silence to the output file. Are you sure?")
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
                editPlayer.saveUndoSnapshot()
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

            // Normalize Stems
            if editPlayer.isNormalizing {
                HStack(spacing: 4) {
                    ProgressView().scaleEffect(0.7).tint(Color.accent)
                    Text("Scanning…")
                        .font(.lato(size: 11, weight: .regular))
                        .foregroundColor(Color.fgMid)
                }
            } else {
                Button("Normalize Stems") {
                    editPlayer.normalizeStems()
                }
                .font(.lato(size: 11, weight: .regular))
                .foregroundColor(editPlayer.hasCollectiveStems ? Color.fgBright : Color.fgMid)
                .buttonStyle(.plain)
                .disabled(!editPlayer.hasCollectiveStems)
                .help("Set collective stems to −0.01 dBFS true peak; ORIGINAL SONG to −6 dBFS")
            }

            Divider().frame(height: 18)

            // Master peak meter
            MasterPeakMeter(peakDB: editPlayer.masterPeakDB)
                .frame(height: 10)

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

    // MARK: - Loop bracket info strip

    private var loopBracketStrip: some View {
        HStack(spacing: 0) {
            Color.bgCard.frame(width: 220)
            Divider().foregroundColor(Color.border)
            HStack(spacing: 6) {
                Image(systemName: "repeat")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(Color.accent.opacity(0.7))
                if let lb = loopBracket {
                    Text("Loop: bar 1 (0:00.000) → bar \(lb.bar) (\(formatLoopTime(lb.endSeconds)))")
                        .font(.lato(size: 10, weight: .medium))
                        .foregroundColor(Color.fgMid)
                } else {
                    Text("Loop: no NEXT SONG marker")
                        .font(.lato(size: 10, weight: .regular))
                        .foregroundColor(Color.fgMid.opacity(0.6))
                }
            }
            .padding(.horizontal, 10)
            Spacer()
        }
        .frame(height: 22)
        .background(Color.bgCard)
        .overlay(alignment: .bottom) { Divider().foregroundColor(Color.border) }
    }

    // MARK: - Timeline

    private var timelineView: some View {
        VStack(spacing: 0) {
        loopBracketStrip
        ScrollView(.vertical) {
            HStack(alignment: .top, spacing: 0) {

                // Left column: track headers — anchored, never scrolls horizontally
                VStack(spacing: 0) {
                    Color.bgCard
                        .frame(width: 220, height: WaveformScrollHost.rulerLaneHeight + WaveformScrollHost.locatorLaneHeight)
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
                            isLockedStem: isProtectedStemURL(url),
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
                            },
                            analyzerResult: analyzer.results.first(where: { $0.filename == url.lastPathComponent }),
                            onRename: { newName in
                                analyzer.renameStem(oldFilename: url.lastPathComponent, newStemName: newName)
                            },
                            onRemoveStem: isProtectedStemURL(url) ? nil : {
                                editPlayer.removeStem(url)
                                selectedURLs.remove(url)
                            }
                        )

                        Divider().foregroundColor(Color.border)
                    }
                }
                .frame(width: 220)

                Divider().foregroundColor(Color.border)

                // Right column: waveforms — NSScrollView host for mouse-centered zoom
                ZStack(alignment: .topLeading) {
                    WaveformScrollHost(
                        stemURLs: sortedStemURLs,
                        stemStates: editPlayer.stemStates,
                        rowHeights: rowHeights,
                        defaultRowHeight: defaultRowHeight,
                        totalDuration: canvasDuration,
                        zoomScale: $zoomScale,
                        zoomScaleAtGestureStart: $zoomScaleAtGestureStart,
                        editPlayer: editPlayer,
                        beatSchedule: metronome.beatSchedule,
                        isSnapEnabled: isSnapEnabled,
                        stemSelections: stemSelections,
                        markers: parsedResult?.markers ?? [],
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
                            if let range { stemSelections = [url: range] } else { stemSelections = [:]; selectedClipIDs = [] }
                        },
                        onAddStemSelection: { url, range in
                            if let range { stemSelections[url] = range } else { stemSelections.removeValue(forKey: url) }
                        },
                        onApproachingRightEdge: {
                            // Grow the canvas by ~20 bars so the grid continues beyond the current right edge.
                            canvasRightPadding += lastBarSeconds * 20
                        },
                        onSetMultiStemSelection: { urls, range in
                            if let range {
                                stemSelections = Dictionary(uniqueKeysWithValues: urls.map { ($0, range) })
                            } else {
                                stemSelections = [:]
                            }
                        },
                        onDeleteRegion: {
                            guard !stemSelections.isEmpty else { return }
                            editPlayer.saveUndoSnapshot()
                            for (url, range) in stemSelections {
                                editPlayer.deleteRegion(url, lo: range.lowerBound, hi: range.upperBound)
                            }
                            stemSelections = [:]
                        },
                        onRemoveStem: {
                            let toRemove = selectedURLs.filter { !isProtectedStemURL($0) }
                            guard !toRemove.isEmpty else { return }
                            for url in toRemove { editPlayer.removeStem(url) }
                            selectedURLs.subtract(toRemove)
                        },
                        selectedURLs: selectedURLs,
                        onLocatorFix: onLocatorFix,
                        onLocatorMove: { alsId, newBeat in
                            editPlayer.moveLocator(alsId: alsId, toBeat: newBeat)
                        },
                        locatorOverrides: editPlayer.locatorOverrides,
                        mtCompleteMode: mtCompleteMode,
                        selectedClipIDs: selectedClipIDs,
                        onSelectClip: { id, additive in
                            if additive {
                                if selectedClipIDs.contains(id) { selectedClipIDs.remove(id) }
                                else { selectedClipIDs.insert(id) }
                            } else {
                                selectedClipIDs = [id]
                                stemSelections = [:]  // clear region selection — new intent is clip/stem
                            }
                            // Sync stem selection so Delete works after clicking a clip
                            selectedURLs = Set(selectedClipIDs.compactMap { clipID in
                                editPlayer.stemURLs.first(where: {
                                    editPlayer.stemStates[$0]?.segments.contains(where: { $0.id == clipID }) == true
                                })
                            })
                        },
                        onTrimLeftEdge: { _, id, delta in
                            let ids = selectedClipIDs.contains(id) && selectedClipIDs.count > 1
                                ? selectedClipIDs : Set([id])
                            editPlayer.trimSegmentsLeft(ids: ids, delta: delta)
                        },
                        onTrimRightEdge: { _, id, delta in
                            let ids = selectedClipIDs.contains(id) && selectedClipIDs.count > 1
                                ? selectedClipIDs : Set([id])
                            editPlayer.trimSegmentsRight(ids: ids, delta: delta)
                        },
                        onRemoveStemByURL: { url in
                            editPlayer.removeStem(url)
                            selectedURLs.remove(url)
                        }
                    )

                    // Name labels are rendered as CATextLayers inside waveformContainer (move with clip on drag)
                }
                .frame(maxWidth: .infinity)
                .frame(height: sortedStemURLs.reduce(CGFloat(0)) {
                    $0 + (rowHeights[$1] ?? defaultRowHeight) + 1
                } + WaveformScrollHost.rulerLaneHeight + WaveformScrollHost.locatorLaneHeight)
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
            Color.bgCard.frame(width: 220)
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
            Image(systemName: isFolderDropTargeted ? "folder.fill" : "waveform")
                .font(.system(size: 28))
                .foregroundColor(isFolderDropTargeted ? Color.accent : Color.fgMid)
                .animation(.easeOut(duration: 0.12), value: isFolderDropTargeted)
            Text(isFolderDropTargeted ? "Release to load session" : "No stems loaded")
                .font(.lato(size: 13))
                .foregroundColor(isFolderDropTargeted ? Color.accent : Color.fgMid)
            if !isFolderDropTargeted {
                Text("Drop a session folder here, or run a Stem Check in the QA tab.")
                    .font(.lato(size: 11))
                    .foregroundColor(Color.fgDim)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(isFolderDropTargeted ? Color.dropHovBg : Color.clear)
        .animation(.easeOut(duration: 0.12), value: isFolderDropTargeted)
    }

    // MARK: - Name Bar Overlay

    /// Semi-transparent name chips pinned to the left edge of the waveform area.
    /// Lives outside the NSScrollView so horizontal scroll doesn't carry them away.
    private var waveformNameOverlay: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: WaveformScrollHost.rulerLaneHeight + WaveformScrollHost.locatorLaneHeight)
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
        // Warn if any stem has been dragged more than 30 seconds right — commit will
        // prepend that much silence to the output file.
        let maxOffset = editPlayer.stemStates.values
            .compactMap { $0.segments.min(by: { $0.sessionStart < $1.sessionStart })?.sessionStart }
            .max() ?? 0
        if maxOffset > 30 {
            largeOffsetSeconds = maxOffset
            showLargeOffsetWarning = true
            return
        }
        performCommit()
    }

    private func performCommit() {
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
    var isLockedStem: Bool = false

    let onToggleMute: () -> Void
    let onToggleSolo: () -> Void
    let onGainChange: (Float) -> Void
    let onSelect: () -> Void
    let onResizeRow: (CGFloat) -> Void
    var analyzerResult: AudioFileResult? = nil
    var onRename: ((String) -> Void)? = nil
    var onRemoveStem: (() -> Void)? = nil

    @State private var resizeStartHeight: CGFloat? = nil
    @State private var isEditingGain = false
    @State private var gainEditText = ""
    @State private var renamePicker = false
    @State private var renameSelection = ""
    @State private var renameDismissedViaEnter = false
    @State private var pencilHover = false
    @State private var allTimePeak: Float = -96.0

    var stemName: String { url.deletingPathExtension().lastPathComponent }

    private var hasNamingIssue: Bool { !(analyzerResult?.issues.isEmpty ?? true) }
    private static let sortedApprovedStems: [String] = AudioAnalyzerService.approvedStems.sorted()

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
            // Row header — tap to select; double-click name to rename
            HStack(spacing: 4) {
                Button { onSelect() } label: {
                    HStack(spacing: 4) {
                        if isSelected {
                            Image(systemName: "checkmark")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(Color.accent)
                        }
                        Text(stemName)
                            .font(.lato(size: 11, weight: .medium))
                            .foregroundColor(hasNamingIssue ? Color.red : Color.fgBright)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .popover(isPresented: $renamePicker, arrowEdge: .trailing) {
                                PickerPopoverContent(
                                    options: Self.sortedApprovedStems,
                                    selection: $renameSelection,
                                    isPresented: $renamePicker,
                                    dismissedViaEnter: $renameDismissedViaEnter,
                                    suggestions: analyzerResult?.suggestedNames ?? []
                                )
                            }
                    }
                }
                .buttonStyle(.plain)
                .simultaneousGesture(TapGesture(count: 2).onEnded {
                    if onRename != nil {
                        renameSelection = stemName
                        renamePicker = true
                    }
                })
                .onChange(of: renamePicker) { isOpen in
                    if !isOpen && !renameSelection.isEmpty && renameSelection != stemName {
                        onRename?(renameSelection)
                    }
                }

                if onRename != nil {
                    Button {
                        renameSelection = stemName
                        renamePicker = true
                    } label: {
                        Image(systemName: "pencil")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundColor(pencilHover ? .accent : (hasNamingIssue ? Color.red.opacity(0.7) : .fgMid))
                            .frame(width: 16, height: 16)
                            .background(RoundedRectangle(cornerRadius: 3)
                                .fill(pencilHover ? Color.accent.opacity(0.15) : Color.clear))
                    }
                    .buttonStyle(.plain)
                    .contentShape(Rectangle())
                    .onHover { h in withAnimation(.easeOut(duration: 0.12)) { pencilHover = h } }
                }
            }

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

                // Locked stems (OG/Guide/Click) get peak-hold meter in remaining space
                if isLockedStem {
                    LockedStemMeter(peakDB: meterDB, allTimePeak: allTimePeak) {
                        allTimePeak = -96
                    }
                }
            }
            .onChange(of: meterDB) { db in
                if isLockedStem, db > allTimePeak { allTimePeak = db }
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
        .frame(width: 220, height: height, alignment: .topLeading)
        .background(isSelected ? Color.accent.opacity(0.08) : Color.bgCard)
        .contextMenu {
            if let remove = onRemoveStem {
                Button(role: .destructive) { remove() } label: {
                    Label("Remove from Session", systemImage: "trash")
                }
            }
        }
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

private enum TrimEdge { case left, right }

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

    var selectedClipIDs: Set<UUID> = []
    var onSelectClip: (UUID, Bool) -> Void = { _, _ in }
    var onTrimLeftEdge: (UUID, Double) -> Void = { _, _ in }
    var onTrimRightEdge: (UUID, Double) -> Void = { _, _ in }

    // Cross-stem selection: plain drag reports which stem-index range the mouse has crossed.
    var stemIndex: Int = 0
    var allStemHeights: [CGFloat] = []
    var onSetCrossSelection: (Int, Int, Range<Double>?) -> Void = { _, _, _ in }
    var onBeginInteraction: () -> Void = {}
    var onRemoveStem: (() -> Void)? = nil

    @State private var dragStartClipStart: Double? = nil
    @State private var optionDragStartTime: Double? = nil
    @State private var isDraggingForSelection: Bool = false
    @State private var isDraggingAdditive: Bool = false    // CMD held at drag start
    @State private var trimEdge: TrimEdge? = nil
    @State private var trimLastX: CGFloat? = nil
    @State private var trimSegmentID: UUID? = nil

    // Name bar zone height — no visual drawn here; overlay in EditView handles rendering.
    // Top 18px of the canvas acts as the drag-to-move zone; below = selection zone.
    private let nameBarHeight: CGFloat = 18

    private var effectiveDuration: Double { max(totalDuration, 1) }

    /// Returns the nearest trim edge (left/right) and its segment ID if the tap location is
    /// within 8px of any segment boundary. Trim takes priority over name-bar move.
    private func findTrimEdge(at location: CGPoint, totalWidth: CGFloat) -> (TrimEdge, UUID)? {
        guard !segments.isEmpty, effectiveDuration > 0 else { return nil }
        let hitZone: CGFloat = 8
        for seg in segments {
            let leftX  = CGFloat(seg.sessionStart / effectiveDuration) * totalWidth
            let rightX = CGFloat(seg.sessionEnd   / effectiveDuration) * totalWidth
            if abs(location.x - leftX)  <= hitZone { return (.left,  seg.id) }
            if abs(location.x - rightX) <= hitZone { return (.right, seg.id) }
        }
        return nil
    }
    /// Returns the lo/hi stem indices covered by the vertical extent of the drag.
    /// Uses the drag's startLocation.y and location.y (both in this canvas's coordinate space)
    /// along with the heights of all stems to find which rows the mouse crossed.
    private func computeStemRange(startY: CGFloat, currentY: CGFloat) -> (Int, Int) {
        guard !allStemHeights.isEmpty, stemIndex < allStemHeights.count else {
            return (stemIndex, stemIndex)
        }
        let myHeight = allStemHeights[stemIndex]
        let topY    = min(startY, currentY)
        let bottomY = max(startY, currentY)
        var loIdx = stemIndex
        var hiIdx = stemIndex
        if topY < 0 {
            var remaining: CGFloat = -topY
            var idx = stemIndex - 1
            while idx >= 0 && remaining > 0 {
                loIdx = idx
                remaining -= allStemHeights[idx] + 1   // +1 for row divider
                idx -= 1
            }
        }
        if bottomY > myHeight {
            var remaining: CGFloat = bottomY - myHeight
            var idx = stemIndex + 1
            while idx < allStemHeights.count && remaining > 0 {
                hiIdx = idx
                remaining -= allStemHeights[idx] + 1
                idx += 1
            }
        }
        return (loIdx, hiIdx)
    }

    private static let pixelsPerSecondBase: CGFloat = 80.0

    var body: some View {
        let totalWidth = max(CGFloat(effectiveDuration) * Self.pixelsPerSecondBase * zoomScale, 400)
        let pixelsPerSecond = Self.pixelsPerSecondBase * zoomScale

        // Waveform fills + outlines are now rendered via CAShapeLayers (see updateNSView)
        // for pixel-accurate positioning at any zoom. This Canvas is a transparent gesture target.
        Color.clear
            .frame(width: totalWidth)
        .background(Color.bg.opacity(0.15))
        .contentShape(Rectangle())
        .gesture(
            // Single gesture handles both taps and drags.
            // minimumDistance: 0 ensures onEnded always fires even for zero-movement clicks,
            // which is required because SpatialTapGesture doesn't reliably fire inside
            // NSHostingView/NSScrollView on macOS.
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    let isOption = NSEvent.modifierFlags.contains(.option)

                    // Suppress mode detection until the drag exceeds 2px — prevents accidental
                    // mode-setting on tiny jitter from minimumDistance: 0.
                    let dist = sqrt(pow(value.translation.width, 2) + pow(value.translation.height, 2))
                    guard dist >= 2 else { return }

                    // First frame: decide mode.
                    // Trim takes priority: if drag starts within 8px of a segment edge → trim.
                    // Then name-bar zone (top 18px) → move clip.
                    // Otherwise (or Option held) → region select. CMD = additive.
                    if trimEdge == nil && !isDraggingForSelection && dragStartClipStart == nil && optionDragStartTime == nil {
                        if let (edge, segID) = findTrimEdge(at: value.startLocation, totalWidth: totalWidth) {
                            onBeginInteraction()
                            trimEdge = edge
                            trimSegmentID = segID
                            trimLastX = value.startLocation.x
                        } else {
                            let inNameBar = value.startLocation.y <= nameBarHeight
                            if inNameBar && !isOption {
                                onBeginInteraction()
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
                    }

                    if let edge = trimEdge, let segID = trimSegmentID {
                        let deltaX = value.location.x - (trimLastX ?? value.startLocation.x)
                        trimLastX = value.location.x
                        if deltaX != 0 {
                            let deltaSeconds = Double(deltaX / pixelsPerSecond)
                            if edge == .left { onTrimLeftEdge(segID, deltaSeconds) }
                            else { onTrimRightEdge(segID, deltaSeconds) }
                        }
                    } else if isDraggingForSelection {
                        let t0 = optionDragStartTime ?? 0
                        let rawT1 = Double(value.location.x / totalWidth) * effectiveDuration
                        let t1 = isSnapEnabled && !beatSchedule.isEmpty
                            ? snapToGrid(rawT1, schedule: beatSchedule) : rawT1
                        let lo = min(t0, t1); let hi = max(t0, t1)
                        if hi - lo > 0.001 {
                            if isDraggingAdditive {
                                onAddSelection(lo..<hi)
                            } else {
                                let (loStem, hiStem) = computeStemRange(startY: value.startLocation.y, currentY: value.location.y)
                                onSetCrossSelection(loStem, hiStem, lo..<hi)
                            }
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
                    // Tap detection: if no drag mode was set (onChanged never advanced past the
                    // 2px guard), treat as a click — seek and optionally clear selections.
                    let isTap = trimEdge == nil && !isDraggingForSelection && dragStartClipStart == nil
                    if isTap {
                        let time = Double(value.startLocation.x / totalWidth) * effectiveDuration
                        let clamped = max(0, min(effectiveDuration, time))
                        let isCmd = NSEvent.modifierFlags.contains(.command)
                        if let seg = segments.first(where: { $0.sessionStart <= clamped + 0.001 && $0.sessionEnd >= clamped - 0.001 }) {
                            onSelectClip(seg.id, isCmd)
                        } else {
                            onSetSelection(nil)
                        }
                        onSeek(clamped)
                        return
                    }

                    if let edge = trimEdge, let segID = trimSegmentID {
                        let deltaX = value.location.x - (trimLastX ?? value.startLocation.x)
                        if deltaX != 0 {
                            let deltaSeconds = Double(deltaX / pixelsPerSecond)
                            if edge == .left { onTrimLeftEdge(segID, deltaSeconds) }
                            else { onTrimRightEdge(segID, deltaSeconds) }
                        }
                    } else if isDraggingForSelection {
                        let t0 = optionDragStartTime ?? 0
                        let rawT1 = Double(value.location.x / totalWidth) * effectiveDuration
                        let t1 = isSnapEnabled && !beatSchedule.isEmpty
                            ? snapToGrid(rawT1, schedule: beatSchedule) : rawT1
                        let lo = min(t0, t1); let hi = max(t0, t1)
                        if hi - lo > 0.001 {
                            if isDraggingAdditive {
                                onAddSelection(lo..<hi)
                            } else {
                                let (loStem, hiStem) = computeStemRange(startY: value.startLocation.y, currentY: value.location.y)
                                onSetCrossSelection(loStem, hiStem, lo..<hi)
                            }
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
                    trimEdge = nil
                    trimLastX = nil
                    trimSegmentID = nil
                    dragStartClipStart = nil
                    optionDragStartTime = nil
                    isDraggingForSelection = false
                    isDraggingAdditive = false
                }
        )
        .onContinuousHover { phase in
            switch phase {
            case .active(let loc):
                if let _ = findTrimEdge(at: loc, totalWidth: totalWidth) {
                    NSCursor.resizeLeftRight.set()
                } else if loc.y <= nameBarHeight {
                    NSCursor.openHand.set()
                } else {
                    NSCursor.crosshair.set()
                }
            case .ended:
                NSCursor.arrow.set()
            }
        }
        .contextMenu {
            if let remove = onRemoveStem {
                Button(role: .destructive) { remove() } label: {
                    Label("Remove from Session", systemImage: "trash")
                }
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

// MARK: - EditScrollView

/// NSScrollView subclass that handles Delete/Forward-Delete in the responder chain.
/// Belt-and-suspenders with the AppKit local event monitor: even if the monitor is bypassed,
/// the scroll view handles the keys gracefully and never beeps.
private class EditScrollView: NSScrollView {
    var onDeleteKey: (() -> Void)?
    var onForwardDeleteKey: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        window?.makeFirstResponder(self)
    }

    override func keyDown(with event: NSEvent) {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.keyCode == 51 && mods.isEmpty {          // ⌫ Delete
            onDeleteKey?()
            return
        }
        if event.keyCode == 117 && mods.isEmpty {         // ⌦ Forward Delete
            onForwardDeleteKey?()
            return
        }
        super.keyDown(with: event)
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
    let markers: [Marker]                       // locators from QA tab — displayed as section flags

    let onSeek: (Double) -> Void
    let onOffsetChange: (URL, Double) -> Void
    let onTrimInChange: (URL, Double) -> Void
    let onTrimOutChange: (URL, Double?) -> Void
    let onSelectionChange: (Range<Double>?) -> Void  // ruler-based: applies globally
    let onSetStemSelection: (URL, Range<Double>?) -> Void  // canvas no-CMD: replace all
    let onAddStemSelection: (URL, Range<Double>?) -> Void  // canvas CMD: update this stem
    let onApproachingRightEdge: () -> Void           // called when scroll nears the right edge — grow canvas
    var onSetMultiStemSelection: ([URL], Range<Double>?) -> Void = { _, _ in }
    var onDeleteRegion: () -> Void = {}
    var onRemoveStem: () -> Void = {}
    var selectedURLs: Set<URL> = []
    var onLocatorFix: ([(Marker, String)]) -> Void = { _ in }
    var onLocatorMove: (String, Double) -> Void = { _, _ in }  // (alsId, newBeat)
    var locatorOverrides: [String: LocatorOverride] = [:]
    var mtCompleteMode: Bool = false
    var selectedClipIDs: Set<UUID> = []
    var onSelectClip: (UUID, Bool) -> Void = { _, _ in }
    var onTrimLeftEdge: (URL, UUID, Double) -> Void = { _, _, _ in }
    var onTrimRightEdge: (URL, UUID, Double) -> Void = { _, _, _ in }
    var onRemoveStemByURL: ((URL) -> Void)? = nil

    private static let protectedStemNames: Set<String> = ["CLICK TRACK", "GUIDE", "ORIGINAL SONG"]
    private func isProtectedURL(_ url: URL) -> Bool {
        Self.protectedStemNames.contains(url.deletingPathExtension().lastPathComponent.uppercased())
    }

    // 24px bar-number ruler + 20px locator lane
    static let rulerLaneHeight: CGFloat = 24
    static let locatorLaneHeight: CGFloat = 20
    private let rulerHeight: CGFloat = WaveformScrollHost.rulerLaneHeight + WaveformScrollHost.locatorLaneHeight

    // MARK: - Time helper
    private static func markerSeconds(_ time: String) -> Double? {
        let parts = time.split(separator: ":")
        if parts.count == 3,
           let m = Double(parts[0]), let s = Double(parts[1]), let ms = Double(parts[2]) {
            return m * 60 + s + ms / 1000
        }
        if parts.count == 2,
           let m = Double(parts[0]), let s = Double(parts[1]) {
            return m * 60 + s
        }
        return nil
    }

    // MARK: Coordinator

    class Coordinator: NSObject {
        var parent: WaveformScrollHost
        weak var scrollView: NSScrollView?
        var hostingView: NSHostingView<AnyView>?

        var gestureStartZoom: CGFloat = 1
        var gestureFocalFraction: CGFloat = 0
        var isZooming: Bool = false   // suppresses waveform path rebuild during pinch

        var playheadLayer: CAShapeLayer?
        var gridDownbeatLayer: CAShapeLayer?
        var gridBeatLayer: CAShapeLayer?
        var gridSubdivLayer: CAShapeLayer?
        var rulerBarNumberLayer: CALayer?   // container for bar number CATextLayers
        var locatorLineLayer: CAShapeLayer? // vertical lines through tracks at each locator
        var waveformContainer: CALayer?    // container for per-stem waveform + outline layers
        var lastContentVersion: Int = -1
        var keyMonitor: Any?

        init(_ parent: WaveformScrollHost) { self.parent = parent }

        deinit {
            if let m = keyMonitor { NSEvent.removeMonitor(m) }
        }

        @objc func handleMagnification(_ r: NSMagnificationGestureRecognizer) {
            guard let sv = scrollView else { return }
            let clipView = sv.contentView

            switch r.state {
            case .began:
                isZooming = true
                gestureStartZoom = parent.zoomScale
                let focalX = r.location(in: clipView).x
                let contentW = clipView.documentRect.width
                gestureFocalFraction = contentW > 0 ? focalX / contentW : 0.5

            case .changed, .ended:
                let newZoom = max(0.01, min(100, gestureStartZoom * (1 + r.magnification)))
                parent.zoomScale = newZoom
                if r.state == .ended {
                    isZooming = false
                    parent.zoomScaleAtGestureStart = newZoom
                }

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

        /// Grow the canvas when the user scrolls within one viewport of the right edge.
        /// Self-regulating: once the canvas grows, the condition clears automatically.
        @objc func handleLiveScroll(_ notification: Notification) {
            guard let sv = notification.object as? NSScrollView,
                  let docView = sv.documentView else { return }
            let rightEdge = sv.documentVisibleRect.maxX
            let contentWidth = docView.frame.width
            let viewportWidth = sv.bounds.width
            guard contentWidth - rightEdge < viewportWidth else { return }
            DispatchQueue.main.async { [weak self] in
                self?.parent.onApproachingRightEdge()
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
        h.combine(markers.count)
        for m in markers { h.combine(m.time); h.combine(m.text) }
        for id in selectedClipIDs.sorted(by: { $0.uuidString < $1.uuidString }) { h.combine(id) }
        h.combine(locatorOverrides.count)
        for (alsId, ov) in locatorOverrides.sorted(by: { $0.key < $1.key }) {
            h.combine(alsId); h.combine(ov.beat)
        }
        return h.finalize()
    }

    /// Convert Ableton beat position to session seconds using the beat schedule.
    private func secondsForBeat(_ beat: Double) -> Double {
        guard !beatSchedule.isEmpty else { return 0 }
        var prev = beatSchedule[0]
        for info in beatSchedule {
            if info.absoluteBeat > beat { break }
            prev = info
        }
        return prev.timeSeconds
    }

    /// Effective session seconds for a marker, respecting locatorOverrides.
    private func effectiveSecondsForMarker(_ m: Marker) -> Double? {
        guard !m.text.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        if let ov = locatorOverrides[m.alsId], let overrideBeat = ov.beat {
            return secondsForBeat(overrideBeat)
        }
        if let beat = m.beat {
            return secondsForBeat(beat)
        }
        return Self.markerSeconds(m.time)
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
        let sv = EditScrollView()
        sv.onDeleteKey = { [weak coordinator = context.coordinator] in
            guard let c = coordinator else { return }
            DispatchQueue.main.async {
                if !c.parent.stemSelections.isEmpty { c.parent.onDeleteRegion() }
                else if !c.parent.selectedURLs.isEmpty { c.parent.onRemoveStem() }
            }
        }
        sv.onForwardDeleteKey = { [weak coordinator = context.coordinator] in
            guard let c = coordinator else { return }
            DispatchQueue.main.async {
                if !c.parent.selectedURLs.isEmpty { c.parent.onRemoveStem() }
            }
        }
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
        rulerBarNumbers.frame = CGRect(x: 0, y: 0, width: documentSize.width, height: WaveformScrollHost.rulerLaneHeight)
        rulerBarNumbers.zPosition = 5
        hv.layer?.addSublayer(rulerBarNumbers)

        // CALayer locator vertical lines — subtle dividers through track area at each locator
        let locatorLines = CAShapeLayer()
        locatorLines.strokeColor = NSColor.white.withAlphaComponent(0.12).cgColor
        locatorLines.lineWidth = 1
        locatorLines.fillColor = nil
        locatorLines.frame = CGRect(x: 0, y: WaveformScrollHost.rulerLaneHeight, width: documentSize.width, height: documentSize.height - WaveformScrollHost.rulerLaneHeight)
        locatorLines.zPosition = 1
        hv.layer?.addSublayer(locatorLines)

        // CALayer waveform container — per-stem waveform fills + segment outlines
        let waveformContainer = CALayer()
        waveformContainer.anchorPoint = CGPoint(x: 0, y: 0)
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
        context.coordinator.locatorLineLayer = locatorLines
        context.coordinator.waveformContainer = waveformContainer

        // Observe live scroll to grow the canvas when the user approaches the right edge.
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.handleLiveScroll(_:)),
            name: NSScrollView.didLiveScrollNotification,
            object: sv
        )

        // Delete key monitor — AppKit-level so it works regardless of SwiftUI focus state.
        // Guards against firing when a text field is active (firstResponder is NSTextView/NSTextField).
        context.coordinator.keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak coordinator = context.coordinator] event in
            guard let c = coordinator,
                  !(NSApp.keyWindow?.firstResponder is NSTextView),
                  !(NSApp.keyWindow?.firstResponder is NSTextField)
            else { return event }
            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            // ⌫ Delete (keyCode 51) — region delete if region selected, else stem delete
            if event.keyCode == 51 && mods.isEmpty {
                if !c.parent.stemSelections.isEmpty {
                    DispatchQueue.main.async { c.parent.onDeleteRegion() }
                } else if !c.parent.selectedURLs.isEmpty {
                    DispatchQueue.main.async { c.parent.onRemoveStem() }
                }
                return nil
            }
            // ⌦ Forward Delete (keyCode 117) — dedicated stem delete (ignores region selection)
            if event.keyCode == 117 && mods.isEmpty {
                if !c.parent.selectedURLs.isEmpty {
                    DispatchQueue.main.async { c.parent.onRemoveStem() }
                }
                return nil
            }
            // CMD+Z — undo
            if event.keyCode == 6 && mods == .command {
                DispatchQueue.main.async { c.parent.editPlayer.undo() }
                return nil
            }
            // CMD+SHIFT+Z — redo
            if event.keyCode == 6 && mods == [.command, .shift] {
                DispatchQueue.main.async { c.parent.editPlayer.redo() }
                return nil
            }
            return event
        }

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

                // Rebuild ruler bar number text layers — stride-spaced so labels don't crowd
                if let rulerContainer = context.coordinator.rulerBarNumberLayer {
                    rulerContainer.frame = CGRect(x: 0, y: 0, width: ds.width, height: WaveformScrollHost.rulerLaneHeight)
                    rulerContainer.sublayers?.forEach { $0.removeFromSuperlayer() }

                    let textColor = NSColor(Color.fgMid)
                    let downbeats = beatSchedule.filter { $0.isDownbeat }

                    // Compute pixels between consecutive downbeats, then choose a stride so
                    // labels are at least 40px apart (prevents cramming at low zoom).
                    let minLabelSpacingPx: CGFloat = 40
                    let avgBarPx: CGFloat = {
                        guard downbeats.count > 1 else { return ds.width }
                        let xs = downbeats.map { CGFloat($0.timeSeconds / totalDuration) * ds.width }
                        let diffs = zip(xs, xs.dropFirst()).map { $1 - $0 }
                        return diffs.reduce(0, +) / CGFloat(diffs.count)
                    }()
                    let stride = max(1, Int(ceil(minLabelSpacingPx / avgBarPx)))

                    for beat in downbeats {
                        guard (beat.bar - 1) % stride == 0 else { continue }
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

                // Vertical marker lines through track area — positions respect locatorOverrides
                let markerPositions: [(x: CGFloat, label: String)] = markers.compactMap { m in
                    guard let secs = effectiveSecondsForMarker(m) else { return nil }
                    return (CGFloat(secs / totalDuration) * ds.width, m.text)
                }.sorted { $0.x < $1.x }
                if let lineLayer = context.coordinator.locatorLineLayer {
                    let trackAreaH = ds.height - WaveformScrollHost.rulerLaneHeight
                    lineLayer.frame = CGRect(x: 0, y: WaveformScrollHost.rulerLaneHeight,
                                            width: ds.width, height: trackAreaH)
                    let linePath = CGMutablePath()
                    for pos in markerPositions {
                        linePath.move(to: CGPoint(x: pos.x, y: 0))
                        linePath.addLine(to: CGPoint(x: pos.x, y: trackAreaH))
                    }
                    CATransaction.begin()
                    CATransaction.setDisableActions(true)
                    lineLayer.path = linePath
                    CATransaction.commit()
                }

            }

            // Rebuild per-stem waveform CAShapeLayers — during pinch zoom, scale the container
            // via CATransform3D so waveforms track the gesture without path recomputation.
            // On gesture end (isZooming = false), reset transform and do full rebuild.
            if let wfContainer = context.coordinator.waveformContainer {
            if context.coordinator.isZooming {
                let startWidth = max(CGFloat(totalDuration) * 80.0 * zoomScaleAtGestureStart, 400)
                let scaleX = startWidth > 0 ? ds.width / startWidth : 1
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                wfContainer.frame = CGRect(origin: .zero, size: CGSize(width: startWidth, height: ds.height))
                wfContainer.transform = CATransform3DMakeScale(scaleX, 1, 1)
                CATransaction.commit()
            } else {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                wfContainer.transform = CATransform3DIdentity
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
                            // Cap to ~1 peak per display point — full detail when zoomed in,
                            // avoids bloated paths when the segment is small on screen.
                            let renderCount = max(1, min(count, Int(segW * 2)))
                            func subPeak(_ i: Int) -> Float {
                                renderCount < count ? sub[Int(Float(i) / Float(renderCount) * Float(count))] : sub[i]
                            }
                            for i in 0..<renderCount {
                                let x = segX + CGFloat(i) / CGFloat(renderCount) * segW
                                let amp = CGFloat(subPeak(i)) * mid * 0.9
                                if i == 0 { fillPath.move(to: CGPoint(x: x, y: mid - amp)) }
                                else { fillPath.addLine(to: CGPoint(x: x, y: mid - amp)) }
                            }
                            for i in stride(from: renderCount - 1, through: 0, by: -1) {
                                let x = segX + CGFloat(i) / CGFloat(renderCount) * segW
                                let amp = CGFloat(subPeak(i)) * mid * 0.9
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

                            // Clip selection: accent tint + outline when this segment is in selectedClipIDs
                            if selectedClipIDs.contains(segment.id) {
                                let clipSelFill = CALayer()
                                clipSelFill.frame = CGRect(x: segX, y: yOff, width: segW, height: h)
                                clipSelFill.backgroundColor = NSColor(Color.accent).withAlphaComponent(0.25).cgColor
                                clipSelFill.zPosition = 4
                                wfContainer.addSublayer(clipSelFill)

                                let clipSelOutline = CAShapeLayer()
                                clipSelOutline.frame = CGRect(x: 0, y: yOff, width: totalW, height: h)
                                let clipSelPath = CGMutablePath()
                                clipSelPath.addRoundedRect(in: CGRect(x: segX + 0.5, y: 0.5, width: segW - 1, height: h - 1), cornerWidth: 4, cornerHeight: 4)
                                clipSelOutline.path = clipSelPath
                                clipSelOutline.fillColor = nil
                                clipSelOutline.strokeColor = NSColor(Color.accent).cgColor
                                clipSelOutline.lineWidth = 2
                                clipSelOutline.zPosition = 5
                                wfContainer.addSublayer(clipSelOutline)
                            }

                            // Trim grip strips — 6px handles at each segment edge (brightened on hover via cursor)
                            let leftGrip = CALayer()
                            leftGrip.frame = CGRect(x: segX, y: yOff + 1, width: 6, height: h - 2)
                            leftGrip.backgroundColor = NSColor.white.withAlphaComponent(0.35).cgColor
                            leftGrip.cornerRadius = 2
                            leftGrip.zPosition = 6
                            wfContainer.addSublayer(leftGrip)

                            let rightGrip = CALayer()
                            rightGrip.frame = CGRect(x: segX + segW - 6, y: yOff + 1, width: 6, height: h - 2)
                            rightGrip.backgroundColor = NSColor.white.withAlphaComponent(0.35).cgColor
                            rightGrip.cornerRadius = 2
                            rightGrip.zPosition = 6
                            wfContainer.addSublayer(rightGrip)
                        }
                    } else if !state.peaks.isEmpty {
                        // Legacy single-clip path
                        let stemDur = state.duration > 0 ? state.duration : effectiveDur
                        let stemW = totalW * CGFloat(min(stemDur, effectiveDur) / effectiveDur)
                        let count = state.peaks.count
                        let renderCount = max(1, min(count, Int(stemW * 2)))
                        func stemPeak(_ i: Int) -> Float {
                            renderCount < count ? state.peaks[Int(Float(i) / Float(renderCount) * Float(count))] : state.peaks[i]
                        }
                        for i in 0..<renderCount {
                            let x = CGFloat(i) / CGFloat(renderCount) * stemW
                            let amp = CGFloat(stemPeak(i)) * mid * 0.9
                            if i == 0 { fillPath.move(to: CGPoint(x: x, y: mid - amp)) }
                            else { fillPath.addLine(to: CGPoint(x: x, y: mid - amp)) }
                        }
                        for i in stride(from: renderCount - 1, through: 0, by: -1) {
                            let x = CGFloat(i) / CGFloat(renderCount) * stemW
                            let amp = CGFloat(stemPeak(i)) * mid * 0.9
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
                CATransaction.commit()
            } // end else (not zooming)
            } // end if let wfContainer

            hv.rootView = AnyView(waveformContent())
            // Capture zooming state now — by the time async fires the gesture may have ended.
            let wasZooming = context.coordinator.isZooming
            DispatchQueue.main.async { [weak nsView] in
                guard let sv = nsView else { return }
                sv.tile()
                // Skip scroll-position reset during zoom — handleMagnification owns
                // scroll position during the gesture and races with this block.
                if !wasZooming {
                    let origin = sv.contentView.bounds.origin
                    sv.contentView.scroll(to: origin)
                    sv.reflectScrolledClipView(sv.contentView)
                }
            }
        }
    }

    // MARK: Content builder

    private func waveformContent() -> some View {
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
                        editPlayer.saveUndoSnapshot()
                        for url in targets {
                            let lo = (stemSelections[url]?.lowerBound ?? originalRange.lowerBound)
                            let hi = (stemSelections[url]?.upperBound ?? originalRange.upperBound)
                            editPlayer.moveRegion(url, lo: lo, hi: hi, to: lo + delta)
                        }
                    }
                )
                // Locator lane — SwiftUI chips with double-click rename + drag-to-reposition
                EditLocatorLane(
                    markers: markers,
                    totalDuration: totalDuration,
                    mtCompleteMode: mtCompleteMode,
                    beatSchedule: beatSchedule,
                    locatorOverrides: locatorOverrides,
                    onFix: onLocatorFix,
                    onLocatorMove: onLocatorMove
                )
                .frame(height: WaveformScrollHost.locatorLaneHeight)
                let allHeights = stemURLs.map { rowHeights[$0] ?? defaultRowHeight }
                ForEach(Array(stemURLs.enumerated()), id: \.element) { (idx, url) in
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
                        onAddSelection: { range in onAddStemSelection(url, range) },
                        selectedClipIDs: selectedClipIDs,
                        onSelectClip: { id, additive in onSelectClip(id, additive) },
                        onTrimLeftEdge: { id, delta in onTrimLeftEdge(url, id, delta) },
                        onTrimRightEdge: { id, delta in onTrimRightEdge(url, id, delta) },
                        stemIndex: idx,
                        allStemHeights: allHeights,
                        onSetCrossSelection: { loIdx, hiIdx, range in
                            let lo = max(0, loIdx); let hi = min(stemURLs.count - 1, hiIdx)
                            let covered = (lo...hi).map { stemURLs[$0] }
                            onSetMultiStemSelection(covered, range)
                        },
                        onBeginInteraction: { editPlayer.saveUndoSnapshot() },
                        onRemoveStem: (!isProtectedURL(url) && onRemoveStemByURL != nil) ? { onRemoveStemByURL?(url) } : nil
                    )
                    .frame(height: height)

                    Divider().foregroundColor(Color.border)
                }

            }
        }
    }
}

// MARK: - Peak Meters

private func meterBarColor(_ db: Float) -> Color {
    if db > 0  { return .red }
    if db >= 0 { return Color(red: 1, green: 0.8, blue: 0) }
    return Color(red: 0.2, green: 0.8, blue: 0.3)
}
private func meterFraction(_ db: Float) -> CGFloat {
    CGFloat(max(0, min(1, (db + 60) / 60)))
}

/// Compact peak-hold meter for locked stems (OG/Guide/Click) — fits in sidebar right margin.
/// Canvas bar + dB number; tap number to reset peak hold.
struct LockedStemMeter: View {
    let peakDB: Float
    let allTimePeak: Float
    let onReset: () -> Void

    private var peakLabel: String {
        allTimePeak <= -96 ? "---" : String(format: "%.1f", allTimePeak)
    }

    var body: some View {
        HStack(spacing: 4) {
            Canvas { ctx, size in
                ctx.fill(Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 2),
                         with: .color(Color.border.opacity(0.4)))
                let w = size.width * meterFraction(peakDB)
                if w > 0 {
                    ctx.fill(Path(roundedRect: CGRect(x: 0, y: 0, width: w, height: size.height), cornerRadius: 2),
                             with: .color(meterBarColor(peakDB)))
                }
                if allTimePeak > -96 {
                    let tx = max(0, size.width * meterFraction(allTimePeak) - 1)
                    ctx.fill(Path(CGRect(x: tx, y: 0, width: 1, height: size.height)),
                             with: .color(meterBarColor(allTimePeak)))
                }
            }
            .frame(width: 38, height: 6)

            Text(peakLabel)
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(allTimePeak > 0 ? .red : allTimePeak >= 0 ? Color(red: 1, green: 0.8, blue: 0) : .fgMid)
                .frame(width: 32, alignment: .trailing)
                .onTapGesture { onReset() }
                .onHover { h in h ? NSCursor.pointingHand.set() : NSCursor.arrow.set() }
                .help("Peak hold — click to reset")
        }
    }
}

/// Canvas-based meter bar — single GPU draw call per frame, no SwiftUI view diffing.
struct StemPeakMeter: View {
    let peakDB: Float
    var body: some View {
        Canvas { ctx, size in
            ctx.fill(Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 2),
                     with: .color(Color.border.opacity(0.4)))
            let w = size.width * meterFraction(peakDB)
            if w > 0 {
                ctx.fill(Path(roundedRect: CGRect(x: 0, y: 0, width: w, height: size.height), cornerRadius: 2),
                         with: .color(meterBarColor(peakDB)))
            }
        }
    }
}

/// Canvas-based master meter with all-time peak hold tick + dB readout. Click number to reset.
struct MasterPeakMeter: View {
    let peakDB: Float
    @State private var allTimePeak: Float = -96.0

    private var peakLabel: String {
        allTimePeak <= -96 ? "---" : String(format: "%.2f", allTimePeak)
    }

    var body: some View {
        HStack(spacing: 6) {
            Canvas { ctx, size in
                // Track
                ctx.fill(Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 2),
                         with: .color(Color.border.opacity(0.4)))
                // Live bar
                let w = size.width * meterFraction(peakDB)
                if w > 0 {
                    ctx.fill(Path(roundedRect: CGRect(x: 0, y: 0, width: w, height: size.height), cornerRadius: 2),
                             with: .color(meterBarColor(peakDB)))
                }
                // All-time peak tick
                if allTimePeak > -96 {
                    let tx = max(0, size.width * meterFraction(allTimePeak) - 1.5)
                    ctx.fill(Path(CGRect(x: tx, y: 0, width: 1.5, height: size.height)),
                             with: .color(meterBarColor(allTimePeak)))
                }
            }
            .frame(width: 80)

            Text(peakLabel)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(allTimePeak > 0 ? .red : allTimePeak >= 0 ? Color(red: 1, green: 0.8, blue: 0) : .fgMid)
                .frame(width: 38, alignment: .trailing)
                .onTapGesture { allTimePeak = -96 }
                .onHover { h in h ? NSCursor.pointingHand.set() : NSCursor.arrow.set() }
                .help("All-time peak — click to reset")
        }
        .onChange(of: peakDB) { db in
            if db > allTimePeak { allTimePeak = db }
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

// MARK: - Edit Tab Locator Lane

/// SwiftUI locator lane rendered above the track area. Supports double-click rename and
/// drag-to-reposition (snaps to bar downbeats).
struct EditLocatorLane: View {
    let markers: [Marker]
    let totalDuration: Double
    let mtCompleteMode: Bool
    let beatSchedule: [BeatInfo]
    let locatorOverrides: [String: LocatorOverride]
    let onFix: ([(Marker, String)]) -> Void
    let onLocatorMove: (String, Double) -> Void

    // Drag state — nil when no drag in progress
    @State private var dragState: (alsId: String, startSeconds: Double, currentBeat: Double, currentSeconds: Double)? = nil

    private func markerSeconds(_ time: String) -> Double? {
        let parts = time.split(separator: ":")
        if parts.count == 3,
           let m = Double(parts[0]), let s = Double(parts[1]), let ms = Double(parts[2]) {
            return m * 60 + s + ms / 1000
        }
        if parts.count == 2,
           let m = Double(parts[0]), let s = Double(parts[1]) {
            return m * 60 + s
        }
        return nil
    }

    /// Effective seconds for a marker, considering live drag and session overrides.
    private func effectiveSeconds(for marker: Marker) -> Double {
        if let ds = dragState, ds.alsId == marker.alsId { return ds.currentSeconds }
        if let ov = locatorOverrides[marker.alsId], let overrideBeat = ov.beat {
            return secondsForBeat(overrideBeat)
        }
        if let beat = marker.beat { return secondsForBeat(beat) }
        return markerSeconds(marker.time) ?? 0
    }

    /// Convert Ableton beat position to session seconds using the beat schedule.
    private func secondsForBeat(_ beat: Double) -> Double {
        guard !beatSchedule.isEmpty else { return 0 }
        // Find the two adjacent entries that bracket this beat and interpolate.
        var prev = beatSchedule[0]
        for info in beatSchedule {
            if info.absoluteBeat > beat { break }
            prev = info
        }
        return prev.timeSeconds
    }

    /// Snap raw seconds to the nearest bar downbeat; returns (snappedSeconds, absoluteBeat).
    private func snapToDownbeat(_ seconds: Double) -> (seconds: Double, beat: Double) {
        let downbeats = beatSchedule.filter { $0.isDownbeat }
        guard !downbeats.isEmpty else { return (seconds, 0) }
        let nearest = downbeats.min(by: { abs($0.timeSeconds - seconds) < abs($1.timeSeconds - seconds) })!
        return (nearest.timeSeconds, nearest.absoluteBeat)
    }

    var body: some View {
        GeometryReader { geo in
            locatorContent(width: geo.size.width)
        }
    }

    @ViewBuilder
    private func locatorContent(width: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            Color.clear.frame(width: width, height: WaveformScrollHost.locatorLaneHeight)

            if totalDuration > 0 && width > 0 {
                let positioned: [(marker: Marker, x: CGFloat)] = markers.compactMap { m in
                    guard !m.text.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
                    let secs = effectiveSeconds(for: m)
                    return (m, CGFloat(secs / totalDuration) * width)
                }.sorted { $0.x < $1.x }

                ForEach(Array(positioned.enumerated()), id: \.element.marker.id) { i, pair in
                    let marker = pair.marker
                    let x = pair.x
                    let nextX = i + 1 < positioned.count ? positioned[i + 1].x : width
                    let chipW = max(0, nextX - x)
                    let isDraggingThis = dragState?.alsId == marker.alsId
                    let isDraggable = marker.text.uppercased() != "COUNT OFF" && !marker.alsId.isEmpty

                    EditLocatorChip(
                        marker: marker,
                        chipWidth: chipW,
                        mtCompleteMode: mtCompleteMode,
                        isDragging: isDraggingThis,
                        onFix: { newName in onFix([(marker, newName)]) }
                    )
                    .frame(width: max(chipW, 4), height: WaveformScrollHost.locatorLaneHeight)
                    .offset(x: max(0, min(x, width - 1)), y: 0)
                    .if(isDraggable) { v in
                        v.gesture(
                            DragGesture(minimumDistance: 3)
                                .onChanged { value in
                                    let pixelsPerSecond = width / CGFloat(totalDuration)
                                    let baseSeconds: Double
                                    if let ds = dragState, ds.alsId == marker.alsId {
                                        baseSeconds = ds.startSeconds
                                    } else {
                                        baseSeconds = effectiveSeconds(for: marker)
                                    }
                                    let rawSeconds = baseSeconds + Double(value.translation.width / pixelsPerSecond)
                                    let clamped = max(0, min(totalDuration, rawSeconds))
                                    let (snappedSecs, snappedBeat) = snapToDownbeat(clamped)
                                    dragState = (alsId: marker.alsId, startSeconds: baseSeconds,
                                                 currentBeat: snappedBeat, currentSeconds: snappedSecs)
                                }
                                .onEnded { _ in
                                    if let ds = dragState, ds.alsId == marker.alsId {
                                        onLocatorMove(ds.alsId, ds.currentBeat)
                                    }
                                    dragState = nil
                                }
                        )
                    }
                }

                // Drag guide line — vertical accent line at current drag position
                if let ds = dragState {
                    let dragX = CGFloat(ds.currentSeconds / totalDuration) * width
                    Rectangle()
                        .fill(Color.accent.opacity(0.8))
                        .frame(width: 1)
                        .frame(maxHeight: .infinity)
                        .offset(x: dragX, y: 0)
                }
            }
        }
    }
}

extension View {
    @ViewBuilder func `if`(_ condition: Bool, transform: (Self) -> some View) -> some View {
        if condition { transform(self) } else { self }
    }
}

// MARK: - Per-locator chip (Edit tab)

struct EditLocatorChip: View {
    let marker: Marker
    let chipWidth: CGFloat
    let mtCompleteMode: Bool
    var isDragging: Bool = false
    let onFix: (String) -> Void

    @State private var pickerOpen = false
    @State private var pickerSelection = ""
    @State private var dismissedViaEnter = false
    @State private var isHovering = false
    @State private var pencilHover = false

    private var isInvalid: Bool {
        !LocatorValidator.isValid(marker.text, mtCompleteMode: mtCompleteMode)
    }

    private var pickerOptions: [String] {
        mtCompleteMode
            ? LocatorValidator.sortedSections
            : LocatorValidator.sortedSections.filter { !LocatorValidator.shortCodes.contains($0) }
    }

    var body: some View {
        let bgColor: Color = isDragging ? Color.accent.opacity(0.35)
            : isInvalid ? Color.red.opacity(0.28)
            : Color(white: 0.12).opacity(0.88)
        let textColor: Color = isInvalid ? Color.red : Color.white.opacity(0.85)

        bgColor
            .overlay(alignment: .leading) {
                // Left-edge accent line
                (isDragging ? Color.accent : isInvalid ? Color.red.opacity(0.6) : Color.white.opacity(0.35))
                    .frame(width: isDragging ? 2 : 1)
            }
            .overlay(alignment: .leading) {
                if chipWidth >= 8 {
                    HStack(spacing: 2) {
                        Text(chipWidth >= 28 ? "▶ \(marker.text)" : "▶")
                            .font(.lato(size: 9, weight: .bold))
                            .foregroundColor(textColor)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        if isHovering && chipWidth >= 44 {
                            Button {
                                pickerSelection = marker.text
                                pickerOpen = true
                            } label: {
                                Image(systemName: "pencil")
                                    .font(.system(size: 8, weight: .medium))
                                    .foregroundColor(pencilHover ? .accent : textColor.opacity(0.7))
                                    .frame(width: 14, height: 14)
                                    .background(RoundedRectangle(cornerRadius: 3)
                                        .fill(pencilHover ? Color.accent.opacity(0.25) : Color.clear))
                            }
                            .buttonStyle(.plain)
                            .contentShape(Rectangle())
                            .onHover { h in withAnimation(.easeOut(duration: 0.12)) { pencilHover = h } }
                            .transition(.opacity)
                        }
                    }
                    .padding(.leading, 5)
                    .padding(.trailing, 4)
                }
            }
            .popover(isPresented: $pickerOpen, arrowEdge: .bottom) {
                PickerPopoverContent(
                    options: pickerOptions,
                    selection: $pickerSelection,
                    isPresented: $pickerOpen,
                    dismissedViaEnter: $dismissedViaEnter
                )
            }
            .contentShape(Rectangle())
            .simultaneousGesture(TapGesture(count: 2).onEnded {
                pickerSelection = marker.text
                pickerOpen = true
            })
            .onChange(of: pickerOpen) { isOpen in
                if !isOpen && !pickerSelection.isEmpty && pickerSelection != marker.text {
                    onFix(pickerSelection)
                }
            }
            .onHover { h in
                withAnimation(.easeOut(duration: 0.08)) { isHovering = h }
                if h { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
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
