import SwiftUI

struct CategorySelection: Equatable {
    let id: String
    let label: String
}

@MainActor
final class IndexerSearchViewModel: ObservableObject {
    @Published var results: [NZBResult] = []
    @Published var categories: [NZBCategory] = NZBCategory.standard
    @Published var isSearching = false
    @Published var hasSearched = false
    @Published var errors: [String] = []
    @Published var notice: String?

    /// Bumped on every search or clear so a slow, older search can't overwrite newer results.
    private var generation = 0

    func clear() {
        generation += 1
        results = []
        errors = []
        hasSearched = false
        isSearching = false
    }

    /// Asks each indexer which categories it offers and merges the answers.
    func loadCategories(indexers: [(profile: ServerProfile, secret: String)]) async {
        var lists: [[NZBCategory]] = []
        await withTaskGroup(of: [NZBCategory].self) { group in
            for entry in indexers {
                let client = ServiceFactory.indexer(entry.profile, secret: entry.secret)
                group.addTask { (try? await client.categories()) ?? [] }
            }
            for await list in group where !list.isEmpty {
                lists.append(list)
            }
        }
        categories = lists.isEmpty ? NZBCategory.standard : NZBCategory.merge(lists)
    }

    func search(
        term: String,
        categoryID: String?,
        indexers: [(profile: ServerProfile, secret: String)]
    ) async {
        generation += 1
        let mine = generation
        isSearching = true
        var collected: [NZBResult] = []
        var failures: [String] = []

        await withTaskGroup(of: (results: [NZBResult], error: String?).self) { group in
            for entry in indexers {
                let client = ServiceFactory.indexer(entry.profile, secret: entry.secret)
                let label = entry.profile.name
                group.addTask {
                    do {
                        return (results: try await client.search(term, category: categoryID), error: nil)
                    } catch {
                        return (results: [], error: "\(label): \(error.localizedDescription)")
                    }
                }
            }
            for await outcome in group {
                collected.append(contentsOf: outcome.results)
                if let message = outcome.error { failures.append(message) }
            }
        }

        guard mine == generation else { return }
        results = collected
        errors = failures
        hasSearched = true
        isSearching = false
    }

    func send(_ result: NZBResult, to client: DownloaderClient, name: String) async {
        do {
            try await client.addURL(result.downloadURL, name: result.title)
            notice = "Sent to \(name)."
        } catch {
            if !isCancellation(error) { notice = "Couldn't send it: \(error.localizedDescription)" }
        }
    }
}

@MainActor
struct IndexerSearchView: View {
    @EnvironmentObject private var store: ServerStore
    @StateObject private var vm = IndexerSearchViewModel()
    @State private var term = ""
    @State private var selection: CategorySelection?
    @State private var sort: ResultSort = .newest
    @State private var selected: NZBResult?

    enum ResultSort: String, CaseIterable, Identifiable {
        case newest = "Newest"
        case largest = "Largest"
        case name = "Name"
        var id: String { rawValue }
    }

    private var sortedResults: [NZBResult] {
        switch sort {
        case .newest:
            return vm.results.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
        case .largest:
            return vm.results.sorted { $0.sizeBytes > $1.sizeBytes }
        case .name:
            return vm.results.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if store.indexers.isEmpty {
                    MissingServerView(
                        title: "No indexers",
                        message: "Add a Newznab-compatible indexer in the Settings tab to search for NZBs."
                    )
                } else {
                    searchContent
                }
            }
            .navigationTitle("Search")
        }
    }

    // MARK: Category picker

    private var categoryMenu: some View {
        Menu {
            Button {
                selection = nil
            } label: {
                if selection == nil {
                    Label("All categories", systemImage: "checkmark")
                } else {
                    Text("All categories")
                }
            }

            ForEach(vm.categories) { parent in
                Menu(parent.name) {
                    Button {
                        selection = CategorySelection(id: parent.id, label: parent.name)
                    } label: {
                        if selection?.id == parent.id {
                            Label("All \(parent.name)", systemImage: "checkmark")
                        } else {
                            Text("All \(parent.name)")
                        }
                    }

                    ForEach(parent.children) { child in
                        Button {
                            selection = CategorySelection(id: child.id, label: "\(parent.name) › \(child.name)")
                        } label: {
                            if selection?.id == child.id {
                                Label(child.name, systemImage: "checkmark")
                            } else {
                                Text(child.name)
                            }
                        }
                    }
                }
            }
        } label: {
            HStack {
                Label("Category", systemImage: "square.grid.2x2")
                Spacer()
                Text(selection?.label ?? "All")
                    .foregroundStyle(.secondary)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
    }

    // MARK: Results

    private var searchContent: some View {
        VStack(spacing: 0) {
            categoryMenu
            Divider()
            resultsList
        }
        .searchable(text: $term, prompt: "Search NZB indexers")
        .onSubmit(of: .search) { Task { await runSearch() } }
        .onChange(of: selection) { _, _ in
            Task { await runSearch() }
        }
        .onChange(of: term) { _, newValue in
            if newValue.isEmpty { Task { await runSearch() } }
        }
        .task(id: store.revision) {
            let entries = store.indexers.map { (profile: $0, secret: store.secret(for: $0)) }
            await vm.loadCategories(indexers: entries)
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Sort", selection: $sort) {
                        ForEach(ResultSort.allCases) { Text($0.rawValue).tag($0) }
                    }
                } label: {
                    Image(systemName: "arrow.up.arrow.down.circle")
                }
                .accessibilityLabel("Sort results")
            }
        }
        .confirmationDialog(
            selected?.title ?? "",
            isPresented: Binding(get: { selected != nil }, set: { if !$0 { selected = nil } }),
            titleVisibility: .visible,
            presenting: selected
        ) { result in
            if let profile = store.activeDownloader,
               let client = ServiceFactory.downloader(profile, secret: store.secret(for: profile)) {
                Button("Send to \(profile.name)") {
                    Task { await vm.send(result, to: client, name: profile.name) }
                }
            }
        } message: { _ in
            if store.activeDownloader == nil {
                Text("Add SABnzbd or NZBGet in Settings first, then you can send results to it.")
            }
        }
        .alert(
            "Download",
            isPresented: Binding(get: { vm.notice != nil }, set: { if !$0 { vm.notice = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(vm.notice ?? "")
        }
    }

    private var resultsList: some View {
        List {
            if !vm.errors.isEmpty {
                Section {
                    ForEach(vm.errors, id: \.self) { message in
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                }
            }
            ForEach(sortedResults) { result in
                Button {
                    selected = result
                } label: {
                    ResultRow(result: result)
                }
                .buttonStyle(.plain)
            }
        }
        .listStyle(.plain)
        .overlay {
            if vm.isSearching {
                ProgressView()
            } else if vm.results.isEmpty {
                ContentUnavailableView(
                    vm.hasSearched ? "No results" : "Search your indexers",
                    systemImage: "magnifyingglass",
                    description: Text(
                        vm.hasSearched
                            ? "Try different words or another category."
                            : "Pick a category to browse the latest releases, or type a name and tap Search."
                    )
                )
            }
        }
    }

    private func runSearch() async {
        let trimmed = term.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty && selection == nil {
            vm.clear()
            return
        }
        if !trimmed.isEmpty && trimmed.count < 2 { return }
        let entries = store.indexers.map { (profile: $0, secret: store.secret(for: $0)) }
        await vm.search(term: trimmed, categoryID: selection?.id, indexers: entries)
    }
}

private struct ResultRow: View {
    let result: NZBResult

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(result.title)
                .font(.subheadline)
                .lineLimit(3)
            HStack(spacing: 8) {
                Text(result.sizeBytes.byteString)
                if let date = result.date {
                    Text(date.relativeString)
                }
                if !result.category.isEmpty {
                    Text(result.category).lineLimit(1)
                }
                Spacer()
                Text(result.indexer)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .padding(.vertical, 2)
    }
}
