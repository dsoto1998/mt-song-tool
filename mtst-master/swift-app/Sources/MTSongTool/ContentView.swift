import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Root content
struct ContentView: View {
    @StateObject private var parser = ParserService()
    @StateObject private var audioAnalyzer = AudioAnalyzerService()
    @StateObject private var stemPlayer = StemPlayerService()
    @StateObject private var editPlayer = EditPlayerService()
    @StateObject private var audioShakePlayer = StemPlayerService()
    @StateObject private var metronome = MetronomeService()
    @ObservedObject private var userSettings = UserSettings.shared
    @State private var copiedMarkers = false
    @State private var copiedSigs = false
    @State private var copiedTempos = false
    @State private var showSettings = false
    @State private var showLive12Alert = false
    @State private var showOldVersionAlert = false
    @State private var ableton11URL: URL? = nil
    @State private var oldVersionAlsPath: String? = nil
    @State private var isConvertingToLive11 = false
    @State private var toastMessage: String = ""
    @State private var toastIsError: Bool = false
    @State private var showToast: Bool = false

    // Song Data fields
    @State private var songKey: String = ""
    @State private var isDetectingKey: Bool = false
    @State private var songTimeSig: String = ""
    @State private var bpmText: String = ""
    @State private var previewStartText: String = ""
    @State private var previewEndText: String = ""
    // Tracks the last auto-calculated Preview End value so we know whether
    // the user has manually overridden it (if current value ≠ this, don't clobber it)
    @State private var previewEndAutoValue: String = ""
    @State private var rehearsalMixOnly: Bool = false
    @State private var highlightMissing: Bool = false
    // Prevents populateSongData from clobbering user-entered fields on re-parse
    // (e.g. after a locator fix-and-re-parse).
    @State private var hasPopulatedSongData = false
    @State private var stemCheckMinimized: Bool = false  // lifted so re-parses don't reset it
    @State private var songDataMinimized: Bool = false
    @State private var locatorsSigMinimized: Bool = false


    @State private var isFileBarTargeted: Bool = false
    @State private var copiedBpm: Bool = false
    @State private var copiedPreviewStart: Bool = false
    @State private var copiedPreviewEnd: Bool = false
    @State private var copiedSongDuration: Bool = false
    @State private var copiedDisplayDuration: Bool = false

    // Active app tab
    enum AppTab { case qa, edit, audioshake }
    @State private var activeTab: AppTab = .qa

    // AudioShake settings entry
    @State private var audioShakeKeyInput: String = ""

    // Focus tracking for Song Data + MTID tab order
    enum SongDataFocus: Hashable {
        case songKey, timeSig, bpm, previewStart, previewEnd, rehearsalMix
    }
    @State private var songDataFocus: SongDataFocus? = nil
    @State private var openSongKeyPicker = false
    @State private var openTimeSigPicker = false

    var body: some View {
        ZStack {
            Color.bg.ignoresSafeArea()

            VStack(spacing: 0) {
                topBar
                    .padding(.bottom, 4)

                // Persistent file bar — always above the scroll content once a file is loaded
                if parser.result != nil {
                    fileDropBar
                        .padding(.horizontal, 20)
                        .padding(.bottom, 10)
                }

                // Tab switcher — always visible
                tabSwitcher
                    .padding(.horizontal, 20)
                    .padding(.bottom, 10)

                if activeTab == .audioshake {
                    AudioShakeView(player: audioShakePlayer)
                        .padding(.horizontal, 20)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if activeTab == .edit {
                    // Edit tab manages its own internal scroll — must NOT be inside outer ScrollView
                    // so that the floating global selection bar at the bottom works correctly.
                    EditView(
                        editPlayer: editPlayer,
                        metronome: metronome,
                        stemURLs: audioAnalyzer.stemURLs,
                        analyzer: audioAnalyzer,
                        parsedResult: parser.result,
                        onLocatorFix: { fixes in applyLocatorFixes(fixes) },
                        mtCompleteMode: userSettings.mtCompleteMode,
                        onFolderDrop: { url in handleFolderDrop(url) },
                        onBuildComplete: { path in loadNewFile(path: path) }
                    )
                    .padding(.horizontal, 20)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    VStack(spacing: 0) {
                        // QA tab content (also shown before any file is loaded — drop zone)
                        // layoutPriority(0) — gets compressed first when space is tight
                        dropZoneOrResults
                            .frame(minHeight: parser.result == nil ? 220 : 0)
                            .padding(.horizontal, 20)
                            .padding(.bottom, 12)

                        // Song Data — persistent once an .als is loaded
                        // layoutPriority(1) — protected from compression, natural height only
                        if parser.result != nil {
                            songDataView
                                .padding(.horizontal, 20)
                                .padding(.bottom, 12)
                                .layoutPriority(1)
                        }

                        // Audio analysis panel — shown after an .als is loaded, or always in Quick Check Mode
                        // layoutPriority(1) — protected from compression, natural height only
                        if parser.result != nil || userSettings.quickCheckMode {
                            VStack(alignment: .trailing, spacing: 8) {
                                AudioAnalysisView(
                                    analyzer: audioAnalyzer,
                                    stemPlayer: stemPlayer,
                                    rehearsalMixOnly: rehearsalMixOnly,
                                    expectedDuration: parser.result?.expectedDuration,
                                    isMinimized: $stemCheckMinimized,
                                    quickCheckMode: userSettings.quickCheckMode,
                                    jamNightMode: userSettings.jamNightMode
                                )
                                .frame(maxWidth: .infinity)
                                // Clear All only shown here in Quick Check Mode without a loaded file
                                // (when a file is loaded, Clear All lives in the file bar)
                                if parser.result == nil {
                                    Button("Clear All") { clearAll() }
                                        .buttonStyle(SecondaryButtonStyle().hoverable())
                                }
                            }
                            .frame(maxWidth: .infinity)
                            .layoutPriority(1)
                            .padding(.horizontal, 20)
                            .padding(.bottom, 20)
                        }

                        // Blank space always sinks to bottom
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }


            // Live 11 conversion loading overlay
            if isConvertingToLive11 {
                Color.black.opacity(0.45)
                    .ignoresSafeArea()
                    .zIndex(200)
                VStack(spacing: 12) {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .scaleEffect(1.2)
                        .tint(.fgBright)
                    Text("Converting to Ableton 11…")
                        .font(.lato(size: 13, weight: .semibold))
                        .foregroundColor(.fgBright)
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 20)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.bgCard)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(Color.border, lineWidth: 1)
                        )
                )
                .transition(.opacity)
                .zIndex(201)
            }

            // Toast pill — centered overlay
            if showToast {
                Text(toastMessage)
                    .font(.lato(size: 13, weight: .semibold))
                    .foregroundColor(toastIsError ? Color.redLight : .accent2)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(
                        Capsule()
                            .fill(toastIsError ? Color.redBg : Color.toastComingBg)
                            .overlay(
                                Capsule()
                                    .stroke(toastIsError ? Color.red.opacity(0.3) : Color.accent2.opacity(0.3), lineWidth: 1)
                            )
                    )
                    .transition(.opacity)
                    .zIndex(100)
            }
        }
        .frame(minWidth: 680, minHeight: 680)
        .onChange(of: parser.isLoading) { isLoading in
            if !isLoading, let version = parser.result?.liveMajorVersion {
                if version == 12 { showLive12Alert = true }
                else if version < 11 {
                    oldVersionAlsPath = parser.alsPath
                    ableton11URL = findAbleton11()
                    clearAll()
                    showOldVersionAlert = true
                }
            }
            // Build metronome schedule whenever a parse completes (used by both QA + Edit tabs)
            // Skip for unsupported versions (Live 12 needs conversion; Live <11 needs re-save)
            let parsedVersion = parser.result?.liveMajorVersion
            let versionOK = parsedVersion == nil || parsedVersion == 11
            if !isLoading, let result = parser.result, versionOK {
                ableton11URL = findAbleton11()
                Log("parse complete — tempoEvents=\(result.tempoEvents.count) timeSigs=\(result.timeSignatures.count) expectedDuration=\(result.expectedDuration.map { String(format: "%.2f", $0) } ?? "nil")", "ContentView")
                metronome.buildSchedule(
                    tempoEvents: result.tempoEvents,
                    timeSigs: result.timeSignatures,
                    totalDuration: result.expectedDuration ?? 0,
                    staticBPM: result.bpm
                )
            }
        }
        .onChange(of: stemPlayer.isPlaying) { playing in
            Log("stemPlayer.isPlaying → \(playing) | currentTime=\(String(format: "%.3f", stemPlayer.currentTime)) sectionStart=\(stemPlayer.activeSectionStart.map { String(format: "%.3f", $0) } ?? "nil")", "ContentView")
            if !playing { metronome.stop() }
            // metronome START is driven by playAnchor below, not isPlaying,
            // so AVPlayer's actual timing is measured before scheduling beats.
        }
        .onChange(of: stemPlayer.playAnchor) { anchor in
            guard let anchor else { return }
            metronome.start(anchorHostTime: anchor.hostTime, startSessionTime: anchor.sessionTime)
        }
        .onChange(of: audioAnalyzer.isConverting) { converting in
            if !converting && audioAnalyzer.conversionErrors.isEmpty {
                showToastMessage("Conversion complete", isError: false)
            }
        }
        .onChange(of: audioAnalyzer.isScanning) { scanning in
            // When stem scan finishes, auto-detect key from ORIGINAL SONG if songKey is empty
            guard !scanning, songKey.isEmpty, let url = originalSongURL else { return }
            Task {
                isDetectingKey = true
                defer { isDetectingKey = false }
                if let key = try? await parser.detectKey(stemPath: url) {
                    if songKey.isEmpty { songKey = key }
                }
            }
        }
        .alert("Ableton 12 Session", isPresented: $showLive12Alert) {
            Button("Convert to Ableton 11") { convertToLive11() }
            Button("Cancel", role: .cancel) { clearAll() }
        } message: {
            Text("This .als is made for Ableton 12. Convert to Ableton 11?")
        }
        .alert("Old Ableton Version", isPresented: $showOldVersionAlert) {
            if ableton11URL != nil {
                Button("Open in Ableton 11") { openInAbleton11(path: oldVersionAlsPath) }
            }
            Button("OK", role: .cancel) { }
        } message: {
            Text("This session was saved in an older version of Ableton. Open it in Ableton 11 and save it before loading it in MT Song Tool.")
        }
    }

    // MARK: Settings gear
    @State private var gearHovered = false
    private var settingsButton: some View {
        Button {
            showSettings.toggle()
        } label: {
            Image(systemName: "gearshape.fill")
                .font(.lato(size: 14))
                .foregroundColor(gearHovered ? .fgBright : .fgDim)
                .padding(6)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) { gearHovered = hovering }
            if hovering { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
        }
        .popover(isPresented: $showSettings, arrowEdge: .top) {
            VStack(spacing: 10) {
                // Theme picker
                HStack {
                    Text("Theme")
                        .font(.lato(size: 11))
                        .foregroundColor(.fgDim)
                    Spacer()
                    HStack(spacing: 0) {
                        ForEach(AppTheme.allCases, id: \.self) { theme in
                            SettingsPillButton(
                                label: theme.label,
                                isActive: userSettings.theme == theme
                            ) {
                                userSettings.theme = theme
                            }
                        }
                    }
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.border, lineWidth: 1)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }

                // Copy All toggle
                HStack {
                    Text("Copy All")
                        .font(.lato(size: 11))
                        .foregroundColor(.fgDim)
                    Spacer()
                    HStack(spacing: 0) {
                        SettingsPillButton(label: "Show", isActive: userSettings.showCopyAll) {
                            userSettings.showCopyAll = true
                        }
                        SettingsPillButton(label: "Hide", isActive: !userSettings.showCopyAll) {
                            userSettings.showCopyAll = false
                        }
                    }
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.border, lineWidth: 1)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }

                Divider()

                // Jam Night toggle visibility
                HStack {
                    Text("Jam Night")
                        .font(.lato(size: 11))
                        .foregroundColor(.fgDim)
                    Spacer()
                    HStack(spacing: 0) {
                        SettingsPillButton(label: "Show", isActive: userSettings.showJamNightToggle) {
                            userSettings.showJamNightToggle = true
                        }
                        SettingsPillButton(label: "Hide", isActive: !userSettings.showJamNightToggle) {
                            userSettings.showJamNightToggle = false
                            userSettings.jamNightMode = false
                        }
                    }
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.border, lineWidth: 1)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }

                Divider()

                // Edit tab settings
                VStack(alignment: .leading, spacing: 6) {
                    Text("Edit")
                        .font(.lato(size: 11, weight: .semibold))
                        .foregroundColor(.fgMid)
                    Toggle(isOn: $userSettings.autoFadeCuts) {
                        Text("Auto 10ms fade-in on cuts")
                            .font(.lato(size: 11))
                            .foregroundColor(.fgBright)
                    }
                    .toggleStyle(.checkbox)
                }

                Divider()

                // AudioShake API key
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 4) {
                        Text("AudioShake")
                            .font(.lato(size: 11, weight: .semibold))
                            .foregroundColor(.fgMid)
                        Image(systemName: "lock.fill")
                            .font(.lato(size: 9))
                            .foregroundColor(.fgDim)
                    }
                    if userSettings.hasAudioShakeKey {
                        HStack {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.lato(size: 11))
                                .foregroundColor(.green)
                            Text("API key saved to Keychain")
                                .font(.lato(size: 11))
                                .foregroundColor(.fgBright)
                            Spacer()
                            Button("Remove") {
                                CredentialStore.delete(key: CredentialStore.audioShakeAPIKeyKey)
                                userSettings.hasAudioShakeKey = false
                                audioShakeKeyInput = ""
                            }
                            .font(.lato(size: 10))
                            .foregroundColor(.red)
                            .buttonStyle(.plain)
                            .onHover { h in h ? NSCursor.pointingHand.set() : NSCursor.arrow.set() }
                        }
                    } else {
                        HStack(spacing: 6) {
                            SecureField("Paste API key…", text: $audioShakeKeyInput)
                                .font(.lato(size: 11))
                                .textFieldStyle(.roundedBorder)
                            Button("Save") {
                                let trimmed = audioShakeKeyInput.trimmingCharacters(in: .whitespaces)
                                guard !trimmed.isEmpty else { return }
                                CredentialStore.save(key: CredentialStore.audioShakeAPIKeyKey, value: trimmed)
                                userSettings.hasAudioShakeKey = true
                                audioShakeKeyInput = ""
                            }
                            .font(.lato(size: 11, weight: .semibold))
                            .foregroundColor(.accent)
                            .buttonStyle(.plain)
                            .disabled(audioShakeKeyInput.trimmingCharacters(in: .whitespaces).isEmpty)
                            .onHover { h in h ? NSCursor.pointingHand.set() : NSCursor.arrow.set() }
                        }
                        Text("Stored encrypted in macOS Keychain")
                            .font(.lato(size: 10))
                            .foregroundColor(.fgDim)
                    }
                }

                Divider()

                // Name + Log Out
                HStack {
                    Text(userSettings.fullName)
                        .font(.lato(size: 13, weight: .bold))
                        .foregroundColor(.fgBright)
                    Spacer()
                    LogOutButton {
                        showSettings = false
                        userSettings.firstName = ""
                        userSettings.lastName = ""
                    }
                }
                Text("v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")")
                    .font(.lato(size: 10))
                    .foregroundColor(.fgDim)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
            .padding(14)
            .frame(width: 260)
        }
    }

    // MARK: Jam Night Mode toggle
    @State private var jamNightHovered = false
    private var jamNightToggle: some View {
        Button {
            userSettings.jamNightMode.toggle()
        } label: {
            let color: Color = userSettings.jamNightMode ? .accent : (jamNightHovered ? .fgBright : .fgDim)
            HStack(spacing: 5) {
                Image(systemName: userSettings.jamNightMode ? "checkmark.square.fill" : "square")
                    .font(.system(size: 10))
                    .foregroundColor(color)
                Text("Jam Night")
                    .font(.lato(size: 10, weight: userSettings.jamNightMode ? .semibold : .regular))
                    .foregroundColor(color)
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(userSettings.jamNightMode ? Color.accent.opacity(0.10) : Color.clear)
                    .overlay(
                        RoundedRectangle(cornerRadius: 5)
                            .stroke(
                                userSettings.jamNightMode ? Color.accent.opacity(0.35) : Color.border.opacity(0.6),
                                lineWidth: 1
                            )
                    )
            )
            .animation(.easeOut(duration: 0.12), value: userSettings.jamNightMode)
            .animation(.easeOut(duration: 0.12), value: jamNightHovered)

        }
        .buttonStyle(.plain)
        .onHover { h in
            jamNightHovered = h
            if h { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
        }
    }

    // MARK: MT Complete Mode toggle
    @State private var mtCompleteHovered = false
    private var mtCompleteToggle: some View {
        Button {
            userSettings.mtCompleteMode.toggle()
        } label: {
            let color: Color = userSettings.mtCompleteMode ? .accent : (mtCompleteHovered ? .fgBright : .fgDim)
            HStack(spacing: 5) {
                Image(systemName: userSettings.mtCompleteMode ? "checkmark.square.fill" : "square")
                    .font(.system(size: 10))
                    .foregroundColor(color)
                Text("MT Complete")
                    .font(.lato(size: 10, weight: userSettings.mtCompleteMode ? .semibold : .regular))
                    .foregroundColor(color)
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(userSettings.mtCompleteMode ? Color.accent.opacity(0.10) : Color.clear)
                    .overlay(
                        RoundedRectangle(cornerRadius: 5)
                            .stroke(
                                userSettings.mtCompleteMode ? Color.accent.opacity(0.35) : Color.border.opacity(0.6),
                                lineWidth: 1
                            )
                    )
            )
            .animation(.easeOut(duration: 0.12), value: userSettings.mtCompleteMode)
            .animation(.easeOut(duration: 0.12), value: mtCompleteHovered)
        }
        .buttonStyle(.plain)
        .onHover { h in
            mtCompleteHovered = h
            if h { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
        }
    }

    // MARK: Quick Check Mode toggle
    @State private var quickCheckHovered = false
    private var quickCheckToggle: some View {
        Button {
            userSettings.quickCheckMode.toggle()
        } label: {
            let color: Color = userSettings.quickCheckMode ? .accent : (quickCheckHovered ? .fgBright : .fgDim)
            HStack(spacing: 5) {
                Image(systemName: userSettings.quickCheckMode ? "checkmark.square.fill" : "square")
                    .font(.system(size: 10))
                    .foregroundColor(color)
                Text("Quick Check")
                    .font(.lato(size: 10, weight: userSettings.quickCheckMode ? .semibold : .regular))
                    .foregroundColor(color)
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(userSettings.quickCheckMode ? Color.accent.opacity(0.10) : Color.clear)
                    .overlay(
                        RoundedRectangle(cornerRadius: 5)
                            .stroke(
                                userSettings.quickCheckMode ? Color.accent.opacity(0.35) : Color.border.opacity(0.6),
                                lineWidth: 1
                            )
                    )
            )
            .animation(.easeOut(duration: 0.12), value: userSettings.quickCheckMode)
            .animation(.easeOut(duration: 0.12), value: quickCheckHovered)
        }
        .buttonStyle(.plain)
        .onHover { h in
            quickCheckHovered = h
            if h { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
        }
    }

    // MARK: Tab switcher
    private var tabSwitcher: some View {
        HStack(spacing: 0) {
            tabButton(label: "QA", tab: .qa)
            tabButton(label: "Edit", tab: .edit)
            tabButton(label: "AudioShake", tab: .audioshake)
            Spacer()
        }
    }

    private func tempoDisplayTime(for time: String, previousTime: String?) -> String {
        guard let prev = previousTime, prev == time else { return time }
        let parts = time.split(separator: ":", maxSplits: 2)
        guard parts.count == 3,
              let mm = Int(parts[0]),
              let ss = Int(parts[1]),
              let mmm = Int(parts[2]) else { return time }
        return String(format: "%02d:%02d:%03d", mm, ss, min(mmm + 1, 999))
    }

    private func tabButton(label: String, tab: AppTab) -> some View {
        let isActive = activeTab == tab
        return Button(label) {
            if tab != .qa { stemPlayer.stop() }
            if tab != .edit { editPlayer.stop() }
            if tab != .audioshake { audioShakePlayer.stop() }
            activeTab = tab
        }
            .font(.lato(size: 12, weight: isActive ? .semibold : .regular))
            .foregroundColor(isActive ? .accent : .fgMid)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(isActive ? Color.accent.opacity(0.12) : Color.clear)
            .cornerRadius(6)
            .buttonStyle(.plain)
    }

    // MARK: Header
    private var topBar: some View {
        ZStack {
            Text("MTST")
                .font(.horizon(size: 35))
                .foregroundColor(.accent)
                .frame(maxWidth: .infinity)
                .allowsHitTesting(false)
            HStack(spacing: 0) {
                MetronomeView(metronome: metronome)
                    .padding(.leading, 16)
                if ableton11URL != nil && parser.result != nil {
                    Button("Open in Ableton Live 11") { openInAbleton11() }
                        .buttonStyle(CompactSecondaryButtonStyle().hoverable())
                        .padding(.leading, 8)
                }
                Spacer()
                HStack(spacing: 10) {
                    if userSettings.showJamNightToggle {
                        jamNightToggle
                    }
                    mtCompleteToggle
                    quickCheckToggle
                    settingsButton
                }
                .padding(.trailing, 16)
            }
        }
        .frame(height: 46)
    }

    // MARK: Main area — drop zone if no result, panels if we have one
    @ViewBuilder
    private var dropZoneOrResults: some View {
        if parser.isLoading {
            loadingView
        } else if let result = parser.result {
            resultsView(result: result)
        } else {
            DropZoneView(errorMessage: parser.errorMessage, onFolderDrop: { url in
                handleFolderDrop(url)
            }) { url in
                loadNewFile(path: url.path)
            }
        }
    }

    // MARK: Loading
    private var loadingView: some View {
        VStack(spacing: 14) {
            ProgressView()
                .scaleEffect(1.3)
                .tint(.accent)
            Text("Parsing file…")
                .font(.lato(size: 13))
                .foregroundColor(.fgDim)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .cardStyle()
    }

    // MARK: Load a new file — clears all state then parses
    private func loadNewFile(path: String) {
        parser.result = nil
        parser.errorMessage = nil
        resetSongData()
        audioAnalyzer.reset()
        parser.parse(alsPath: path)
    }

    // MARK: Handle a dropped session folder — finds .als + stems subfolder
    private func handleFolderDrop(_ url: URL) {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: .skipsHiddenFiles
        ) else { return }

        // Load the first .als found at root
        if let alsURL = items.first(where: { $0.pathExtension.lowercased() == "als" }) {
            loadNewFile(path: alsURL.path)
        }

        // Find the first subdirectory that contains .wav files — treat it as the stems folder
        let subfolders = items.filter { item in
            var isDir: ObjCBool = false
            fm.fileExists(atPath: item.path, isDirectory: &isDir)
            return isDir.boolValue
        }
        if let stemsDir = subfolders.first(where: { dir in
            let contents = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
            return contents.contains { $0.pathExtension.lowercased() == "wav" }
        }) {
            audioAnalyzer.analyze(folder: stemsDir)
        }
    }

    // MARK: File picker (used by file bar tap and initial drop zone)
    private func openFilePicker() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "als") ?? .data]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose an Ableton Live Set (.als)"
        panel.prompt = "Open"

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            loadNewFile(path: url.path)
        }
    }

    // MARK: Auto-populate Song Data fields from parsed result
    private func populateSongData(from result: ParsedResult) {
        // Only populate on the first parse — skip on re-parses triggered by locator fixes
        // so we don't clobber fields the user has already filled in.
        guard !hasPopulatedSongData else { return }
        hasPopulatedSongData = true
        // Time signature: first time sig from the song
        if let firstTS = result.timeSignatures.first {
            if SongDataOptions.timeSignatures.contains(firstTS.sig) {
                songTimeSig = firstTS.sig
            }
        }

        // BPM: initial tempo from Ableton session
        if let bpm = result.bpm {
            let rounded = bpm.truncatingRemainder(dividingBy: 1) == 0
                ? String(format: "%.0f", bpm)
                : String(format: "%.2f", bpm)
            bpmText = rounded
        }

        // Preview start: first CHORUS after 01:00, minus 10 seconds, as whole seconds
        if let start = TimecodeHelper.computePreviewStart(markers: result.markers) {
            previewStartText = "\(max(0, start))"
            let autoEnd = "\(max(0, start) + 45)"
            previewEndText = autoEnd
            previewEndAutoValue = autoEnd
        }

        // Auto-enable MT Complete mode when short-code locators V1, VS, and V4 are all present
        let locatorNames = Set(result.markers.map { $0.text })
        if locatorNames.contains("V1") && locatorNames.contains("VS") && locatorNames.contains("V4") {
            userSettings.mtCompleteMode = true
        }
    }

    // MARK: Issue category checks
    private var hasSessionWarnings: Bool {
        guard let result = parser.result else { return false }
        if userSettings.jamNightMode {
            // Jam Night: allow tempo ramps, loop/clip alignment issues
            return result.warnings.contains {
                !$0.hasPrefix("Tempo ramp:") &&
                !$0.hasSuffix("does not end on beat 1") &&
                !$0.contains("are not the same length")
            }
        }
        return !result.warnings.isEmpty
    }

    private var hasInvalidLocators: Bool {
        guard let result = parser.result else { return false }
        return result.markers.contains { !LocatorValidator.isValid($0.text, mtCompleteMode: userSettings.mtCompleteMode) }
    }

    private var hasOffBeatLocators: Bool {
        guard let result = parser.result else { return false }
        return result.markers.contains { $0.offBeat }
    }

    // Block until a stem scan has been completed (results must be present).
    // In Quick Check Mode stems are optional, so this is never a blocker.
    private var originalSongURL: URL? {
        audioAnalyzer.stemURLs.first {
            $0.deletingPathExtension().lastPathComponent.uppercased() == "ORIGINAL SONG"
        }
    }

    private var stemCheckRequired: Bool {
        !userSettings.quickCheckMode && audioAnalyzer.results.isEmpty
    }

    private var hasAudioIssues: Bool {
        audioAnalyzer.results.contains { !$0.isClean }
    }

    // Block if a stem scan has been run but required stems are not present.
    // Jam Night: only ORIGINAL SONG required. Normal: CLICK TRACK + ORIGINAL SONG (+ GUIDE unless rehearsalMixOnly).
    private var hasMissingRequiredStems: Bool {
        guard !audioAnalyzer.results.isEmpty else { return false }
        let present = Set(audioAnalyzer.results.map {
            URL(fileURLWithPath: $0.filename).deletingPathExtension().lastPathComponent.uppercased()
        })
        var required: Set<String> = ["ORIGINAL SONG"]
        if !userSettings.jamNightMode {
            required.insert("CLICK TRACK")
            if !rehearsalMixOnly { required.insert("GUIDE") }
        }
        return !required.isSubset(of: present)
    }

    private var isLive12Session: Bool {
        parser.result?.liveMajorVersion == 12
    }

    private var isOldSession: Bool {
        if let v = parser.result?.liveMajorVersion { return v < 11 }
        return false
    }

    private var copyBlocked: Bool {
        isLive12Session || isOldSession || hasInvalidLocators || hasOffBeatLocators || hasSessionWarnings || stemCheckRequired || hasAudioIssues || hasDataMissing || hasMissingRequiredStems
    }

    private var copyBlockedReason: String {
        if isLive12Session { return "Convert to Live 11 first" }
        if isOldSession { return "Re-save in Ableton 11 first" }
        if hasInvalidLocators { return "Fix invalid locators first" }
        if hasOffBeatLocators { return "Fix off-beat locators first" }
        if hasSessionWarnings { return "Resolve session warnings first" }
        if hasMissingRequiredStems { return "Required stems missing" }
        if hasAudioIssues { return "Fix stem issues first" }
        if stemCheckRequired { return "Run stem check first" }
        if hasDataMissing { return "Fill in required song data" }
        return "Fix errors before copying"
    }

    private var hasDataMissing: Bool {
        let requireAll = !userSettings.quickCheckMode
        return (requireAll && songKey.isEmpty) ||
        songTimeSig.isEmpty ||
        bpmText.isEmpty ||
        (requireAll && previewStartText.isEmpty) ||
        (requireAll && previewEndText.isEmpty)
    }

    // MARK: Results (two-panel split)
    private func resultsView(result: ParsedResult) -> some View {
        VStack(spacing: 12) {
                // Two independent scrollable panels — always rendered so headers stay visible
                if !locatorsSigMinimized {
                    HStack {
                        Spacer()
                        Button {
                            withAnimation(.easeInOut(duration: 0.18)) { locatorsSigMinimized.toggle() }
                        } label: {
                            Image(systemName: "chevron.up")
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
                HStack(alignment: .top, spacing: 20) {
                    // Locators panel
                    PanelView(
                        title: "Locators",
                        icon: "mappin",
                        isEmpty: result.markers.isEmpty,
                        emptyMessage: "No locators found",
                        copyLabel: copiedMarkers ? "Copied!" : "Copy All",
                        showCopyButton: userSettings.showCopyAll,
                        copyDisabled: copyBlocked,
                        copyBlockedReason: copyBlockedReason,
                        onCopyBlocked: copyBlockedToast,
                        onCopy: {
                            if copiedMarkers { withAnimation(.easeOut(duration: 0.1)) { copiedMarkers = false }; return }
                            let text = result.markers.map { "\($0.time)  \($0.timeEnd)  \($0.text)" }.joined(separator: "\n")
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(text, forType: .string)
                            withAnimation(.easeOut(duration: 0.1)) { copiedMarkers = true }
                        }
                    ) {
                        LocatorCheckView(
                            markers: result.markers,
                            copyDisabled: copyBlocked,
                            onBlocked: copyBlockedToast,
                            onFix: { fixes in applyLocatorFixes(fixes) },
                            mtCompleteMode: userSettings.mtCompleteMode,
                            jamNightMode: userSettings.jamNightMode,
                            firstTempoChangeMarkerIndex: result.firstTempoChangeMarkerIndex,
                            stemPlayer: stemPlayer,
                            audioAnalyzer: audioAnalyzer
                        )
                    }

                    // Time signatures panel
                    PanelView(
                        title: "Time Signatures",
                        icon: "music.note",
                        isEmpty: result.timeSignatures.isEmpty,
                        emptyMessage: "No time signature changes",
                        copyLabel: copiedSigs ? "Copied!" : "Copy All",
                        showCopyButton: userSettings.showCopyAll,
                        copyDisabled: copyBlocked,
                        copyBlockedReason: copyBlockedReason,
                        onCopyBlocked: copyBlockedToast,
                        onCopy: {
                            if copiedSigs { withAnimation(.easeOut(duration: 0.1)) { copiedSigs = false }; return }
                            let text = result.timeSignatures.map { "\($0.time)  \($0.sig)" }.joined(separator: "\n")
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(text, forType: .string)
                            withAnimation(.easeOut(duration: 0.1)) { copiedSigs = true }
                        }
                    ) {
                        HStack(spacing: 12) {
                            Text("#")
                                .frame(width: 22, alignment: .trailing)
                            Text("TIME START")
                                .frame(width: 108, alignment: .leading)
                            Text("TIME SIGNATURE")
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .font(.lato(size: 10, weight: .semibold))
                        .foregroundColor(.fgDim)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 5)

                        Divider().background(Color.border)

                        let firstTempoChangeBeat = result.tempoEvents.first(where: { $0.beat > 0 })?.beat
                        let firstTempoChangeTSIndex: Int? = firstTempoChangeBeat.flatMap { changeBeat in
                            result.timeSignatures.firstIndex(where: { ($0.beat ?? -1) >= changeBeat })
                        }

                        ForEach(Array(result.timeSignatures.enumerated()), id: \.element.id) { index, ts in
                            if index == firstTempoChangeTSIndex {
                                tsSigTempoChangeDivider
                            }
                            RowView(number: index + 1, left: ts.time, right: ts.sig, copyDisabled: copyBlocked, onBlocked: copyBlockedToast)
                        }
                    }

                    // Tempo panel (Jam Night mode only)
                    if userSettings.jamNightMode {
                        PanelView(
                            title: "Tempo",
                            icon: "metronome",
                            isEmpty: result.tempoEvents.isEmpty,
                            emptyMessage: "No tempo data",
                            copyLabel: copiedTempos ? "Copied!" : "Copy All",
                            showCopyButton: userSettings.showCopyAll,
                            copyDisabled: copyBlocked,
                            copyBlockedReason: copyBlockedReason,
                            onCopyBlocked: copyBlockedToast,
                            onCopy: {
                                if copiedTempos { withAnimation(.easeOut(duration: 0.1)) { copiedTempos = false }; return }
                                let text = result.tempoEvents.map { "\($0.time)  \(String(format: "%.2f", $0.bpm)) BPM" }.joined(separator: "\n")
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(text, forType: .string)
                                withAnimation(.easeOut(duration: 0.1)) { copiedTempos = true }
                            }
                        ) {
                            HStack(spacing: 12) {
                                Text("#")
                                    .frame(width: 22, alignment: .trailing)
                                Text("BPM")
                                    .frame(width: 108, alignment: .leading)
                                Text("TIME")
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .font(.lato(size: 10, weight: .semibold))
                            .foregroundColor(.fgDim)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 5)

                            Divider().background(Color.border)

                            ForEach(Array(result.tempoEvents.enumerated()), id: \.offset) { index, event in
                                let isRamp = event.isRampStart || event.isRampEnd
                                RowView(number: index + 1, left: String(format: "%.2f", event.bpm), right: tempoDisplayTime(for: event.time, previousTime: index > 0 ? result.tempoEvents[index - 1].time : nil), isInvalid: isRamp, rampBadge: isRamp, copyDisabled: copyBlocked, onBlocked: copyBlockedToast, leftMinWidth: 44)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: locatorsSigMinimized ? 38 : 2000)
                .clipped()
                .layoutPriority(1)

                // Collapse toggle — bottom only when collapsed
                if locatorsSigMinimized {
                    HStack {
                        Spacer()
                        Button {
                            withAnimation(.easeInOut(duration: 0.18)) { locatorsSigMinimized.toggle() }
                        } label: {
                            Image(systemName: "chevron.down")
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

                // MARK: Session warnings
                if !result.warnings.isEmpty {
                    warningsView(warnings: result.warnings)
                }
        }
        .onAppear { populateSongData(from: result) }
    }

    // MARK: Time signatures tempo-change divider
    private var tsSigTempoChangeDivider: some View {
        HStack(spacing: 6) {
            Rectangle()
                .fill(Color.accent.opacity(0.5))
                .frame(height: 1)
            Text("1st Tempo Change")
                .font(.lato(size: 10, weight: .semibold))
                .foregroundColor(.accent)
                .fixedSize()
            Rectangle()
                .fill(Color.accent.opacity(0.5))
                .frame(height: 1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
    }

    // MARK: Session warnings panel
    private func warningsView(warnings: [String]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(Color.red)
                    .font(.lato(size: 12, weight: .semibold))
                Text("Session Issues")
                    .font(.lato(size: 13, weight: .semibold))
                    .foregroundColor(Color.red)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider()
                .background(Color.red.opacity(0.3))

            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(warnings.enumerated()), id: \.offset) { _, warning in
                    HStack(alignment: .top, spacing: 8) {
                        Text("•")
                            .foregroundColor(Color.red)
                            .font(.lato(size: 12))
                        Text(warning)
                            .font(.lato(size: 12))
                            .foregroundColor(Color.redLight)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.redBg)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.red.opacity(0.3), lineWidth: 1)
                )
        )
    }

    // MARK: Toast helper
    private func copyBlockedToast() {
        showToastMessage("Fix errors before copying", isError: true)
    }

    private func showToastMessage(_ message: String, isError: Bool, duration: Double = 2.5) {
        toastMessage = message
        toastIsError = isError
        withAnimation(.easeOut(duration: 0.25)) { showToast = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
            withAnimation(.easeOut(duration: 0.25)) { showToast = false }
        }
    }

    // MARK: Persistent file drop bar
    private var fileDropBar: some View {
        HStack(spacing: 8) {
            // Drop zone
            HStack(spacing: 8) {
                Image(systemName: "doc.fill")
                    .font(.system(size: 11))
                    .foregroundColor(.accent)

                if let result = parser.result {
                    Text(result.file)
                        .font(.lato(size: 12, weight: .medium))
                        .foregroundColor(.fgMid)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer()

                Text(isFileBarTargeted ? "Release to open" : "Drop to replace")
                    .font(.lato(size: 10))
                    .foregroundColor(isFileBarTargeted ? .accent : .fgDim)
                    .animation(.easeOut(duration: 0.12), value: isFileBarTargeted)
            }
            .padding(.horizontal, 12)
            .frame(height: 35)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isFileBarTargeted ? Color.accent.opacity(0.07) : Color.bgCard)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(
                                isFileBarTargeted ? Color.accent : Color.border,
                                style: StrokeStyle(lineWidth: 1, dash: isFileBarTargeted ? [4, 4] : [])
                            )
                    )
                    .animation(.easeOut(duration: 0.15), value: isFileBarTargeted)
            )
            .contentShape(Rectangle())
            .onTapGesture { openFilePicker() }
            .onDrop(of: [UTType.fileURL], isTargeted: $isFileBarTargeted) { providers in
                guard let provider = providers.first else { return false }
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    DispatchQueue.main.async {
                        var url: URL?
                        if let data = item as? Data {
                            url = URL(dataRepresentation: data, relativeTo: nil)
                        } else if let u = item as? URL {
                            url = u
                        }
                        guard let url else { return }
                        var isDir: ObjCBool = false
                        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
                        if isDir.boolValue {
                            handleFolderDrop(url)
                        } else if url.pathExtension.lowercased() == "als" {
                            loadNewFile(path: url.path)
                        }
                    }
                }
                return true
            }
            .onHover { h in
                if h { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
            }

            // Action buttons
            if parser.result?.liveMajorVersion == 12 {
                Button("Convert to Live 11") { convertToLive11() }
                    .buttonStyle(FixedHeightSecondaryButtonStyle(height: 35).hoverable())
            }
            Button("Clear All") { clearAll() }
                .buttonStyle(FixedHeightSecondaryButtonStyle(height: 35).hoverable())
        }
    }

    // MARK: Reset song data when loading another file
    private func resetSongData() {
        showToast = false
        highlightMissing = false
        songKey = ""
        songTimeSig = ""
        bpmText = ""
        previewStartText = ""
        previewEndText = ""
        previewEndAutoValue = ""
        rehearsalMixOnly = false
        hasPopulatedSongData = false
    }

    // MARK: Locator fix — write NEW_*.als then re-parse the new file
    private func applyLocatorFixes(_ fixes: [(Marker, String)]) {
        parser.fixLocators(fixes: fixes.map { (alsId: $0.0.alsId, newName: $0.1) }) { success, newPath, error in
            if success, let newPath = newPath {
                parser.parse(alsPath: newPath)
                showToastMessage("Locators updated", isError: false)
            } else {
                showToastMessage(error ?? "Fix failed", isError: true)
            }
        }
    }

    // MARK: Convert to Live 11 — write <name>_Live11.als alongside the original
    private func findAbleton11() -> URL? {
        let fm = FileManager.default
        let searchDirs = [
            URL(fileURLWithPath: "/Applications"),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")
        ]
        for dir in searchDirs {
            guard let contents = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { continue }
            if let match = contents.first(where: { url in
                let name = url.lastPathComponent
                return name.hasPrefix("Ableton Live 11") && name.hasSuffix(".app")
            }) { return match }
        }
        return nil
    }

    private func openInAbleton11(path: String? = nil) {
        guard let appURL = ableton11URL,
              let alsPath = path ?? parser.alsPath else { return }
        let alsURL = URL(fileURLWithPath: alsPath)
        NSWorkspace.shared.open([alsURL], withApplicationAt: appURL, configuration: .init()) { _, error in
            if let error { DispatchQueue.main.async { self.showToastMessage(error.localizedDescription, isError: true) } }
        }
    }

    private func convertToLive11() {
        withAnimation(.easeOut(duration: 0.15)) { isConvertingToLive11 = true }
        parser.downgradeToLive11 { success, newPath, error in
            withAnimation(.easeOut(duration: 0.15)) { isConvertingToLive11 = false }
            if success, let newPath = newPath {
                loadNewFile(path: newPath)
            } else {
                showToastMessage(error ?? "Conversion failed", isError: true)
            }
        }
    }

    // MARK: Clear All — resets every panel back to empty state
    private func clearAll() {
        stemPlayer.stop()
        parser.result = nil
        parser.errorMessage = nil
        resetSongData()
        audioAnalyzer.reset()
        stemCheckMinimized = false
        songDataMinimized = false
        locatorsSigMinimized = false
        userSettings.quickCheckMode = false
        userSettings.mtCompleteMode = false
        userSettings.jamNightMode = false
        NotificationCenter.default.post(name: .audioShakeClearAll, object: nil)
    }

    private var songDurationText: String {
        guard let d = parser.result?.expectedDuration else { return "" }
        return String(format: "%.3f", d)
    }

    private var displayDurationText: String {
        guard let markers = parser.result?.markers else { return "" }
        guard let v1 = markers.first(where: { $0.text == "V1" }),
              let secs = TimecodeHelper.toSeconds(v1.time) else { return "" }
        return String(format: "%.3f", secs)
    }

    // MARK: Song Data panel
    private var songDataView: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: 6) {
                Image(systemName: "music.quarternote.3")
                    .foregroundColor(.accent)
                    .font(.lato(size: 12, weight: .semibold))
                Text("Song Data")
                    .font(.lato(size: 13, weight: .semibold))
                    .foregroundColor(.fgBright)
                if hasDataMissing {
                    Text("· Missing fields")
                        .font(.lato(size: 11))
                        .foregroundColor(.red)
                }
                Spacer()
            }
            .padding(.horizontal, 14)
            .frame(height: 38)

            Divider()
                .background(Color.border)

            if !songDataMinimized {
                HStack {
                    Spacer()
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) { songDataMinimized.toggle() }
                    } label: {
                        Image(systemName: "chevron.up")
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

                // Fields grid
                VStack(spacing: 14) {
                    HStack(spacing: 20) {
                        songDataField(label: "Song Key", isMissing: songKey.isEmpty && !isDetectingKey) {
                            HStack(spacing: 6) {
                                SongDataPickerView(selection: $songKey, options: SongDataOptions.songKeys, placeholder: isDetectingKey ? "Detecting…" : "Select Key", isMissing: songKey.isEmpty && !isDetectingKey, onEnter: { songDataFocus = nil; NSApp.keyWindow?.makeFirstResponder(nil) }, onTab: { songDataFocus = .timeSig }, triggerOpen: $openSongKeyPicker)
                                if isDetectingKey {
                                    ProgressView()
                                        .scaleEffect(0.6)
                                        .frame(width: 16, height: 16)
                                }
                            }
                        }

                        songDataField(label: "Time Signature", isMissing: songTimeSig.isEmpty) {
                            SongDataPickerView(selection: $songTimeSig, options: SongDataOptions.timeSignatures, placeholder: "Select", isMissing: songTimeSig.isEmpty, onEnter: { songDataFocus = nil; NSApp.keyWindow?.makeFirstResponder(nil) }, onTab: { songDataFocus = .bpm }, triggerOpen: $openTimeSigPicker)
                        }

                        songDataField(label: "BPM", isMissing: bpmText.isEmpty) {
                            HStack(spacing: 4) {
                                songDataTextField(text: $bpmText, placeholder: "", numbersOnly: true, isMissing: bpmText.isEmpty, isFocused: songDataFocus == .bpm, onTab: { songDataFocus = .previewStart }, onFocus: { songDataFocus = .bpm })
                                songDataCopyButton(value: bpmText, copied: $copiedBpm, copyDisabled: copyBlocked)
                            }
                        }
                    }

                    HStack(spacing: 20) {
                        songDataField(label: "Preview Start (sec)", isMissing: previewStartText.isEmpty) {
                            HStack(spacing: 4) {
                                songDataTextField(text: $previewStartText, placeholder: "", numbersOnly: true, isMissing: previewStartText.isEmpty, isFocused: songDataFocus == .previewStart, onTab: { songDataFocus = .previewEnd }, onFocus: { songDataFocus = .previewStart })
                                songDataCopyButton(value: previewStartText, copied: $copiedPreviewStart, copyDisabled: copyBlocked)
                            }
                        }
                        .onChange(of: previewStartText) { newStart in
                            // Auto-fill Preview End as start + 45 whenever the user types a value,
                            // but only if Preview End is empty or still matches the last auto-calculated value
                            // (i.e. the user hasn't manually overridden it).
                            guard let startVal = Int(newStart) else { return }
                            let computedEnd = "\(startVal + 45)"
                            if previewEndText.isEmpty || previewEndText == previewEndAutoValue {
                                previewEndText = computedEnd
                                previewEndAutoValue = computedEnd
                            }
                        }

                        songDataField(label: "Preview End (sec)", isMissing: previewEndText.isEmpty) {
                            HStack(spacing: 4) {
                                songDataTextField(text: $previewEndText, placeholder: "", numbersOnly: true, isMissing: previewEndText.isEmpty, isFocused: songDataFocus == .previewEnd, onTab: { songDataFocus = .rehearsalMix }, onFocus: { songDataFocus = .previewEnd })
                                songDataCopyButton(value: previewEndText, copied: $copiedPreviewEnd, copyDisabled: copyBlocked)
                            }
                        }

                        songDataField(label: "RehearsalMix Only") {
                            HoverCheckbox(isOn: $rehearsalMixOnly, isFocused: songDataFocus == .rehearsalMix, onTab: { songDataFocus = nil })
                        }
                    }

                    if userSettings.mtCompleteMode {
                        HStack(spacing: 20) {
                            songDataField(label: "Song Duration") {
                                HStack(spacing: 4) {
                                    readOnlyDataDisplay(text: songDurationText)
                                    songDataCopyButton(value: songDurationText, copied: $copiedSongDuration, copyDisabled: copyBlocked || songDurationText.isEmpty)
                                }
                            }
                            songDataField(label: "Display Duration") {
                                HStack(spacing: 4) {
                                    readOnlyDataDisplay(text: displayDurationText)
                                    songDataCopyButton(value: displayDurationText, copied: $copiedDisplayDuration, copyDisabled: copyBlocked || displayDurationText.isEmpty)
                                }
                            }
                            Spacer()
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .onChange(of: songDataFocus) { focus in
                    switch focus {
                    case .songKey:
                        NSApp.keyWindow?.makeFirstResponder(nil)
                        DispatchQueue.main.async { openSongKeyPicker = true }
                    case .timeSig:
                        NSApp.keyWindow?.makeFirstResponder(nil)
                        DispatchQueue.main.async { openTimeSigPicker = true }
                    default: break
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            } else {
                HStack {
                    Spacer()
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) { songDataMinimized.toggle() }
                    } label: {
                        Image(systemName: "chevron.down")
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
        }
        .cardStyle()
    }

    // MARK: Song Data field helpers
    private func songDataField<Content: View>(label: String, isMissing: Bool = false, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.lato(size: 11, weight: .semibold))
                .foregroundColor(isMissing ? Color.red : .fgDim)
                .animation(.easeOut(duration: 0.2), value: isMissing)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func songDataTextField(text: Binding<String>, placeholder: String, numbersOnly: Bool, isMissing: Bool = false, isFocused: Bool = false, onTab: (() -> Void)? = nil, onFocus: (() -> Void)? = nil) -> some View {
        SongDataTextFieldView(text: text, placeholder: placeholder, numbersOnly: numbersOnly, isMissing: isMissing, isFocused: isFocused, onTab: onTab, onFocus: onFocus)
    }

    @ViewBuilder
    private func songDataCopyButton(value: String, copied: Binding<Bool>, copyDisabled: Bool = false) -> some View {
        SongDataCopyButton(value: value, copied: copied, copyDisabled: copyDisabled, onBlocked: copyBlockedToast)
    }

    private func readOnlyDataDisplay(text: String) -> some View {
        Text(text.isEmpty ? "—" : text)
            .font(.lato(size: 13))
            .foregroundColor(text.isEmpty ? .fgDim : .fgBright)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.inputBg)
                    .overlay(RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.border, lineWidth: 1))
            )
    }
}
