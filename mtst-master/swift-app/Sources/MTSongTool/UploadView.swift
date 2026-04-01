import SwiftUI

/// Upload tab — Nolan Ryan stem copy + BackOffice session upload.
struct UploadView: View {
    // Inputs from ContentView
    let mtidText: String
    let committedMTID: String
    let songName: String
    let stemsFolder: URL?
    let alsPath: URL?
    let songKey: String
    let songTimeSig: String
    let bpmText: String
    let previewStartText: String
    let previewEndText: String
    let rehearsalMixOnly: Bool

    @ObservedObject var queueService: QueueService
    @StateObject private var nrService = NolanRyanService()
    @ObservedObject var boService: BackOfficeService
    @ObservedObject private var userSettings = UserSettings.shared

    @State private var showAddToQueueSheet = false
    @State private var pulsePhase: Bool = false
    @State private var copyInitiated: Bool = false

    var body: some View {
        VStack(spacing: 12) {
            nolanRyanCard
            backOfficeCard
            Spacer()
        }
        // Establish BackOffice session on tab open
        .task {
            await boService.ensureLoggedIn()
        }
        // Fetch song metadata when MTID is committed (Enter pressed), not on every keystroke
        .task(id: committedMTID) {
            await boService.fetchSongData(mtid: committedMTID)
        }
        // Re-fetch when login completes (covers credential-save → ensureLoggedIn flow)
        .onChange(of: boService.isLoggedIn) { loggedIn in
            if loggedIn && !committedMTID.isEmpty {
                Task { await boService.fetchSongData(mtid: committedMTID) }
            }
        }
        // Clear stale song data when a new MTID is committed
        .onChange(of: committedMTID) { _ in boService.reset() }
        // After .als upload completes, create the NR folder via BackOffice —
        // unless the folder already exists, in which case skip BackOffice entirely.
        .onChange(of: boService.uploadComplete) { complete in
            guard complete else { return }
            if nrService.isFolderReady {
                boService.uploadStemsComplete = true
            } else {
                Task { await boService.triggerUploadStems(mtid: committedMTID) }
            }
        }
        // Watch for MTID folder to appear on Nolan Ryan (polls every 3 s, starts on commit)
        .task(id: committedMTID) {
            nrService.resetFolderWatch()
            guard !committedMTID.isEmpty else { return }
            if nrService.folderExists(mtid: committedMTID, volumeName: userSettings.nolanRyanVolumeName) {
                nrService.isFolderReady = true
                return
            }
            nrService.isWatchingForFolder = true
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard !Task.isCancelled else { break }
                if nrService.folderExists(mtid: committedMTID, volumeName: userSettings.nolanRyanVolumeName) {
                    nrService.isFolderReady = true
                    nrService.isWatchingForFolder = false
                    return
                }
            }
            nrService.isWatchingForFolder = false
        }
        .onAppear {
            if nrService.isFolderReady && !copyInitiated {
                withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
                    pulsePhase = true
                }
            }
        }
        .onChange(of: nrService.isFolderReady) { ready in
            if ready && !copyInitiated {
                withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
                    pulsePhase = true
                }
            }
        }
        .onChange(of: copyInitiated) { initiated in
            if initiated {
                withAnimation(.default) { pulsePhase = false }
            }
        }
        .onChange(of: mtidText) { _ in
            copyInitiated = false
            pulsePhase = false
        }
        .sheet(isPresented: $showAddToQueueSheet) {
            AddToQueueSheet(
                stemsFolder: stemsFolder,
                alsPath: alsPath,
                mtidText: mtidText,
                songName: resolvedSongName,
                volumeName: userSettings.nolanRyanVolumeName,
                nrService: nrService,
                queueService: queueService,
                fetchedTitle: boService.fetchedTitle
            ) {
                showAddToQueueSheet = false
            }
        }
    }

    // MARK: Nolan Ryan card

    private var nolanRyanCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Image(systemName: "server.rack")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.accent)
                Text("NOLAN RYAN")
                    .font(.lato(size: 13, weight: .semibold))
                    .foregroundColor(.fgBright)
                Spacer()
                copyButton
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider().background(Color.border)

            VStack(alignment: .leading, spacing: 6) {
                // Mount status
                HStack(spacing: 6) {
                    let mounted = nrService.isMounted(volumeName: userSettings.nolanRyanVolumeName)
                    Image(systemName: mounted ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundColor(mounted ? .green : .red)
                    Text(mounted
                         ? "/Volumes/\(userSettings.nolanRyanVolumeName) — connected"
                         : "Not mounted — connect via Finder (⌘K)")
                        .font(.lato(size: 11))
                        .foregroundColor(mounted ? .fgMid : .red)
                    if !mounted {
                        Button("Connect") {
                            nrService.openConnectSheet(volumeName: userSettings.nolanRyanVolumeName)
                        }
                        .font(.lato(size: 10))
                        .buttonStyle(CompactSecondaryButtonStyle().hoverable())
                    }
                }

                // Destination folder — live detection status
                HStack(spacing: 6) {
                    let mounted = nrService.isMounted(volumeName: userSettings.nolanRyanVolumeName)
                    if mtidText.isEmpty {
                        Image(systemName: "folder")
                            .font(.system(size: 10))
                            .foregroundColor(.fgDim)
                        Text("Enter MTID below to locate folder")
                            .font(.lato(size: 11))
                            .foregroundColor(.fgDim)
                    } else if !mounted {
                        Image(systemName: "folder")
                            .font(.system(size: 10))
                            .foregroundColor(.fgDim)
                        Text("Connect to Nolan Ryan to detect folder")
                            .font(.lato(size: 11))
                            .foregroundColor(.fgDim)
                    } else if nrService.isFolderReady {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 10))
                            .foregroundColor(.green)
                        let folderName = nrService.actualFolderName(mtid: mtidText, volumeName: userSettings.nolanRyanVolumeName) ?? "\(mtidText) - …"
                        Text(folderName)
                            .font(.lato(size: 11))
                            .foregroundColor(.fgMid)
                    } else if nrService.isWatchingForFolder {
                        ProgressView().scaleEffect(0.6)
                        Text("Waiting for folder to appear on Nolan Ryan…")
                            .font(.lato(size: 11))
                            .foregroundColor(.fgDim)
                    } else {
                        Image(systemName: "folder")
                            .font(.system(size: 10))
                            .foregroundColor(.fgDim)
                        Text("\(userSettings.nolanRyanVolumeName)/\(mtidText) - …")
                            .font(.lato(size: 11))
                            .foregroundColor(.fgDim)
                    }
                }

                // Stem count
                HStack(spacing: 6) {
                    Image(systemName: "waveform")
                        .font(.system(size: 10))
                        .foregroundColor(.fgDim)
                    if let folder = stemsFolder {
                        let count = wavCount(in: folder)
                        Text("\(count) stem\(count == 1 ? "" : "s") ready to queue")
                            .font(.lato(size: 11))
                            .foregroundColor(.fgMid)
                    } else {
                        Text("No stems folder loaded")
                            .font(.lato(size: 11))
                            .foregroundColor(.fgDim)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .cardStyle()
    }

    private var copyButton: some View {
        Button("Queue Stems") {
            copyInitiated = true
            showAddToQueueSheet = true
        }
        .font(.lato(size: 12, weight: .semibold))
        .foregroundColor(copyEnabled ? .green : .fgDim)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(copyEnabled
                      ? Color.green.opacity(copyInitiated ? 0.15 : (pulsePhase ? 0.35 : 0.08))
                      : Color.fgDim.opacity(0.12))
        )
        .disabled(!copyEnabled)
    }

    private var copyEnabled: Bool {
        !mtidText.isEmpty && stemsFolder != nil && boService.uploadComplete && nrService.isFolderReady
    }

    // MARK: BackOffice card

    private var backOfficeCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: "arrow.up.to.line.circle")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.accent2)
                Text("BACK OFFICE")
                    .font(.lato(size: 13, weight: .semibold))
                    .foregroundColor(.fgBright)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider().background(Color.border)

            VStack(alignment: .leading, spacing: 6) {
                // MTID target
                HStack(spacing: 6) {
                    Image(systemName: mtidText.isEmpty ? "number.circle" : "number.circle.fill")
                        .font(.system(size: 10))
                        .foregroundColor(mtidText.isEmpty ? .red : .fgDim)
                    Text(mtidText.isEmpty ? "No MTID — enter below" : "MTID \(mtidText)")
                        .font(.lato(size: 11))
                        .foregroundColor(mtidText.isEmpty ? .red : .fgMid)
                }

                // .als file status
                HStack(spacing: 6) {
                    Image(systemName: alsPath != nil ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundColor(alsPath != nil ? .green : .fgDim)
                    Text(alsPath.map { $0.lastPathComponent } ?? "No .als file loaded")
                        .font(.lato(size: 11))
                        .foregroundColor(alsPath != nil ? .fgMid : .fgDim)
                }

                // Song data summary
                let baseFields = [songKey, songTimeSig, bpmText, previewStartText, previewEndText].filter { !$0.isEmpty }
                let fields = rehearsalMixOnly ? baseFields + ["RMO"] : baseFields
                HStack(spacing: 6) {
                    Image(systemName: "music.note.list")
                        .font(.system(size: 10))
                        .foregroundColor(.fgDim)
                    Text(fields.isEmpty ? "No song data" : fields.joined(separator: " · "))
                        .font(.lato(size: 11))
                        .foregroundColor(.fgMid)
                        .lineLimit(1)
                }

                // Login status
                HStack(spacing: 6) {
                    if boService.isLoggingIn {
                        ProgressView().scaleEffect(0.6)
                        Text("Connecting to BackOffice…")
                            .font(.lato(size: 11))
                            .foregroundColor(.fgDim)
                    } else if boService.isLoggedIn {
                        Image(systemName: "person.crop.circle.fill.badge.checkmark")
                            .font(.system(size: 10))
                            .foregroundColor(.green)
                        Text("Logged in as \(userSettings.backOfficeUsername)")
                            .font(.lato(size: 11))
                            .foregroundColor(.fgMid)
                    } else if userSettings.hasBackOfficeCreds {
                        Image(systemName: "person.crop.circle.badge.xmark")
                            .font(.system(size: 10))
                            .foregroundColor(.red)
                        Text("Not logged in — check credentials in ⚙ Settings")
                            .font(.lato(size: 11))
                            .foregroundColor(.red)
                    } else {
                        Image(systemName: "person.crop.circle.badge.xmark")
                            .font(.system(size: 10))
                            .foregroundColor(.fgDim)
                        Text("BackOffice credentials not saved — set in ⚙ Settings")
                            .font(.lato(size: 11))
                            .foregroundColor(.fgDim)
                    }
                }

                // Fetched song title / status (or loading indicator)
                if boService.isLoading {
                    HStack(spacing: 6) {
                        ProgressView().scaleEffect(0.6)
                        Text("Fetching song info…")
                            .font(.lato(size: 11))
                            .foregroundColor(.fgDim)
                    }
                } else if !boService.fetchedTitle.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "info.circle")
                            .font(.system(size: 10))
                            .foregroundColor(.fgDim)
                        Text(boService.fetchedTitle)
                            .font(.lato(size: 11, weight: .semibold))
                            .foregroundColor(.fgMid)
                        if !boService.fetchedStatus.isEmpty {
                            Text("· \(boService.fetchedStatus)")
                                .font(.lato(size: 11))
                                .foregroundColor(boService.fetchedStatus == "Released" ? .green : .fgDim)
                        }
                    }
                }

                // Session upload status
                if boService.isUploading {
                    HStack(spacing: 6) {
                        ProgressView().scaleEffect(0.6)
                        Text("Uploading to BackOffice…")
                            .font(.lato(size: 11))
                            .foregroundColor(.fgDim)
                    }
                } else if boService.uploadComplete {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 10))
                            .foregroundColor(.green)
                        Text("Session uploaded")
                            .font(.lato(size: 11))
                            .foregroundColor(.green)
                    }
                }

                // NR folder creation status (triggered automatically after upload)
                if boService.isTriggeringUploadStems {
                    HStack(spacing: 6) {
                        ProgressView().scaleEffect(0.6)
                        Text("Creating Nolan Ryan folder…")
                            .font(.lato(size: 11))
                            .foregroundColor(.fgDim)
                    }
                } else if boService.uploadStemsComplete {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 10))
                            .foregroundColor(.green)
                        Text("Nolan Ryan folder created")
                            .font(.lato(size: 11))
                            .foregroundColor(.green)
                    }
                }

                // Errors
                if let err = boService.lastError {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 10))
                            .foregroundColor(.red)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(err)
                                .font(.lato(size: 11))
                                .foregroundColor(.red)
                                .fixedSize(horizontal: false, vertical: true)
                            if let url = boService.uploadStemsBlockedShellURL {
                                HStack(spacing: 8) {
                                    Link("Open Song Shell", destination: url)
                                        .font(.lato(size: 11))
                                        .foregroundColor(.accent)
                                    Button("Create NR Folder") {
                                        Task { await boService.triggerUploadStems(mtid: committedMTID) }
                                    }
                                    .font(.lato(size: 10))
                                    .buttonStyle(CompactSecondaryButtonStyle().hoverable())
                                }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .cardStyle()
    }

    // MARK: Helpers

    private var resolvedSongName: String {
        guard !songName.isEmpty else { return "" }
        return URL(fileURLWithPath: songName).deletingPathExtension().lastPathComponent
    }

    private func wavCount(in folder: URL) -> Int {
        (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension.lowercased() == "wav" }.count) ?? 0
    }
}

// MARK: - Add to Queue Sheet

struct AddToQueueSheet: View {
    let stemsFolder: URL?
    let alsPath: URL?
    let mtidText: String
    let songName: String
    let volumeName: String
    let nrService: NolanRyanService
    let queueService: QueueService
    let fetchedTitle: String
    let onDismiss: () -> Void

    @State private var wavFiles: [String] = []
    @State private var added = false

    private var alsName: String {
        alsPath?.lastPathComponent ?? ""
    }

    private var nrFolderName: String? {
        nrService.actualFolderName(mtid: mtidText, volumeName: volumeName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Image(systemName: "plus.circle")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.accent)
                Text("ADD TO QUEUE")
                    .font(.lato(size: 13, weight: .semibold))
                    .foregroundColor(.fgBright)
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 14)

            Divider().background(Color.border)

            VStack(alignment: .leading, spacing: 10) {
                // Session
                VStack(alignment: .leading, spacing: 3) {
                    Text("SESSION")
                        .font(.lato(size: 10, weight: .semibold))
                        .foregroundColor(.fgDim)
                    HStack(spacing: 6) {
                        Image(systemName: "doc.fill")
                            .font(.system(size: 11))
                            .foregroundColor(.accent)
                        Text(alsName.isEmpty ? "No session loaded" : alsName)
                            .font(.lato(size: 11))
                            .foregroundColor(alsName.isEmpty ? .fgDim : .fgMid)
                    }
                }

                // NR destination
                VStack(alignment: .leading, spacing: 3) {
                    Text("NOLAN RYAN DESTINATION")
                        .font(.lato(size: 10, weight: .semibold))
                        .foregroundColor(.fgDim)
                    HStack(spacing: 6) {
                        Image(systemName: nrFolderName != nil ? "folder.fill" : "folder")
                            .font(.system(size: 11))
                            .foregroundColor(nrFolderName != nil ? .accent : .fgDim)
                        if let folder = nrFolderName {
                            Text("/Volumes/\(volumeName)/\(folder)")
                                .font(.lato(size: 11))
                                .foregroundColor(.fgMid)
                        } else {
                            Text("Not yet created — folder will be needed before processing")
                                .font(.lato(size: 11))
                                .foregroundColor(.fgDim)
                        }
                    }
                }

                // Stems list
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(wavFiles.count) FILE\(wavFiles.count == 1 ? "" : "S") TO COPY")
                        .font(.lato(size: 10, weight: .semibold))
                        .foregroundColor(.fgDim)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(wavFiles, id: \.self) { name in
                                HStack(spacing: 6) {
                                    Image(systemName: "waveform")
                                        .font(.system(size: 9))
                                        .foregroundColor(.fgDim)
                                    Text(name)
                                        .font(.lato(size: 11))
                                        .foregroundColor(.fgMid)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 180)
                    .padding(8)
                    .background(Color.bg)
                    .cornerRadius(6)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.border, lineWidth: 1))
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            Divider().background(Color.border)

            HStack {
                Spacer()
                Button("Cancel") { onDismiss() }
                    .font(.lato(size: 12))
                    .buttonStyle(CompactSecondaryButtonStyle().hoverable())
                Button(added ? "Added ✓" : "Add to Queue") {
                    guard let folder = stemsFolder else { return }
                    queueService.addItem(
                        mtid: mtidText,
                        songName: fetchedTitle.isEmpty ? songName : fetchedTitle,
                        stemsFolderPath: folder.path,
                        alsName: alsName,
                        nrFolderName: nrFolderName
                    )
                    added = true
                    Task {
                        try? await Task.sleep(nanoseconds: 800_000_000)
                        onDismiss()
                    }
                }
                .font(.lato(size: 12, weight: .semibold))
                .buttonStyle(CompactSecondaryButtonStyle().hoverable())
                .disabled(wavFiles.isEmpty || mtidText.isEmpty || added)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .background(Color.bgCard)
        .frame(width: 420)
        .onAppear {
            guard let folder = stemsFolder else { return }
            wavFiles = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension.lowercased() == "wav" }
                .map { $0.lastPathComponent }
                .sorted()) ?? []
        }
    }
}
