import Foundation

// MARK: - Approved values

enum SongDataOptions {
    static let songKeys: [String] = [
        "A", "Am", "Ab",
        "B", "Bm", "Bb", "Bbm",
        "C", "Cm", "C#m",
        "D", "Dm", "Db",
        "E", "Em", "Eb", "Ebm",
        "F", "Fm", "F#m",
        "G", "Gm", "Gb", "G#m",
    ]

    static let timeSignatures: [String] = [
        "2/4", "3/4", "4/4", "5/4", "6/4", "7/4", "9/4",
        "10/4", "11/4", "12/4", "13/4",
        "3/8", "6/8", "7/8", "9/8", "10/8", "11/8", "12/8", "13/8",
    ]
}

// MARK: - Timecode helpers

enum TimecodeHelper {
    /// Parse "MM:SS:mmm" timecode to total seconds (Double)
    static func toSeconds(_ timecode: String) -> Double? {
        let parts = timecode.split(separator: ":")
        guard parts.count == 3,
              let minutes = Double(parts[0]),
              let seconds = Double(parts[1]),
              let millis = Double(parts[2]) else { return nil }
        return minutes * 60.0 + seconds + millis / 1000.0
    }

    /// Find the first CHORUS marker that occurs after 01:00:000,
    /// subtract 10 seconds, and return as whole seconds (rounded down).
    /// Returns nil if no qualifying chorus is found.
    static func computePreviewStart(markers: [Marker]) -> Int? {
        let chorusLabels: Set<String> = [
            "CHORUS", "CHORUS 1", "CHORUS 2", "CHORUS 3", "CHORUS 4",
            "CHORUS 5", "CHORUS 6", "CHORUS 7", "CHORUS 8",
        ]

        for marker in markers {
            guard chorusLabels.contains(marker.text.trimmingCharacters(in: .whitespaces).uppercased()) else { continue }
            guard let secs = toSeconds(marker.time), secs >= 60.0 else { continue }
            let preview = secs - 10.0
            return Int(preview) // floor
        }
        return nil
    }
}
