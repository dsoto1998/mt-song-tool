import Foundation
import AppKit
import AVFoundation

@MainActor
final class AudioShakeService: ObservableObject {

    // MARK: - Types

    enum Phase: Equatable {
        case idle
        case uploading
        case processing(String)
        case downloading(Int, Int)   // completed, total
        case done
        case failed(String)

        var isActive: Bool {
            switch self { case .idle, .done, .failed: return false; default: return true }
        }

        var isFailed: Bool {
            if case .failed = self { return true }
            return false
        }

        var statusText: String {
            switch self {
            case .idle:                          return ""
            case .uploading:                     return "Uploading file…"
            case .processing(let msg):           return msg.isEmpty ? "Processing…" : msg
            case .downloading(let n, let total): return "Downloading \(n) / \(total)…"
            case .done:                          return "Done"
            case .failed(let msg):               return msg
            }
        }
    }

    struct StemResult: Identifiable {
        let id = UUID()
        let model: String
        let url: URL
        var waveformPeaks: [Float] = []
        var duration: Double = 0

        var displayName: String {
            AudioShakeService.allModels.first { $0.id == model }?.label ?? model
        }
    }

    struct ModelDef: Identifiable {
        let id: String
        let label: String
        let group: String
    }

    nonisolated static let allModels: [ModelDef] = [
        ModelDef(id: "vocals",          label: "Vocals",            group: "Vocals"),
        ModelDef(id: "vocals_lead",     label: "Lead Vocals",       group: "Vocals"),
        ModelDef(id: "vocals_backing",  label: "Backing Vocals",    group: "Vocals"),
        ModelDef(id: "instrumental",    label: "Instrumental",      group: "Vocals"),
        ModelDef(id: "drums",           label: "Drums",             group: "Core"),
        ModelDef(id: "bass",            label: "Bass",              group: "Core"),
        ModelDef(id: "guitar",          label: "Guitar",            group: "Guitar"),
        ModelDef(id: "guitar_electric", label: "Electric Guitar",   group: "Guitar"),
        ModelDef(id: "guitar_acoustic", label: "Acoustic Guitar",   group: "Guitar"),
        ModelDef(id: "piano",           label: "Piano",             group: "Keys"),
        ModelDef(id: "keys",            label: "Keys",              group: "Keys"),
        ModelDef(id: "strings",         label: "Strings",           group: "Other"),
        ModelDef(id: "wind",            label: "Wind",              group: "Other"),
        ModelDef(id: "other",           label: "Other",             group: "Other"),
        ModelDef(id: "other-x-guitar",  label: "Other −Guitar",     group: "Other"),
    ]

    nonisolated static let modelGroups = ["Vocals", "Core", "Guitar", "Keys", "Other"]

    /// Default stem selection — shown blue in the UI on launch and after Clear All.
    nonisolated static let defaultModels: Set<String> = [
        "vocals_lead", "vocals_backing",
        "drums", "bass",
        "guitar", "guitar_electric", "guitar_acoustic",
        "piano", "keys",
        "strings", "wind", "other-x-guitar"
    ]

    // MARK: - Published

    @Published var phase: Phase = .idle
    @Published var results: [StemResult] = []
    @Published var extractionPhase: Phase = .idle
    @Published var extractingURL: URL? = nil

    // MARK: - Private

    private var runTask: Task<Void, Never>?
    private var extractionTask: Task<Void, Never>?
    private let baseURL = "https://api.audioshake.ai"
    private let urlSession = URLSession.shared
    private var logHandle: FileHandle?
    private static let logDir = URL(fileURLWithPath: "/Volumes/MTEng0/claude-apps/mt-song-tool/logs")

    // MARK: - Public

    func run(fileURL: URL, models: [String], outputFolder: URL) {
        runTask?.cancel()
        results = []
        openLogFile()
        log("=== AudioShake run started ===")
        log("File: \(fileURL.path)")
        log("Models (\(models.count)): \(models.joined(separator: ", "))")
        log("Output folder: \(outputFolder.path)")
        runTask = Task { await _run(fileURL: fileURL, models: models, outputFolder: outputFolder) }
    }

    func cancel() {
        log("Run cancelled by user")
        closeLogFile()
        runTask?.cancel()
        runTask = nil
        phase = .idle
    }

    func reset() {
        cancel()
        extractionTask?.cancel()
        extractionTask = nil
        results = []
        phase = .idle
        extractionPhase = .idle
        extractingURL = nil
    }

    func runPianoExtraction(from url: URL, outputFolder: URL) {
        extractionTask?.cancel()
        extractingURL = url
        openLogFile()
        log("=== Piano extraction started from: \(url.lastPathComponent) ===")
        extractionTask = Task { await _runPianoExtraction(fileURL: url, outputFolder: outputFolder) }
    }

    // MARK: - Core

    private func _run(fileURL: URL, models: [String], outputFolder: URL) async {
        guard let apiKey = CredentialStore.load(key: CredentialStore.audioShakeAPIKeyKey), !apiKey.isEmpty else {
            log("ERROR: No API key configured")
            closeLogFile()
            phase = .failed("No API key — add one in Settings.")
            return
        }
        do {
            // Convert FLAC → WAV before upload (AudioShake does not support FLAC)
            var uploadURL = fileURL
            var tempWAV: URL? = nil
            if fileURL.pathExtension.lowercased() == "flac" {
                phase = .uploading
                log("Converting FLAC to WAV before upload…")
                let converted = await Task.detached(priority: .userInitiated) {
                    guard let ffmpeg = AudioAnalyzerService.ffmpegPath() else { return Optional<URL>.none }
                    return AudioShakeService.convertFlacToWav(url: fileURL, ffmpegPath: ffmpeg)
                }.value
                guard let wav = converted else {
                    log("ERROR: FLAC → WAV conversion failed")
                    closeLogFile()
                    phase = .failed("Could not convert FLAC to WAV before upload.")
                    return
                }
                log("FLAC converted → \(wav.lastPathComponent)")
                uploadURL = wav
                tempWAV = wav
            }
            defer { if let t = tempWAV { try? FileManager.default.removeItem(at: t) } }

            phase = .uploading
            log("Uploading asset: \(uploadURL.lastPathComponent)")
            let assetId = try await uploadAsset(fileURL: uploadURL, apiKey: apiKey)
            log("Asset uploaded — assetId: \(assetId)")
            try Task.checkCancellation()

            phase = .processing("Queuing…")
            log("Creating task for \(models.count) models")
            let taskId = try await createTask(assetId: assetId, models: models, apiKey: apiKey)
            log("Task created — taskId: \(taskId)")
            try Task.checkCancellation()

            log("Polling for completion…")
            let taskResponse = try await pollUntilDone(taskId: taskId, apiKey: apiKey)
            try Task.checkCancellation()

            let completed = taskResponse.targets.filter { $0.status == "completed" }
            let errored  = taskResponse.targets.filter { $0.status == "error" }
            log("Polling done — \(completed.count) completed, \(errored.count) errored")
            for t in errored { log("  ERROR target: \(t.model) status=\(t.status)") }

            var stemResults: [StemResult] = []
            var pcmErrors: [String] = []

            for (i, target) in completed.enumerated() {
                let wavOutput = target.outputs?.first(where: { $0.format == "wav" })
                let anyOutput = target.outputs?.first
                guard let output = wavOutput ?? anyOutput,
                      let dlURL = URL(string: output.url) else {
                    log("  SKIP \(target.model): no usable output URL (outputs=\(target.outputs?.count ?? 0))")
                    continue
                }
                try Task.checkCancellation()
                phase = .downloading(i, completed.count)
                let displayName = Self.allModels.first { $0.id == target.model }?.label ?? target.model
                let dest = outputFolder.appendingPathComponent("\(displayName).wav")
                log("Downloading [\(i+1)/\(completed.count)] \(target.model) → \(displayName).wav from \(dlURL.lastPathComponent)")
                try await downloadFile(from: dlURL, to: dest)
                log("  Saved → \(dest.path)")
                // Convert to 24-bit PCM so Ableton can import it (AudioShake outputs 32-bit float)
                let (pcmOK, pcmErr) = await Task.detached(priority: .userInitiated) {
                    guard let ffmpeg = AudioAnalyzerService.ffmpegPath() else {
                        return (false, "FFmpeg not found")
                    }
                    return AudioShakeService.convertToPCM24(url: dest, ffmpegPath: ffmpeg)
                }.value
                if !pcmOK {
                    log("  WARN: PCM conversion failed for \(dest.lastPathComponent): \(pcmErr)")
                    pcmErrors.append(dest.lastPathComponent)
                }
                let (peaks, dur) = await Task.detached(priority: .userInitiated) {
                    AudioShakeService.extractPeaks(url: dest)
                }.value
                stemResults.append(StemResult(model: target.model, url: dest,
                                              waveformPeaks: peaks, duration: dur))
                phase = .downloading(i + 1, completed.count)
            }

            results = stemResults
            log("=== Run complete — \(stemResults.count)/\(models.count) stems saved ===")
            closeLogFile()
            if pcmErrors.isEmpty {
                phase = .done
            } else {
                let names = pcmErrors.joined(separator: ", ")
                phase = .failed("Format conversion failed for \(names) — re-encode to 24-bit PCM before importing into Ableton.")
            }
        } catch is CancellationError {
            log("Run cancelled (CancellationError)")
            closeLogFile()
        } catch {
            log("ERROR: \(error.localizedDescription)")
            log("=== Run failed ===")
            closeLogFile()
            phase = .failed(error.localizedDescription)
        }
    }

    // MARK: - Piano extraction

    private func _runPianoExtraction(fileURL: URL, outputFolder: URL) async {
        guard let apiKey = CredentialStore.load(key: CredentialStore.audioShakeAPIKeyKey), !apiKey.isEmpty else {
            log("ERROR: No API key configured")
            closeLogFile()
            extractionPhase = .failed("No API key — add one in Settings.")
            extractingURL = nil
            return
        }
        do {
            extractionPhase = .uploading
            log("Uploading stem for re-separation: \(fileURL.lastPathComponent)")
            let assetId = try await uploadAsset(fileURL: fileURL, apiKey: apiKey)
            log("Asset uploaded — assetId: \(assetId)")
            try Task.checkCancellation()

            extractionPhase = .processing("Queuing…")
            let taskId = try await createResidualTask(assetId: assetId, apiKey: apiKey)
            log("Residual task created — taskId: \(taskId)")
            try Task.checkCancellation()

            log("Polling for completion…")
            let taskResponse = try await pollUntilDone(taskId: taskId, apiKey: apiKey)
            try Task.checkCancellation()

            guard let pianoTarget = taskResponse.targets.first(where: { $0.model == "piano" && $0.status == "completed" }),
                  let outputs = pianoTarget.outputs, !outputs.isEmpty else {
                throw NSError(domain: "AudioShake", code: 0,
                              userInfo: [NSLocalizedDescriptionKey: "No completed piano output in response"])
            }

            var newResults: [StemResult] = []
            var pcmErrors: [String] = []

            // Output 0 → isolated piano from the re-uploaded stem
            if let dlURL = URL(string: outputs[0].url) {
                extractionPhase = .downloading(0, outputs.count)
                let dest = outputFolder.appendingPathComponent("Piano (from Other-Guitar).wav")
                log("Downloading piano stem → \(dest.lastPathComponent)")
                try await downloadFile(from: dlURL, to: dest)
                let (pcmOK, pcmErr) = await Task.detached(priority: .userInitiated) {
                    guard let ffmpeg = AudioAnalyzerService.ffmpegPath() else { return (false, "FFmpeg not found") }
                    return AudioShakeService.convertToPCM24(url: dest, ffmpegPath: ffmpeg)
                }.value
                if !pcmOK {
                    log("  WARN: PCM conversion failed for \(dest.lastPathComponent): \(pcmErr)")
                    pcmErrors.append(dest.lastPathComponent)
                }
                let (peaks, dur) = await Task.detached(priority: .userInitiated) {
                    AudioShakeService.extractPeaks(url: dest)
                }.value
                newResults.append(StemResult(model: "Piano (from Other-Guitar)", url: dest,
                                             waveformPeaks: peaks, duration: dur))
                extractionPhase = .downloading(1, outputs.count)
            }

            // Output 1 (residual) → other-x-guitar minus piano
            if outputs.count > 1, let dlURL = URL(string: outputs[1].url) {
                extractionPhase = .downloading(1, outputs.count)
                let dest = outputFolder.appendingPathComponent("Other-Guitar (no Piano).wav")
                log("Downloading residual stem → \(dest.lastPathComponent)")
                try await downloadFile(from: dlURL, to: dest)
                let (pcmOK, pcmErr) = await Task.detached(priority: .userInitiated) {
                    guard let ffmpeg = AudioAnalyzerService.ffmpegPath() else { return (false, "FFmpeg not found") }
                    return AudioShakeService.convertToPCM24(url: dest, ffmpegPath: ffmpeg)
                }.value
                if !pcmOK {
                    log("  WARN: PCM conversion failed for \(dest.lastPathComponent): \(pcmErr)")
                    pcmErrors.append(dest.lastPathComponent)
                }
                let (peaks, dur) = await Task.detached(priority: .userInitiated) {
                    AudioShakeService.extractPeaks(url: dest)
                }.value
                newResults.append(StemResult(model: "Other-Guitar (no Piano)", url: dest,
                                             waveformPeaks: peaks, duration: dur))
                extractionPhase = .downloading(2, outputs.count)
            } else {
                log("NOTE: Only one output received — residual may not be in output[1]. Check raw log above.")
            }

            results.append(contentsOf: newResults)
            log("=== Piano extraction complete — \(newResults.count) stem(s) added ===")
            closeLogFile()
            if pcmErrors.isEmpty {
                extractionPhase = .done
            } else {
                let names = pcmErrors.joined(separator: ", ")
                extractionPhase = .failed("Format conversion failed for \(names) — re-encode to 24-bit PCM before importing into Ableton.")
            }
            extractingURL = nil
        } catch is CancellationError {
            log("Extraction cancelled (CancellationError)")
            closeLogFile()
            extractingURL = nil
        } catch {
            log("ERROR: \(error.localizedDescription)")
            log("=== Piano extraction failed ===")
            closeLogFile()
            extractionPhase = .failed(error.localizedDescription)
            extractingURL = nil
        }
    }

    private func createResidualTask(assetId: String, apiKey: String) async throws -> String {
        let url = URL(string: "\(baseURL)/tasks")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let targets: [[String: Any]] = [["model": "piano", "formats": ["wav"], "residual": true]]
        req.httpBody = try JSONSerialization.data(withJSONObject: ["assetId": assetId, "targets": targets])

        let (data, response) = try await urlSession.data(for: req)
        try checkHTTP(response, data)
        return try JSONDecoder().decode(TaskCreatedResponse.self, from: data).id
    }

    // MARK: - API calls

    private func uploadAsset(fileURL: URL, apiKey: String) async throws -> String {
        let url = URL(string: "\(baseURL)/assets")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")

        let boundary = "Boundary-\(UUID().uuidString)"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.httpBody = try buildMultipartBody(boundary: boundary, fileURL: fileURL)

        let (data, response) = try await urlSession.data(for: req)
        try checkHTTP(response, data)
        return try JSONDecoder().decode(AssetUploadResponse.self, from: data).id
    }

    private func createTask(assetId: String, models: [String], apiKey: String) async throws -> String {
        let url = URL(string: "\(baseURL)/tasks")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let targets = models.map { ["model": $0, "formats": ["wav"]] }
        req.httpBody = try JSONSerialization.data(withJSONObject: ["assetId": assetId, "targets": targets])

        let (data, response) = try await urlSession.data(for: req)
        try checkHTTP(response, data)
        return try JSONDecoder().decode(TaskCreatedResponse.self, from: data).id
    }

    private func pollUntilDone(taskId: String, apiKey: String) async throws -> TaskStatusResponse {
        let url = URL(string: "\(baseURL)/tasks/\(taskId)")!
        var req = URLRequest(url: url)
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")

        while true {
            try Task.checkCancellation()
            let (data, response) = try await urlSession.data(for: req)
            try checkHTTP(response, data)
            let task = try JSONDecoder().decode(TaskStatusResponse.self, from: data)
            let allSettled = task.targets.allSatisfy { $0.status == "completed" || $0.status == "error" }
            if allSettled {
                // Log raw JSON once so we can inspect the actual output structure
                if let pretty = try? JSONSerialization.jsonObject(with: data),
                   let prettyData = try? JSONSerialization.data(withJSONObject: pretty, options: .prettyPrinted),
                   let prettyStr = String(data: prettyData, encoding: .utf8) {
                    log("Raw task response:\n\(prettyStr)")
                }
                return task
            }
            let done = task.targets.filter { $0.status == "completed" }.count
            let errs = task.targets.filter { $0.status == "error" }.count
            log("Poll: \(done)/\(task.targets.count) ready\(errs > 0 ? ", \(errs) error(s)" : "")")
            phase = .processing("\(done) / \(task.targets.count) stems ready")
            try await Task.sleep(nanoseconds: 3_000_000_000)
        }
    }

    private func downloadFile(from src: URL, to dest: URL) async throws {
        let (tmp, _) = try await urlSession.download(from: src)
        let fm = FileManager.default
        if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
        try fm.moveItem(at: tmp, to: dest)
    }

    /// Extracts 500 normalized (0–1) amplitude peaks and duration from an audio file.
    /// Runs off the main thread — call via Task.detached.
    nonisolated static func extractPeaks(url: URL) -> ([Float], Double) {
        guard let file = try? AVAudioFile(forReading: url) else { return ([], 0) }
        let format = file.processingFormat
        let duration = Double(file.length) / format.sampleRate
        let targetPoints = 500
        var peaks = [Float](repeating: 0, count: targetPoints)
        let chunkSize: AVAudioFrameCount = 8192
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkSize) else {
            return ([], duration)
        }
        let totalFrames = file.length
        let channelCount = Int(format.channelCount)
        while file.framePosition < file.length {
            let framePos = file.framePosition
            guard (try? file.read(into: buffer)) != nil else { break }
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
            }
        }
        if let maxPeak = peaks.max(), maxPeak > 0 {
            peaks = peaks.map { $0 / maxPeak }
        }
        return (peaks, duration)
    }

    /// Converts a FLAC file to a temporary WAV in the system temp directory.
    /// Returns the temp WAV URL on success, or nil on failure.
    /// Caller is responsible for deleting the temp file when done.
    nonisolated private static func convertFlacToWav(url: URL, ffmpegPath: String) -> URL? {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(url.deletingPathExtension().lastPathComponent + "_audioshake.wav")
        try? FileManager.default.removeItem(at: tmp)
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: ffmpegPath)
        proc.arguments = ["-hide_banner", "-loglevel", "error", "-y", "-i", url.path, tmp.path]
        do { try proc.run(); proc.waitUntilExit() } catch { return nil }
        return proc.terminationStatus == 0 ? tmp : nil
    }

    /// Converts a WAV file to 24-bit integer PCM in-place using FFmpeg.
    /// Preserves original sample rate. On success, replaces the file at `url`.
    /// On failure, leaves the original file intact and returns an error message.
    nonisolated private static func convertToPCM24(url: URL, ffmpegPath: String) -> (Bool, String) {
        let tmp = url.deletingPathExtension().appendingPathExtension("_pcm24tmp.wav")
        try? FileManager.default.removeItem(at: tmp)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: ffmpegPath)
        proc.arguments = [
            "-hide_banner", "-loglevel", "error", "-y",
            "-i", url.path,
            "-c:a", "pcm_s24le",
            tmp.path
        ]
        let errPipe = Pipe()
        proc.standardError = errPipe
        do { try proc.run(); proc.waitUntilExit() } catch {
            try? FileManager.default.removeItem(at: tmp)
            return (false, error.localizedDescription)
        }
        guard proc.terminationStatus == 0 else {
            let msg = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
                ?? "Unknown FFmpeg error"
            try? FileManager.default.removeItem(at: tmp)
            return (false, msg.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        do {
            try FileManager.default.removeItem(at: url)
            try FileManager.default.moveItem(at: tmp, to: url)
            return (true, "")
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            return (false, error.localizedDescription)
        }
    }

    private func checkHTTP(_ response: URLResponse, _ data: Data) throws {
        guard let http = response as? HTTPURLResponse, http.statusCode >= 400 else { return }
        let body = String(data: data, encoding: .utf8) ?? ""
        throw NSError(domain: "AudioShake", code: http.statusCode,
                      userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode): \(body)"])
    }

    private func buildMultipartBody(boundary: String, fileURL: URL) throws -> Data {
        var body = Data()
        func a(_ s: String) { if let d = s.data(using: .utf8) { body.append(d) } }
        let ext  = fileURL.pathExtension.lowercased()
        let mime: String
        switch ext {
        case "mp3":         mime = "audio/mpeg"
        case "m4a", "aac":  mime = "audio/mp4"
        case "aiff", "aif": mime = "audio/aiff"
        default:            mime = "audio/wav"
        }
        a("--\(boundary)\r\n")
        a("Content-Disposition: form-data; name=\"file\"; filename=\"\(fileURL.lastPathComponent)\"\r\n")
        a("Content-Type: \(mime)\r\n\r\n")
        body.append(try Data(contentsOf: fileURL))
        a("\r\n--\(boundary)--\r\n")
        return body
    }

    // MARK: - Logging

    private func openLogFile() {
        closeLogFile()
        let fm = FileManager.default
        try? fm.createDirectory(at: Self.logDir, withIntermediateDirectories: true)
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd_HHmmss"
        let name = "audioshake_\(fmt.string(from: Date())).log"
        let path = Self.logDir.appendingPathComponent(name).path
        fm.createFile(atPath: path, contents: nil)
        logHandle = FileHandle(forWritingAtPath: path)
    }

    private func closeLogFile() {
        try? logHandle?.close()
        logHandle = nil
    }

    private func log(_ message: String) {
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm:ss.SSS"
        let line = "[\(fmt.string(from: Date()))] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        try? logHandle?.write(contentsOf: data)
    }
}

// MARK: - Decodable response types

private struct AssetUploadResponse: Decodable { let id: String }
private struct TaskCreatedResponse:  Decodable { let id: String }

private struct TaskStatusResponse: Decodable {
    let id: String
    let targets: [TargetStatus]
}

private struct TargetStatus: Decodable {
    let model: String
    let status: String
    let outputs: [OutputFile]?

    enum CodingKeys: String, CodingKey {
        case model, status
        case outputs = "output"
    }
}

private struct OutputFile: Decodable {
    let format: String
    let url: String

    enum CodingKeys: String, CodingKey {
        case format
        case url = "link"
    }
}
