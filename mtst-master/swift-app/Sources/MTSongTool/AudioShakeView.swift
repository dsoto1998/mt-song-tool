import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - AudioShake Tab

struct AudioShakeView: View {
    @ObservedObject var player: StemPlayerService
    @StateObject private var service = AudioShakeService()

    @State private var droppedFileURL: URL? = nil
    @State private var isTargeted = false
    @State private var dropZoneHovered = false
    @State private var selectedModels: Set<String> = AudioShakeService.defaultModels
    @State private var removeFileURL: URL? = nil
    @State private var removeFileTargeted = false
    @State private var removeFileHovered = false
    @State private var removeOutputFolder: URL? = nil
    @State private var outputFolder: URL? = nil

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                fileCard
                modelsCard
                removeCard
                if service.phase.isActive || service.phase.isFailed {
                    statusCard
                }
                if !service.results.isEmpty {
                    resultsCard
                }
            }
            .padding(.vertical, 8)
            .padding(.bottom, 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onReceive(NotificationCenter.default.publisher(for: .audioShakeClearAll)) { _ in
            selectedModels = AudioShakeService.defaultModels
            droppedFileURL = nil
            removeFileURL = nil
            removeOutputFolder = nil
            outputFolder = nil
            service.reset()
            player.stop()
        }
    }

    // MARK: - File drop zone

    private var fileCard: some View {
        Group {
            if let url = droppedFileURL {
                // Loaded state
                HStack(spacing: 10) {
                    Image(systemName: "waveform")
                        .font(.lato(size: 14))
                        .foregroundColor(.accent)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(url.lastPathComponent)
                            .font(.lato(size: 13, weight: .medium))
                            .foregroundColor(.fgBright)
                            .lineLimit(1)
                        Text(fileSizeString(url: url))
                            .font(.lato(size: 11))
                            .foregroundColor(.fgDim)
                    }
                    Spacer()
                    Button {
                        droppedFileURL = nil
                        service.reset()
                        player.stop()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.lato(size: 11))
                            .foregroundColor(.fgDim)
                    }
                    .buttonStyle(.plain)
                    .onHover { h in h ? NSCursor.pointingHand.set() : NSCursor.arrow.set() }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .cardStyle()
            } else {
                // Drop zone
                let active = isTargeted || dropZoneHovered
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(isTargeted ? Color.dropHovBg : (dropZoneHovered ? Color.accent.opacity(0.05) : Color.bgCard))
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(active ? Color.accent : Color.border, lineWidth: active ? 2 : 1)
                        .animation(.easeInOut(duration: 0.15), value: active)

                    VStack(spacing: 8) {
                        Image(systemName: isTargeted ? "arrow.down.doc.fill" : "waveform.badge.plus")
                            .font(.lato(size: 32, weight: .light))
                            .foregroundColor(active ? .accent : .fgDim)
                            .animation(.spring(response: 0.25), value: active)
                        Text("Drop a mixed audio file")
                            .font(.lato(size: 14, weight: .medium))
                            .foregroundColor(active ? .fgBright : .fgMid)
                        Text("wav · mp3 · aiff · m4a · aac")
                            .font(.lato(size: 11))
                            .foregroundColor(active ? .fgMid : .fgDim)
                    }
                }
                .frame(height: 110)
                .contentShape(Rectangle())
                .onDrop(of: [UTType.fileURL.identifier], isTargeted: $isTargeted) { providers in
                    handleDrop(providers: providers)
                }
                .onTapGesture { browseForFile() }
                .onHover { h in
                    withAnimation(.easeInOut(duration: 0.15)) { dropZoneHovered = h }
                    h ? NSCursor.pointingHand.set() : NSCursor.arrow.set()
                }
            }
        }
    }

    // MARK: - Model picker

    private var modelsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Stems to Separate")
                    .font(.lato(size: 12, weight: .semibold))
                    .foregroundColor(.fgBright)
                Spacer()
                Button("Select All") {
                    selectedModels = Set(AudioShakeService.allModels.map(\.id))
                }
                .buttonStyle(CompactSecondaryButtonStyle().hoverable())

                Button("Clear") {
                    selectedModels = []
                }
                .buttonStyle(CompactSecondaryButtonStyle().hoverable())
            }

            ForEach(AudioShakeService.modelGroups, id: \.self) { group in
                let groupModels = AudioShakeService.allModels.filter { $0.group == group }
                VStack(alignment: .leading, spacing: 5) {
                    Text(group)
                        .font(.lato(size: 10, weight: .semibold))
                        .foregroundColor(.fgDim)
                        .textCase(.uppercase)
                    HStack(spacing: 6) {
                        ForEach(groupModels) { def in
                            ModelToggleChip(def: def, selectedModels: $selectedModels)
                        }
                        Spacer()
                    }
                }
            }

            Divider().background(Color.border)

            HStack(spacing: 10) {
                if !selectedModels.isEmpty {
                    Text("\(selectedModels.count) stem\(selectedModels.count == 1 ? "" : "s") selected")
                        .font(.lato(size: 11))
                        .foregroundColor(.fgDim)
                }
                Spacer()
                let isRunning = service.phase.isActive
                let canRun = droppedFileURL != nil && !selectedModels.isEmpty && !isRunning
                if let folder = outputFolder {
                    Text(folder.lastPathComponent)
                        .font(.lato(size: 11))
                        .foregroundColor(.fgDim)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 180, alignment: .trailing)
                }
                if isRunning {
                    Button("Cancel") {
                        service.cancel()
                    }
                    .buttonStyle(SecondaryButtonStyle().hoverable())
                } else {
                    Button("Separate") {
                        if outputFolder == nil { pickOutputFolder() }
                        guard let file = droppedFileURL, let folder = outputFolder else { return }
                        let models = AudioShakeService.allModels
                            .filter { selectedModels.contains($0.id) }
                            .map(\.id)
                        service.run(fileURL: file, models: models, outputFolder: folder)
                    }
                    .buttonStyle(PrimaryButtonStyle().hoverable())
                    .opacity(canRun ? 1.0 : 0.45)
                    .disabled(!canRun)
                }
            }
        }
        .padding(14)
        .cardStyle()
    }

    // MARK: - Stems to Remove card

    private var removeCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header
            HStack(spacing: 6) {
                Image(systemName: "pianokeys")
                    .font(.lato(size: 12))
                    .foregroundColor(.accent2)
                Text("Stems to Remove")
                    .font(.lato(size: 12, weight: .semibold))
                    .foregroundColor(.accent2)
                Spacer()
                Text("Remove an instrument from a stem")
                    .font(.lato(size: 10))
                    .foregroundColor(.fgDim)
            }

            // Drop zone / loaded file
            if let url = removeFileURL {
                HStack(spacing: 10) {
                    Image(systemName: "waveform")
                        .font(.lato(size: 12))
                        .foregroundColor(.accent2)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(url.lastPathComponent)
                            .font(.lato(size: 12, weight: .medium))
                            .foregroundColor(.fgBright)
                            .lineLimit(1)
                        Text(fileSizeString(url: url))
                            .font(.lato(size: 10))
                            .foregroundColor(.fgDim)
                    }
                    Spacer()
                    Button {
                        removeFileURL = nil
                    } label: {
                        Image(systemName: "xmark")
                            .font(.lato(size: 11))
                            .foregroundColor(.fgDim)
                    }
                    .buttonStyle(.plain)
                    .onHover { h in h ? NSCursor.pointingHand.set() : NSCursor.arrow.set() }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(Color.accent2.opacity(0.06))
                        .overlay(
                            RoundedRectangle(cornerRadius: 7)
                                .stroke(Color.accent2.opacity(0.25), lineWidth: 1)
                        )
                )
            } else {
                let active = removeFileTargeted || removeFileHovered
                ZStack {
                    RoundedRectangle(cornerRadius: 7)
                        .fill(removeFileTargeted ? Color.accent2.opacity(0.08) : (removeFileHovered ? Color.accent2.opacity(0.04) : Color.bgCard.opacity(0)))
                    RoundedRectangle(cornerRadius: 7)
                        .stroke(active ? Color.accent2 : Color.border, lineWidth: active ? 1.5 : 1)
                        .animation(.easeInOut(duration: 0.15), value: active)
                    HStack(spacing: 8) {
                        Image(systemName: removeFileTargeted ? "arrow.down.doc.fill" : "waveform.badge.plus")
                            .font(.lato(size: 16, weight: .light))
                            .foregroundColor(active ? .accent2 : .fgDim)
                            .animation(.spring(response: 0.25), value: active)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Drop a stem file")
                                .font(.lato(size: 12, weight: .medium))
                                .foregroundColor(active ? .fgBright : .fgMid)
                            Text("wav · mp3 · aiff · m4a")
                                .font(.lato(size: 10))
                                .foregroundColor(active ? .fgMid : .fgDim)
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                }
                .frame(height: 58)
                .contentShape(Rectangle())
                .onDrop(of: [UTType.fileURL.identifier], isTargeted: $removeFileTargeted) { providers in
                    handleRemoveDrop(providers: providers)
                }
                .onTapGesture { browseForRemoveFile() }
                .onHover { h in
                    withAnimation(.easeInOut(duration: 0.15)) { removeFileHovered = h }
                    h ? NSCursor.pointingHand.set() : NSCursor.arrow.set()
                }
            }

            // Instrument label + action row
            HStack(spacing: 10) {
                // Piano chip (non-interactive label, accent2-tinted)
                Text("Piano")
                    .font(.lato(size: 11, weight: .semibold))
                    .foregroundColor(.accent2)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .fill(Color.accent2.opacity(0.12))
                            .overlay(
                                RoundedRectangle(cornerRadius: 5)
                                    .stroke(Color.accent2.opacity(0.5), lineWidth: 1)
                            )
                    )

                Spacer()

                if let folder = removeOutputFolder {
                    Text(folder.lastPathComponent)
                        .font(.lato(size: 11))
                        .foregroundColor(.fgDim)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 180, alignment: .trailing)
                }

                // Status / button
                Group {
                    if service.extractionPhase.isActive {
                        HStack(spacing: 6) {
                            ProgressView()
                                .scaleEffect(0.55)
                                .frame(width: 14, height: 14)
                            Text(service.extractionPhase.statusText)
                                .font(.lato(size: 11))
                                .foregroundColor(.fgDim)
                        }
                    } else if case .done = service.extractionPhase {
                        HStack(spacing: 5) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.lato(size: 12))
                                .foregroundColor(.green)
                            Text("Done")
                                .font(.lato(size: 11))
                                .foregroundColor(.fgMid)
                        }
                    } else if case .failed(let msg) = service.extractionPhase {
                        Text(msg)
                            .font(.lato(size: 11))
                            .foregroundColor(.red)
                            .lineLimit(2)
                            .multilineTextAlignment(.trailing)
                    } else {
                        // If no output folder yet, Extract will prompt for one first
                        Button("Extract") {
                            if removeOutputFolder == nil { pickRemoveOutputFolder() }
                            guard let file = removeFileURL, let folder = removeOutputFolder else { return }
                            service.runPianoExtraction(from: file, outputFolder: folder)
                        }
                        .buttonStyle(PrimaryButtonStyle().hoverable())
                        .opacity(removeFileURL != nil ? 1.0 : 0.45)
                        .disabled(removeFileURL == nil)
                    }
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.bgCard)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.accent2.opacity(0.2), lineWidth: 1)
                )
        )
    }

    // MARK: - Status card

    private var statusCard: some View {
        HStack(spacing: 10) {
            if service.phase.isActive {
                ProgressView()
                    .scaleEffect(0.6)
                    .frame(width: 16, height: 16)
            } else {
                Image(systemName: "exclamationmark.circle")
                    .font(.lato(size: 13))
                    .foregroundColor(.red)
            }
            Text(service.phase.statusText)
                .font(.lato(size: 12))
                .foregroundColor(service.phase.isFailed ? .red : .fgMid)
                .lineLimit(2)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .cardStyle()
    }

    // MARK: - Results card

    private var resultsCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.lato(size: 12))
                    .foregroundColor(.green)
                Text("Separated Stems")
                    .font(.lato(size: 12, weight: .semibold))
                    .foregroundColor(.fgBright)
                Text("· \(service.results.count) file\(service.results.count == 1 ? "" : "s")")
                    .font(.lato(size: 11))
                    .foregroundColor(.fgDim)
                Spacer()
                if let folder = outputFolder {
                    Button {
                        NSWorkspace.shared.open(folder)
                    } label: {
                        Label("Show in Finder", systemImage: "folder")
                            .font(.lato(size: 10))
                            .foregroundColor(.fgDim)
                    }
                    .buttonStyle(.plain)
                    .onHover { h in h ? NSCursor.pointingHand.set() : NSCursor.arrow.set() }
                }
                Button("Clear") {
                    service.reset()
                    player.stop()
                }
                .buttonStyle(CompactSecondaryButtonStyle().hoverable())
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider()
                .background(Color.border)

            ForEach(Array(service.results.enumerated()), id: \.element.id) { idx, result in
                if idx > 0 {
                    Divider().background(Color.border).padding(.leading, 44)
                }
                AudioShakeResultRow(
                    result: result,
                    player: player,
                    isExtracting: service.extractingURL == result.url,
                    onExtractPiano: extractPianoAction(for: result)
                )
            }
        }
        .cardStyle()
    }

    // MARK: - Helpers

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        _ = provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
            let url: URL?
            if let u = item as? URL {
                url = u
            } else if let data = item as? Data {
                url = URL(dataRepresentation: data, relativeTo: nil)
            } else {
                url = nil
            }
            guard let url else { return }
            DispatchQueue.main.async {
                let resolved = url.resolvingSymlinksInPath()
                let ext = resolved.pathExtension.lowercased()
                let audioExts = ["wav", "mp3", "aiff", "aif", "m4a", "aac", "flac"]
                guard audioExts.contains(ext) else { return }
                droppedFileURL = resolved
                outputFolder = nil
                service.reset()
                player.stop()
            }
        }
        return true
    }

    private func browseForFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [
            .audio, .wav, .mp3, .aiff,
            UTType("public.m4a-audio") ?? .audio,
            UTType("com.apple.m4a-audio") ?? .audio,
        ]
        panel.message = "Choose a mixed audio file to separate"
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url {
            droppedFileURL = url
            outputFolder = nil
            service.reset()
            player.stop()
        }
    }

    private func handleRemoveDrop(providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        _ = provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
            let url: URL?
            if let u = item as? URL {
                url = u
            } else if let data = item as? Data {
                url = URL(dataRepresentation: data, relativeTo: nil)
            } else {
                url = nil
            }
            guard let url else { return }
            DispatchQueue.main.async {
                let resolved = url.resolvingSymlinksInPath()
                let ext = resolved.pathExtension.lowercased()
                let audioExts = ["wav", "mp3", "aiff", "aif", "m4a", "aac", "flac"]
                guard audioExts.contains(ext) else { return }
                removeFileURL = resolved
                removeOutputFolder = nil
            }
        }
        return true
    }

    private func browseForRemoveFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [
            .audio, .wav, .mp3, .aiff,
            UTType("public.m4a-audio") ?? .audio,
            UTType("com.apple.m4a-audio") ?? .audio,
        ]
        panel.message = "Choose a stem to remove an instrument from"
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url {
            removeFileURL = url
            removeOutputFolder = nil
        }
    }

    private func extractPianoAction(for result: AudioShakeService.StemResult) -> (() -> Void)? {
        guard result.model == "other-x-guitar", let folder = outputFolder else { return nil }
        return { service.runPianoExtraction(from: result.url, outputFolder: folder) }
    }

    private func pickOutputFolder() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.message = "Choose where to save the separated stems"
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url {
            outputFolder = url
        }
    }

    private func pickRemoveOutputFolder() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.message = "Choose where to save the extracted stems"
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url {
            removeOutputFolder = url
        }
    }

    private func fileSizeString(url: URL) -> String {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int64 else { return "" }
        let mb = Double(size) / 1_048_576
        return mb >= 1 ? String(format: "%.1f MB", mb) : String(format: "%.0f KB", Double(size) / 1024)
    }
}

// MARK: - Model toggle chip

private struct ModelToggleChip: View {
    let def: AudioShakeService.ModelDef
    @Binding var selectedModels: Set<String>
    @State private var isHovered = false

    var isSelected: Bool { selectedModels.contains(def.id) }

    var body: some View {
        Button {
            if isSelected { selectedModels.remove(def.id) } else { selectedModels.insert(def.id) }
        } label: {
            Text(def.label)
                .font(.lato(size: 11, weight: isSelected ? .semibold : .regular))
                .foregroundColor(isSelected ? .accent : (isHovered ? .fgMid : .fgDim))
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(isSelected ? Color.accent.opacity(0.12) : (isHovered ? Color.border.opacity(0.3) : Color.clear))
                        .overlay(
                            RoundedRectangle(cornerRadius: 5)
                                .stroke(isSelected ? Color.accent.opacity(0.5) : Color.border, lineWidth: 1)
                        )
                )
        }
        .buttonStyle(.plain)
        .onHover { h in
            withAnimation(.easeOut(duration: 0.1)) { isHovered = h }
            h ? NSCursor.pointingHand.set() : NSCursor.arrow.set()
        }
    }
}

// MARK: - Result playback row

private struct AudioShakeResultRow: View {
    let result: AudioShakeService.StemResult
    @ObservedObject var player: StemPlayerService
    var isExtracting: Bool = false
    var onExtractPiano: (() -> Void)? = nil
    @State private var rowHovered = false
    @State private var playHover = false
    @State private var isScrubbing = false
    @State private var scrubValue: Double = 0

    private var isCurrent: Bool { player.playingStemURL == result.url }
    private var isPlaying: Bool { isCurrent && player.isPlaying }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                // Play / pause
                Button {
                    if isCurrent { player.togglePause() } else { player.play(url: result.url) }
                } label: {
                    ZStack {
                        Circle()
                            .fill(Color.accent.opacity(isPlaying ? 0.15 : (rowHovered ? 0.08 : 0)))
                            .frame(width: 28, height: 28)
                        Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                            .font(.lato(size: 10, weight: .medium))
                            .foregroundColor(.accent)
                            .offset(x: isPlaying ? 0 : 1)
                    }
                }
                .buttonStyle(.plain)
                .onHover { h in h ? NSCursor.pointingHand.set() : NSCursor.arrow.set() }
                .frame(width: 28)

                // Name
                Text(result.displayName)
                    .font(.lato(size: 12, weight: .medium))
                    .foregroundColor(.fgBright)

                Spacer()

                // Reveal in Finder
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([result.url])
                } label: {
                    Image(systemName: "arrow.up.right.square")
                        .font(.lato(size: 11))
                        .foregroundColor(rowHovered ? .fgMid : .fgDim)
                }
                .buttonStyle(.plain)
                .onHover { h in h ? NSCursor.pointingHand.set() : NSCursor.arrow.set() }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)

            // Waveform playback bar — slides in when this stem is active
            if isCurrent {
                waveformBar
                    .padding(.horizontal, 14)
                    .padding(.bottom, 8)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                    .contentShape(Rectangle())
                    .onTapGesture { }  // absorb stray taps
            }

            // Piano extraction sub-row — only on other-x-guitar results
            if let extract = onExtractPiano {
                Divider()
                    .background(Color.border.opacity(0.4))
                    .padding(.leading, 38)
                HStack(spacing: 6) {
                    Image(systemName: "pianokeys")
                        .font(.system(size: 10))
                        .foregroundColor(.fgDim)
                    if isExtracting {
                        ProgressView()
                            .scaleEffect(0.5)
                            .frame(width: 12, height: 12)
                        Text("Extracting…")
                            .font(.lato(size: 11))
                            .foregroundColor(.fgDim)
                    } else {
                        Button("Extract Piano", action: extract)
                            .buttonStyle(CompactSecondaryButtonStyle().hoverable())
                    }
                    Spacer()
                }
                .padding(.leading, 38)
                .padding(.trailing, 14)
                .padding(.vertical, 6)
            }
        }
        .background(isCurrent ? Color.accent.opacity(0.04) : Color.clear)
        .contentShape(Rectangle())
        .onHover { h in withAnimation(.easeOut(duration: 0.1)) { rowHovered = h } }
        .animation(.easeInOut(duration: 0.15), value: isCurrent)
    }

    private var waveformBar: some View {
        HStack(spacing: 8) {
            // Play / pause
            Button {
                player.togglePause()
            } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.accent)
                    .frame(width: 20, height: 20)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(playHover ? Color.accent.opacity(0.15) : Color.clear)
                    )
            }
            .buttonStyle(.plain)
            .frame(width: 28, height: 28)
            .contentShape(Rectangle())
            .onHover { h in withAnimation(.easeOut(duration: 0.12)) { playHover = h } }

            // Elapsed time
            let currentT = isScrubbing ? scrubValue : player.currentTime
            Text(formatTime(currentT))
                .font(.lato(size: 9))
                .foregroundColor(.fgDim)
                .monospacedDigit()
                .frame(width: 30, alignment: .trailing)

            // Waveform
            WaveformSeekView(
                peaks: result.waveformPeaks,
                progress: player.duration > 0 ? currentT / player.duration : 0,
                onSeek: { p in
                    let t = p * player.duration
                    isScrubbing = true
                    scrubValue = t
                    player.seek(to: t)
                },
                onSeekEnd: {
                    player.seek(to: scrubValue)
                    isScrubbing = false
                }
            )
            .frame(height: 36)

            // Remaining time
            Text("-" + formatTime(max(0, player.duration - currentT)))
                .font(.lato(size: 9))
                .foregroundColor(.fgDim)
                .monospacedDigit()
                .frame(width: 30, alignment: .leading)

            // Volume
            Image(systemName: "speaker.wave.2.fill")
                .font(.system(size: 9))
                .foregroundColor(.fgDim)

            Slider(value: Binding(
                get: { Double(player.volume) },
                set: { player.volume = Float($0) }
            ), in: 0...1)
            .frame(width: 60)
        }
    }

    private func formatTime(_ t: Double) -> String {
        guard t.isFinite && t >= 0 else { return "0:00" }
        let s = Int(t)
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

extension Notification.Name {
    static let audioShakeClearAll = Notification.Name("com.multitracks.MTSongTool.audioShakeClearAll")
}
