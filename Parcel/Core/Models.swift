import Foundation

enum ServerKind: String, Codable, CaseIterable, Identifiable {
    case sabnzbd, nzbget, sonarr, radarr, indexer

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sabnzbd: return "SABnzbd"
        case .nzbget: return "NZBGet"
        case .sonarr: return "Sonarr"
        case .radarr: return "Radarr"
        case .indexer: return "NZB Indexer"
        }
    }

    var sectionTitle: String {
        switch self {
        case .sabnzbd, .nzbget: return "Downloaders"
        case .sonarr: return "Sonarr"
        case .radarr: return "Radarr"
        case .indexer: return "NZB Indexers"
        }
    }

    var isDownloader: Bool { self == .sabnzbd || self == .nzbget }
    var usesUsername: Bool { self == .nzbget }

    var secretLabel: String {
        self == .nzbget ? "Password" : "API Key"
    }

    var urlPlaceholder: String {
        switch self {
        case .sabnzbd: return "http://192.168.1.10:8080"
        case .nzbget: return "http://192.168.1.10:6789"
        case .sonarr: return "http://192.168.1.10:8989"
        case .radarr: return "http://192.168.1.10:7878"
        case .indexer: return "https://api.your-indexer.com"
        }
    }

    var systemImage: String {
        switch self {
        case .sabnzbd, .nzbget: return "arrow.down.circle"
        case .sonarr: return "tv"
        case .radarr: return "film"
        case .indexer: return "magnifyingglass"
        }
    }
}

/// A saved server. The API key / password lives in the Keychain, keyed by `id`.
struct ServerProfile: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var kind: ServerKind
    var name: String
    var baseURL: String
    var username: String = ""
    var allowSelfSignedCertificate: Bool = false
}
