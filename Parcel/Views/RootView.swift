import SwiftUI

struct RootView: View {
    var body: some View {
        TabView {
            DownloadsView()
                .tabItem { Label("Downloads", systemImage: "arrow.down.circle") }

            ArrRootView(kind: .sonarr)
                .tabItem { Label("TV", systemImage: "tv") }

            ArrRootView(kind: .radarr)
                .tabItem { Label("Movies", systemImage: "film") }

            IndexerSearchView()
                .tabItem { Label("Search", systemImage: "magnifyingglass") }

            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
    }
}

struct MissingServerView: View {
    let title: String
    let message: String

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: "server.rack")
        } description: {
            Text(message)
        }
    }
}

struct PosterView: View {
    let url: URL?
    var width: CGFloat = 46
    var height: CGFloat = 69

    var body: some View {
        AsyncImage(url: url) { phase in
            switch phase {
            case .success(let image):
                image.resizable().scaledToFill()
            default:
                ZStack {
                    Color.gray.opacity(0.2)
                    Image(systemName: "photo").foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}
