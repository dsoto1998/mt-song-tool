import Foundation

// MARK: - Model

enum QueueStatus: String, Codable {
    case pending, processing, success, failed
}

struct QueueItem: Codable, Identifiable {
    let id: UUID
    let mtid: String
    let songName: String
    let stemsFolderPath: String
    let alsName: String
    let nrFolderName: String?
    let addedAt: Date
    var status: QueueStatus
    var errorMessage: String?

    init(mtid: String, songName: String, stemsFolderPath: String, alsName: String, nrFolderName: String?) {
        self.id = UUID()
        self.mtid = mtid
        self.songName = songName
        self.stemsFolderPath = stemsFolderPath
        self.alsName = alsName
        self.nrFolderName = nrFolderName
        self.addedAt = Date()
        self.status = .pending
        self.errorMessage = nil
    }
}

// MARK: - Service

@MainActor
final class QueueService: ObservableObject {
    @Published var items: [QueueItem] = []
    @Published var isProcessing = false
    @Published var activeNRServices: [UUID: NolanRyanService] = [:]

    private let udKey = "mtst_queue_items"

    init() { load() }

    /// Add a song to the queue. No-ops if the MTID is already pending.
    func addItem(mtid: String, songName: String, stemsFolderPath: String, alsName: String, nrFolderName: String?) {
        guard !items.contains(where: { $0.mtid == mtid && $0.status == .pending }) else { return }
        items.append(QueueItem(
            mtid: mtid,
            songName: songName,
            stemsFolderPath: stemsFolderPath,
            alsName: alsName,
            nrFolderName: nrFolderName
        ))
        persist()
    }

    func removeItem(id: UUID) {
        items.removeAll { $0.id == id }
        persist()
    }

    func clearAll() {
        items.removeAll()
        persist()
    }

    func clearCompleted() {
        items.removeAll { $0.status == .success }
        persist()
    }

    func retryItem(id: UUID) {
        if let idx = items.firstIndex(where: { $0.id == id }) {
            items[idx].status = .pending
            items[idx].errorMessage = nil
        }
        persist()
    }

    /// Process all pending/failed items concurrently: each gets its own NR service instance.
    /// Copy stems → verify → trigger BackOffice for every item in parallel.
    func processAll(boService: BackOfficeService, volumeName: String) async {
        guard !isProcessing else { return }
        isProcessing = true
        defer { isProcessing = false }

        let toProcess = items.filter { $0.status == .pending || $0.status == .failed }

        for item in toProcess {
            if let idx = items.firstIndex(where: { $0.id == item.id }) {
                items[idx].status = .processing
                items[idx].errorMessage = nil
            }
            activeNRServices[item.id] = NolanRyanService()
        }
        persist()

        await withTaskGroup(of: Void.self) { group in
            for item in toProcess {
                group.addTask { @MainActor [self] in
                    await self.runItem(item, boService: boService, volumeName: volumeName)
                }
            }
        }
    }

    /// Process a single item immediately, regardless of the batch isProcessing flag.
    func processItem(id: UUID, boService: BackOfficeService, volumeName: String) async {
        guard let item = items.first(where: { $0.id == id }),
              item.status == .pending || item.status == .failed else { return }

        if let idx = items.firstIndex(where: { $0.id == id }) {
            items[idx].status = .processing
            items[idx].errorMessage = nil
        }
        activeNRServices[id] = NolanRyanService()
        persist()

        await runItem(item, boService: boService, volumeName: volumeName)
    }

    // MARK: - Private processing core

    private func runItem(_ item: QueueItem, boService: BackOfficeService, volumeName: String) async {
        let itemID = item.id
        guard let nrService = activeNRServices[itemID] else { return }
        defer { activeNRServices.removeValue(forKey: itemID) }

        let stemsFolderURL = URL(fileURLWithPath: item.stemsFolderPath)
        guard FileManager.default.fileExists(atPath: stemsFolderURL.path) else {
            fail(itemID, "Stems folder not found: \(item.stemsFolderPath)")
            return
        }

        await nrService.copyStems(
            from: stemsFolderURL,
            mtid: item.mtid,
            songName: item.alsName,
            volumeName: volumeName
        )

        if let error = nrService.lastError {
            fail(itemID, error)
            return
        }
        if !nrService.verificationPassed {
            let files = nrService.verificationFailed.joined(separator: ", ")
            fail(itemID, "Verification failed: \(files)")
            return
        }

        let result = await boService.triggerUploadStemsResult(mtid: item.mtid)
        switch result {
        case .success:
            succeed(itemID)
        case .failure(let err):
            fail(itemID, err.localizedDescription)
        }
    }

    // MARK: Item state helpers

    private func fail(_ id: UUID, _ message: String) {
        if let idx = items.firstIndex(where: { $0.id == id }) {
            items[idx].status = .failed
            items[idx].errorMessage = message
        }
        persist()
    }

    private func succeed(_ id: UUID) {
        if let idx = items.firstIndex(where: { $0.id == id }) {
            items[idx].status = .success
            items[idx].errorMessage = nil
        }
        persist()
    }

    // MARK: Persistence

    private func persist() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        UserDefaults.standard.set(data, forKey: udKey)
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: udKey),
              let decoded = try? JSONDecoder().decode([QueueItem].self, from: data) else { return }
        items = decoded
    }
}
