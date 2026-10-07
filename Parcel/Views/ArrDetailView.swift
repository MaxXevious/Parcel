import SwiftUI

private struct SeasonGroup: Identifiable {
    let season: Int
    let entries: [ArrEntry]
    var id: Int { season }
    var title: String { season == 0 ? "Specials" : "Season \(season)" }
}

struct ArrDetailView: View {
    let item: ArrItem
    let kind: ServerKind
    let client: ArrClient
    let onChange: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var monitored: Bool
    @State private var episodes: [ArrEntry] = []
    @State private var notice: String?
    @State private var errorMessage: String?
    @State private var confirmDelete = false
    @State private var episodeTarget: EpisodeTarget?

    init(item: ArrItem, kind: ServerKind, client: ArrClient, onChange: @escaping () -> Void) {
        self.item = item
        self.kind = kind
        self.client = client
        self.onChange = onChange
        _monitored = State(initialValue: item.monitored)
    }

    private var seasonGroups: [SeasonGroup] {
        let grouped = Dictionary(grouping: episodes) { $0.season ?? 0 }
        return grouped.keys.sorted(by: >).map { season in
            let sorted = (grouped[season] ?? []).sorted { ($0.number ?? 0) < ($1.number ?? 0) }
            return SeasonGroup(season: season, entries: sorted)
        }
    }

    var body: some View {
        List {
            Section {
                HStack(alignment: .top, spacing: 14) {
                    PosterView(url: item.posterURL, width: 90, height: 135)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(item.title).font(.title3.weight(.semibold))
                        if let year = item.year {
                            Text(String(year)).foregroundStyle(.secondary)
                        }
                        if let subtitle = item.subtitle, !subtitle.isEmpty {
                            Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
                        }
                        Text(item.statusText).font(.subheadline)
                        if item.sizeOnDisk > 0 {
                            Text(item.sizeOnDisk.byteString).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if let overview = item.overview, !overview.isEmpty {
                    Text(overview)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Toggle("Monitored", isOn: Binding(
                    get: { monitored },
                    set: { value in
                        monitored = value
                        Task { await setMonitored(value) }
                    }
                ))

                Button {
                    Task { await searchItem() }
                } label: {
                    Label(
                        kind == .sonarr ? "Search for missing episodes" : "Search for this movie",
                        systemImage: "magnifyingglass"
                    )
                }

                Button(role: .destructive) {
                    confirmDelete = true
                } label: {
                    Label("Remove from library", systemImage: "trash")
                }
            }

            if let errorMessage {
                Section {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }

            ForEach(seasonGroups) { group in
                Section(group.title) {
                    ForEach(group.entries) { entry in
                        episodeRow(entry)
                    }
                }
            }
        }
        .navigationTitle(item.title)
        .sheet(item: $episodeTarget) { target in
            EpisodeDetailView(target: target, client: client)
        }
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadEpisodes() }
        .confirmationDialog("Remove \(item.title)?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Remove from library", role: .destructive) {
                Task { await delete(files: false) }
            }
            Button("Remove and delete files", role: .destructive) {
                Task { await delete(files: true) }
            }
        }
        .alert(
            "Done",
            isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(notice ?? "")
        }
    }

    private func episodeRow(_ entry: ArrEntry) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.detail ?? "Episode")
                    .font(.subheadline)
                    .lineLimit(2)
                if let date = entry.date {
                    Text(date.formatted(date: .abbreviated, time: .omitted))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if !entry.monitored {
                Image(systemName: "bookmark.slash").foregroundStyle(.secondary)
            }
            Image(systemName: entry.hasFile ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(entry.hasFile ? Color.green : Color.secondary)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if let episodeID = entry.episodeID {
                episodeTarget = EpisodeTarget(seriesID: item.arrID, episodeID: episodeID, seriesTitle: item.title)
            }
        }
        .swipeActions(edge: .trailing) {
            Button {
                Task { await searchEpisode(entry) }
            } label: {
                Label("Search", systemImage: "magnifyingglass")
            }
            .tint(.blue)
        }
    }

    // MARK: Actions

    private func show(_ error: Error) {
        if !isCancellation(error) { errorMessage = error.localizedDescription }
    }

    private func loadEpisodes() async {
        guard kind == .sonarr else { return }
        do {
            episodes = try await client.episodes(for: item)
        } catch {
            show(error)
        }
    }

    private func searchItem() async {
        do {
            try await client.search(item: item)
            notice = "Search started."
        } catch {
            show(error)
        }
    }

    private func searchEpisode(_ entry: ArrEntry) async {
        do {
            try await client.search(entry: entry)
            notice = "Search started."
        } catch {
            show(error)
        }
    }

    private func setMonitored(_ value: Bool) async {
        do {
            try await client.setMonitored(value, for: item)
            onChange()
        } catch {
            monitored = !value
            show(error)
        }
    }

    private func delete(files: Bool) async {
        do {
            try await client.delete(item, deleteFiles: files)
            onChange()
            dismiss()
        } catch {
            show(error)
        }
    }
}

// MARK: - Add flow

struct AddItemView: View {
    let kind: ServerKind
    let client: ArrClient
    let onAdded: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var term = ""
    @State private var results: [ArrItem] = []
    @State private var isSearching = false
    @State private var hasSearched = false
    @State private var errorMessage: String?
    @State private var selected: ArrItem?

    var body: some View {
        NavigationStack {
            List {
                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
                ForEach(results) { item in
                    Button {
                        selected = item
                    } label: {
                        ArrItemRow(item: item, showStatus: false)
                    }
                    .buttonStyle(.plain)
                }
            }
            .listStyle(.plain)
            .overlay {
                if isSearching {
                    ProgressView()
                } else if results.isEmpty {
                    ContentUnavailableView(
                        hasSearched ? "No results" : "Search to add",
                        systemImage: "magnifyingglass",
                        description: Text(hasSearched ? "Try a different title." : "Type a title and tap Search.")
                    )
                }
            }
            .searchable(
                text: $term,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: kind == .sonarr ? "Search TV shows" : "Search movies"
            )
            .onSubmit(of: .search) { Task { await runSearch() } }
            .navigationTitle(kind == .sonarr ? "Add Show" : "Add Movie")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .sheet(item: $selected) { item in
                AddOptionsView(item: item, client: client) {
                    onAdded()
                    dismiss()
                }
            }
        }
    }

    private func runSearch() async {
        let trimmed = term.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 2 else { return }
        isSearching = true
        errorMessage = nil
        do {
            results = try await client.lookup(trimmed)
        } catch {
            if !isCancellation(error) { errorMessage = error.localizedDescription }
        }
        hasSearched = true
        isSearching = false
    }
}

private struct AddOptionsView: View {
    let item: ArrItem
    let client: ArrClient
    let onAdded: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var options: ArrAddOptions?
    @State private var profileID = 0
    @State private var folder = ""
    @State private var isAdding = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 12) {
                        PosterView(url: item.posterURL)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.title).font(.headline)
                            if let year = item.year {
                                Text(String(year)).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                if item.inLibrary {
                    Section {
                        Label("Already in your library", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                } else if let options {
                    Section {
                        Picker("Quality profile", selection: $profileID) {
                            ForEach(options.qualityProfiles) { profile in
                                Text(profile.name).tag(profile.id)
                            }
                        }
                        Picker("Root folder", selection: $folder) {
                            ForEach(options.rootFolders, id: \.self) { path in
                                Text(path).tag(path)
                            }
                        }
                    }
                    Section {
                        Button {
                            Task { await add() }
                        } label: {
                            if isAdding {
                                ProgressView()
                            } else {
                                Text("Add and search")
                            }
                        }
                        .disabled(isAdding || profileID == 0 || folder.isEmpty)
                    }
                } else if errorMessage == nil {
                    HStack {
                        ProgressView()
                        Text("Loading options…").foregroundStyle(.secondary)
                    }
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Add")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .task { await loadOptions() }
        }
    }

    private func loadOptions() async {
        do {
            let loaded = try await client.addOptions()
            options = loaded
            profileID = loaded.qualityProfiles.first?.id ?? 0
            folder = loaded.rootFolders.first ?? ""
        } catch {
            if !isCancellation(error) { errorMessage = error.localizedDescription }
        }
    }

    private func add() async {
        isAdding = true
        errorMessage = nil
        do {
            try await client.add(item, qualityProfileID: profileID, rootFolder: folder)
            onAdded()
            dismiss()
        } catch {
            if !isCancellation(error) { errorMessage = error.localizedDescription }
        }
        isAdding = false
    }
}

// MARK: - Episode details

struct EpisodeTarget: Identifiable {
    let seriesID: Int
    let episodeID: Int
    let seriesTitle: String
    var id: Int { episodeID }
}

struct EpisodeDetailView: View {
    let target: EpisodeTarget
    let client: ArrClient

    @Environment(\.dismiss) private var dismiss
    @State private var info: EpisodeInfo?
    @State private var errorMessage: String?
    @State private var notice: String?

    var body: some View {
        NavigationStack {
            Group {
                if let info {
                    details(info)
                } else if let errorMessage {
                    ContentUnavailableView(
                        "Couldn't load the episode",
                        systemImage: "exclamationmark.triangle",
                        description: Text(errorMessage)
                    )
                } else {
                    ProgressView("Loading…")
                }
            }
            .navigationTitle(target.seriesTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task { await load() }
            .alert(
                "Search",
                isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(notice ?? "")
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func details(_ info: EpisodeInfo) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let url = info.screenshotURL {
                    Color.clear
                        .aspectRatio(16.0 / 9.0, contentMode: .fit)
                        .overlay {
                            AsyncImage(url: url) { phase in
                                switch phase {
                                case .success(let image):
                                    image.resizable().scaledToFill()
                                default:
                                    Color.gray.opacity(0.2)
                                }
                            }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text(info.code)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(info.title)
                        .font(.title2.weight(.bold))
                    if let finale = info.finaleLabel {
                        Text(finale)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.orange.opacity(0.2), in: Capsule())
                    }
                }

                VStack(spacing: 8) {
                    fact("Aired", info.airDate.map { $0.formatted(date: .long, time: .omitted) } ?? "TBA")
                    if let minutes = info.runtimeMinutes {
                        fact("Runtime", "\(minutes) min")
                    }
                    fact("Status", status(info))
                }

                if let overview = info.overview, !overview.isEmpty {
                    Text(overview)
                } else {
                    Text("There's no synopsis for this episode on TheTVDB yet.")
                        .foregroundStyle(.secondary)
                }

                VStack(spacing: 10) {
                    if let url = info.tvdbURL {
                        Link(destination: url) {
                            Label("Open on TheTVDB", systemImage: "safari")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    Button {
                        Task { await search() }
                    } label: {
                        Label("Search for this episode", systemImage: "magnifyingglass")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding()
        }
    }

    private func fact(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value)
        }
        .font(.subheadline)
    }

    private func status(_ info: EpisodeInfo) -> String {
        if info.hasFile { return "Downloaded" }
        return info.monitored ? "Monitored, not downloaded yet" : "Not monitored"
    }

    private func load() async {
        do {
            info = try await client.episodeInfo(episodeID: target.episodeID, seriesID: target.seriesID)
        } catch {
            if !isCancellation(error) { errorMessage = error.localizedDescription }
        }
    }

    private func search() async {
        let entry = ArrEntry(
            id: "ep-\(target.episodeID)",
            itemID: target.seriesID,
            episodeID: target.episodeID,
            title: target.seriesTitle,
            detail: nil,
            date: nil,
            hasFile: false,
            monitored: true,
            season: nil,
            number: nil
        )
        do {
            try await client.search(entry: entry)
            notice = "Search started."
        } catch {
            if !isCancellation(error) { notice = "Couldn't start the search: \(error.localizedDescription)" }
        }
    }
}
