import Foundation

// MARK: - AppLogger

/// Writes timestamped log lines to /Volumes/MTEng0/claude-apps/mt-song-tool/logs/mtst-YYYY-MM-DD.log
/// Also mirrors output to NSLog for Xcode console visibility.
final class AppLogger {
    static let shared = AppLogger()

    private let logDir = URL(fileURLWithPath: "/Volumes/MTEng0/claude-apps/mt-song-tool/logs")
    private let queue = DispatchQueue(label: "com.multitracks.mtst.logger", qos: .utility)
    private var fileHandle: FileHandle?

    private let tsFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    private init() {
        let dayFormatter = DateFormatter()
        dayFormatter.dateFormat = "yyyy-MM-dd"
        let filename = "mtst-\(dayFormatter.string(from: Date())).log"
        let logFile = logDir.appendingPathComponent(filename)

        try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: logFile.path) {
            FileManager.default.createFile(atPath: logFile.path, contents: nil)
        }
        fileHandle = try? FileHandle(forWritingTo: logFile)
        fileHandle?.seekToEndOfFile()

        // Session start marker
        let header = "\n──────────────────────────────────────────────────\n" +
                     "Session started \(dayFormatter.string(from: Date())) \(tsFormatter.string(from: Date()))\n" +
                     "──────────────────────────────────────────────────\n"
        if let data = header.data(using: .utf8) {
            fileHandle?.write(data)
        }
    }

    func log(_ message: String, _ component: String) {
        let ts = tsFormatter.string(from: Date())
        let line = "[\(ts)] [\(component)] \(message)\n"
        NSLog("[MTST] [\(component)] %@", message)
        queue.async { [weak self] in
            guard let self, let data = line.data(using: .utf8) else { return }
            self.fileHandle?.write(data)
        }
    }
}

/// Global shorthand — call as: Log("message", "Component")
func Log(_ message: String, _ component: String = "App") {
    AppLogger.shared.log(message, component)
}
