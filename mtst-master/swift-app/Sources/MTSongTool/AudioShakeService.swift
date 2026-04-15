import Foundation
import AppKit

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

    // MARK: - Published

    @Published var phase: Phase = .idle
    @Published var results: [StemResult] = []

    // MARK: - Private

    private var runTask: Task<Void, Never>?
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
        results = []
        phase = .idle
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
            phase = .uploading
            log("Uploading asset: \(fileURL.lastPathComponent)")
            let assetId = try await uploadAsset(fileURL: fileURL, apiKey: apiKey)
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
                let dest = outputFolder.appendingPathComponent("\(target.model).wav")
                log("Downloading [\(i+1)/\(completed.count)] \(target.model) from \(dlURL.lastPathComponent)")
                try await downloadFile(from: dlURL, to: dest)
                log("  Saved → \(dest.path)")
                stemResults.append(StemResult(model: target.model, url: dest))
                phase = .downloading(i + 1, completed.count)
            }

            results = stemResults
            log("=== Run complete — \(stemResults.count)/\(models.count) stems saved ===")
            closeLogFile()
            phase = .done
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
}

private struct OutputFile: Decodable {
    let format: String
    let url: String
}
