import Foundation
import AppKit

@MainActor
final class ALSGeneratorService: ObservableObject {

    // MARK: - Types

    enum Phase: Equatable {
        case idle
        case building
        case done(String)   // output path
        case failed(String)

        var isActive: Bool {
            if case .building = self { return true }
            return false
        }
    }

    struct BuildLocator: Identifiable, Codable {
        let id: UUID
        var beat: Double
        var name: String

        init(beat: Double, name: String) {
            self.id = UUID()
            self.beat = beat
            self.name = name
        }

        // Preserve id across encode/decode round-trips
        enum CodingKeys: String, CodingKey { case id, beat, name }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
            beat = try c.decode(Double.self, forKey: .beat)
            name = try c.decode(String.self, forKey: .name)
        }
    }

    // MARK: - Published

    @Published var phase: Phase = .idle

    // MARK: - Public

    func build(
        outputPath: String,
        clips: [(name: String, filePath: String, durationSeconds: Double, volumeDB: Double)],
        bpm: Double,
        tempoEvents: [TempoEvent],
        timeSignatures: [TimeSig],
        locators: [BuildLocator],
        loopEndBeat: Double
    ) {
        phase = .building

        let clipDicts: [[String: Any]] = clips.map { c in
            ["name": c.name, "file_path": c.filePath,
             "duration_seconds": c.durationSeconds, "volume_db": c.volumeDB]
        }
        let tempoEventDicts: [[String: Any]] = tempoEvents.map {
            ["beat": $0.beat, "bpm": $0.bpm]
        }
        let tsDicts: [[String: Any]] = timeSignatures.compactMap { ts in
            guard let beat = ts.beat else { return nil }
            let parts = ts.sig.split(separator: "/")
            guard parts.count == 2, let num = Int(parts[0]), let den = Int(parts[1]) else { return nil }
            return ["beat": beat, "numerator": num, "denominator": den] as [String: Any]
        }
        let locatorDicts: [[String: Any]] = locators.map {
            ["beat": $0.beat, "name": $0.name]
        }

        let cmd: [String: Any] = [
            "action": "generate_als",
            "output_path": outputPath,
            "clips": clipDicts,
            "bpm": bpm,
            "tempo_events": tempoEventDicts,
            "time_signatures": tsDicts,
            "locators": locatorDicts,
            "loop_end_beat": loopEndBeat
        ]

        guard let cmdData = try? JSONSerialization.data(withJSONObject: cmd),
              let cmdStr = String(data: cmdData, encoding: .utf8) else {
            phase = .failed("Could not build command payload")
            return
        }

        Task {
            let output = await ParserService.runSend(command: cmdStr)
            guard let data = output.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                phase = .failed("Invalid response from parser")
                return
            }
            if let err = json["error"] as? String {
                phase = .failed(err)
            } else if let path = json["path"] as? String {
                phase = .done(path)
            } else {
                phase = .failed("No path in response")
            }
        }
    }

    func reset() { phase = .idle }
}

// MARK: - BuildSessionStore

@MainActor
final class BuildSessionStore: ObservableObject {
    @Published var bpm: String = ""
    @Published var timeSig: String = "4/4"
    @Published var locators: [ALSGeneratorService.BuildLocator] = []
    @Published var outputFolder: URL? = nil
    @Published var loopEndBeat: Double = 0
    @Published var savedURL: URL? = nil   // non-nil = has a saved file (Save vs Save As)

    /// Extra tempo events beyond beat 0 (build mode only). Beat-0 BPM comes from `bpm`.
    @Published var additionalTempoEvents: [TempoEvent] = []
    /// Bumped whenever additionalTempoEvents changes, for rebuildBeatSchedule onChange trigger.
    @Published var tempoEventsVersion: Int = 0

    var isDirty: Bool { !bpm.isEmpty || !locators.isEmpty || loopEndBeat > 0 || !additionalTempoEvents.isEmpty }

    func reset() {
        bpm = ""; timeSig = "4/4"; locators = []
        outputFolder = nil; loopEndBeat = 0; savedURL = nil
        additionalTempoEvents = []; tempoEventsVersion = 0
    }

    func addTempoEvent(_ event: TempoEvent) {
        additionalTempoEvents.append(event)
        additionalTempoEvents.sort { $0.beat < $1.beat }
        tempoEventsVersion += 1
    }

    func updateTempoEvent(at index: Int, to event: TempoEvent) {
        guard additionalTempoEvents.indices.contains(index) else { return }
        additionalTempoEvents[index] = event
        additionalTempoEvents.sort { $0.beat < $1.beat }
        tempoEventsVersion += 1
    }

    func removeTempoEvent(at index: Int) {
        guard additionalTempoEvents.indices.contains(index) else { return }
        additionalTempoEvents.remove(at: index)
        tempoEventsVersion += 1
    }

    private struct Snapshot: Codable {
        var bpm: String
        var timeSig: String
        var locators: [ALSGeneratorService.BuildLocator]
        var loopEndBeat: Double
        var additionalTempoEvents: [TempoEvent]
    }

    func save(to url: URL) throws {
        let snap = Snapshot(bpm: bpm, timeSig: timeSig, locators: locators,
                            loopEndBeat: loopEndBeat, additionalTempoEvents: additionalTempoEvents)
        let data = try JSONEncoder().encode(snap)
        try data.write(to: url)
        savedURL = url
    }

    func load(from url: URL) throws {
        let data = try Data(contentsOf: url)
        let snap = try JSONDecoder().decode(Snapshot.self, from: data)
        bpm = snap.bpm; timeSig = snap.timeSig; locators = snap.locators
        loopEndBeat = snap.loopEndBeat
        additionalTempoEvents = snap.additionalTempoEvents
        tempoEventsVersion += 1
        savedURL = url
    }
}
