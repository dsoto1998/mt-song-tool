import Foundation
import AVFoundation

// MARK: - Models

enum AudioFileStatus {
    case ok
    case silent
    case corrupted(String)

    var label: String {
        switch self {
        case .ok:           return "OK"
        case .silent:       return "Silent"
        case .corrupted:    return "Corrupted"
        }
    }
}

struct AudioFileResult: Identifiable {
    let id = UUID()
    let filename: String
    let status: AudioFileStatus
    let issues: [String]   // e.g. ["Unknown Stem", "48kHz", "24-bit"]
    var waveformPeaks: [Float]  // 500 normalized (0–1) amplitude samples; empty for corrupted/empty files
    var duration: Double        // seconds; 0 for corrupted/silent files

    init(filename: String, status: AudioFileStatus, issues: [String], waveformPeaks: [Float] = [], duration: Double = 0) {
        self.filename = filename
        self.status = status
        self.issues = issues
        self.waveformPeaks = waveformPeaks
        self.duration = duration
    }

    var isClean: Bool {
        if case .ok = status { return issues.isEmpty }
        return false
    }
}

// MARK: - Service

class AudioAnalyzerService: ObservableObject {
    @Published var results: [AudioFileResult] = []
    @Published var isScanning = false
    @Published var progress: (current: Int, total: Int) = (0, 0)
    @Published var folderName: String = ""
    @Published var errorMessage: String? = nil

    // Conversion state
    @Published var isConverting = false
    @Published var conversionProgress: (current: Int, total: Int) = (0, 0)
    @Published var conversionErrors: [String] = []
    private(set) var lastScannedFolder: URL? = nil

    /// Full URLs for all scanned stems (folder + filename). Empty if no folder loaded.
    var stemURLs: [URL] {
        guard let folder = lastScannedFolder else { return [] }
        return results.map { folder.appendingPathComponent($0.filename) }
    }

    // Expected stem duration sourced from the .als loop bracket (set by ContentView before calling analyze)
    var expectedDuration: Double? = nil

    // Approved stem names stored uppercased for case-insensitive lookup.
    // Source: PARTS Ardentra ROI Summary Report (March 2026)
    static let approvedStems: Set<String> = [

        // Required
        "CLICK TRACK", "GUIDE", "ORIGINAL SONG",

        // Guitars
        "GUITARS",
        "EG", "EG 1", "EG 2", "EG 3", "EG 4", "EG 5", "EG 6", "EG 7",
        "EG 8", "EG 9", "EG 10", "EG 11", "EG 12", "EG GROUP", "EG GROUP 1", "EG GROUP 2",
        "AG", "AG 1", "AG 2", "AG 3", "AG GROUP", "12 STRING", "12 STRING AG",
        "EBOW", "LAP STEEL", "LAP STEEL 1", "LAP STEEL 2", "SLIDE GUITAR", "TREMOLO",

        // Bass
        "BASS", "BASS 1", "BASS 2",
        "SYNTH BASS", "SYNTH BASS 1", "SYNTH BASS 2",

        // Keys / Synths
        "KEYS", "KEYS 1", "KEYS 2", "KEYS 3", "KEYS 4", "KEYS 5",
        "KEYS 6", "KEYS 7", "KEYS 8", "KEYS 9", "KEYS 10", "KEYS GROUP",
        "PIANO", "PIANO 1", "PIANO 2", "PIANO 3", "PIANO FX",
        "ELECTRIC PIANO", "RHODES", "WURLI", "CP 70", "CLAV", "MELLOTRON",
        "ORGAN", "ORGAN 1", "ORGAN 2",
        "ARPS", "ARPS 1", "ARPS 2", "BELLS", "DULCIMER", "DULCIMER 1", "DULCIMER 2",
        "SYNTH LEAD", "SYNTH PAD", "SYNTH STRINGS", "SYNTH BELLS", "SYNTH HORNS", "SYNTH GROUP",
        "THEREMIN", "VOCODER",

        // Drums / Percussion
        "DRUMS", "DRUMS (LIVE)", "DRUMS 1", "DRUMS 2",
        "AUX DRUMS", "AUX DRUMS (LIVE)",
        "PERC", "PERC 1", "PERC 2", "PERC 3", "PERC 4",
        "PERC (LIVE)", "PERC (LIVE) 1", "PERC (LIVE) 2",
        "TOMS", "SHAKER", "TAMBOURINE", "TAMBOURINE 1", "TAMBOURINE 2",
        "CLAPS", "SNAPS", "STOMPS", "BEATBOX",
        "CONGAS", "BONGO", "DJEMBE", "CAJON", "TIMBALES", "TIMPANI",
        "COWBELL", "CHIMES", "BAR CHIMES", "SLEIGH BELLS",
        "CRASH CYMBALS", "SUS CYMBALS", "BRUSHES", "STEEL DRUMS", "TURNTABLES",

        // Loops / FX
        "LOOP", "LOOP 1", "LOOP 2", "LOOP 3", "LOOP 4",
        "FX", "FX 1", "FX 2",
        "SYNTH LOOP", "SYNTH LOOP 1", "SYNTH LOOP 2", "SYNTH FX",

        // Vocals
        "VOCALS",
        "LEAD VOCAL", "LEAD VOCAL 1", "LEAD VOCAL 2", "LEAD VOCAL 3",
        "BGVS", "BGVS 1", "BGVS 2", "BGVS 3", "BGVS 4", "BGVS 5", "BGVS 6",
        "BGVS FX", "BGVS FX 1", "BGVS FX 2", "BGVS FX 3", "BGVS FX 4",
        "ALTO", "ALTO 1", "ALTO 2", "BARITONE",
        "SOPRANO", "SOPRANO 1", "SOPRANO 2",
        "TENOR", "TENOR 1", "TENOR 2", "TENOR 3",
        "CHOIR", "CHOIR 1", "CHOIR 2", "CHOIR 3",
        "OOHS", "OOHS 1", "OOHS 2", "OOHS 3",
        "KIDS", "SPOKEN WORD", "WHISTLE",
        "VOX CHOP", "VOX FX", "VOX LOOP",

        // Strings
        "STRINGS", "STRINGS 1", "STRINGS 2", "STRINGS 3", "STRINGS 4",
        "VIOLIN", "VIOLIN 1", "VIOLIN 2", "VIOLIN 3",
        "VIOLA", "VIOLA 1", "VIOLA 2", "VIOLA 3",
        "CELLO", "CELLO 1", "CELLO 2", "CELLO 3",
        "DOUBLE BASS", "DOUBLE BASS 1", "DOUBLE BASS 2", "DOUBLE BASS 3",
        "UPRIGHT BASS", "HARP", "VIBES", "MARIMBA", "GLOCKENSPIEL",

        // Brass / Winds
        "BRASS", "HORNS", "HORNS 1", "HORNS 2",
        "TRUMPET", "TRUMPET 1", "TRUMPET 2", "TRUMPET 3",
        "TROMBONE", "TROMBONE 1", "TROMBONE 2", "TROMBONE 3",
        "TUBA", "TUBA 1", "TUBA 2", "TUBA 3",
        "FRENCH HORN", "FRENCH HORN 1", "FRENCH HORN 2", "FRENCH HORN 3",
        "SAX", "SAX 1", "SAX 2", "SAX 3",
        "FLUTE", "FLUTE 1", "FLUTE 2", "FLUTE 3",
        "OBOE", "CLARINET", "CLARINET 1", "CLARINET 2", "CLARINET 3",
        "WOODWINDS", "ORCHESTRA",

        // World / Other
        "ACCORDION", "ACCORDION 1", "ACCORDION 2",
        "BAGPIPES", "BANJO", "BANJO 1", "BANJO 2",
        "BOUZOUKI", "BOUZOUKI 1", "BOUZOUKI 2",
        "CUATRO", "DAEGEUM", "DOBRO 1", "DOBRO 2", "DOBRO 3",
        "FIDDLE", "GAYAGEUM", "GUIRO",
        "GUZHENG", "GUZHENG 1", "GUZHENG 2",
        "HARMONICA", "HARMONIUM", "JANGGU", "LYRE",
        "MANDOLIN", "MANDOLIN 1", "MANDOLIN 2",
        "PIRI", "RUBAB", "SITAR",
        "UKULELE", "UKULELE 1", "UKULELE 2",

    ]

    func analyze(folder: URL) {
        isScanning = true
        results = []
        errorMessage = nil
        folderName = folder.lastPathComponent
        lastScannedFolder = folder

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }

            let wavFiles: [URL]
            do {
                wavFiles = try FileManager.default
                    .contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
                    .filter { $0.pathExtension.lowercased() == "wav" }
                    .sorted { $0.lastPathComponent < $1.lastPathComponent }
            } catch {
                DispatchQueue.main.async {
                    self.errorMessage = "Could not read folder"
                    self.isScanning = false
                }
                return
            }

            let total = wavFiles.count
            DispatchQueue.main.async { self.progress = (0, total) }

            let expectedDur = self.expectedDuration
            var results: [AudioFileResult] = []
            for (i, url) in wavFiles.enumerated() {
                DispatchQueue.main.async { self.progress = (i + 1, total) }
                results.append(Self.analyzeFile(url, approvedStems: Self.approvedStems, expectedDuration: expectedDur))
            }

            // Post-pass: flag stems that share the same name (case-insensitive, no extension)
            var nameBuckets: [String: [Int]] = [:]
            for (i, result) in results.enumerated() {
                let key = URL(fileURLWithPath: result.filename)
                    .deletingPathExtension().lastPathComponent.lowercased()
                nameBuckets[key, default: []].append(i)
            }
            let dupIndices = Set(nameBuckets.values.filter { $0.count > 1 }.flatMap { $0 })
            if !dupIndices.isEmpty {
                results = results.enumerated().map { i, r in
                    guard dupIndices.contains(i) else { return r }
                    return AudioFileResult(filename: r.filename, status: r.status, issues: r.issues + ["Duplicate"], waveformPeaks: r.waveformPeaks, duration: r.duration)
                }
            }

            DispatchQueue.main.async {
                self.results = results
                self.isScanning = false
            }
        }
    }

    func reset() {
        results = []
        folderName = ""
        errorMessage = nil
        progress = (0, 0)
        lastScannedFolder = nil
        isConverting = false
        conversionProgress = (0, 0)
        conversionErrors = []
        expectedDuration = nil
    }

    // MARK: Fix naming issues (Extra Space / Wrong Caps)

    /// Results that can be auto-fixed by renaming (Extra Space or Wrong Caps).
    var fixableResults: [AudioFileResult] {
        results.filter {
            $0.issues.contains("Extra Space") ||
            $0.issues.contains("Wrong Caps") ||
            $0.issues.contains("Special Chars")
        }
    }

    /// Renames files in-place to fix Extra Space and Wrong Caps issues, then re-scans.
    func fixNamingIssues() {
        guard let folder = lastScannedFolder else { return }
        let toFix = fixableResults   // capture before going async

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            var fixErrors: [String] = []

            for result in toFix {
                let url = URL(fileURLWithPath: result.filename)
                let stemName = url.deletingPathExtension().lastPathComponent

                // Apply fixes in order:
                // 1. Replace special characters with a space (keeps letters, digits, spaces, parens).
                //    Replacing rather than stripping means "EG-1" → "EG 1" (recognized)
                //    rather than "EG1" (unrecognized).
                // 2. Collapse runs of spaces, then trim
                // 3. Uppercase the entire name (stem names must be ALL CAPS)
                // 4. Only proceed if the result maps to a recognized approved stem —
                //    e.g. "BA$$" → "BA" is not approved, so skip and leave it flagged.
                let allowed = CharacterSet.letters.union(.decimalDigits).union(.init(charactersIn: " ()"))
                var fixed = String(stemName.unicodeScalars.map { allowed.contains($0) ? Character($0) : Character(" ") })
                // If parens are unbalanced after replacing invalid chars, strip all parens.
                // e.g. "EG 1(" → strip → "EG 1"; "DRUMS-(LIVE)" → balanced, keep → "DRUMS (LIVE)".
                var parenDepth = 0; var unbalanced = false
                for c in fixed {
                    if c == "(" { parenDepth += 1 }
                    else if c == ")" { parenDepth -= 1; if parenDepth < 0 { unbalanced = true; break } }
                }
                if unbalanced || parenDepth != 0 {
                    fixed = String(fixed.filter { $0 != "(" && $0 != ")" })
                }
                while fixed.contains("  ") { fixed = fixed.replacingOccurrences(of: "  ", with: " ") }
                fixed = fixed.trimmingCharacters(in: .whitespaces).uppercased()

                // Skip if the cleaned name isn't a recognized stem
                guard Self.approvedStems.contains(fixed.uppercased()) else { continue }

                let fixedFilename = fixed + ".wav"
                guard fixedFilename != result.filename else { continue }

                let source      = folder.appendingPathComponent(result.filename)
                let destination = folder.appendingPathComponent(fixedFilename)

                // On case-insensitive filesystems (macOS default), renaming to a different
                // casing of the same name looks like a collision. Detect this by comparing
                // lowercased paths — if they match, the source IS the destination (same inode),
                // so route through a UUID temp name to force the case change.
                let isCaseRename = source.path.lowercased() == destination.path.lowercased()

                if !isCaseRename && FileManager.default.fileExists(atPath: destination.path) {
                    fixErrors.append("\(result.filename) → '\(fixedFilename)' already exists")
                    continue
                }
                do {
                    if isCaseRename {
                        let tmp = folder.appendingPathComponent(UUID().uuidString + ".wav")
                        try FileManager.default.moveItem(at: source, to: tmp)
                        try FileManager.default.moveItem(at: tmp, to: destination)
                    } else {
                        try FileManager.default.moveItem(at: source, to: destination)
                    }
                } catch {
                    fixErrors.append("\(result.filename): \(error.localizedDescription)")
                }
            }

            if !fixErrors.isEmpty {
                DispatchQueue.main.async { self.errorMessage = fixErrors.joined(separator: "\n") }
            }

            // Re-scan so results reflect the new filenames
            self.analyze(folder: folder)
        }
    }

    // MARK: Single stem rename (triggered by inline edit in AudioFileRow)

    /// Renames a single stem file to `newStemName + ".wav"` in place, then re-scans the folder.
    /// `newStemName` must already be validated (ALL CAPS, in approvedStems) before calling.
    func renameStem(oldFilename: String, newStemName: String) {
        guard let folder = lastScannedFolder else { return }
        let newFilename = newStemName + ".wav"
        guard newFilename != oldFilename else { return }

        let source      = folder.appendingPathComponent(oldFilename)
        let destination = folder.appendingPathComponent(newFilename)

        // On case-insensitive filesystems a casing-only rename looks like a collision —
        // detect it and route through a UUID temp name to force the change.
        let isCaseRename = source.path.lowercased() == destination.path.lowercased()

        if !isCaseRename && FileManager.default.fileExists(atPath: destination.path) {
            self.errorMessage = "'\(newFilename)' already exists."
            return
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            do {
                if isCaseRename {
                    let tmp = folder.appendingPathComponent(UUID().uuidString + ".wav")
                    try FileManager.default.moveItem(at: source, to: tmp)
                    try FileManager.default.moveItem(at: tmp, to: destination)
                } else {
                    try FileManager.default.moveItem(at: source, to: destination)
                }
            } catch {
                DispatchQueue.main.async { self.errorMessage = error.localizedDescription }
                return
            }
            self.analyze(folder: folder)
        }
    }

    // MARK: Per-file analysis (runs on background thread)

    private static func analyzeFile(_ url: URL, approvedStems: Set<String>, expectedDuration: Double? = nil) -> AudioFileResult {
        let name = url.lastPathComponent
        // Stem name = filename without extension
        let stemName = url.deletingPathExtension().lastPathComponent

        var issues: [String] = []

        // --- Stem name validation ---
        if let nameIssue = validateStemName(stemName, approvedStems: approvedStems) {
            issues.append(nameIssue)
        }

        // --- Open file ---
        guard let file = try? AVAudioFile(forReading: url) else {
            return AudioFileResult(filename: name, status: .corrupted("Unreadable"), issues: issues)
        }

        // --- Format validation ---
        if let fmtIssue = checkFormat(file) {
            issues.append(fmtIssue)
        }

        // --- Duration check ---
        // Tolerance = 5 samples at the file's native sample rate.
        // Measurement against real Ableton WAV exports shows a consistent ~2.63-sample offset
        // between dawtool's beat→seconds calculation and the actual exported frame count.
        // 5 samples (~0.113ms at 44.1kHz) absorbs that offset with ~2 samples of headroom.
        let sampleRate = file.fileFormat.sampleRate
        let fileDuration = Double(file.length) / sampleRate
        if let expected = expectedDuration {
            let tolerance = 5.0 / sampleRate
            let diff = fileDuration - expected
            if diff > tolerance {
                issues.append("Too Long")
            } else if diff < -tolerance {
                issues.append("Too Short")
            }
        }

        // --- Empty file ---
        guard file.length > 0 else {
            return AudioFileResult(filename: name, status: .silent, issues: issues)
        }

        // --- Silence detection ---
        let format = file.processingFormat
        let chunkSize: AVAudioFrameCount = 8192
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkSize) else {
            return AudioFileResult(filename: name, status: .corrupted("Buffer error"), issues: issues)
        }

        let threshold: Float = 1e-4 // -80 dBFS — ~10% above 16-bit TPDF dither peak (~6e-5), below any audible content

        // Accumulate 500 peak buckets for waveform visualization while scanning for silence.
        // Reading the full file (no early exit) so every bucket gets populated.
        let totalFrames = file.length
        let targetPoints = 500
        var peaks = [Float](repeating: 0, count: targetPoints)
        var hasAudio = false
        let channelCount = Int(format.channelCount)

        while file.framePosition < file.length {
            let framePos = file.framePosition
            do { try file.read(into: buffer) } catch {
                return AudioFileResult(filename: name, status: .corrupted("Read error"), issues: issues)
            }
            guard let channelData = buffer.floatChannelData else { break }
            let frameCount = Int(buffer.frameLength)

            for f in 0..<frameCount {
                let bucket = min(
                    Int(Double(framePos + AVAudioFramePosition(f)) / Double(totalFrames) * Double(targetPoints)),
                    targetPoints - 1
                )
                var maxSample: Float = 0
                for ch in 0..<channelCount {
                    let s = abs(channelData[ch][f])
                    if s > maxSample { maxSample = s }
                }
                if maxSample > peaks[bucket] { peaks[bucket] = maxSample }
                if maxSample > threshold { hasAudio = true }
            }
        }

        // Normalize peaks to 0–1 range
        if let maxPeak = peaks.max(), maxPeak > 0 {
            peaks = peaks.map { $0 / maxPeak }
        }

        return AudioFileResult(
            filename: name,
            status: hasAudio ? .ok : .silent,
            issues: issues,
            waveformPeaks: peaks,
            duration: fileDuration
        )
    }

    // MARK: Stem name validation

    /// Returns an issue string if the stem name is invalid, nil if it's acceptable.
    private static func validateStemName(_ name: String, approvedStems: Set<String>) -> String? {
        // No leading/trailing spaces, and no internal runs of multiple spaces
        if name != name.trimmingCharacters(in: .whitespaces) || name.contains("  ") {
            return "Extra Space"
        }

        // Only letters, digits, spaces, and parentheses are valid in a stem name.
        // Parentheses are permitted because approved names like "DRUMS (LIVE)" use them,
        // but they must be balanced — a lone "(" or ")" is flagged as a special char.
        let allowed = CharacterSet.letters.union(.decimalDigits).union(.init(charactersIn: " ()"))
        if name.unicodeScalars.contains(where: { !allowed.contains($0) }) {
            return "Special Chars"
        }
        var depth = 0
        for c in name {
            if c == "(" { depth += 1 }
            else if c == ")" {
                depth -= 1
                if depth < 0 { return "Special Chars" }  // unmatched closing paren
            }
        }
        if depth != 0 { return "Special Chars" }  // unmatched opening paren

        // Check against approved list (case-insensitive)
        guard approvedStems.contains(name.uppercased()) else {
            return "Check Stem Name"
        }

        // Stem names must be ALL CAPS — every letter must be uppercase.
        if name != name.uppercased() {
            return "Wrong Caps"
        }

        return nil
    }

    // MARK: Format validation

    /// Returns a short issue label if the file is not 44.1kHz / 16-bit, nil otherwise.
    private static func checkFormat(_ file: AVAudioFile) -> String? {
        let fmt = file.fileFormat
        let sampleRate = fmt.sampleRate
        let bitDepth = fmt.settings[AVLinearPCMBitDepthKey] as? Int

        var problems: [String] = []
        if sampleRate != 44100 {
            let khz = sampleRate / 1000
            problems.append("\(Int(khz))kHz")
        }
        if let bd = bitDepth, bd != 16 {
            problems.append("\(bd)-bit")
        }

        return problems.isEmpty ? nil : problems.joined(separator: " ")
    }

    // MARK: - Audio Conversion

    /// Files from the last scan that have at least one format issue (sample rate or bit depth).
    var formatNonConformingFiles: [AudioFileResult] {
        results.filter { $0.issues.contains(where: Self.isFormatIssue) }
    }

    private static func isFormatIssue(_ issue: String) -> Bool {
        issue.hasSuffix("kHz") || issue.hasSuffix("-bit")
    }

    /// Finds the bundled FFmpeg binary inside the .app, falling back to the system PATH.
    static func ffmpegPath() -> String? {
        // Bundled copy: Contents/Frameworks/ffmpeg (placed there by make_swift_app.sh)
        let bundled = Bundle.main.bundleURL
            .appendingPathComponent("Contents")
            .appendingPathComponent("Frameworks")
            .appendingPathComponent("ffmpeg")
        if FileManager.default.isExecutableFile(atPath: bundled.path) {
            return bundled.path
        }
        // Fallback: system PATH (Homebrew install on dev machines)
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = ["which", "ffmpeg"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        try? proc.run()
        proc.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return out.isEmpty ? nil : out
    }

    /// Runs FFmpeg to convert a single file to 44.1 kHz / 16-bit WAV.
    /// Must be called off the main thread. Returns (success, errorMessage).
    private static func runFFmpegConvert(ffmpegPath: String, source: URL, destination: URL) -> (Bool, String) {
        try? FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: nil
        )
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: ffmpegPath)
        proc.arguments = [
            "-hide_banner", "-loglevel", "error", "-y",
            "-i", source.path,
            "-ar", "44100",
            "-c:a", "pcm_s16le",
            destination.path
        ]
        let errPipe = Pipe()
        proc.standardError = errPipe
        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {
            return (false, error.localizedDescription)
        }
        if proc.terminationStatus == 0 { return (true, "") }
        let data = errPipe.fileHandleForReading.readDataToEndOfFile()
        let msg = String(data: data, encoding: .utf8) ?? "Unknown FFmpeg error"
        return (false, msg.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Copies ALL stems to a sibling output folder named "<original>_44.1kHz_16bit",
    /// converting non-conforming files (sample rate / bit depth) via FFmpeg
    /// and straight-copying already-conforming files unchanged.
    /// Then rescans the complete output folder so Stem Check reflects the full set.
    func convertNonConforming() {
        guard let sourceFolder = lastScannedFolder else { return }
        guard let ffmpeg = Self.ffmpegPath() else {
            DispatchQueue.main.async {
                self.errorMessage = "FFmpeg not found. Re-run make_swift_app.sh to bundle it."
            }
            return
        }

        let allFiles = results
        guard !allFiles.isEmpty else { return }

        let parent = sourceFolder.deletingLastPathComponent()
        let originalName = sourceFolder.lastPathComponent
        // Temporary working folder — will be renamed to the original name after conversion
        let outputFolder = parent.appendingPathComponent(originalName + "_44.1kHz_16bit")
        // Final folder names after rename
        let doNotUseFolder = parent.appendingPathComponent(originalName + " - DO NOT USE")
        let finalFolder = sourceFolder  // output takes the original source name

        isConverting = true
        conversionProgress = (0, allFiles.count)
        conversionErrors = []

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }

            try? FileManager.default.createDirectory(
                at: outputFolder, withIntermediateDirectories: true, attributes: nil)

            var errors: [String] = []
            for (i, result) in allFiles.enumerated() {
                DispatchQueue.main.async {
                    self.conversionProgress = (i + 1, allFiles.count)
                }
                let source = sourceFolder.appendingPathComponent(result.filename)
                let destination = outputFolder.appendingPathComponent(result.filename)
                let needsConversion = result.issues.contains(where: Self.isFormatIssue)

                if needsConversion {
                    // Run FFmpeg to fix sample rate / bit depth
                    let (success, errMsg) = Self.runFFmpegConvert(
                        ffmpegPath: ffmpeg,
                        source: source,
                        destination: destination
                    )
                    if !success { errors.append(result.filename + ": " + errMsg) }
                } else {
                    // Already conforming — copy as-is so the output folder is complete
                    do {
                        if FileManager.default.fileExists(atPath: destination.path) {
                            try FileManager.default.removeItem(at: destination)
                        }
                        try FileManager.default.copyItem(at: source, to: destination)
                    } catch {
                        errors.append(result.filename + ": " + error.localizedDescription)
                    }
                }
            }

            // Rename folders:
            //   original  →  "[NAME] - DO NOT USE"
            //   output    →  "[NAME]"  (takes the original folder's name)
            var folderToScan = outputFolder
            do {
                try FileManager.default.moveItem(at: sourceFolder, to: doNotUseFolder)
                try FileManager.default.moveItem(at: outputFolder, to: finalFolder)
                folderToScan = finalFolder
            } catch {
                errors.append("Could not rename folders: " + error.localizedDescription)
            }

            DispatchQueue.main.async {
                self.isConverting = false
                self.conversionErrors = errors
            }

            // Rescan the final folder (now carries the original folder name)
            self.analyze(folder: folderToScan)
        }
    }

    // MARK: - Edit Bake-Out

    /// Applies nudge offsets, trims, cuts, and gain changes for each stem via FFmpeg,
    /// writes results to a sibling "[NAME] (Edited)" folder, renames the original to
    /// "[NAME] - DO NOT USE", and rescans the new folder.
    /// - Parameters:
    ///   - stemStates: the edit state map from EditPlayerService
    ///   - autoFadeCuts: whether to apply a 10ms fade-in after each cut point
    ///   - completion: called on main thread with optional error message
    func applyEdits(stemStates: [URL: StemState], autoFadeCuts: Bool, completion: @escaping (String?) -> Void) {
        guard let sourceFolder = lastScannedFolder else {
            completion("No stem folder loaded.")
            return
        }
        guard let ffmpeg = Self.ffmpegPath() else {
            completion("FFmpeg not found. Re-run make_swift_app.sh to bundle it.")
            return
        }

        let parent = sourceFolder.deletingLastPathComponent()
        let originalName = sourceFolder.lastPathComponent
        let workingFolder  = parent.appendingPathComponent(originalName + " (Edited)")
        let doNotUseFolder = parent.appendingPathComponent(originalName + " - DO NOT USE")
        let finalFolder    = sourceFolder  // edited output takes back the original name

        isConverting = true
        conversionProgress = (0, results.count)
        conversionErrors = []

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }

            try? FileManager.default.createDirectory(
                at: workingFolder, withIntermediateDirectories: true, attributes: nil)

            var errors: [String] = []

            for (i, result) in self.results.enumerated() {
                DispatchQueue.main.async { self.conversionProgress = (i + 1, self.results.count) }

                let source = sourceFolder.appendingPathComponent(result.filename)
                let dest   = workingFolder.appendingPathComponent(result.filename)
                let state  = stemStates[source] ?? StemState()

                let hasOffset  = state.offset != 0
                let hasTrim    = state.trimIn != 0 || state.trimOut != nil
                let hasCuts    = !state.cuts.isEmpty
                let hasGain    = state.gain != 1.0

                if !hasOffset && !hasTrim && !hasCuts && !hasGain {
                    // No edits — copy as-is
                    do {
                        if FileManager.default.fileExists(atPath: dest.path) {
                            try FileManager.default.removeItem(at: dest)
                        }
                        try FileManager.default.copyItem(at: source, to: dest)
                    } catch {
                        errors.append(result.filename + ": " + error.localizedDescription)
                    }
                    continue
                }

                // Build FFmpeg filter chain
                var filters: [String] = []

                if state.gain != 1.0 {
                    filters.append("volume=\(state.gain)")
                }

                var args: [String] = ["-hide_banner", "-loglevel", "error", "-y"]

                // Trim: -ss (start) / -to (end)
                let trimStart = state.trimIn > 0 ? state.trimIn : 0.0
                if trimStart > 0 { args += ["-ss", String(trimStart)] }
                args += ["-i", source.path]
                if let trimEnd = state.trimOut { args += ["-to", String(trimEnd)] }

                // Offset (positive = prepend silence via adelay)
                if state.offset > 0 {
                    let ms = Int(state.offset * 1000)
                    filters.append("adelay=\(ms)|\(ms)")
                }

                // Gain
                if state.gain != 1.0 {
                    filters.append("volume=\(state.gain)")
                }

                if !filters.isEmpty {
                    // Remove duplicated volume if added above
                    let uniqueFilters = Array(NSOrderedSet(array: filters)) as! [String]
                    args += ["-af", uniqueFilters.joined(separator: ",")]
                }

                if hasCuts {
                    // Split into segments at each cut point, applying fade-in to each segment
                    var cutPoints = state.cuts.sorted()
                    var segmentStart = trimStart
                    var segmentIndex = 0
                    var segmentURLs: [URL] = []

                    for cutPoint in cutPoints + [state.trimOut ?? Double.infinity] {
                        let baseName = URL(fileURLWithPath: result.filename).deletingPathExtension().lastPathComponent
                        let segDest = workingFolder.appendingPathComponent(
                            "\(baseName)_seg\(segmentIndex).wav"
                        )
                        var segArgs: [String] = ["-hide_banner", "-loglevel", "error", "-y",
                                                 "-ss", String(segmentStart), "-i", source.path]
                        if cutPoint != Double.infinity { segArgs += ["-to", String(cutPoint)] }

                        var segFilters: [String] = []
                        if autoFadeCuts && segmentIndex > 0 {
                            segFilters.append("afade=t=in:st=0:d=0.01")
                        }
                        if state.gain != 1.0 { segFilters.append("volume=\(state.gain)") }
                        if !segFilters.isEmpty { segArgs += ["-af", segFilters.joined(separator: ",")] }

                        segArgs.append(segDest.path)
                        _ = Self.runFFmpeg(ffmpegPath: ffmpeg, arguments: segArgs)
                        segmentURLs.append(segDest)
                        segmentStart = cutPoint
                        segmentIndex += 1
                    }

                    // If single segment, just rename to final dest
                    if segmentURLs.count == 1 {
                        try? FileManager.default.moveItem(at: segmentURLs[0], to: dest)
                    }
                    // Multiple segments are left as _seg0, _seg1 etc. in the output folder
                } else {
                    args.append(dest.path)
                    let (success, errMsg) = Self.runFFmpeg(ffmpegPath: ffmpeg, arguments: args)
                    if !success { errors.append(result.filename + ": " + errMsg) }
                }
            }

            // Rename folders
            var folderToScan = workingFolder
            do {
                try FileManager.default.moveItem(at: sourceFolder, to: doNotUseFolder)
                try FileManager.default.moveItem(at: workingFolder, to: finalFolder)
                folderToScan = finalFolder
            } catch {
                errors.append("Could not rename folders: " + error.localizedDescription)
            }

            DispatchQueue.main.async {
                self.isConverting = false
                self.conversionErrors = errors
                completion(errors.isEmpty ? nil : errors.joined(separator: "\n"))
            }

            self.analyze(folder: folderToScan)
        }
    }

    /// Run FFmpeg with arbitrary arguments. Returns (success, stderr).
    private static func runFFmpeg(ffmpegPath: String, arguments: [String]) -> (Bool, String) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: ffmpegPath)
        proc.arguments = arguments
        let errPipe = Pipe()
        proc.standardError = errPipe
        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {
            return (false, error.localizedDescription)
        }
        if proc.terminationStatus == 0 { return (true, "") }
        let data = errPipe.fileHandleForReading.readDataToEndOfFile()
        let msg = String(data: data, encoding: .utf8) ?? "Unknown FFmpeg error"
        return (false, msg.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
