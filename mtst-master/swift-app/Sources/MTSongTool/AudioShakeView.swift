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
    @State private var selectedModels: Set<String> = ["vocals", "instrumental", "drums", "bass"]
    @State private var outputFolder: URL? = nil

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                fileCard
                modelsCard
                outputFolderCard
                runRow
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
        }
        .padding(14)
        .cardStyle()
    }

    // MARK: - Output folder

    private var outputFolderCard: some View {
        HStack(spacing: 10) {
            Image(systemName: "folder")
                .font(.lato(size: 12))
                .foregroundColor(outputFolder != nil ? .accent : .fgDim)

            if let folder = outputFolder {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Output Folder")
                        .font(.lato(size: 10))
                        .foregroundColor(.fgDim)
                    Text(folder.path)
                        .font(.lato(size: 11))
                        .foregroundColor(.fgBright)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            } else {
                Text("Choose output folder")
                    .font(.lato(size: 13))
                    .foregroundColor(.fgMid)
            }

            Spacer()

            Button(outputFolder == nil ? "Choose…" : "Change…") {
                pickOutputFolder()
            }
            .buttonStyle(CompactSecondaryButtonStyle().hoverable())
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .cardStyle()
    }

    // MARK: - Run row

    private var runRow: some View {
        HStack(spacing: 10) {
            let canRun = droppedFileURL != nil && !selectedModels.isEmpty && outputFolder != nil && !service.phase.isActive
            let isRunning = service.phase.isActive

            if isRunning {
                Button("Cancel") {
                    service.cancel()
                }
                .buttonStyle(SecondaryButtonStyle().hoverable())
            } else {
                Button("Separate") {
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

            if !service.results.isEmpty && !isRunning {
                Button("Clear Results") {
                    service.reset()
                    player.stop()
                }
                .buttonStyle(SecondaryButtonStyle().hoverable())
            }

            Spacer()

            if !selectedModels.isEmpty {
                Text("\(selectedModels.count) stem\(selectedModels.count == 1 ? "" : "s") selected")
                    .font(.lato(size: 11))
                    .foregroundColor(.fgDim)
            }
        }
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
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider()
                .background(Color.border)

            ForEach(Array(service.results.enumerated()), id: \.element.id) { idx, result in
                if idx > 0 {
                    Divider().background(Color.border).padding(.leading, 44)
                }
                AudioShakeResultRow(result: result, player: player)
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
            service.reset()
            player.stop()
        }
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
    @State private var rowHovered = false

    private var isCurrent: Bool { player.playingStemURL == result.url }
    private var isPlaying: Bool { isCurrent && player.isPlaying }
    private var progress: Double {
        guard isCurrent, player.duration > 0 else { return 0 }
        return min(player.currentTime / player.duration, 1)
    }

    var body: some View {
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

            // Name + progress bar
            VStack(alignment: .leading, spacing: 4) {
                Text(result.displayName)
                    .font(.lato(size: 12, weight: .medium))
                    .foregroundColor(.fgBright)

                if isCurrent {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Rectangle()
                                .fill(Color.border)
                                .frame(height: 2)
                                .cornerRadius(1)
                            Rectangle()
                                .fill(Color.accent)
                                .frame(width: geo.size.width * progress, height: 2)
                                .cornerRadius(1)
                        }
                    }
                    .frame(height: 2)
                }
            }

            Spacer()

            // Time / duration
            if isCurrent {
                Text("\(formatTime(player.currentTime)) / \(formatTime(player.duration))")
                    .font(.lato(size: 10))
                    .foregroundColor(.fgDim)
                    .monospacedDigit()
            }

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
        .background(isCurrent ? Color.accent.opacity(0.04) : Color.clear)
        .contentShape(Rectangle())
        .onHover { h in withAnimation(.easeOut(duration: 0.1)) { rowHovered = h } }
    }

    private func formatTime(_ t: Double) -> String {
        guard t.isFinite && t >= 0 else { return "0:00" }
        let s = Int(t)
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
