import SwiftUI

enum ArrSection: String, CaseIterable, Identifiable {
    case library = "Library"
    case calendar = "Calendar"
    case wanted = "Wanted"
    case activity = "Activity"

    var id: String { rawValue }
}

@MainActor
final class ArrViewModel: ObservableObject {
    @Published var library: [ArrItem] = []
    @Published var calendar: [ArrEntry] = []
    @Published var wanted: [ArrEntry] = []
    @Published var queue: [ArrQueueEntry] = []
    @Published var loaded: Set<ArrSection> = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var notice: String?

    let client: ArrClient

    init(client: ArrClient) {
        self.client = client
    }

    private func report(_ error: Error) {
        if !isCancellation(error) { errorMessage = error.localizedDescription }
    }

    func load(_ section: ArrSection) async {
        isLoading = true
        defer { isLoading = false }
        do {
            switch section {
            case .library:
                library = try await client.library()
            case .calendar:
                let now = Date()
                let start = Calendar.current.date(byAdding: .day, value: -1, to: now) ?? now
                let end = Calendar.current.date(byAdding: .day, value: 30, to: now) ?? now
                calendar = try await client.calendar(start: start, end: end)
            case .wanted:
                wanted = try await client.wanted()
            case .activity:
                queue = try await client.queue()
            }
            loaded.insert(section)
            errorMessage = nil
        } catch {
            report(error)
        }
    }

    func search(_ entry: ArrEntry) async {
        do {
            try await client.search(entry: entry)
            notice = "Search started for \(entry.title)."
        } catch {
            report(error)
        }
    }

    func searchAllMissing() async {
        do {
            try await client.searchAllMissing()
            notice = "Searching for all missing items."
        } catch {
            report(error)
        }
    }
}

// MARK: - Entry point for the TV and Movies tabs

struct ArrRootView: View {
    let kind: ServerKind
    @EnvironmentObject private var store: ServerStore

    private var title: String { kind == .sonarr ? "TV Shows" : "Movies" }

    var body: some View {
        NavigationStack {
            if let profile = store.first(of: kind),
               let client = ServiceFactory.arr(profile, secret: store.secret(for: profile)) {
                ArrContentView(kind: kind, client: client)
                    .id(store.revision)
            } else {
                MissingServerView(
                    title: "No \(kind.title) server",
                    message: "Add your \(kind.title) server in the Settings tab."
                )
                .navigationTitle(title)
            }
        }
    }
}

private struct DayGroup: Identifiable {
    let day: Date
    let entries: [ArrEntry]
    var id: Date { day }
}

@MainActor
struct ArrContentView: View {
    let kind: ServerKind

    @StateObject private var vm: ArrViewModel
    @State private var section: ArrSection = .library
    @State private var filter = ""
    @State private var showingAdd = false
    @State private var confirmSearchAll = false
    @State private var episodeTarget: EpisodeTarget?

    init(kind: ServerKind, client: ArrClient) {
        self.kind = kind
        _vm = StateObject(wrappedValue: ArrViewModel(client: client))
    }

    private var title: String { kind == .sonarr ? "TV Shows" : "Movies" }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Section", selection: $section) {
                ForEach(ArrSection.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.bottom, 8)

            List {
                if let message = vm.errorMessage {
                    Section {
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                }
                content
            }
            .listStyle(.plain)
            .sheet(item: $episodeTarget) { target in
                EpisodeDetailView(target: target, client: vm.client)
            }
            .overlay {
                if vm.isLoading && !vm.loaded.contains(section) {
                    ProgressView()
                }
            }
        }
        .navigationTitle(title)
        .searchable(text: $filter, prompt: "Filter library")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showingAdd = true } label: { Image(systemName: "plus") }
                    .accessibilityLabel("Add")
            }
            if section == .wanted {
                ToolbarItem(placement: .topBarLeading) {
                    Button { confirmSearchAll = true } label: { Image(systemName: "magnifyingglass") }
                        .accessibilityLabel("Search all missing")
                }
            }
        }
        .task(id: section) {
            if section == .activity {
                while !Task.isCancelled {
                    await vm.load(.activity)
                    try? await Task.sleep(for: .seconds(5))
                }
            } else {
                await vm.load(section)
            }
        }
        .refreshable { await vm.load(section) }
        .navigationDestination(for: ArrItem.self) { item in
            ArrDetailView(item: item, kind: kind, client: vm.client) {
                Task { await vm.load(.library) }
            }
        }
        .sheet(isPresented: $showingAdd) {
            AddItemView(kind: kind, client: vm.client) {
                Task { await vm.load(.library) }
            }
        }
        .confirmationDialog("Search for every missing item?", isPresented: $confirmSearchAll, titleVisibility: .visible) {
            Button("Search All Missing") { Task { await vm.searchAllMissing() } }
        } message: {
            Text("This asks \(kind.title) to search your indexers for everything monitored that's missing. It can use a lot of indexer API calls.")
        }
        .alert(
            "Done",
            isPresented: Binding(get: { vm.notice != nil }, set: { if !$0 { vm.notice = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(vm.notice ?? "")
        }
    }

    // MARK: Sections

    @ViewBuilder
    private var content: some View {
        switch section {
        case .library: libraryRows
        case .calendar: calendarRows
        case .wanted: wantedRows
        case .activity: activityRows
        }
    }

    private var filteredLibrary: [ArrItem] {
        let term = filter.trimmingCharacters(in: .whitespaces)
        guard !term.isEmpty else { return vm.library }
        return vm.library.filter { $0.title.localizedCaseInsensitiveContains(term) }
    }

    @ViewBuilder
    private var libraryRows: some View {
        if filteredLibrary.isEmpty && vm.loaded.contains(.library) {
            Text(vm.library.isEmpty ? "Your library is empty. Tap + to add something." : "No matches.")
                .foregroundStyle(.secondary)
        }
        ForEach(filteredLibrary) { item in
            NavigationLink(value: item) {
                ArrItemRow(item: item)
            }
        }
    }

    private var calendarGroups: [DayGroup] {
        let dated = vm.calendar.filter { $0.date != nil }
        let grouped = Dictionary(grouping: dated) { entry in
            Calendar.current.startOfDay(for: entry.date ?? Date())
        }
        return grouped.keys.sorted().map { DayGroup(day: $0, entries: grouped[$0] ?? []) }
    }

    @ViewBuilder
    private var calendarRows: some View {
        if calendarGroups.isEmpty && vm.loaded.contains(.calendar) {
            Text("Nothing scheduled in the next 30 days.").foregroundStyle(.secondary)
        }
        ForEach(calendarGroups) { group in
            Section(group.day.formatted(date: .complete, time: .omitted)) {
                ForEach(group.entries) { entry in
                    entryRow(entry)
                }
            }
        }
    }

    @ViewBuilder
    private var wantedRows: some View {
        if vm.wanted.isEmpty && vm.loaded.contains(.wanted) {
            Text("Nothing missing. Nice.").foregroundStyle(.secondary)
        }
        ForEach(vm.wanted) { entry in
            entryRow(entry)
        }
    }

    @ViewBuilder
    private var activityRows: some View {
        if vm.queue.isEmpty && vm.loaded.contains(.activity) {
            Text("Nothing is downloading.").foregroundStyle(.secondary)
        }
        ForEach(vm.queue) { entry in
            if kind == .sonarr, let seriesID = entry.seriesID, let episodeID = entry.episodeID {
                Button {
                    episodeTarget = EpisodeTarget(seriesID: seriesID, episodeID: episodeID, seriesTitle: entry.title)
                } label: {
                    ArrQueueRow(entry: entry)
                }
                .buttonStyle(.plain)
            } else {
                ArrQueueRow(entry: entry)
            }
        }
    }

    @ViewBuilder
    private func tappable(_ entry: ArrEntry) -> some View {
        if kind == .sonarr, let episodeID = entry.episodeID {
            Button {
                episodeTarget = EpisodeTarget(seriesID: entry.itemID, episodeID: episodeID, seriesTitle: entry.title)
            } label: {
                EntryRow(entry: entry)
            }
            .buttonStyle(.plain)
        } else {
            EntryRow(entry: entry)
        }
    }

    private func entryRow(_ entry: ArrEntry) -> some View {
        tappable(entry)
            .swipeActions(edge: .trailing) {
                Button {
                    Task { await vm.search(entry) }
                } label: {
                    Label("Search", systemImage: "magnifyingglass")
                }
                .tint(.blue)
            }
    }
}

// MARK: - Rows

struct ArrItemRow: View {
    let item: ArrItem
    var showStatus = true

    var body: some View {
        HStack(spacing: 12) {
            PosterView(url: item.posterURL)

            VStack(alignment: .leading, spacing: 4) {
                Text(item.title)
                    .font(.headline)
                    .lineLimit(2)

                if !metaLine.isEmpty {
                    Text(metaLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if showStatus {
                    if let progress = item.progress, progress < 1 {
                        ProgressView(value: progress)
                    }
                    HStack(spacing: 6) {
                        if !item.monitored {
                            Image(systemName: "bookmark.slash")
                        }
                        Text(item.statusText)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                } else if item.inLibrary {
                    Label("In library", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            }
        }
    }

    private var metaLine: String {
        var parts: [String] = []
        if let year = item.year { parts.append(String(year)) }
        if let subtitle = item.subtitle, !subtitle.isEmpty { parts.append(subtitle) }
        return parts.joined(separator: " · ")
    }
}

private struct EntryRow: View {
    let entry: ArrEntry

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title)
                    .font(.subheadline.weight(.semibold))
                if let detail = entry.detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let date = entry.date {
                    Text(date.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer()
            Image(systemName: icon)
                .foregroundStyle(entry.hasFile ? Color.green : Color.secondary)
        }
        .contentShape(Rectangle())
    }

    private var icon: String {
        if entry.hasFile { return "checkmark.circle.fill" }
        return entry.monitored ? "arrow.down.circle" : "circle.dashed"
    }
}

private struct ArrQueueRow: View {
    let entry: ArrQueueEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(entry.title)
                .font(.subheadline.weight(.semibold))
            if let detail = entry.detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: entry.progress)
            HStack {
                Text(entry.status)
                if let left = entry.timeLeft, !left.isEmpty {
                    Text("· \(left)")
                }
                Spacer()
                Text("\(Int(entry.progress * 100))%")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            if let warning = entry.warning {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .contentShape(Rectangle())
        .padding(.vertical, 2)
    }
}
