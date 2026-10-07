import Foundation

enum ServiceFactory {
    static func downloader(_ profile: ServerProfile, secret: String) -> DownloaderClient? {
        let http = HTTPClient.shared(allowSelfSigned: profile.allowSelfSignedCertificate)
        switch profile.kind {
        case .sabnzbd:
            return SABnzbdClient(baseURL: profile.baseURL, apiKey: secret, http: http)
        case .nzbget:
            return NZBGetClient(baseURL: profile.baseURL, username: profile.username, password: secret, http: http)
        default:
            return nil
        }
    }

    static func arr(_ profile: ServerProfile, secret: String) -> ArrClient? {
        let api = ArrHTTP(
            baseURL: profile.baseURL,
            apiKey: secret,
            http: HTTPClient.shared(allowSelfSigned: profile.allowSelfSignedCertificate)
        )
        switch profile.kind {
        case .sonarr: return SonarrClient(api: api)
        case .radarr: return RadarrClient(api: api)
        default: return nil
        }
    }

    static func indexer(_ profile: ServerProfile, secret: String) -> IndexerClient {
        IndexerClient(
            name: profile.name,
            baseURL: profile.baseURL,
            apiKey: secret,
            http: HTTPClient.shared(allowSelfSigned: profile.allowSelfSignedCertificate)
        )
    }

    static func test(_ profile: ServerProfile, secret: String) async throws -> String {
        switch profile.kind {
        case .sabnzbd, .nzbget:
            guard let client = downloader(profile, secret: secret) else { throw APIError.badURL }
            return try await client.testConnection()
        case .sonarr, .radarr:
            guard let client = arr(profile, secret: secret) else { throw APIError.badURL }
            return try await client.testConnection()
        case .indexer:
            return try await indexer(profile, secret: secret).testConnection()
        }
    }
}
