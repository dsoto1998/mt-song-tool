import Foundation

/// Accepted locator labels — must be ALL CAPS, no leading/trailing spaces.
/// Empty string is also valid (blank locator).
enum LocatorValidator {
    private static let acceptedSections: Set<String> = [
        // Count / Intro / Outro
        "COUNT OFF",
        "INTRO",
        "OUTRO",
        "ENDING",

        // Verse
        "VERSE",
        "VERSE 1", "VERSE 2", "VERSE 3", "VERSE 4",
        "VERSE 5", "VERSE 6", "VERSE 7", "VERSE 8",

        // Chorus
        "CHORUS",
        "CHORUS 1", "CHORUS 2", "CHORUS 3", "CHORUS 4",
        "CHORUS 5", "CHORUS 6", "CHORUS 7", "CHORUS 8",

        // Pre Chorus
        "PRE CHORUS",
        "PRE CHORUS 1", "PRE CHORUS 2", "PRE CHORUS 3", "PRE CHORUS 4",

        // Post-Chorus
        "POST-CHORUS",
        "POST-CHORUS 1", "POST-CHORUS 2", "POST-CHORUS 3", "POST-CHORUS 4",

        // Bridge
        "BRIDGE",
        "BRIDGE 1", "BRIDGE 2", "BRIDGE 3", "BRIDGE 4",
        "BRIDGE 5", "BRIDGE 6", "BRIDGE 7", "BRIDGE 8",

        // Refrain
        "REFRAIN",
        "REFRAIN 1", "REFRAIN 2", "REFRAIN 3", "REFRAIN 4",

        // Tag
        "TAG",
        "TAG 1", "TAG 2", "TAG 3", "TAG 4",

        // Other sections
        "TURNAROUND",
        "INTERLUDE",
        "INSTRUMENTAL",
        "VAMP",
        "SOLO",
        "BREAKDOWN",
        "CHANNEL",
        "EXHORTATION",
        "RAP",
        "ACAPELLA",
        "PAD",
        "CLICK",

        // Short codes
        "V1", "VS", "V4", "VC", "VB", "VV", "VP",
        "E1", "E4",

        // Other
        "NEXT SONG",
    ]

    /// Short code section names — only shown in the picker when MT Complete mode is on.
    static let shortCodes: Set<String> = [
        "V1", "VS", "V4", "VC", "VB", "VV", "VP", "E1", "E4",
    ]

    /// Ordered list of all valid section names — grouped by song structure for the rename picker.
    static let sortedSections: [String] = [
        // Verse
        "VERSE", "VERSE 1", "VERSE 2", "VERSE 3", "VERSE 4",
        "VERSE 5", "VERSE 6", "VERSE 7", "VERSE 8",
        // Chorus
        "CHORUS", "CHORUS 1", "CHORUS 2", "CHORUS 3", "CHORUS 4",
        "CHORUS 5", "CHORUS 6", "CHORUS 7", "CHORUS 8",
        // Pre Chorus
        "PRE CHORUS", "PRE CHORUS 1", "PRE CHORUS 2", "PRE CHORUS 3", "PRE CHORUS 4",
        // Post-Chorus
        "POST-CHORUS", "POST-CHORUS 1", "POST-CHORUS 2", "POST-CHORUS 3", "POST-CHORUS 4",
        // Bridge
        "BRIDGE", "BRIDGE 1", "BRIDGE 2", "BRIDGE 3", "BRIDGE 4",
        "BRIDGE 5", "BRIDGE 6", "BRIDGE 7", "BRIDGE 8",
        // Refrain
        "REFRAIN", "REFRAIN 1", "REFRAIN 2", "REFRAIN 3", "REFRAIN 4",
        // Tag
        "TAG", "TAG 1", "TAG 2", "TAG 3", "TAG 4",
        // Count / Intro / Outro
        "COUNT OFF", "INTRO", "OUTRO", "ENDING",
        "TURNAROUND", "INTERLUDE", "INSTRUMENTAL", "VAMP",
        "SOLO", "BREAKDOWN", "CHANNEL", "EXHORTATION",
        "RAP", "ACAPELLA", "PAD", "CLICK",
        // Other
        "NEXT SONG",
        // Short Codes
        "V1", "VS", "V4", "VC", "VB", "VV", "VP",
        "E1", "E4",
    ]

    /// Returns true if the label is valid (ALL CAPS, no extra spaces, recognized section or empty).
    /// Short codes are only valid when `mtCompleteMode` is true.
    static func isValid(_ label: String, mtCompleteMode: Bool = false) -> Bool {
        // Empty / blank locator is invalid
        if label.isEmpty { return false }

        // Check for leading/trailing spaces
        if label != label.trimmingCharacters(in: .whitespaces) { return false }

        // Must be ALL CAPS
        if label != label.uppercased() { return false }

        // Short codes only accepted in MT Complete sessions
        if !mtCompleteMode && shortCodes.contains(label) { return false }

        // Must be a recognized section
        return acceptedSections.contains(label)
    }
}
