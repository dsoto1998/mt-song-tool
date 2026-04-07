import Foundation
import AVFoundation
import Accelerate

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

// MARK: - Suggestion types

struct StemSuggestion: Equatable {
    let name: String
    let confidence: Float  // 0.0–1.0
    var isTaken: Bool = false
}


struct AudioFileResult: Identifiable {
    let id = UUID()
    let filename: String
    let status: AudioFileStatus
    let issues: [String]   // e.g. ["Unknown Stem", "48kHz", "24-bit"]
    var waveformPeaks: [Float]  // 500 normalized (0–1) amplitude samples; empty for corrupted/empty files
    var duration: Double        // seconds; 0 for corrupted/silent files
    var suggestedNames: [StemSuggestion]     // populated when "Check Stem Name" present

    init(filename: String, status: AudioFileStatus, issues: [String],
         waveformPeaks: [Float] = [], duration: Double = 0,
         suggestedNames: [StemSuggestion] = []) {
        self.filename = filename
        self.status = status
        self.issues = issues
        self.waveformPeaks = waveformPeaks
        self.duration = duration
        self.suggestedNames = suggestedNames
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
            var slots: [AudioFileResult?] = Array(repeating: nil, count: total)
            let lock = NSLock()
            var completedCount = 0
            let concurrentQueue = DispatchQueue(label: "com.mtst.stemAnalysis", attributes: .concurrent)
            let group = DispatchGroup()

            for (i, url) in wavFiles.enumerated() {
                group.enter()
                concurrentQueue.async { [weak self] in
                    let result = Self.analyzeFile(url, approvedStems: Self.approvedStems, expectedDuration: expectedDur)
                    lock.lock()
                    slots[i] = result
                    completedCount += 1
                    let count = completedCount
                    lock.unlock()
                    DispatchQueue.main.async { self?.progress = (count, total) }
                    group.leave()
                }
            }
            group.wait()

            // Post-pass: flag stems that share the same name (case-insensitive, no extension)
            var results: [AudioFileResult] = slots.compactMap { $0 }
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
                    return AudioFileResult(filename: r.filename, status: r.status, issues: r.issues + ["Duplicate"],
                                          waveformPeaks: r.waveformPeaks, duration: r.duration,
                                          suggestedNames: r.suggestedNames)
                }
            }

            // Post-pass: flag numbered stems with gaps in their sequence (e.g. EG 1, EG 2, EG 4 → EG 3 missing)
            results = Self.flagSequenceGaps(in: results)

            // Post-pass: mark taken suggestions and append next available numbered variants
            results = Self.refineSuggestions(in: results)

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
        // Tolerance = 10 samples at the file's native sample rate (~0.227ms at 44.1kHz).
        let sampleRate = file.fileFormat.sampleRate
        let fileDuration = Double(file.length) / sampleRate
        if let expected = expectedDuration {
            let tolerance = 10.0 / sampleRate
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

        // Suggestions for invalid stem names.
        // Wrong Caps: direct 1.0-confidence suggestion of the uppercased form.
        // Extra Space / Special Chars: if normalizing produces a direct approved match, use it
        //   at 1.0 confidence instead of running the full similarity engine (which can surface
        //   unrelated stems via token overlap as fallbacks when the direct match is taken).
        // Check Stem Name: full similarity engine.
        var suggestedNames: [StemSuggestion] = []
        if issues.contains("Wrong Caps") {
            suggestedNames = [StemSuggestion(name: stemName.uppercased(), confidence: 1.0)]
        } else if issues.contains("Extra Space") || issues.contains("Special Chars") {
            let normalized = normalizeFilename(stemName)
            if approvedStems.contains(normalized) {
                suggestedNames = [StemSuggestion(name: normalized, confidence: 1.0)]
            } else {
                let containsLive = normalized.contains("LIVE")
                suggestedNames = stringSuggestions(normalizedFilename: normalized, containsLiveWord: containsLive)
                    .prefix(5).map { StemSuggestion(name: $0.0, confidence: $0.1) }
            }
        } else if issues.contains("Check Stem Name") {
            let normalized = normalizeFilename(stemName)
            let containsLive = normalized.contains("LIVE")
            suggestedNames = stringSuggestions(normalizedFilename: normalized, containsLiveWord: containsLive)
                .prefix(5).map { StemSuggestion(name: $0.0, confidence: $0.1) }
        }

        return AudioFileResult(
            filename: name,
            status: hasAudio ? .ok : .silent,
            issues: issues,
            waveformPeaks: peaks,
            duration: fileDuration,
            suggestedNames: suggestedNames
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

                let hasSegmentEdits = state.segments.count > 1 ||
                    (state.segments.first.map { $0.sessionStart != 0 } ?? false)
                let hasOffset  = state.offset != 0
                let hasTrim    = state.trimIn != 0 || state.trimOut != nil
                let hasCuts    = !state.cuts.isEmpty
                let hasGain    = state.gain != 1.0

                if hasSegmentEdits {
                    // Multi-segment bake-out: assemble pieces with silence gaps using FFmpeg filter_complex.
                    // Segments sorted by session start; gaps between them become silence.
                    let sorted = state.segments.sorted { $0.sessionStart < $1.sessionStart }
                    var filterParts: [String] = []
                    var concatInputs: [String] = []
                    var pieceIdx = 0

                    var cursor = 0.0
                    for seg in sorted {
                        let gapDur = seg.sessionStart - cursor
                        if gapDur > 0.001 {
                            filterParts.append("aevalsrc=0:d=\(String(format: "%.6f", gapDur))[g\(pieceIdx)]")
                            concatInputs.append("[g\(pieceIdx)]")
                            pieceIdx += 1
                        }
                        filterParts.append("[0:a]atrim=start=\(String(format: "%.6f", seg.sourceStart)):end=\(String(format: "%.6f", seg.sourceEnd)),asetpts=PTS-STARTPTS[s\(pieceIdx)]")
                        concatInputs.append("[s\(pieceIdx)]")
                        cursor = seg.sessionEnd
                        pieceIdx += 1
                    }

                    let n = concatInputs.count
                    let concatFilter = concatInputs.joined() + "concat=n=\(n):v=0:a=1[out]"
                    filterParts.append(concatFilter)
                    let filterComplex = filterParts.joined(separator: ";")

                    var args: [String] = ["-hide_banner", "-loglevel", "error", "-y",
                                          "-i", source.path,
                                          "-filter_complex", filterComplex,
                                          "-map", "[out]"]
                    if hasGain { args += ["-af", "volume=\(state.gain)"] }
                    args += ["-c:a", "pcm_s16le", "-ar", "44100", dest.path]
                    let (success, errMsg) = Self.runFFmpeg(ffmpegPath: ffmpeg, arguments: args)
                    if !success { errors.append(result.filename + ": " + errMsg) }
                } else if !hasOffset && !hasTrim && !hasCuts && !hasGain {
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
                } else {
                    // Legacy single-clip edits (offset / trim / cuts / gain)
                    var filters: [String] = []
                    var args: [String] = ["-hide_banner", "-loglevel", "error", "-y"]

                    let trimStart = state.trimIn > 0 ? state.trimIn : 0.0
                    if trimStart > 0 { args += ["-ss", String(trimStart)] }
                    args += ["-i", source.path]
                    if let trimEnd = state.trimOut { args += ["-to", String(trimEnd)] }

                    if state.offset > 0 {
                        let ms = Int(state.offset * 1000)
                        filters.append("adelay=\(ms)|\(ms)")
                    }
                    if state.gain != 1.0 { filters.append("volume=\(state.gain)") }

                    if !filters.isEmpty {
                        let uniqueFilters = Array(NSOrderedSet(array: filters)) as! [String]
                        args += ["-af", uniqueFilters.joined(separator: ",")]
                    }

                    if hasCuts {
                        var cutPoints = state.cuts.sorted()
                        var segmentStart = trimStart
                        var segmentIndex = 0
                        var segmentURLs: [URL] = []

                        for cutPoint in cutPoints + [state.trimOut ?? Double.infinity] {
                            let baseName = URL(fileURLWithPath: result.filename).deletingPathExtension().lastPathComponent
                            let segDest = workingFolder.appendingPathComponent("\(baseName)_seg\(segmentIndex).wav")
                            var segArgs: [String] = ["-hide_banner", "-loglevel", "error", "-y",
                                                     "-ss", String(segmentStart), "-i", source.path]
                            if cutPoint != Double.infinity { segArgs += ["-to", String(cutPoint)] }
                            var segFilters: [String] = []
                            if autoFadeCuts && segmentIndex > 0 { segFilters.append("afade=t=in:st=0:d=0.01") }
                            if state.gain != 1.0 { segFilters.append("volume=\(state.gain)") }
                            if !segFilters.isEmpty { segArgs += ["-af", segFilters.joined(separator: ",")] }
                            segArgs.append(segDest.path)
                            _ = Self.runFFmpeg(ffmpegPath: ffmpeg, arguments: segArgs)
                            segmentURLs.append(segDest)
                            segmentStart = cutPoint
                            segmentIndex += 1
                        }
                        if segmentURLs.count == 1 {
                            try? FileManager.default.moveItem(at: segmentURLs[0], to: dest)
                        }
                    } else {
                        args.append(dest.path)
                        let (success, errMsg) = Self.runFFmpeg(ffmpegPath: ffmpeg, arguments: args)
                        if !success { errors.append(result.filename + ": " + errMsg) }
                    }
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

    // MARK: - Stem Suggestion Engine

    // Long-form or common alternate phrasings → abbreviated canonical form.
    // Applied to the normalized filename before string matching so that e.g.
    // "ELECTRIC GUITAR 1" scores perfectly against "EG 1".
    private static let abbreviationExpansions: [(pattern: String, replacement: String)] = [
        ("ELECTRIC GUITAR",    "EG"),
        ("ACOUSTIC GUITAR",    "AG"),
        ("BACKGROUND VOCALS",  "BGVS"),
        ("BACKGROUND VOCAL",   "BGVS"),
        ("BACKING VOCALS",     "BGVS"),
        ("BACKING VOCAL",      "BGVS"),
        ("BACKUP VOCALS",      "BGVS"),
        ("BG VOCALS",          "BGVS"),
        ("BG VOCAL",           "BGVS"),
        ("BGV",                "BGVS"),
        ("LEAD VOX",           "LEAD VOCAL"),
        ("LEAD VX",            "LEAD VOCAL"),
        ("VOX",                "VOCALS"),
        ("BASS GUITAR",        "BASS"),
        ("UPRIGHT",            "UPRIGHT BASS"),
        ("DOUBLE BASS GTR",    "DOUBLE BASS"),
        ("KEYBOARDS",          "KEYS"),
        ("KEYBOARD",           "KEYS"),
        ("DRUM KIT",           "DRUMS"),
        ("DRUM SET",           "DRUMS"),
        ("PERCUSSION",         "PERC"),
        ("ELECTRIC GTR",       "EG"),
        ("ACOUSTIC GTR",       "AG"),
        ("ELEC GUITAR",        "EG"),
        ("ACOU GUITAR",        "AG"),
        ("ELEC GTR",           "EG"),
        ("E GTR",              "EG"),
        ("A GTR",              "AG"),
        ("ELECTRIC BASS",      "BASS"),
        ("ELEC BASS",          "BASS"),
        ("ELECTRIC",           "EG"),
        ("ACOUSTIC",           "AG"),
    ]

    // Patterns that expand to multiple candidate families.
    // e.g. "GTR 1" → suggestions for both "EG 1" and "AG 1".
    private static let multiExpansions: [(pattern: String, replacements: [String])] = [
        ("GTR", ["EG", "AG"]),
    ]

    private static func applyAbbreviations(_ normalized: String) -> String {
        var s = normalized
        for (pattern, replacement) in abbreviationExpansions {
            s = s.replacingOccurrences(of: pattern, with: replacement)
        }
        while s.contains("  ") { s = s.replacingOccurrences(of: "  ", with: " ") }
        return s.trimmingCharacters(in: .whitespaces)
    }

    /// Token-level fuzzy expansion for typos in instrument words.
    /// e.g. "ELECTR 1" → "EG 1", "ELECC 1" → "EG 1", "ACOUST 3" → "AG 3".
    /// Tries 2-token windows then 1-token windows (longest-match-first).
    /// Scores both full and prefix-truncated pattern, taking the min distance.
    /// Threshold: max(1, min(phrase, pattern) / 3) — based on shorter length.
    /// dist == 0 skipped (exact hits already handled by applyAbbreviations).
    private static func fuzzyApplyAbbreviations(_ normalized: String) -> String {
        let tokens = normalized.components(separatedBy: " ").filter { !$0.isEmpty }
        guard tokens.count >= 1 else { return normalized }

        for windowSize in stride(from: min(2, tokens.count), through: 1, by: -1) {
            let phrase = tokens[0..<windowSize].joined(separator: " ")
            let rest   = tokens[windowSize...].joined(separator: " ")
            let phraseChars = Array(phrase)

            var bestReplacement: String? = nil
            var bestDist = Int.max
            for (pattern, replacement) in abbreviationExpansions {
                let patChars = Array(pattern)
                let fullDist = levenshtein(phraseChars, patChars)
                let truncDist = phraseChars.count < patChars.count
                    ? levenshtein(phraseChars, Array(patChars.prefix(phraseChars.count)))
                    : fullDist
                let dist = min(fullDist, truncDist)
                let threshold = max(1, min(phraseChars.count, patChars.count) / 3)
                if dist > 0 && dist <= threshold && dist < bestDist {
                    bestDist = dist
                    bestReplacement = replacement
                }
            }

            if let rep = bestReplacement {
                let result = rest.isEmpty ? rep : "\(rep) \(rest)"
                return applyAbbreviations(result)
            }
        }
        return normalized
    }

    // MARK: Filename normalization

    private static func normalizeFilename(_ filename: String) -> String {
        var s = URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent
        s = s.uppercased()
        let separators = CharacterSet(charactersIn: "-_.")
        s = s.components(separatedBy: separators).joined(separator: " ")
        let allowed = CharacterSet.letters.union(.decimalDigits).union(.init(charactersIn: " ()"))
        s = String(s.unicodeScalars.map { allowed.contains($0) ? Character($0) : Character(" ") })
        while s.contains("  ") { s = s.replacingOccurrences(of: "  ", with: " ") }
        return s.trimmingCharacters(in: .whitespaces)
    }

    // MARK: String similarity

    private static func levenshtein(_ a: [Character], _ b: [Character]) -> Int {
        let n = a.count, m = b.count
        if n == 0 { return m }
        if m == 0 { return n }
        var prev = Array(0...m)
        var curr = [Int](repeating: 0, count: m + 1)
        for i in 1...n {
            curr[0] = i
            for j in 1...m {
                curr[j] = a[i-1] == b[j-1] ? prev[j-1] : min(prev[j-1]+1, prev[j]+1, curr[j-1]+1)
            }
            swap(&prev, &curr)
        }
        return prev[m]
    }

    /// Returns (stemName, score) pairs for all approved stems with score ≥ 0.25.
    /// Scores both the raw normalized filename and an abbreviation-expanded form,
    /// taking the max — so "ELECTRIC GUITAR 1" scores perfectly against "EG 1".
    /// (LIVE) variants excluded unless `containsLiveWord` is true.
    private static func stringSuggestions(normalizedFilename: String, containsLiveWord: Bool) -> [(String, Float)] {
        let expanded      = applyAbbreviations(normalizedFilename)
        let fuzzyExpanded = fuzzyApplyAbbreviations(normalizedFilename)
        var scored: [(String, Float)] = []

        for query in Set([normalizedFilename, expanded, fuzzyExpanded]) {
            let qChars  = Array(query)
            let qTokens = Set(query.components(separatedBy: " ").filter { !$0.isEmpty })

            for stem in approvedStems {
                let isLiveVariant = stem.contains("(LIVE)")
                if isLiveVariant && !containsLiveWord { continue }

                let stemChars = Array(stem)
                let maxLen = max(qChars.count, stemChars.count)
                guard maxLen > 0 else { continue }

                let dist = levenshtein(qChars, stemChars)
                let levScore = 1.0 - Float(dist) / Float(maxLen)

                let stemTokens = Set(stem.components(separatedBy: " "))
                let overlap = qTokens.intersection(stemTokens).count
                let tokenScore: Float = qTokens.isEmpty ? 0 : Float(overlap) / Float(max(qTokens.count, 1))
                let tokenBonus: Float = (!qTokens.isEmpty && qTokens.isSubset(of: stemTokens)) ? 0.3 : 0
                let prefixBonus: Float = stem.hasPrefix(query) && !query.isEmpty ? 0.2 : 0

                let score = min(max(levScore, tokenScore + tokenBonus) + prefixBonus, 1.0)
                if score >= 0.25 { scored.append((stem, score)) }
            }
        }

        // Multi-expansions: ambiguous abbreviations that map to multiple families.
        // e.g. "GTR 1" → score "EG 1" and "AG 1" as high-confidence candidates.
        let tokens = normalizedFilename.components(separatedBy: " ").filter { !$0.isEmpty }
        for (pattern, replacements) in multiExpansions {
            guard let idx = tokens.firstIndex(of: pattern) else { continue }
            let suffix = tokens[(idx + 1)...].joined(separator: " ")
            for rep in replacements {
                let candidate = suffix.isEmpty ? rep : "\(rep) \(suffix)"
                let isLiveVariant = candidate.contains("(LIVE)")
                if (!isLiveVariant || containsLiveWord) && approvedStems.contains(candidate) {
                    scored.append((candidate, 0.95))
                }
            }
        }

        // Deduplicate: keep highest score per stem
        var best: [String: Float] = [:]
        for (stem, score) in scored { best[stem] = max(best[stem] ?? 0, score) }
        return best.map { ($0.key, $0.value) }.sorted { $0.1 > $1.1 }
    }

    // MARK: - Post-scan: sequence gap detection

    /// Flags numbered stems whose base group has gaps (e.g. EG 1, EG 2, EG 4 → EG 3 missing).
    /// Only applies when a base has 2+ numbered stems and the numbers aren't 1…N consecutive.
    static func flagSequenceGaps(in results: [AudioFileResult]) -> [AudioFileResult] {
        // Build map: base name → [(index, number)]
        // Matches trailing integer: "EG 1" → ("EG", 1), "BGVS FX 3" → ("BGVS FX", 3)
        var groups: [String: [(index: Int, number: Int)]] = [:]
        for (i, result) in results.enumerated() {
            let stemName = URL(fileURLWithPath: result.filename)
                .deletingPathExtension().lastPathComponent.uppercased()
            // Only consider stems that are valid (approved) — skip unknowns/corrupted
            guard Self.approvedStems.contains(stemName) else { continue }
            // Split on last space to get base + trailing number
            if let spaceRange = stemName.range(of: " ", options: .backwards),
               let num = Int(stemName[stemName.index(after: spaceRange.lowerBound)...]) {
                let base = String(stemName[..<spaceRange.lowerBound])
                groups[base, default: []].append((index: i, number: num))
            }
        }

        // Find which indices need the gap issue
        var gapIndices = Set<Int>()
        for (_, entries) in groups where entries.count >= 2 {
            let nums = entries.map(\.number)
            let maxNum = nums.max()!
            let expected = Set(1...maxNum)
            if Set(nums) != expected {
                entries.forEach { gapIndices.insert($0.index) }
            }
        }

        guard !gapIndices.isEmpty else { return results }
        return results.enumerated().map { i, r in
            guard gapIndices.contains(i) else { return r }
            return AudioFileResult(filename: r.filename, status: r.status,
                                   issues: r.issues + ["Gap in Sequence"],
                                   waveformPeaks: r.waveformPeaks, duration: r.duration,
                                   suggestedNames: r.suggestedNames)
        }
    }

    // MARK: - Post-scan refinement

    /// Second pass over all results: marks suggestions whose name is already taken
    /// by a valid stem in the folder, and appends the next available numbered variant.
    static func refineSuggestions(in results: [AudioFileResult]) -> [AudioFileResult] {
        // A stem "takes" a name only when its filename IS already the correct name —
        // i.e. it has no naming issues. Files with Wrong Caps / Extra Space / Special Chars /
        // Check Stem Name are themselves candidates for rename and must not block their own
        // target name from appearing as an available suggestion.
        let namingIssues: Set<String> = ["Check Stem Name", "Wrong Caps", "Extra Space", "Special Chars"]
        var takenNames = Set<String>()
        for result in results {
            guard result.issues.allSatisfy({ !namingIssues.contains($0) }) else { continue }
            let name = URL(fileURLWithPath: result.filename)
                .deletingPathExtension().lastPathComponent.uppercased()
            takenNames.insert(name)
        }

        return results.map { result in
            guard !result.suggestedNames.isEmpty else { return result }

            var refined: [StemSuggestion] = []
            var addedVariants = Set<String>()

            for sug in result.suggestedNames {
                let taken = takenNames.contains(sug.name)
                refined.append(StemSuggestion(name: sug.name, confidence: sug.confidence, isTaken: taken))
                if taken, let next = nextAvailable(for: sug.name, taken: takenNames),
                   !addedVariants.contains(next) {
                    refined.append(StemSuggestion(name: next, confidence: sug.confidence * 0.9, isTaken: false))
                    addedVariants.insert(next)
                }
            }

            // Non-taken first (by confidence), then taken
            refined.sort {
                if $0.isTaken != $1.isTaken { return !$0.isTaken }
                return $0.confidence > $1.confidence
            }

            return AudioFileResult(filename: result.filename, status: result.status, issues: result.issues,
                                   waveformPeaks: result.waveformPeaks, duration: result.duration,
                                   suggestedNames: refined)
        }
    }

    /// Finds the lowest available numbered variant of a stem name not in `taken`.
    /// "EG 1" → tries "EG 2", "EG 3" … "EG" (no number) → tries "EG 1", "EG 2" …
    private static func nextAvailable(for name: String, taken: Set<String>) -> String? {
        let parts = name.components(separatedBy: " ")
        let base: String
        let startN: Int
        if let last = parts.last, let n = Int(last) {
            base   = parts.dropLast().joined(separator: " ")
            startN = n + 1
        } else {
            base   = name
            startN = 1
        }
        for n in startN...(startN + 15) {
            let candidate = "\(base) \(n)"
            if !taken.contains(candidate) && approvedStems.contains(candidate) { return candidate }
        }
        return nil
    }

}

