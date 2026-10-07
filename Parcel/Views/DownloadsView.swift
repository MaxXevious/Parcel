import SwiftUI

@MainActor
final class DownloadsViewModel: ObservableObject {
    @Published var snapshot: DownloaderSnapshot?
    @Published var history: [HistoryItem] = []
    @Published var errorMessage: String?

    private let client: DownloaderClient

    init(client: DownloaderClient) {
        self.client = client
    }

    private func report(_ error: Error) {
        if !isCancellation(error) { errorMessage = error.localizedDescription }
    }

    func refreshQueue() async {
        do {
            snapshot = try await client.fetchQueue()
            errorMessage = nil
        } catch {
            report(error)
        }
    }

    func refreshHistory() async {
        do {
            history = try await client.fetchHistory(limit: 50)
            errorMessage = nil
        } catch {
            report(error)
        }
    }

    private func run(_ work: () async throws -> Void) async {
        do { try await work() } catch { report(error) }
        await refreshQueue()
    }

    func togglePauseAll() async {
        let paused = snapshot?.status.isPaused ?? false
        await run {
            if paused { try await client.resumeAll() } else { try await client.pauseAll() }
        }
    }

    func toggle(_ item: DownloadItem) async {
        await run {
            if item.isPaused { try await client.resume(id: item.id) } else { try await client.pause(id: item.id) }
        }
    }

    func delete(_ item: DownloadItem) async {
        await run { try await client.delete(id: item.id) }
    }

    func deleteHistory(_ item: HistoryItem) async {
        do {
            try await client.deleteHistory(id: item.id)
            history.removeAll { $0.id == item.id }
        } catch {
            report(error)
        }
    }

    func setSpeedLimit(_ bytesPerSec: Int64) async {
        await run { try await client.setSpeedLimit(bytesPerSec: bytesPerSec) }
    }
}

// MARK: - Screen

struct DownloadsView: View {
    @EnvironmentObject private var store: ServerStore

    var body: some View {
        NavigationStack {
            if let profile = store.activeDownloader,
               let client = ServiceFactory.downloader(profile, secret: store.secret(for: profile)) {
                DownloadsContent(profile: profile, client: client)
                    .id("\(profile.id.uuidString)-\(store.revision)")
            } else {
                MissingServerView(
                    title: "No downloader",
                    message: "Add SABnzbd or NZBGet in the Settings tab."
                )
                .navigationTitle("Downloads")
            }
        }
    }
}

@MainActor
private struct DownloadsContent: View {
    let profile: ServerProfile

    @EnvironmentObject private var store: ServerStore
    @StateObject private var vm: DownloadsViewModel
    @State private var tab: Tab = .queue
    @State private var pendingDelete: DownloadItem?

    enum Tab: String, CaseIterable, Identifiable {
        case queue = "Queue"
        case history = "History"
        var id: String { rawValue }
    }

    private static let limits: [(label: String, bytes: Int64)] = [
        ("Unlimited", 0),
        ("1 MB/s", 1_048_576),
        ("2 MB/s", 2 * 1_048_576),
        ("5 MB/s", 5 * 1_048_576),
        ("10 MB/s", 10 * 1_048_576),
        ("25 MB/s", 25 * 1_048_576),
        ("50 MB/s", 50 * 1_048_576)
    ]

    init(profile: ServerProfile, client: DownloaderClient) {
        self.profile = profile
        _vm = StateObject(wrappedValue: DownloadsViewModel(client: client))
    }

    var body: some View {
        List {
            if let message = vm.errorMessage {
                Section {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }

            if let status = vm.snapshot?.status {
                Section { statusHeader(status) }
            }

            Section {
                Picker("View", selection: $tab) {
                    ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
            }

            switch tab {
            case .queue: queueRows
            case .history: historyRows
            }
        }
        .navigationTitle(profile.name)
        .toolbar {
            if store.downloaders.count > 1 {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        ForEach(store.downloaders) { downloader in
                            Button {
                                store.activeDownloaderID = downloader.id
                            } label: {
                                if downloader.id == profile.id {
                                    Label(downloader.name, systemImage: "checkmark")
                                } else {
                                    Text(downloader.name)
                                }
                            }
                        }
                    } label: {
                        Image(systemName: "arrow.left.arrow.right.circle")
                    }
                    .accessibilityLabel("Switch downloader")
                }
            }
        }
        .task(id: tab) {
            switch tab {
            case .queue:
                while !Task.isCancelled {
                    await vm.refreshQueue()
                    try? await Task.sleep(for: .seconds(3))
                }
            case .history:
                await vm.refreshHistory()
            }
        }
        .refreshable {
            await vm.refreshQueue()
            if tab == .history { await vm.refreshHistory() }
        }
        .confirmationDialog(
            "Delete this download?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible,
            presenting: pendingDelete
        ) { item in
            Button("Delete", role: .destructive) { Task { await vm.delete(item) } }
        } message: { item in
            Text(item.name)
        }
    }

    // MARK: Pieces

    private func statusHeader(_ status: DownloaderStatus) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(status.isPaused ? "Paused" : status.speedBytesPerSec.speedString)
                    .font(.title2.weight(.semibold))
                    .monospacedDigit()
                Spacer()
                Text("\(status.remainingBytes.byteString) left")
                    .foregroundStyle(.secondary)
            }

            HStack {
                Button {
                    Task { await vm.togglePauseAll() }
                } label: {
                    Label(
                        status.isPaused ? "Resume" : "Pause",
                        systemImage: status.isPaused ? "play.fill" : "pause.fill"
                    )
                }
                .buttonStyle(.bordered)

                Menu {
                    ForEach(Self.limits, id: \.label) { limit in
                        Button {
                            Task { await vm.setSpeedLimit(limit.bytes) }
                        } label: {
                            if limit.bytes == status.speedLimitBytesPerSec {
                                Label(limit.label, systemImage: "checkmark")
                            } else {
                                Text(limit.label)
                            }
                        }
                    }
                } label: {
                    Label(
                        status.speedLimitBytesPerSec > 0 ? "Limit \(status.speedLimitBytesPerSec.speedString)" : "No limit",
                        systemImage: "speedometer"
                    )
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var queueRows: some View {
        if let items = vm.snapshot?.items {
            if items.isEmpty {
                Text("Nothing in the queue.").foregroundStyle(.secondary)
            }
            ForEach(items) { item in
                DownloadRow(item: item)
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            pendingDelete = item
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                    .swipeActions(edge: .leading) {
                        Button {
                            Task { await vm.toggle(item) }
                        } label: {
                            Label(item.isPaused ? "Resume" : "Pause", systemImage: item.isPaused ? "play.fill" : "pause.fill")
                        }
                        .tint(.orange)
                    }
            }
        } else if vm.errorMessage == nil {
            HStack { ProgressView(); Text("Loading…").foregroundStyle(.secondary) }
        }
    }

    @ViewBuilder
    private var historyRows: some View {
        if vm.history.isEmpty {
            Text("No history yet.").foregroundStyle(.secondary)
        }
        ForEach(vm.history) { item in
            HistoryRow(item: item)
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) {
                        Task { await vm.deleteHistory(item) }
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
        }
    }
}

private struct DownloadRow: View {
    let item: DownloadItem

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(item.name)
                .font(.subheadline)
                .lineLimit(2)
            ProgressView(value: item.progress)
            HStack {
                Text(item.isPaused ? "Paused" : item.status)
                if let eta = item.eta, !eta.isEmpty, !item.isPaused {
                    Text("· \(eta)")
                }
                Spacer()
                Text("\(item.remainingBytes.byteString) of \(item.sizeBytes.byteString)")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

private struct HistoryRow: View {
    let item: HistoryItem

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(item.name)
                .font(.subheadline)
                .lineLimit(2)
            HStack {
                Text(item.status)
                    .foregroundStyle(item.failed ? Color.red : Color.green)
                Text(item.sizeBytes.byteString)
                if let completed = item.completed {
                    Text(completed.relativeString)
                }
                Spacer()
                if let category = item.category, !category.isEmpty, category != "*" {
                    Text(category)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}
