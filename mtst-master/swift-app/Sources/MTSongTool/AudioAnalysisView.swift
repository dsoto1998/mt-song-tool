import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Stem Check Panel

struct AudioAnalysisView: View {
    @ObservedObject var analyzer: AudioAnalyzerService
    @ObservedObject var stemPlayer: StemPlayerService
    var rehearsalMixOnly: Bool = false
    var expectedDuration: Double? = nil     // passed from ContentView via parser.result
    @Binding var isMinimized: Bool          // lifted to ContentView so re-parses don't reset it
    var quickCheckMode: Bool = false        // when true, missing stems don't show red border
    var jamNightMode: Bool = false          // when true, only ORIGINAL SONG is required
    @State private var isTargeted = false
    @State private var isHovering = false
    @State private var showConvertConfirm = false
    @State private var showFixNamesConfirm = false
    private let scrollAreaHeight: CGFloat = 256  // 8 rows × 32pt

    // Required stems in fixed display order
    private var requiredStems: [String] {
        if jamNightMode { return ["ORIGINAL SONG"] }
        return rehearsalMixOnly
            ? ["CLICK TRACK", "ORIGINAL SONG"]
            : ["CLICK TRACK", "GUIDE", "ORIGINAL SONG"]
    }

    // Lookup map: uppercased stem name → result
    private var presentByUpperName: [String: AudioFileResult] {
        Dictionary(
            analyzer.results.map { result in
                let name = URL(fileURLWithPath: result.filename)
                    .deletingPathExtension().lastPathComponent.uppercased()
                return (name, result)
            },
            uniquingKeysWith: { first, _ in first }
        )
    }

    // Results that are NOT one of the pinned required stems
    // Non-pinned results: stems with issues first (A–Z), then clean stems (A–Z)
    private var remainingResults: [AudioFileResult] {
        let nonPinned = analyzer.results.filter { result in
            let upper = URL(fileURLWithPath: result.filename)
                .deletingPathExtension().lastPathComponent.uppercased()
            return !requiredStems.contains(upper)
        }
        let withIssues = nonPinned.filter { !$0.isClean }
            .sorted { $0.filename.lowercased() < $1.filename.lowercased() }
        let clean = nonPinned.filter { $0.isClean }
            .sorted { $0.filename.lowercased() < $1.filename.lowercased() }
        return withIssues + clean
    }

    // Missing required stems (not found in results)
    private var missingRequiredCount: Int {
        requiredStems.filter { presentByUpperName[$0] == nil }.count
    }

    // Total issue count: each silent/corrupted status + each validation issue + each missing required stem
    private var issueCount: Int {
        let fileIssues = analyzer.results.reduce(0) { count, result in
            var n = result.issues.count
            if case .ok = result.status { } else { n += 1 }  // silent or corrupted = +1
            return count + n
        }
        return fileIssues + missingRequiredCount
    }

    // Red border when no scan has been run and not currently scanning.
    // Suppressed in Quick Check Mode — stems are optional there.
    private var showAsMissing: Bool {
        !quickCheckMode && analyzer.results.isEmpty && !analyzer.isScanning
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: 6) {
                Image(systemName: "waveform")
                    .foregroundColor(showAsMissing ? .red : .accent)
                    .font(.lato(size: 12, weight: .semibold))
                Text("Stem Check")
                    .font(.lato(size: 13, weight: .semibold))
                    .foregroundColor(showAsMissing ? .red : .fgBright)
                if !analyzer.results.isEmpty {
                    Text("· \(analyzer.results.count) files\(issueCount > 0 ? ", \(issueCount) issue\(issueCount == 1 ? "" : "s")" : "")")
                        .font(.lato(size: 11))
                        .foregroundColor(issueCount > 0 ? .red : .fgDim)
                }
                Spacer()
                if !analyzer.fixableResults.isEmpty && !analyzer.isConverting && !analyzer.isScanning {
                    Button("Fix Names") { showFixNamesConfirm = true }
                        .buttonStyle(CompactSecondaryButtonStyle().hoverable())
                }
                if !analyzer.formatNonConformingFiles.isEmpty && !analyzer.isConverting && !analyzer.isScanning {
                    Button("Fix Format") { showConvertConfirm = true }
                        .buttonStyle(CompactSecondaryButtonStyle().hoverable())
                }
                if !analyzer.results.isEmpty || analyzer.isScanning || analyzer.isConverting {
                    Button("Clear") { analyzer.reset() }
                        .buttonStyle(CompactSecondaryButtonStyle().hoverable())
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 38)

            Divider().background(Color.border)

            if analyzer.isConverting {
                convertingView
            } else if analyzer.isScanning {
                scanningView
            } else if let err = analyzer.errorMessage {
                errorView(message: err)
            } else if !analyzer.results.isEmpty {
                if !isMinimized {
                    collapseToggleView
                    ScrollView(.vertical, showsIndicators: true) {
                        resultsListView
                    }
                    .frame(height: scrollAreaHeight)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                } else {
                    collapseToggleView
                }
            } else {
                dropZoneView
            }
        }
        .background(Color.bgCard)
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(showAsMissing ? Color.red : Color.border, lineWidth: showAsMissing ? 1.5 : 1)
        )
        .alert("Fix Stem Names?", isPresented: $showFixNamesConfirm) {
            Button("Rename") { analyzer.fixNamingIssues() }
            Button("Cancel", role: .cancel) { }
        } message: {
            let n = analyzer.fixableResults.count
            Text("\(n) file\(n == 1 ? "" : "s") will be renamed in place to fix spacing and capitalization. This cannot be undone.")
        }
        .alert("Convert Non-Conforming Files?", isPresented: $showConvertConfirm) {
            Button("Convert") { analyzer.convertNonConforming() }
            Button("Cancel", role: .cancel) { }
        } message: {
            let bad = analyzer.formatNonConformingFiles.count
            let total = analyzer.results.count
            Text("All \(total) stems will be copied to a new folder next to your stems folder. \(bad) non-conforming file\(bad == 1 ? "" : "s") will be converted to 44.1 kHz / 16-bit WAV; the rest will be copied as-is. Your originals will not be changed.")
        }
    }

    // MARK: Drop zone

    private var dropZoneView: some View {
        HStack(spacing: 10) {
            Image(systemName: isTargeted ? "folder.fill" : "folder")
                .font(.system(size: 14))
                .foregroundColor(isTargeted ? .accent : (showAsMissing ? .red : .fgDim))
                .animation(.easeOut(duration: 0.12), value: isTargeted)

            Text(isTargeted ? "Release to scan" : "Drop stems folder or click Browse")
                .font(.lato(size: 12))
                .foregroundColor(isTargeted ? .accent : (showAsMissing ? .red.opacity(0.8) : .fgDim))

            Spacer()

            Button("Browse") { openFolderPicker() }
                .buttonStyle(CompactSecondaryButtonStyle().hoverable())
        }
        .padding(.horizontal, 14)
        .frame(height: 48)
        .background(isHovering || isTargeted ? Color.dropHovBg : Color.clear)
        .animation(.easeOut(duration: 0.12), value: isTargeted)
        .contentShape(Rectangle())
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { isHovering = h } }
        .onDrop(of: [UTType.fileURL, .folder], isTargeted: $isTargeted) { providers in
            guard let provider = providers.first else { return false }
            // loadItem(forTypeIdentifier:) required on macOS — Finder delivers folder URLs as
            // bookmark Data via public.file-url; loadObject(ofClass: URL.self) returns nil for folders.
            let typeId = provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
                ? UTType.fileURL.identifier : "public.folder"
            Log("provider types=\(provider.registeredTypeIdentifiers) → loading as \(typeId)", "StemDrop")
            provider.loadItem(forTypeIdentifier: typeId, options: nil) { item, error in
                Log("loadItem: itemType=\(type(of: item)) error=\(String(describing: error))", "StemDrop")
                DispatchQueue.main.async {
                    var url: URL?
                    if let data = item as? Data {
                        url = URL(dataRepresentation: data, relativeTo: nil)
                    } else if let u = item as? NSURL {
                        url = u as URL
                    } else if let u = item as? URL {
                        url = u
                    }
                    Log("resolved url=\(url?.path ?? "nil")", "StemDrop")
                    guard let url else { return }
                    var isDir: ObjCBool = false
                    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
                        Log("not a directory or not found: \(url.path)", "StemDrop")
                        return
                    }
                    let fm = FileManager.default
                    let items = (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
                    if items.contains(where: { $0.pathExtension.lowercased() == "wav" }) {
                        analyzer.expectedDuration = expectedDuration
                        analyzer.analyze(folder: url)
                    } else {
                        let subfolders = items.filter { item in
                            var isSubDir: ObjCBool = false
                            fm.fileExists(atPath: item.path, isDirectory: &isSubDir)
                            return isSubDir.boolValue
                        }
                        if let stemsDir = subfolders.first(where: { dir in
                            let contents = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
                            return contents.contains { $0.pathExtension.lowercased() == "wav" }
                        }) {
                            analyzer.expectedDuration = expectedDuration
                            analyzer.analyze(folder: stemsDir)
                        }
                    }
                }
            }
            return true
        }
    }

    // MARK: Converting progress

    private var convertingView: some View {
        HStack(spacing: 10) {
            ProgressView()
                .scaleEffect(0.7)
                .tint(.accent)
            Text("Converting \(analyzer.conversionProgress.current) of \(analyzer.conversionProgress.total)…")
                .font(.lato(size: 12))
                .foregroundColor(.fgDim)
            Spacer()
        }
        .padding(.horizontal, 14)
        .frame(height: 48)
    }

    // MARK: Scanning progress

    private var scanningView: some View {
        HStack(spacing: 10) {
            ProgressView()
                .scaleEffect(0.7)
                .tint(.accent)
            Text("Scanning \(analyzer.progress.current) of \(analyzer.progress.total)…")
                .font(.lato(size: 12))
                .foregroundColor(.fgDim)
            Spacer()
        }
        .padding(.horizontal, 14)
        .frame(height: 48)
    }

    // MARK: Error

    private func errorView(message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundColor(.red)
            Text(message)
                .font(.lato(size: 12))
                .foregroundColor(.redLight)
        }
        .padding(.horizontal, 14)
        .frame(height: 48)
    }

    // MARK: Collapse toggle

    /// Centered chevron strip between the header and results list.
    /// Click to collapse the list (leaving the header visible); click again to restore.
    private var collapseToggleView: some View {
        HStack {
            Spacer()
            Button {
                withAnimation(.easeInOut(duration: 0.18)) { isMinimized.toggle() }
            } label: {
                Image(systemName: isMinimized ? "chevron.down" : "chevron.up")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.fgDim)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 3)
                    .background(
                        Capsule()
                            .fill(Color.fgDim.opacity(0.08))
                            .overlay(Capsule().stroke(Color.border.opacity(0.6), lineWidth: 0.5))
                    )
            }
            .buttonStyle(.plain)
            .onHover { h in
                if h { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
            }
            Spacer()
        }
        .frame(height: 18)
        .contentShape(Rectangle())
    }

    // MARK: Results — pinned required stems first, then alphabetical

    private var resultsListView: some View {
        VStack(spacing: 0) {
            // Conversion error banner (shown after a partial conversion failure)
            if !analyzer.conversionErrors.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 10))
                            .foregroundColor(.orange)
                        let n = analyzer.conversionErrors.count
                        Text("\(n) file\(n == 1 ? "" : "s") could not be converted — originals unchanged.")
                            .font(.lato(size: 11, weight: .semibold))
                            .foregroundColor(.orange)
                        Spacer()
                    }
                    if let firstError = analyzer.conversionErrors.first {
                        Text(firstError)
                            .font(.lato(size: 10))
                            .foregroundColor(.orange.opacity(0.75))
                            .lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(Color.orange.opacity(0.08))
            }
            // Required stems pinned in fixed order
            ForEach(requiredStems, id: \.self) { stemName in
                if let result = presentByUpperName[stemName] {
                    AudioFileRow(
                        result: result,
                        folderURL: analyzer.lastScannedFolder,
                        stemPlayer: stemPlayer,
                        onRename: { newName in
                            analyzer.renameStem(oldFilename: result.filename, newStemName: newName)
                        }
                    )
                } else {
                    MissingStemRow(stemName: stemName)
                }
            }
            // Remaining stems alphabetically
            ForEach(remainingResults) { result in
                AudioFileRow(
                    result: result,
                    folderURL: analyzer.lastScannedFolder,
                    stemPlayer: stemPlayer,
                    onRename: { newName in
                        analyzer.renameStem(oldFilename: result.filename, newStemName: newName)
                    }
                )
            }
        }
    }

    // MARK: Folder picker

    private func openFolderPicker() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose a folder containing .wav stems"
        panel.prompt = "Scan"
        if panel.runModal() == .OK, let url = panel.url {
            analyzer.expectedDuration = expectedDuration
            analyzer.analyze(folder: url)
        }
    }
}

// MARK: - Missing required stem row

struct MissingStemRow: View {
    let stemName: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.red)
                .frame(width: 14)

            Text(stemName + ".wav")
                .font(.lato(size: 11))
                .foregroundColor(.red)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            StatusBadge(label: "Missing", color: .red)
        }
        .padding(.horizontal, 14)
        .frame(height: 32)
    }
}

// MARK: - Waveform seek control

struct WaveformSeekView: View {
    let peaks: [Float]           // normalized 0–1, 500 points
    let progress: Double         // 0–1 current playhead position
    var sectionStart: Double? = nil  // seconds; nil = no active section
    var sectionEnd: Double? = nil    // seconds
    var totalDuration: Double = 0    // seconds (for converting section times to fractions)
    let onSeek: (Double) -> Void
    let onSeekEnd: () -> Void

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Canvas { ctx, size in
                    guard !peaks.isEmpty else { return }
                    let count = peaks.count
                    let stepX = size.width / CGFloat(count)
                    let midY = size.height / 2
                    let playheadX = size.width * CGFloat(max(0, min(1, progress)))

                    // Build a single continuous filled path: top edge L→R, bottom edge R→L
                    var waveform = Path()
                    waveform.move(to: CGPoint(x: 0, y: midY))
                    for i in 0..<count {
                        let x = CGFloat(i) * stepX + stepX * 0.5
                        let h = CGFloat(peaks[i]) * midY * 0.9
                        waveform.addLine(to: CGPoint(x: x, y: midY - h))
                    }
                    waveform.addLine(to: CGPoint(x: size.width, y: midY))
                    for i in stride(from: count - 1, through: 0, by: -1) {
                        let x = CGFloat(i) * stepX + stepX * 0.5
                        let h = CGFloat(peaks[i]) * midY * 0.9
                        waveform.addLine(to: CGPoint(x: x, y: midY + h))
                    }
                    waveform.closeSubpath()

                    if let secStart = sectionStart, let secEnd = sectionEnd, totalDuration > 0 {
                        // Section mode: dim everything, highlight window, fill played portion blue
                        let secStartX = size.width * CGFloat(max(0, min(1, secStart / totalDuration)))
                        let secEndX   = size.width * CGFloat(max(0, min(1, secEnd   / totalDuration)))

                        // Dim entire waveform
                        ctx.drawLayer { l in
                            l.fill(waveform, with: .color(Color.fgMid.opacity(0.15)))
                        }

                        // Section window background (slightly brighter)
                        ctx.drawLayer { l in
                            l.clip(to: Path(CGRect(x: secStartX, y: 0, width: secEndX - secStartX, height: size.height)))
                            l.fill(waveform, with: .color(Color.fgMid.opacity(0.35)))
                        }

                        // Played portion within section (blue: secStart → playhead)
                        ctx.drawLayer { l in
                            l.clip(to: Path(CGRect(x: secStartX, y: 0, width: max(0, playheadX - secStartX), height: size.height)))
                            l.fill(waveform, with: .color(Color.accent.opacity(0.9)))
                        }
                    } else {
                        // Normal mode: blue left of playhead, gray right
                        ctx.drawLayer { l in
                            l.clip(to: Path(CGRect(x: 0, y: 0, width: playheadX, height: size.height)))
                            l.fill(waveform, with: .color(Color.accent.opacity(0.9)))
                        }
                        ctx.drawLayer { l in
                            l.clip(to: Path(CGRect(x: playheadX, y: 0, width: size.width - playheadX, height: size.height)))
                            l.fill(waveform, with: .color(Color.fgMid.opacity(0.4)))
                        }
                    }

                    // Playhead line
                    var playhead = Path()
                    playhead.move(to: CGPoint(x: playheadX, y: 0))
                    playhead.addLine(to: CGPoint(x: playheadX, y: size.height))
                    ctx.stroke(playhead, with: .color(.white.opacity(0.8)), lineWidth: 1.5)
                }

            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let p = max(0, min(1, Double(value.location.x / geo.size.width)))
                        onSeek(p)
                    }
                    .onEnded { _ in onSeekEnd() }
            )
        }
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(Color.fgMid.opacity(0.5), lineWidth: 1.0)
        )
    }
}

// MARK: - Per-file result row

struct AudioFileRow: View {
    let result: AudioFileResult
    var folderURL: URL? = nil
    @ObservedObject var stemPlayer: StemPlayerService
    /// Called with the new ALL-CAPS stem name (no extension) after the user picks a valid rename.
    /// If nil, double-click to rename is disabled for this row.
    var onRename: ((String) -> Void)? = nil

    @State private var pickerOpen = false
    @State private var renameSelection = ""
    @State private var dismissedViaEnter = false
    @State private var isHovering = false
    @State private var playHover = false
    @State private var pencilHover = false
    @State private var isScrubbing = false
    @State private var scrubValue: Double = 0

    /// Sorted approved stems list for the picker
    private static let sortedStems: [String] = AudioAnalyzerService.approvedStems.sorted()

    /// Stem name without the .wav extension
    private var stemName: String {
        URL(fileURLWithPath: result.filename).deletingPathExtension().lastPathComponent
    }

    private var myURL: URL? {
        folderURL?.appendingPathComponent(result.filename)
    }

    private var isThisStemActive: Bool {
        guard let mine = myURL, let playing = stemPlayer.playingStemURL else { return false }
        return mine == playing
    }

    var body: some View {
        VStack(spacing: 0) {
            // Main row content
            HStack(spacing: 8) {
                Image(systemName: statusIcon)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(statusColor)
                    .frame(width: 14)

                // Name column — tap twice to open rename picker
                HStack(spacing: 4) {
                    Text(result.filename)
                        .font(.lato(size: 11))
                        .foregroundColor(.fgMid)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .popover(isPresented: $pickerOpen, arrowEdge: .bottom) {
                            PickerPopoverContent(
                                options: Self.sortedStems,
                                selection: $renameSelection,
                                isPresented: $pickerOpen,
                                dismissedViaEnter: $dismissedViaEnter,
                                onEnterOut: nil,
                                onTabOut: nil,
                                suggestions: result.suggestedNames
                            )
                        }
                    if isHovering && onRename != nil {
                        Button {
                            renameSelection = stemName
                            pickerOpen = true
                        } label: {
                            Image(systemName: "pencil")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundColor(pencilHover ? .accent : .fgMid)
                                .frame(width: 20, height: 20)
                                .background(
                                    RoundedRectangle(cornerRadius: 4)
                                        .fill(pencilHover ? Color.accent.opacity(0.15) : Color.clear)
                                )
                        }
                        .buttonStyle(.plain)
                        .contentShape(Rectangle())
                        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { pencilHover = h } }
                        .transition(.opacity)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .simultaneousGesture(TapGesture(count: 2).onEnded {
                    if onRename != nil {
                        renameSelection = stemName
                        pickerOpen = true
                    }
                })
                .onChange(of: pickerOpen) { isOpen in
                    if isOpen {
                        stemPlayer.stop()
                    } else if renameSelection != stemName && !renameSelection.isEmpty {
                        onRename?(renameSelection)
                    }
                }

                // Badges: audio status + validation issues + inline suggestion chip
                HStack(spacing: 4) {
                    if result.isClean {
                        StatusBadge(label: "OK", color: .green)
                    } else {
                        if case .silent = result.status {
                            StatusBadge(label: "Silent", color: .red)
                        } else if case .corrupted = result.status {
                            StatusBadge(label: "Corrupted", color: .red)
                        }
                        ForEach(result.issues, id: \.self) { issue in
                            StatusBadge(label: issue, color: issueColor(issue))
                        }
                    }
                    // High-confidence suggestion chip — quick-accept with one click
                    if let top = result.suggestedNames.first(where: { !$0.isTaken }), top.confidence >= 0.80, onRename != nil {
                        HStack(spacing: 3) {
                            Image(systemName: "arrow.right")
                                .font(.system(size: 7, weight: .semibold))
                                .foregroundColor(.fgDim)
                            Text(top.name)
                                .font(.lato(size: 10, weight: .medium))
                                .foregroundColor(.fgMid)
                            Button {
                                onRename?(top.name)
                            } label: {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 8, weight: .bold))
                                    .foregroundColor(.accent)
                                    .padding(.horizontal, 3)
                                    .padding(.vertical, 2)
                                    .background(
                                        RoundedRectangle(cornerRadius: 3)
                                            .fill(Color.accent.opacity(0.12))
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 32)

            // Playback bar — shown when this stem is the active one
            if isThisStemActive {
                playbackBar
                    .padding(.horizontal, 14)
                    .padding(.bottom, 8)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                    .contentShape(Rectangle())
                    .onTapGesture { }  // absorb stray taps — prevents row restart-on-tap
            }
        }
        .background(isHovering ? Color.bgCardHov : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture(count: 1) {
            guard let url = myURL else { return }
            if isThisStemActive {
                stemPlayer.stop()
            } else {
                stemPlayer.play(url: url)
            }
        }
        .onHover { h in
            withAnimation(.easeOut(duration: 0.08)) { isHovering = h }
            if h && onRename != nil { NSCursor.pointingHand.set() }
            else { NSCursor.arrow.set() }
        }
        .animation(.easeInOut(duration: 0.15), value: isThisStemActive)
    }

    // MARK: Playback bar

    private var playbackBar: some View {
        HStack(spacing: 8) {
            // Play / pause button
            Button {
                stemPlayer.togglePause()
            } label: {
                Image(systemName: stemPlayer.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.accent)
                    .frame(width: 20, height: 20)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(playHover ? Color.accent.opacity(0.15) : Color.clear)
                    )
            }
            .buttonStyle(.plain)
            .frame(width: 28, height: 28)  // enlarged tap target
            .contentShape(Rectangle())
            .onHover { h in withAnimation(.easeOut(duration: 0.12)) { playHover = h } }

            // Elapsed time
            let currentT = isScrubbing ? scrubValue : stemPlayer.currentTime
            let knownDuration = stemPlayer.duration
            Text(formatTime(currentT))
                .font(.lato(size: 9))
                .foregroundColor(.fgDim)
                .monospacedDigit()
                .frame(width: 30, alignment: .trailing)

            // Waveform seek control
            WaveformSeekView(
                peaks: result.waveformPeaks,
                progress: knownDuration > 0 ? currentT / knownDuration : 0,
                sectionStart: stemPlayer.activeSectionStart,
                sectionEnd: stemPlayer.activeSectionEnd,
                totalDuration: stemPlayer.duration,
                onSeek: { p in
                    let target = p * stemPlayer.duration
                    isScrubbing = true
                    scrubValue = target
                    stemPlayer.seek(to: target)
                },
                onSeekEnd: {
                    stemPlayer.seek(to: scrubValue)
                    isScrubbing = false
                    if let start = stemPlayer.activeSectionStart,
                       let end = stemPlayer.activeSectionEnd,
                       scrubValue < start || scrubValue > end {
                        stemPlayer.exitSectionMode()
                    }
                }
            )
            .frame(height: 36)

            // Remaining time
            Text("-" + formatTime(max(0, stemPlayer.duration - currentT)))
                .font(.lato(size: 9))
                .foregroundColor(.fgDim)
                .monospacedDigit()
                .frame(width: 30, alignment: .leading)

            // Loop button — always reserves space so waveform width stays stable;
            // visible and interactive only during section playback
            Button {
                stemPlayer.isLooping.toggle()
            } label: {
                Image(systemName: "repeat")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(stemPlayer.isLooping ? .accent : .fgDim)
            }
            .buttonStyle(.plain)
            .opacity(stemPlayer.activeSectionStart != nil ? 1 : 0)
            .allowsHitTesting(stemPlayer.activeSectionStart != nil)

            // Volume
            Image(systemName: "speaker.wave.2.fill")
                .font(.system(size: 9))
                .foregroundColor(.fgDim)

            Slider(value: Binding(
                get: { Double(stemPlayer.volume) },
                set: { stemPlayer.volume = Float($0) }
            ), in: 0...1)
            .tint(.accent)
            .frame(width: 60)

            Text("\(Int(stemPlayer.volume * 100))%")
                .font(.lato(size: 10, weight: .regular))
                .foregroundColor(.fgDim)
                .frame(width: 28, alignment: .leading)
                .monospacedDigit()
        }
    }

    // MARK: Helpers

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite && seconds >= 0 else { return "0:00" }
        let s = Int(seconds)
        return "\(s / 60):\(String(format: "%02d", s % 60))"
    }

    private var statusIcon: String {
        switch result.status {
        case .ok:           return result.issues.isEmpty ? "checkmark.circle.fill" : "exclamationmark.circle.fill"
        case .silent:       return "speaker.slash.fill"
        case .corrupted:    return "exclamationmark.triangle.fill"
        }
    }

    private var statusColor: Color {
        result.isClean ? .green : .red
    }

    private func issueColor(_ issue: String) -> Color {
        switch issue {
        case "Check Stem Name": return .red
        case "Too Short":       return .red
        case "Too Long":        return .red
        case "Duplicate":       return .red
        case "Gap in Sequence": return .red
        case "Special Chars":   return .orange
        case "Wrong Caps":      return .orange
        case "Extra Space":     return .orange
        default:                return .orange  // format issues (48kHz, 24-bit, etc.)
        }
    }
}

// MARK: - Status badge

struct StatusBadge: View {
    let label: String
    let color: Color

    var body: some View {
        Text(label)
            .font(.lato(size: 10, weight: .semibold))
            .foregroundColor(color)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(color.opacity(0.12))
            )
    }
}
