import SwiftUI

// MARK: - Queue tab

struct QueueView: View {
    @ObservedObject var queueService: QueueService
    @ObservedObject var boService: BackOfficeService
    @ObservedObject private var userSettings = UserSettings.shared

    private var activeItems: [QueueItem] {
        queueService.items.filter { $0.status != .success }
    }

    private var completedItems: [QueueItem] {
        queueService.items.filter { $0.status == .success }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // MARK: Active queue card
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "list.bullet.rectangle")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.accent)
                    Text("NR PROCESSING QUEUE")
                        .font(.lato(size: 13, weight: .semibold))
                        .foregroundColor(.fgBright)
                    Spacer()
                    Button("Process All") {
                        Task {
                            await queueService.processAll(
                                boService: boService,
                                volumeName: userSettings.nolanRyanVolumeName
                            )
                        }
                    }
                    .font(.lato(size: 12, weight: .semibold))
                    .buttonStyle(CompactSecondaryButtonStyle().hoverable())
                    .disabled(processAllDisabled)

                    Button("Clear Queue") {
                        queueService.clearAll()
                    }
                    .font(.lato(size: 12))
                    .buttonStyle(CompactSecondaryButtonStyle().hoverable())
                    .disabled(activeItems.isEmpty || queueService.isProcessing)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)

                Divider().background(Color.border)

                if activeItems.isEmpty {
                    HStack {
                        Spacer()
                        VStack(spacing: 8) {
                            Image(systemName: "tray")
                                .font(.system(size: 22))
                                .foregroundColor(.fgDim)
                            Text("No songs queued")
                                .font(.lato(size: 12))
                                .foregroundColor(.fgDim)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 28)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(activeItems.enumerated()), id: \.element.id) { idx, item in
                            QueueItemRow(
                                item: item,
                                nrService: queueService.activeNRServices[item.id],
                                onProcess: {
                                    Task {
                                        await queueService.processItem(
                                            id: item.id,
                                            boService: boService,
                                            volumeName: userSettings.nolanRyanVolumeName
                                        )
                                    }
                                },
                                onRetry: { queueService.retryItem(id: item.id) },
                                onClear: { queueService.removeItem(id: item.id) }
                            )
                            if idx < activeItems.count - 1 {
                                Divider().background(Color.border).padding(.leading, 14)
                            }
                        }
                    }
                }
            }
            .cardStyle()

            // MARK: Completed card
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.green)
                    Text("COMPLETED")
                        .font(.lato(size: 13, weight: .semibold))
                        .foregroundColor(.fgBright)
                    Spacer()
                    Button("Clear All") {
                        queueService.clearCompleted()
                    }
                    .font(.lato(size: 12))
                    .buttonStyle(CompactSecondaryButtonStyle().hoverable())
                    .disabled(completedItems.isEmpty)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)

                Divider().background(Color.border)

                if completedItems.isEmpty {
                    HStack {
                        Spacer()
                        Text("No completed songs")
                            .font(.lato(size: 12))
                            .foregroundColor(.fgDim)
                        Spacer()
                    }
                    .padding(.vertical, 18)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(completedItems.enumerated()), id: \.element.id) { idx, item in
                            CompletedItemRow(item: item, onClear: { queueService.removeItem(id: item.id) })
                            if idx < completedItems.count - 1 {
                                Divider().background(Color.border).padding(.leading, 14)
                            }
                        }
                    }
                }
            }
            .cardStyle()

            Spacer()
        }
    }

    private var processAllDisabled: Bool {
        queueService.isProcessing ||
        !activeItems.contains(where: { $0.status == .pending || $0.status == .failed })
    }
}

// MARK: - Active queue item row

struct QueueItemRow: View {
    let item: QueueItem
    var nrService: NolanRyanService?
    var onProcess: (() -> Void)?
    var onRetry: (() -> Void)?
    let onClear: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            statusIcon
                .frame(width: 16, alignment: .center)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("MTID \(item.mtid)")
                        .font(.lato(size: 11, weight: .semibold))
                        .foregroundColor(.fgBright)
                    if !item.songName.isEmpty {
                        Text("·")
                            .font(.lato(size: 11))
                            .foregroundColor(.fgDim)
                        Text(item.songName)
                            .font(.lato(size: 11))
                            .foregroundColor(.fgMid)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }

                if !item.alsName.isEmpty || item.nrFolderName != nil {
                    HStack(spacing: 4) {
                        if !item.alsName.isEmpty {
                            Text(item.alsName)
                                .font(.lato(size: 10))
                                .foregroundColor(.fgDim)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        if let folder = item.nrFolderName {
                            Text("→")
                                .font(.lato(size: 10))
                                .foregroundColor(.fgDim)
                            Text(folder)
                                .font(.lato(size: 10))
                                .foregroundColor(.fgDim)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }

                if item.status == .processing, let nr = nrService {
                    processingDetail(nr: nr)
                } else if let err = item.errorMessage {
                    Text(err)
                        .font(.lato(size: 10))
                        .foregroundColor(.red)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer()

            statusBadge

            if (item.status == .pending || item.status == .failed), let onProcess {
                Button("Process") { onProcess() }
                    .font(.lato(size: 10, weight: .semibold))
                    .buttonStyle(CompactSecondaryButtonStyle().hoverable())
            }

            if item.status == .failed, let onRetry {
                Button("Retry") { onRetry() }
                    .font(.lato(size: 10))
                    .buttonStyle(CompactSecondaryButtonStyle().hoverable())
            }

            if item.status != .processing {
                Button("Clear") { onClear() }
                    .font(.lato(size: 10))
                    .buttonStyle(CompactSecondaryButtonStyle().hoverable())
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func processingDetail(nr: NolanRyanService) -> some View {
        NRProgressDetail(nrService: nr)
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch item.status {
        case .pending:
            Image(systemName: "clock")
                .font(.system(size: 11))
                .foregroundColor(.fgDim)
        case .processing:
            ProgressView().scaleEffect(0.55)
        case .success:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 11))
                .foregroundColor(.green)
        case .failed:
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 11))
                .foregroundColor(.red)
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch item.status {
        case .pending:
            Text("Pending")
                .font(.lato(size: 10))
                .foregroundColor(.fgDim)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.fgDim.opacity(0.12))
                .cornerRadius(4)
        case .processing:
            Text("Processing…")
                .font(.lato(size: 10))
                .foregroundColor(.accent)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.accent.opacity(0.12))
                .cornerRadius(4)
        case .success:
            Text("Done")
                .font(.lato(size: 10))
                .foregroundColor(.green)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.green.opacity(0.12))
                .cornerRadius(4)
        case .failed:
            Text("Failed")
                .font(.lato(size: 10))
                .foregroundColor(.red)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.red.opacity(0.12))
                .cornerRadius(4)
        }
    }
}

// MARK: - Completed item row

private struct CompletedItemRow: View {
    let item: QueueItem
    let onClear: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 11))
                .foregroundColor(.green)
                .frame(width: 16, alignment: .center)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("MTID \(item.mtid)")
                        .font(.lato(size: 11, weight: .semibold))
                        .foregroundColor(.fgBright)
                    if !item.songName.isEmpty {
                        Text("·")
                            .font(.lato(size: 11))
                            .foregroundColor(.fgDim)
                        Text(item.songName)
                            .font(.lato(size: 11))
                            .foregroundColor(.fgMid)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                if !item.alsName.isEmpty {
                    Text(item.alsName)
                        .font(.lato(size: 10))
                        .foregroundColor(.fgDim)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer()

            Text("Done")
                .font(.lato(size: 10))
                .foregroundColor(.green)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.green.opacity(0.12))
                .cornerRadius(4)

            Button("Clear") { onClear() }
                .font(.lato(size: 10))
                .buttonStyle(CompactSecondaryButtonStyle().hoverable())
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}

// MARK: - NR copy progress (observes NolanRyanService live)

/// Separate view so @ObservedObject can track nrService's published properties.
private struct NRProgressDetail: View {
    @ObservedObject var nrService: NolanRyanService

    var body: some View {
        if nrService.isCopying {
            let (done, total) = nrService.copyProgress
            VStack(alignment: .leading, spacing: 3) {
                ProgressView(value: Double(done), total: Double(max(total, 1)))
                    .tint(.accent)
                    .frame(maxWidth: 220)
                Text(nrService.currentFileName.isEmpty
                     ? "Copying \(done) of \(total)…"
                     : "\(nrService.currentFileName) (\(done)/\(total))")
                    .font(.lato(size: 10))
                    .foregroundColor(.fgDim)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        } else if nrService.isVerifying {
            HStack(spacing: 5) {
                ProgressView().scaleEffect(0.55)
                Text("Verifying…")
                    .font(.lato(size: 10))
                    .foregroundColor(.fgDim)
            }
        } else if nrService.copyComplete && nrService.verificationPassed {
            HStack(spacing: 5) {
                ProgressView().scaleEffect(0.55)
                Text("Triggering BackOffice…")
                    .font(.lato(size: 10))
                    .foregroundColor(.fgDim)
            }
        } else {
            HStack(spacing: 5) {
                ProgressView().scaleEffect(0.55)
                Text("Copying stems…")
                    .font(.lato(size: 10))
                    .foregroundColor(.fgDim)
            }
        }
    }
}
