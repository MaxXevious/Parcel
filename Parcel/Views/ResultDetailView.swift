import SwiftUI

/// Opens when you tap an NZB search result: the release details, a Send button,
/// and links to read about the movie or show on TMDB or TheTVDB.
struct ResultDetailView: View {
    let result: NZBResult
    /// Name of the active downloader, or nil when none is set up.
    let downloaderName: String?
    let onSend: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var web: MediaLink?

    private var links: [MediaLink] { MediaLinks.links(for: result) }

    private var kindLabel: String? {
        switch MediaLinks.kind(of: result) {
        case .tv: return "TV show"
        case .movie: return "Movie"
        case .unknown: return nil
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(result.title)
                        .font(.headline)
                        .textSelection(.enabled)
                }

                Section("Details") {
                    if let kindLabel { fact("Looks like", kindLabel) }
                    if !result.category.isEmpty { fact("Category", result.category) }
                    fact("Size", result.sizeBytes.byteString)
                    if let date = result.date {
                        fact("Posted", "\(date.formatted(date: .abbreviated, time: .shortened)) (\(date.relativeString))")
                    }
                    if let grabs = result.grabs { fact("Grabs", String(grabs)) }
                    fact("Indexer", result.indexer)
                }

                Section {
                    if let name = downloaderName {
                        Button {
                            onSend()
                        } label: {
                            Label("Send to \(name)", systemImage: "arrow.down.circle.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                    } else {
                        Text("Add SABnzbd or NZBGet in Settings first, then you can send results to it.")
                            .foregroundStyle(.secondary)
                    }
                }

                if !links.isEmpty {
                    Section {
                        ForEach(links) { link in
                            Button {
                                web = link
                            } label: {
                                Label(link.title, systemImage: link.systemImage)
                            }
                        }
                    } header: {
                        Text("About this title")
                    } footer: {
                        if links.contains(where: { $0.isSearch }) {
                            Text("This indexer didn't tag the release with an ID, so these links search by the name in the release title.")
                        }
                    }
                }
            }
            .navigationTitle("Result")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(item: $web) { link in
                SafariView(url: link.url)
                    .ignoresSafeArea()
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func fact(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).multilineTextAlignment(.trailing)
        }
        .font(.subheadline)
    }
}
