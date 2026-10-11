import SwiftUI

@MainActor
final class ReleaseSearchViewModel: ObservableObject {
    @Published var releases: [ArrRelease] = []
    @Published var isSearching = false
    @Published var hasSearched = false
    @Published var errorMessage: String?
    @Published var notice: String?
    @Published var grabbingID: String?

    private let client: ArrClient
    private let episodeID: Int
    /// Bumped on every search so an older, slower search can't overwrite newer results.
    private var generation = 0

    init(client: ArrClient, episodeID: Int) {
        self.client = client
        self.episodeID = episodeID
    }

    func search() async {
        generation += 1
        let mine = generation
        isSearching = true
        errorMessage = nil

        var found: [ArrRelease] = []
        var failure: String?
        do {
            found = try await client.releases(episodeID: episodeID)
        } catch {
            if isCancellation(error) { return }
            failure = error.localizedDescription
        }

        guard mine == generation else { return }
        releases = found
        errorMessage = failure
        hasSearched = true
        isSearching = false
    }

    func grab(_ release: ArrRelease) async {
        grabbingID = release.id
        do {
            try await client.grab(release)
            notice = "Sent to Sonarr. It will start downloading shortly, and you can follow it in the Activity section."
        } catch {
            if !isCancellation(error) {
                notice = "Couldn't download it: \(error.localizedDescription)"
            }
        }
        grabbingID = nil
    }
}

// MARK: - Screen

struct ReleaseListView: View {
    let subtitle: String

    @StateObject private var vm: ReleaseSearchViewModel
    @State private var sort: ReleaseSort = .best
    @State private var hideRejected = false
    @State private var selected: ArrRelease?

    enum ReleaseSort: String, CaseIterable, Identifiable {
        case best = "Best match"
        case newest = "Newest"
        case largest = "Largest"
        var id: String { rawValue }
    }

    init(target: EpisodeTarget, client: ArrClient, subtitle: String) {
        self.subtitle = subtitle
        _vm = StateObject(wrappedValue: ReleaseSearchViewModel(client: client, episodeID: target.episodeID))
    }

    private var visible: [ArrRelease] {
        let base = hideRejected ? vm.releases.filter { $0.approved } : vm.releases
        switch sort {
        case .best:
            return base.sorted { first, second in
                if first.approved != second.approved { return first.approved }
                return first.weight < second.weight
            }
        case .newest:
            return base.sorted { $0.ageMinutes < $1.ageMinutes }
        case .largest:
            return base.sorted { $0.sizeBytes > $1.sizeBytes }
        }
    }

    private var summary: String {
        let approved = vm.releases.filter { $0.approved }.count
        return "\(vm.releases.count) found · \(approved) accepted by Sonarr"
    }

    var body: some View {
        List {
            if !vm.releases.isEmpty {
                Section {
                    if visible.isEmpty {
                        Text("Everything found was rejected. Turn off “Hide rejected” in the menu to see it.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(visible) { release in
                        Button {
                            selected = release
                        } label: {
                            ReleaseRow(release: release, isBusy: vm.grabbingID == release.id)
                        }
                        .buttonStyle(.plain)
                        .disabled(vm.grabbingID != nil)
                    }
                } header: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(subtitle).font(.headline)
                        Text(summary).font(.caption)
                    }
                    .textCase(nil)
                }
            }
        }
        .listStyle(.plain)
        .overlay { stateOverlay }
        .navigationTitle("Releases")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if vm.isSearching {
                    ProgressView()
                } else {
                    Menu {
                        Picker("Sort", selection: $sort) {
                            ForEach(ReleaseSort.allCases) { Text($0.rawValue).tag($0) }
                        }
                        Toggle("Hide rejected", isOn: $hideRejected)
                        Button {
                            Task { await vm.search() }
                        } label: {
                            Label("Search again", systemImage: "arrow.clockwise")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("Sort and filter")
                }
            }
        }
        .task {
            if !vm.hasSearched { await vm.search() }
        }
        .confirmationDialog(
            selected?.title ?? "",
            isPresented: Binding(get: { selected != nil }, set: { if !$0 { selected = nil } }),
            titleVisibility: .visible,
            presenting: selected
        ) { release in
            if release.approved {
                Button("Download") {
                    Task { await vm.grab(release) }
                }
            } else {
                Button("Download anyway", role: .destructive) {
                    Task { await vm.grab(release) }
                }
            }
        } message: { release in
            if release.approved {
                Text("\(release.quality) · \(release.sizeBytes.byteString) · \(release.indexer)")
            } else {
                Text("Sonarr rejected this release:\n" + release.rejections.joined(separator: "\n"))
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

    @ViewBuilder
    private var stateOverlay: some View {
        if vm.isSearching && vm.releases.isEmpty {
            VStack(spacing: 12) {
                ProgressView()
                Text("Asking your indexers…\nThis can take up to a minute.")
                    .multilineTextAlignment(.center)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } else if let message = vm.errorMessage, vm.releases.isEmpty {
            ContentUnavailableView {
                Label("Search failed", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again") { Task { await vm.search() } }
            }
        } else if vm.hasSearched && vm.releases.isEmpty {
            ContentUnavailableView(
                "No releases found",
                systemImage: "magnifyingglass",
                description: Text("None of the indexers in Sonarr returned anything for this episode. It may not have been posted yet.")
            )
        }
    }
}

// MARK: - Row

private struct ReleaseRow: View {
    let release: ArrRelease
    let isBusy: Bool

    private var ageText: String {
        let minutes = release.ageMinutes
        if minutes < 60 { return "\(Int(minutes))m" }
        let hours = minutes / 60
        if hours < 48 { return "\(Int(hours))h" }
        let days = hours / 24
        if days < 365 { return "\(Int(days))d" }
        return String(format: "%.1fy", days / 365)
    }

    private var sourceLine: String {
        var parts = [release.indexer]
        if let group = release.releaseGroup { parts.append(group) }
        if release.isTorrent {
            parts.append(release.seeders.map { "torrent, \($0) seeders" } ?? "torrent")
        }
        return parts.joined(separator: " · ")
    }

    private var showsLanguage: Bool {
        guard let language = release.language else { return false }
        return language != "English" && language != "Unknown"
    }

    private var rejectionText: String? {
        guard !release.approved, let first = release.rejections.first else { return nil }
        let extra = release.rejections.count - 1
        return extra > 0 ? "\(first) (+\(extra) more)" : first
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 6) {
                Text(release.title)
                    .font(.subheadline)
                    .lineLimit(3)

                HStack(spacing: 6) {
                    Chip(text: release.quality)
                    if showsLanguage, let language = release.language {
                        Chip(text: language, tint: .purple)
                    }
                    Text(release.sizeBytes.byteString)
                    Text(ageText)
                    Spacer(minLength: 0)
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                Text(sourceLine)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)

                if let text = rejectionText {
                    Label(text, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
            if isBusy { ProgressView() }
        }
        .opacity(release.approved ? 1 : 0.65)
        .contentShape(Rectangle())
        .padding(.vertical, 2)
    }
}

private struct Chip: View {
    let text: String
    var tint: Color = .accentColor

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(tint.opacity(0.15), in: Capsule())
    }
}
