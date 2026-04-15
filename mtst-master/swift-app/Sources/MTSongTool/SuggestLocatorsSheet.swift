import SwiftUI
import AppKit
import PDFKit
import UniformTypeIdentifiers

// MARK: - Lyric text extraction

private func extractText(from url: URL) -> String? {
    let ext = url.pathExtension.lowercased()

    // PDF — PDFKit
    if ext == "pdf" {
        guard let doc = PDFDocument(url: url) else { return nil }
        return doc.string
    }

    // txt / rtf / docx — NSAttributedString handles all three
    if let attrStr = try? NSAttributedString(
        url: url,
        options: [.characterEncoding: NSUTF8StringEncoding],
        documentAttributes: nil
    ) {
        return attrStr.string
    }
    // Fallback for non-UTF-8 plain text
    return try? String(contentsOf: url, encoding: .utf16)
}

// MARK: - Parsed section row (label + first lyric line preview)

private struct ParsedSectionRow: View {
    let index: Int
    let label: String
    let firstWords: String?

    var body: some View {
        HStack(spacing: 10) {
            Text("\(index + 1)")
                .font(.lato(size: 11))
                .foregroundColor(.fgDim)
                .frame(width: 20, alignment: .trailing)

            Text(label)
                .font(.lato(size: 12, weight: .semibold))
                .foregroundColor(.fgBright)
                .frame(width: 140, alignment: .leading)

            if let words = firstWords {
                Text(words)
                    .font(.lato(size: 11))
                    .foregroundColor(.fgMid)
                    .lineLimit(1)
                    .truncationMode(.tail)
            } else {
                Text("instrumental")
                    .font(.lato(size: 11).italic())
                    .foregroundColor(.fgDim)
            }

            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
    }
}

// MARK: - Suggestion result row

private struct SuggestionResultRow: View {
    let index: Int
    let suggestion: LocatorSuggesterService.Suggestion

    var body: some View {
        HStack(spacing: 10) {
            // Status icon
            Image(systemName: suggestion.isLocated ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .font(.system(size: 11))
                .foregroundColor(suggestion.isLocated ? .green : .orange)
                .frame(width: 16)

            // Number
            Text("\(index + 1)")
                .font(.lato(size: 11))
                .foregroundColor(.fgDim)
                .frame(width: 20, alignment: .trailing)

            // Label
            Text(suggestion.label)
                .font(.lato(size: 12, weight: .semibold))
                .foregroundColor(.fgBright)
                .frame(width: 140, alignment: .leading)

            if let ts = suggestion.timeString {
                // Timestamp
                Text(ts)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.accent)
                    .frame(width: 80, alignment: .leading)

                // Confidence pip
                confidencePip
            } else {
                Text("not found — place manually")
                    .font(.lato(size: 11).italic())
                    .foregroundColor(.orange)
            }

            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
    }

    private var confidencePip: some View {
        let high = suggestion.confidence >= 0.75
        return HStack(spacing: 3) {
            Circle()
                .fill(high ? Color.green : Color.orange)
                .frame(width: 5, height: 5)
            Text(high ? "high" : "low")
                .font(.lato(size: 10))
                .foregroundColor(high ? .green : .orange)
        }
    }
}

// MARK: - Main sheet

struct SuggestLocatorsSheet: View {
    let alsPath: String?           // nil = Build Session mode (no .als yet)
    let bpm: Double?               // used when alsPath is nil
    let originalSongURL: URL?
    @ObservedObject var suggester: LocatorSuggesterService
    var buildStore: BuildSessionStore? = nil  // non-nil in Build Session mode
    /// Called with the new .als path (existing-file mode) or "" (build mode) after apply.
    let onApply: (String) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var lyricText: String = ""
    @State private var parsedSections: [(label: String, firstWords: String?)] = []
    @State private var isDropTargeted = false
    @State private var dropError: String? = nil
    @State private var isWriting = false
    @State private var urlText: String = ""
    @State private var isFetchingURL = false

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            sheetHeader
            Divider().background(Color.border)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if lyricText.isEmpty {
                        dropZoneSection
                    } else {
                        parsedSectionsSection
                        if originalSongURL == nil {
                            noOriginalSongWarning
                        }
                        analyzeButton
                    }

                    switch suggester.phase {
                    case .idle:
                        EmptyView()
                    case .analyzing:
                        analyzingSection
                    case .done(let sugs):
                        resultsDivider
                        resultsSection(sugs)
                        applySection(sugs)
                    case .failed(let err):
                        resultsDivider
                        errorSection(err)
                    }
                }
                .padding(16)
            }
        }
        .background(Color.bgCard)
        .frame(width: 480)
        .onDisappear { suggester.reset() }
    }

    // MARK: - Sub-views

    private var sheetHeader: some View {
        HStack {
            Image(systemName: "waveform.and.magnifyingglass")
                .font(.system(size: 13))
                .foregroundColor(.accent)
            Text("Suggest Locators")
                .font(.horizon(size: 13))
                .foregroundColor(.fgBright)
            Spacer()
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11))
                    .foregroundColor(.fgMid)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var dropZoneSection: some View {
        VStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(
                        isDropTargeted ? Color.accent : Color.border,
                        style: StrokeStyle(lineWidth: 1.5, dash: [5])
                    )
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(isDropTargeted ? Color.accent.opacity(0.06) : Color.bg.opacity(0.4))
                    )

                VStack(spacing: 8) {
                    Image(systemName: "doc.text.below.ecg")
                        .font(.system(size: 28))
                        .foregroundColor(isDropTargeted ? .accent : .fgDim)
                    Text("Drop lyric or chord chart here")
                        .font(.lato(size: 13, weight: .semibold))
                        .foregroundColor(isDropTargeted ? .accent : .fgMid)
                    Text(".txt  ·  .rtf  ·  .docx  ·  .pdf")
                        .font(.lato(size: 11))
                        .foregroundColor(.fgDim)
                }
            }
            .frame(height: 120)
            .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
                handleDrop(providers)
            }

            if let err = dropError {
                Text(err)
                    .font(.lato(size: 11))
                    .foregroundColor(.red)
            }

            // Or browse
            Button("Browse…") { browseForFile() }
                .buttonStyle(CompactSecondaryButtonStyle().hoverable())

            // Or paste a URL
            Divider().background(Color.border).padding(.vertical, 4)
            Text("Or paste a lyrics URL (Genius, AZLyrics, etc.)")
                .font(.lato(size: 11))
                .foregroundColor(.fgMid)

            HStack(spacing: 6) {
                TextField("https://genius.com/…", text: $urlText)
                    .font(.system(size: 11, design: .monospaced))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { fetchFromURL() }

                if isFetchingURL {
                    ProgressView().scaleEffect(0.7).frame(width: 24, height: 24)
                } else {
                    Button("Fetch") { fetchFromURL() }
                        .buttonStyle(CompactSecondaryButtonStyle().hoverable())
                        .disabled(urlText.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private var parsedSectionsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("\(parsedSections.count) sections found")
                    .font(.lato(size: 11, weight: .semibold))
                    .foregroundColor(.fgMid)
                Spacer()
                Button("Change File") {
                    lyricText = ""
                    parsedSections = []
                    suggester.reset()
                    dropError = nil
                }
                .buttonStyle(CompactSecondaryButtonStyle().hoverable())
            }
            .padding(.bottom, 8)

            VStack(spacing: 0) {
                ForEach(Array(parsedSections.enumerated()), id: \.offset) { idx, sec in
                    ParsedSectionRow(index: idx, label: sec.label, firstWords: sec.firstWords)
                    if idx < parsedSections.count - 1 {
                        Divider().background(Color.border).padding(.leading, 44)
                    }
                }
            }
            .background(Color.bg.opacity(0.5))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.border, lineWidth: 1))
        }
    }

    private var noOriginalSongWarning: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10))
                .foregroundColor(.orange)
            Text("No ORIGINAL SONG stem found — scan stems first")
                .font(.lato(size: 11))
                .foregroundColor(.orange)
        }
        .padding(.top, 10)
    }

    private var analyzeButton: some View {
        Button(action: runAnalysis) {
            HStack(spacing: 6) {
                Image(systemName: "waveform.and.magnifyingglass")
                Text("Analyze Audio")
            }
        }
        .buttonStyle(SecondaryButtonStyle().hoverable())
        .disabled(originalSongURL == nil || parsedSections.isEmpty)
        .padding(.top, 12)
    }

    private var analyzingSection: some View {
        VStack(spacing: 10) {
            Divider().background(Color.border).padding(.vertical, 8)
            HStack(spacing: 10) {
                ProgressView()
                    .scaleEffect(0.7)
                    .frame(width: 16, height: 16)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Analyzing audio…")
                        .font(.lato(size: 12, weight: .semibold))
                        .foregroundColor(.fgBright)
                    Text("Whisper is transcribing the audio. This takes ~40–60 seconds.")
                        .font(.lato(size: 11))
                        .foregroundColor(.fgMid)
                }
                Spacer()
            }
        }
    }

    private var resultsDivider: some View {
        Divider().background(Color.border).padding(.vertical, 8)
    }

    private func resultsSection(_ suggestions: [LocatorSuggesterService.Suggestion]) -> some View {
        let located = suggestions.filter { $0.isLocated }.count
        return VStack(alignment: .leading, spacing: 0) {
            Text("\(located) of \(suggestions.count) sections located")
                .font(.lato(size: 11, weight: .semibold))
                .foregroundColor(.fgMid)
                .padding(.bottom, 8)

            VStack(spacing: 0) {
                ForEach(Array(suggestions.enumerated()), id: \.element.id) { idx, sug in
                    SuggestionResultRow(index: idx, suggestion: sug)
                    if idx < suggestions.count - 1 {
                        Divider().background(Color.border).padding(.leading, 44)
                    }
                }
            }
            .background(Color.bg.opacity(0.5))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.border, lineWidth: 1))
        }
    }

    private func applySection(_ suggestions: [LocatorSuggesterService.Suggestion]) -> some View {
        let located = suggestions.filter { $0.isLocated }
        let skipped = suggestions.count - located.count

        return VStack(alignment: .leading, spacing: 6) {
            if skipped > 0 {
                Text("\(skipped) section\(skipped == 1 ? "" : "s") not found will be skipped — place manually in Ableton.")
                    .font(.lato(size: 11))
                    .foregroundColor(.orange)
            }

            HStack {
                Spacer()
                if isWriting {
                    ProgressView().scaleEffect(0.7).frame(width: 16, height: 16)
                } else {
                    Button("Apply \(located.count) Locator\(located.count == 1 ? "" : "s")") {
                        applyLocators(located)
                    }
                    .buttonStyle(SecondaryButtonStyle().hoverable())
                    .disabled(located.isEmpty)
                }
            }
        }
        .padding(.top, 12)
    }

    private func errorSection(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 12))
                .foregroundColor(.red)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 4) {
                Text("Analysis failed")
                    .font(.lato(size: 12, weight: .semibold))
                    .foregroundColor(.red)
                Text(message)
                    .font(.lato(size: 11))
                    .foregroundColor(.fgMid)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Try Again") { runAnalysis() }
                    .buttonStyle(CompactSecondaryButtonStyle().hoverable())
                    .padding(.top, 2)
            }
        }
    }

    // MARK: - Actions

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            guard let data = item as? Data,
                  let url  = URL(dataRepresentation: data, relativeTo: nil) else { return }
            DispatchQueue.main.async { loadLyricFile(url) }
        }
        return true
    }

    private func browseForFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText, .rtf,
                                      UTType(filenameExtension: "docx") ?? .data,
                                      .pdf]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            loadLyricFile(url)
        }
    }

    private func loadLyricFile(_ url: URL) {
        dropError = nil
        guard let text = extractText(from: url), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            dropError = "Could not extract text from \(url.lastPathComponent)"
            return
        }
        let sections = parseLyricSections(from: text)
        if sections.isEmpty {
            dropError = "No section headers found (e.g. [Verse 1], [Chorus], or MultiTracks chart format)"
            return
        }
        lyricText     = text
        parsedSections = sections
        suggester.reset()
    }

    private func fetchFromURL() {
        let trimmed = urlText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        dropError = nil
        isFetchingURL = true
        suggester.fetchLyricsURL(trimmed) { text, error in
            isFetchingURL = false
            if let error {
                dropError = error
                return
            }
            guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                dropError = "No lyrics found at that URL"
                return
            }
            let sections = parseLyricSections(from: text)
            if sections.isEmpty {
                dropError = "No section headers found (e.g. [Verse 1], [Chorus], or MultiTracks chart format)"
                return
            }
            lyricText      = text
            parsedSections = sections
            urlText        = ""
            suggester.reset()
        }
    }

    private func runAnalysis() {
        guard let wavURL = originalSongURL, !lyricText.isEmpty else { return }
        suggester.analyze(alsPath: alsPath, bpm: bpm, wavPath: wavURL.path, lyricText: lyricText)
    }

    private func applyLocators(_ located: [LocatorSuggesterService.Suggestion]) {
        // Build Session mode — add locators directly to buildStore
        if let store = buildStore {
            for sug in located {
                guard let beat = sug.beat else { continue }
                store.locators.append(ALSGeneratorService.BuildLocator(beat: beat, name: sug.label))
            }
            store.locators.sort { $0.beat < $1.beat }
            onApply("")
            dismiss()
            return
        }

        // Existing .als mode — write into the file
        guard let als = alsPath else { return }
        isWriting = true
        let locators = located.compactMap { sug -> (beat: Double, name: String)? in
            guard let beat = sug.beat else { return nil }
            return (beat: beat, name: sug.label)
        }
        suggester.writeLocators(alsPath: als, locators: locators) { success, newPath, error in
            isWriting = false
            if success, let newPath = newPath {
                onApply(newPath)
                dismiss()
            } else {
                // Surface error inside the sheet
                suggester.phase = .failed(error ?? "Write failed")
            }
        }
    }

    // MARK: - Client-side section parsing (mirrors Python _parse_lyric_sections)

    private func parseLyricSections(from text: String) -> [(label: String, firstWords: String?)] {
        // Section header patterns: [Verse 1]  Chorus  (Bridge 2)  Pre-Chorus:
        let headerPattern = try? NSRegularExpression(
            pattern: #"^\s*[\[\(\*#_]?\s*((?:verse|chorus|pre[\s\-]?chorus|post[\s\-]?chorus|bridge|intro|outro|tag|refrain|turnaround|interlude|instrumental|vamp|solo|breakdown|channel|exhortation|rap|acapella|pad|ending|count[\s\-]?off|next[\s]?song)(?:\s+\d+)?)\s*[\]\)\*#_:]*\s*$"#,
            options: [.caseInsensitive]
        )
        // MT Charts PDF footer/metadata lines to skip when collecting first words
        let metadataPattern = try? NSRegularExpression(
            pattern: #"^(?:a product of MultiTracks\.com|Writers:|As recorded by:|mtID:|Key:|Tempo:|Time:|Page:\s*\d)"#,
            options: [.caseInsensitive]
        )
        // MultiTracks Charts PDF format: short code + ALL-CAPS section name
        // e.g. "C CHORUS", "Vp VAMP", "V1 VERSE 1", "Pc PRE CHORUS", "Ta TURNAROUND"
        let mtPdfPattern = try? NSRegularExpression(
            pattern: #"^[A-Za-z]{1,3}\d*\s+(VAMP|INTRO|VERSE(?:\s+\d+)?|PRE CHORUS|CHORUS|TURNAROUND|BREAKDOWN|BRIDGE|INSTRUMENTAL|OUTRO|ENDING|TAG|REFRAIN|INTERLUDE|SOLO|COUNT OFF|NEXT SONG|POST.?CHORUS|CHANNEL|EXHORTATION|RAP|ACAPELLA|PAD)(?:\s+\d+)?$"#
        )
        // Chord symbols to strip: G  Am  F#m7  Dsus2  C/G
        let chordPattern = try? NSRegularExpression(
            pattern: #"\b[A-G][b#]?(?:maj|min|m|M|sus|add|dim|aug|\d)*(?:/[A-G][b#]?)?\b"#
        )

        var sections: [(label: String, firstWords: String?)] = []
        var currentLabel: String? = nil
        var currentFirstWords: String? = nil

        let lines = text.components(separatedBy: .newlines)
        for line in lines {
            let stripped = line.trimmingCharacters(in: .whitespaces)
            if stripped.isEmpty { continue }

            let range = NSRange(stripped.startIndex..., in: stripped)
            var matchedRaw: String? = nil

            if let m = headerPattern?.firstMatch(in: stripped, options: [], range: range),
               let labelRange = Range(m.range(at: 1), in: stripped) {
                matchedRaw = String(stripped[labelRange])
            } else if let m = mtPdfPattern?.firstMatch(in: stripped, options: [], range: range),
                      let labelRange = Range(m.range(at: 1), in: stripped) {
                matchedRaw = String(stripped[labelRange])
            }

            if let raw = matchedRaw {
                if let label = currentLabel {
                    sections.append((label: label, firstWords: currentFirstWords))
                }
                currentLabel = canonicalLabel(raw)
                currentFirstWords = nil
            } else if currentLabel != nil, currentFirstWords == nil {
                // Skip known PDF metadata/footer lines
                if let mp = metadataPattern,
                   mp.firstMatch(in: stripped, range: NSRange(stripped.startIndex..., in: stripped)) != nil {
                    continue
                }
                // First lyric line — strip chords
                var clean = stripped
                if let cp = chordPattern {
                    let ns = NSMutableString(string: clean)
                    cp.replaceMatches(in: ns, range: NSRange(location: 0, length: ns.length), withTemplate: "")
                    clean = ns as String
                }
                clean = clean
                    .replacingOccurrences(of: "|", with: " ")
                    .replacingOccurrences(of: "/", with: " ")
                    .components(separatedBy: .whitespaces)
                    .filter { !$0.isEmpty }
                    .joined(separator: " ")
                if clean.count > 2 {
                    currentFirstWords = clean
                }
            }
        }
        if let label = currentLabel {
            sections.append((label: label, firstWords: currentFirstWords))
        }
        return sections
    }

    private func canonicalLabel(_ raw: String) -> String {
        let upper = raw.trimmingCharacters(in: .whitespaces)
                       .uppercased()
                       .components(separatedBy: .whitespaces)
                       .filter { !$0.isEmpty }
                       .joined(separator: " ")
        // Normalize common variants
        let normalized = upper
            .replacingOccurrences(of: "PRE-CHORUS", with: "PRE CHORUS")
            .replacingOccurrences(of: "POST CHORUS", with: "POST-CHORUS")
            .replacingOccurrences(of: "COUNT-OFF",   with: "COUNT OFF")
        return normalized
    }
}
