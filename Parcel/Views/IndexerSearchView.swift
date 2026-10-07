import SwiftUI

@MainActor
final class IndexerSearchViewModel: ObservableObject {
    @Published var results: [NZBResult] = []
    @Published var isSearching = false
    @Published var hasSearched = false
    @Published var errors: [String] = []
    @Published var notice: String?

    func search(
        term: String,
        category: IndexerCategory,
        indexers: [(profile: ServerProfile, secret: String)]
    ) async {
        isSearching = true
        var collected: [NZBResult] = []
        var failures: [String] = []

        await withTaskGroup(of: (results: [NZBResult], error: String?).self) { group in
            for entry in indexers {
                let client = ServiceFactory.indexer(entry.profile, secret: entry.secret)
                let label = entry.profile.name
                let code = category.code
                group.addTask {
                    do {
                        return (results: try await client.search(term, category: code), error: nil)
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
    @State private var category: IndexerCategory = .all
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
                    resultsList
                }
            }
            .navigationTitle("Search")
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
                    description: Text(vm.hasSearched ? "Try different words or another category." : "Type a name and tap Search.")
                )
            }
        }
        .searchable(text: $term, prompt: "Search NZB indexers")
        .onSubmit(of: .search) { Task { await runSearch() } }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Category", selection: $category) {
                        ForEach(IndexerCategory.allCases) { Text($0.rawValue).tag($0) }
                    }
                    Picker("Sort", selection: $sort) {
                        ForEach(ResultSort.allCases) { Text($0.rawValue).tag($0) }
                    }
                } label: {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                }
                .accessibilityLabel("Filter and sort")
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

    private func runSearch() async {
        let trimmed = term.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 2 else { return }
        let entries = store.indexers.map { (profile: $0, secret: store.secret(for: $0)) }
        await vm.search(term: trimmed, category: category, indexers: entries)
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
