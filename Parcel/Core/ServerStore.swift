import Foundation

@MainActor
final class ServerStore: ObservableObject {
    @Published private(set) var profiles: [ServerProfile] = []
    /// Bumps whenever a server is saved or deleted so screens rebuild their clients.
    @Published private(set) var revision = 0
    @Published var activeDownloaderID: UUID? {
        didSet {
            UserDefaults.standard.set(activeDownloaderID?.uuidString, forKey: Self.activeKey)
        }
    }

    private static let profilesKey = "parcel.profiles.v1"
    private static let activeKey = "parcel.activeDownloader.v1"

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.profilesKey),
           let decoded = try? JSONDecoder().decode([ServerProfile].self, from: data) {
            profiles = decoded
        }
        if let text = UserDefaults.standard.string(forKey: Self.activeKey) {
            activeDownloaderID = UUID(uuidString: text)
        }
    }

    var downloaders: [ServerProfile] { profiles.filter { $0.kind.isDownloader } }
    var indexers: [ServerProfile] { profiles.filter { $0.kind == .indexer } }

    var activeDownloader: ServerProfile? {
        if let id = activeDownloaderID, let match = profiles.first(where: { $0.id == id }) {
            return match
        }
        return downloaders.first
    }

    func first(of kind: ServerKind) -> ServerProfile? {
        profiles.first { $0.kind == kind }
    }

    func profiles(of kind: ServerKind) -> [ServerProfile] {
        profiles.filter { $0.kind == kind }
    }

    func secret(for profile: ServerProfile) -> String {
        Keychain.get(profile.id.uuidString)
    }

    func save(_ profile: ServerProfile, secret: String) {
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[index] = profile
        } else {
            profiles.append(profile)
        }
        Keychain.set(secret, for: profile.id.uuidString)
        if profile.kind.isDownloader && activeDownloaderID == nil {
            activeDownloaderID = profile.id
        }
        persist()
    }

    func delete(_ profile: ServerProfile) {
        profiles.removeAll { $0.id == profile.id }
        Keychain.delete(profile.id.uuidString)
        if activeDownloaderID == profile.id {
            activeDownloaderID = downloaders.first?.id
        }
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(profiles) {
            UserDefaults.standard.set(data, forKey: Self.profilesKey)
        }
        revision += 1
    }
}
