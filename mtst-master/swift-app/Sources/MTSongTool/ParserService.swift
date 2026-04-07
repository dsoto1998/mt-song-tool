import Foundation

struct TempoEvent {
    let beat: Double   // beat position in the session
    let bpm: Double    // tempo value at that beat
}

struct ParsedResult {
    var file: String
    var bpm: Double?
    var markers: [Marker]
    var timeSignatures: [TimeSig]
    var warnings: [String]
    var expectedDuration: Double?   // loop bracket length in seconds (nil if not computable)
    var firstTempoChangeMarkerIndex: Int?  // index of first marker at/after first tempo change; nil if no changes
    var liveMajorVersion: Int?      // e.g. 11 or 12; nil if not determinable
    var tempoEvents: [TempoEvent]   // beat→BPM automation events for metronome scheduling
}

struct Marker: Identifiable {
    let id = UUID()
    var time: String
    var timeEnd: String = ""
    var text: String
    var alsId: String = ""   // Ableton XML locator Id — used for write-back
    var offBeat: Bool = false  // true if locator does not land on beat 1 of a bar
}

struct TimeSig: Identifiable {
    let id = UUID()
    var time: String
    var sig: String
    var beat: Double?   // beat position from parser; used for metronome grid alignment
}

// MARK: - Persistent parser process (stays alive for instant parsing)

/// Manages a long-running Python parser process.
/// Launched once on app start with `--server` flag.
/// Swift sends file paths via stdin, reads JSON responses from stdout.
class ParserProcess {
    private var process: Process?
    private var stdinPipe: Pipe?
    private var stdoutPipe: Pipe?
    private var isReady = false
    private let lock = NSLock()

    /// Resolve the parser binary path
    private static func resolveParser() -> (executable: String, args: [String], env: [String: String]?) {
        // 1. Bundled binary in parse_als_dir next to main executable
        let execURL = URL(fileURLWithPath: ProcessInfo.processInfo.arguments[0])
        let macosDir = execURL.deletingLastPathComponent()
        let bundlePath = macosDir
            .appendingPathComponent("parse_als_dir")
            .appendingPathComponent("parse_als").path
        if FileManager.default.isExecutableFile(atPath: bundlePath) {
            return (executable: bundlePath, args: ["--server"], env: nil)
        }

        // 2. Dev fallback
        let root = "/Volumes/MTEng0/claude-apps/mt-song-tool/mtst-master"
        return (
            executable: "\(root)/venv/bin/python3",
            args: ["\(root)/parse_als.py", "--server"],
            env: ["DAWTOOL_PATH": root]
        )
    }

    /// Launch the parser process in server mode
    func start() {
        let resolved = Self.resolveParser()

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: resolved.executable)
        proc.arguments = resolved.args

        if let extraEnv = resolved.env {
            var env = ProcessInfo.processInfo.environment
            for (k, v) in extraEnv { env[k] = v }
            proc.environment = env
        }

        let inPipe = Pipe()
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardInput = inPipe
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        do {
            try proc.run()
        } catch {
            NSLog("[MTST] Failed to start parser: %@", error.localizedDescription)
            return
        }

        self.process = proc
        self.stdinPipe = inPipe
        self.stdoutPipe = outPipe

        // Wait for the "ready" signal from Python
        if let line = readLine(), line.contains("ready") {
            isReady = true
            NSLog("[MTST] Parser process ready (pid %d)", proc.processIdentifier)
        }
    }

    /// Send any single-line string and read back one line of JSON.
    /// This is the shared primitive used by both parse() and sendCommand().
    func send(_ line: String) -> String {
        lock.lock()
        defer { lock.unlock() }

        if !isReady || process?.isRunning != true {
            isReady = false
            start()
        }

        guard isReady, let inPipe = stdinPipe,
              let data = (line + "\n").data(using: .utf8) else {
            return "{\"error\": \"Parser not available\"}"
        }

        inPipe.fileHandleForWriting.write(data)
        return readLine() ?? "{\"error\": \"No response from parser\"}"
    }

    /// Send a file path and read back one line of JSON
    func parse(alsPath: String) -> String {
        send(alsPath)
    }

    /// Read a single line from stdout
    private func readLine() -> String? {
        guard let handle = stdoutPipe?.fileHandleForReading else { return nil }

        var buffer = Data()
        while true {
            let byte = handle.readData(ofLength: 1)
            if byte.isEmpty { return nil }  // EOF
            if byte[0] == UInt8(ascii: "\n") { break }
            buffer.append(byte)
        }
        return String(data: buffer, encoding: .utf8)
    }

    func stop() {
        stdinPipe?.fileHandleForWriting.closeFile()
        process?.terminate()
        process = nil
        isReady = false
    }
}

// MARK: - ParserService (SwiftUI-facing)

@MainActor
class ParserService: ObservableObject {
    @Published var result: ParsedResult? = nil
    @Published var errorMessage: String? = nil
    @Published var isLoading: Bool = false
    /// Path of the most-recently parsed .als — retained for locator write-back.
    private(set) var alsPath: String? = nil

    /// Shared persistent parser process
    private static let parserProcess = ParserProcess()

    /// Call once at app launch to pre-warm the parser
    static func warmUp() {
        DispatchQueue.global(qos: .userInitiated).async {
            parserProcess.start()
        }
    }

    func parse(alsPath: String) {
        self.alsPath = alsPath
        isLoading = true
        errorMessage = nil
        result = nil

        Task {
            let output = await Self.runParse(alsPath: alsPath)
            self.isLoading = false
            self.handle(output: output)
        }
    }

    private nonisolated static func runParse(alsPath: String) async -> String {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let result = parserProcess.parse(alsPath: alsPath)
                continuation.resume(returning: result)
            }
        }
    }

    // MARK: Locator write-back

    /// Rename one or more locators in the .als file, writing output to NEW_<name>.als.
    /// fixes: array of (alsId, newName) pairs — newName must pass LocatorValidator.isValid().
    /// Completion: (success, newPath, errorMessage)
    func fixLocators(fixes: [(alsId: String, newName: String)], completion: @escaping (Bool, String?, String?) -> Void) {
        guard let path = alsPath else { completion(false, nil, "No .als file loaded"); return }

        let fixDicts = fixes.map { ["als_id": $0.alsId, "new_name": $0.newName] }
        let cmdDict: [String: Any] = ["action": "fix_locators", "path": path, "fixes": fixDicts]
        guard let cmdData = try? JSONSerialization.data(withJSONObject: cmdDict),
              let cmdStr  = String(data: cmdData, encoding: .utf8) else {
            completion(false, nil, "Could not build command")
            return
        }

        Task {
            let output = await Self.runSend(command: cmdStr)
            guard let data = output.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                completion(false, nil, "Invalid response from parser")
                return
            }
            if let err = json["error"] as? String {
                completion(false, nil, err)
            } else {
                let newPath = json["new_path"] as? String
                completion(true, newPath, nil)
            }
        }
    }

    /// Convert a Live 12 .als to Live 11 format, writing <name>_Live11.als alongside it.
    /// Completion: (success, newPath, errorMessage)
    func downgradeToLive11(completion: @escaping (Bool, String?, String?) -> Void) {
        guard let path = alsPath else { completion(false, nil, "No .als file loaded"); return }

        let cmdDict: [String: Any] = ["action": "downgrade_to_live11", "path": path]
        guard let cmdData = try? JSONSerialization.data(withJSONObject: cmdDict),
              let cmdStr  = String(data: cmdData, encoding: .utf8) else {
            completion(false, nil, "Could not build command")
            return
        }

        Task {
            let output = await Self.runSend(command: cmdStr)
            guard let data = output.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                completion(false, nil, "Invalid response from parser")
                return
            }
            if let err = json["error"] as? String {
                completion(false, nil, err)
            } else {
                let newPath = json["new_path"] as? String
                completion(true, newPath, nil)
            }
        }
    }

    private nonisolated static func runSend(command: String) async -> String {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let result = parserProcess.send(command)
                continuation.resume(returning: result)
            }
        }
    }

    private func handle(output: String) {
        guard !output.isEmpty,
              let data = output.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            errorMessage = "Could not parse output from parser."
            return
        }

        if let err = json["error"] as? String, !err.isEmpty {
            errorMessage = err
            return
        }

        let fileName = json["file"] as? String ?? ""
        let bpm = json["bpm"] as? Double

        let markersRaw = json["markers"] as? [[String: Any]] ?? []
        let markers = markersRaw.map { Marker(time: $0["time"] as? String ?? "", timeEnd: $0["time_end"] as? String ?? "", text: $0["text"] as? String ?? "", alsId: $0["als_id"] as? String ?? "", offBeat: $0["off_beat"] as? Bool ?? false) }

        let tsRaw = json["time_signatures"] as? [[String: Any]] ?? []
        let timeSigs = tsRaw.map { TimeSig(time: $0["time"] as? String ?? "", sig: $0["sig"] as? String ?? "", beat: $0["beat"] as? Double) }

        let warnings = json["warnings"] as? [String] ?? []
        let expectedDuration = json["expected_duration"] as? Double
        let firstTempoChangeMarkerIndex = json["first_tempo_change_marker_index"] as? Int
        let liveMajorVersion = json["live_major_version"] as? Int

        let tempoEventsRaw = json["tempo_events"] as? [[Double]] ?? []
        let tempoEvents = tempoEventsRaw.compactMap { arr -> TempoEvent? in
            guard arr.count >= 2 else { return nil }
            return TempoEvent(beat: arr[0], bpm: arr[1])
        }

        Log("parsed '\(fileName)' — bpm=\(bpm.map { String($0) } ?? "nil") tempoEvents=\(tempoEvents.count) timeSigs=\(timeSigs.count) markers=\(markers.count) expectedDuration=\(expectedDuration.map { String(format: "%.2f", $0) } ?? "nil") liveMajorVersion=\(liveMajorVersion.map { String($0) } ?? "nil")", "Parser")
        if !tempoEvents.isEmpty {
            Log("tempoEvents: \(tempoEvents.prefix(5).map { "beat=\($0.beat) bpm=\($0.bpm)" }.joined(separator: ", "))\(tempoEvents.count > 5 ? " …+\(tempoEvents.count - 5) more" : "")", "Parser")
        }
        result = ParsedResult(file: fileName, bpm: bpm, markers: markers, timeSignatures: timeSigs, warnings: warnings, expectedDuration: expectedDuration, firstTempoChangeMarkerIndex: firstTempoChangeMarkerIndex, liveMajorVersion: liveMajorVersion, tempoEvents: tempoEvents)
    }
}
