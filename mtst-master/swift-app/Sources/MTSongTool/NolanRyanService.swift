import Foundation
import AppKit

/// Handles copying stem files to the Nolan Ryan SMB share.
/// The share is accessed as a mounted Finder volume at /Volumes/{volumeName}.
@MainActor
class NolanRyanService: ObservableObject {
    @Published var isCopying = false
    @Published var copyProgress: (Int, Int) = (0, 0)   // (copied, total)
    @Published var currentFileName: String = ""
    @Published var completedFiles: Set<String> = []
    @Published var lastError: String? = nil
    @Published var copyComplete = false
    @Published var isVerifying = false
    @Published var verificationPassed = false
    @Published var verificationFailed: [String] = []
    @Published var isFolderReady = false
    @Published var isWatchingForFolder = false

    /// True when the NR volume is mounted (case-insensitive match on volume name).
    /// Uses /Volumes directory listing rather than mountedVolumeURLs — the latter
    /// triggers the macOS network volume permission prompt on Ventura+.
    func isMounted(volumeName: String) -> Bool {
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: "/Volumes")) ?? []
        return entries.contains { $0.lowercased() == volumeName.lowercased() }
    }

    /// Returns the actual folder name on the volume whose name starts with `mtid`, or nil if not found.
    func actualFolderName(mtid: String, volumeName: String) -> String? {
        guard isMounted(volumeName: volumeName) else { return nil }
        let pitchingURL = URL(fileURLWithPath: "/Volumes/\(volumeName)", isDirectory: true)
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: pitchingURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        return entries.first { $0.lastPathComponent.hasPrefix(mtid) }?.lastPathComponent
    }

    /// True when a folder starting with `mtid` exists on the volume.
    func folderExists(mtid: String, volumeName: String) -> Bool {
        guard isMounted(volumeName: volumeName) else { return false }
        let pitchingURL = URL(fileURLWithPath: "/Volumes/\(volumeName)", isDirectory: true)
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: pitchingURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return entries.contains { $0.lastPathComponent.hasPrefix(mtid) }
    }

    /// Reset folder detection state (call when MTID changes or upload tab closes).
    func resetFolderWatch() {
        isFolderReady = false
        isWatchingForFolder = false
    }

    /// Open Finder's "Connect to Server" sheet for smb://nolanryan.
    /// "nolanryan" is the SMB server hostname — the share "Pitching" will appear
    /// in the volume picker. After mounting, isMounted() checks for the volume name.
    func openConnectSheet(volumeName: String) {
        if let url = URL(string: "smb://nolanryan") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Copy all .wav files from `stemsFolder` to /Volumes/{volumeName}/pitching/{mtid} - {songName}/.
    /// - Parameters:
    ///   - stemsFolder: URL of the folder containing the stem .wav files.
    ///   - mtid: The song MTID (used in destination folder name).
    ///   - songName: The song name (used in destination folder name).
    ///   - volumeName: The Finder volume name for the NR share (default: "nolanryan").
    func copyStems(
        from stemsFolder: URL,
        mtid: String,
        songName: String,
        volumeName: String
    ) async {
        copyComplete = false
        lastError = nil
        currentFileName = ""
        completedFiles = []
        isVerifying = false
        verificationPassed = false
        verificationFailed = []

        let fm = FileManager.default

        // Safety: verify mount
        guard isMounted(volumeName: volumeName) else {
            lastError = "Nolan Ryan is not mounted. Connect via Finder (⌘K → smb://\(volumeName)) then try again."
            return
        }

        // Find all .wav files in the stems folder
        let wavFiles: [URL]
        do {
            let contents = try fm.contentsOfDirectory(at: stemsFolder, includingPropertiesForKeys: nil)
            wavFiles = contents.filter { $0.pathExtension.lowercased() == "wav" }
        } catch {
            lastError = "Could not read stems folder: \(error.localizedDescription)"
            return
        }

        guard !wavFiles.isEmpty else {
            lastError = "No .wav files found in the stems folder."
            return
        }

        // BackOffice creates the song folder when "Upload Stems" is pressed there.
        // The Pitching share root IS the pitching directory — no subdirectory.
        // Find the folder whose name starts with the MTID (e.g. "12345 - Song Name").
        let pitchingURL = URL(fileURLWithPath: "/Volumes/\(volumeName)", isDirectory: true)
        let folderEntries = (try? fm.contentsOfDirectory(
            at: pitchingURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        let destination = folderEntries.first {
            $0.lastPathComponent.hasPrefix(mtid)
        }
        guard let destination else {
            lastError = "Folder for MTID \(mtid) not found on Nolan Ryan. Press 'Upload Stems' in BackOffice first, then try again."
            return
        }

        isCopying = true
        copyProgress = (0, wavFiles.count)

        for (index, sourceFile) in wavFiles.enumerated() {
            currentFileName = sourceFile.lastPathComponent
            let destFile = destination.appendingPathComponent(sourceFile.lastPathComponent)
            do {
                // Run blocking SMB I/O off the main thread
                try await Task.detached(priority: .userInitiated) {
                    if fm.fileExists(atPath: destFile.path) {
                        try fm.removeItem(at: destFile)
                    }
                    try fm.copyItem(at: sourceFile, to: destFile)
                }.value
            } catch {
                isCopying = false
                lastError = "Failed to copy \(sourceFile.lastPathComponent): \(error.localizedDescription)"
                return
            }
            completedFiles.insert(sourceFile.lastPathComponent)
            copyProgress = (index + 1, wavFiles.count)
        }

        isCopying = false
        currentFileName = ""
        await verifyStems(wavFiles: wavFiles, destination: destination)
        copyComplete = true
    }

    private func verifyStems(wavFiles: [URL], destination: URL) async {
        isVerifying = true
        let failed = await Task.detached(priority: .userInitiated) {
            var failed: [String] = []
            let fm = FileManager.default
            for file in wavFiles {
                let dest = destination.appendingPathComponent(file.lastPathComponent)
                let srcSize = (try? fm.attributesOfItem(atPath: file.path)[.size] as? Int) ?? -1
                let dstSize = (try? fm.attributesOfItem(atPath: dest.path)[.size] as? Int) ?? -2
                if srcSize != dstSize { failed.append(file.lastPathComponent) }
            }
            return failed
        }.value
        verificationFailed = failed
        verificationPassed = failed.isEmpty
        isVerifying = false
    }
}
