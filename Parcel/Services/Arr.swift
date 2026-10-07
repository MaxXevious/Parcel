import Foundation

// MARK: - Unified models shared by Sonarr and Radarr

/// A series (Sonarr) or movie (Radarr), either from the library or from a lookup.
struct ArrItem: Identifiable, Hashable {
    var arrID: Int                 // 0 when not yet in the library
    var externalID: Int            // tvdbId / tmdbId
    var title: String
    var year: Int?
    var subtitle: String?
    var overview: String?
    var posterURL: URL?
    var monitored: Bool
    var statusText: String
    var progress: Double?
    var sizeOnDisk: Int64
    var lookupPayload: Data?       // raw lookup JSON, re-posted when adding

    var id: String { "\(arrID)-\(externalID)" }
    var inLibrary: Bool { arrID > 0 }
}

/// An episode (Sonarr) or a movie release (Radarr) shown in calendar/wanted lists.
struct ArrEntry: Identifiable, Hashable {
    var id: String
    var itemID: Int
    var episodeID: Int?
    var title: String
    var detail: String?
    var date: Date?
    var hasFile: Bool
    var monitored: Bool
    var season: Int?
    var number: Int?
}

struct ArrQueueEntry: Identifiable, Hashable {
    var id: Int
    var title: String
    var detail: String?
    var status: String
    var progress: Double
    var timeLeft: String?
    var warning: String?
}

struct ArrQualityProfile: Identifiable, Decodable, Hashable {
    let id: Int
    let name: String
}

struct ArrAddOptions {
    var qualityProfiles: [ArrQualityProfile]
    var rootFolders: [String]
}

protocol ArrClient: Sendable {
    func testConnection() async throws -> String
    func library() async throws -> [ArrItem]
    func calendar(start: Date, end: Date) async throws -> [ArrEntry]
    func wanted() async throws -> [ArrEntry]
    func queue() async throws -> [ArrQueueEntry]
    func lookup(_ term: String) async throws -> [ArrItem]
    func addOptions() async throws -> ArrAddOptions
    func add(_ item: ArrItem, qualityProfileID: Int, rootFolder: String) async throws
    func search(item: ArrItem) async throws
    func search(entry: ArrEntry) async throws
    func searchAllMissing() async throws
    func episodes(for item: ArrItem) async throws -> [ArrEntry]
    func setMonitored(_ monitored: Bool, for item: ArrItem) async throws
    func delete(_ item: ArrItem, deleteFiles: Bool) async throws
}

// MARK: - HTTP helper (both apps use the same v3 REST conventions)

struct ArrHTTP: Sendable {
    let baseURL: String
    let apiKey: String
    let http: HTTPClient

    func request(_ method: String, _ path: String, query: [(String, String)] = [], json: Any? = nil) throws -> URLRequest {
        let url = try URLBuilder.make(base: baseURL, path: path, query: query)
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(apiKey, forHTTPHeaderField: "X-Api-Key")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let json {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: json)
        }
        return request
    }

    func get(_ path: String, query: [(String, String)] = []) async throws -> Data {
        try await http.send(try request("GET", path, query: query))
    }

    func fetch<T: Decodable>(_ type: T.Type, _ path: String, query: [(String, String)] = []) async throws -> T {
        let data = try await get(path, query: query)
        return try http.decode(type, from: data)
    }

    @discardableResult
    func send(_ method: String, _ path: String, query: [(String, String)] = [], json: Any? = nil) async throws -> Data {
        try await http.send(try request(method, path, query: query, json: json))
    }

    func command(_ body: [String: Any]) async throws {
        try await send("POST", "/api/v3/command", json: body)
    }

    /// Fetches the full object, flips `monitored`, and PUTs it back.
    func setMonitored(_ monitored: Bool, path: String) async throws {
        let data = try await get(path)
        guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw APIError.badResponse
        }
        object["monitored"] = monitored
        try await send("PUT", path, json: object)
    }

    func addOptions() async throws -> ArrAddOptions {
        async let profiles = fetch([ArrQualityProfile].self, "/api/v3/qualityprofile")
        async let folders = fetch([ArrRootFolder].self, "/api/v3/rootfolder")
        let (p, f) = try await (profiles, folders)
        return ArrAddOptions(qualityProfiles: p, rootFolders: f.compactMap { $0.path })
    }

    func poster(from images: [ArrImage]?) -> URL? {
        guard let images, let image = images.first(where: { $0.coverType == "poster" }) ?? images.first else {
            return nil
        }
        if let remote = image.remoteUrl, !remote.isEmpty, let url = URL(string: remote) {
            return url
        }
        if let local = image.url, !local.isEmpty {
            let separator = local.contains("?") ? "&" : "?"
            let text = URLBuilder.normalizedBase(baseURL) + local + separator + "apikey=" + URLBuilder.encode(apiKey)
            return URL(string: text)
        }
        return nil
    }
}

// MARK: - Shared decodables

struct ArrSystemStatus: Decodable {
    let appName: String?
    let version: String?
}

struct ArrPage<T: Decodable>: Decodable {
    let records: [T]?
}

struct ArrImage: Decodable {
    let coverType: String?
    let remoteUrl: String?
    let url: String?
}

struct ArrRootFolder: Decodable {
    let path: String?
}

struct ArrQueueRecord: Decodable {
    let id: Int?
    let title: String?
    let status: String?
    let size: Double?
    let sizeleft: Double?
    let timeleft: String?
    let errorMessage: String?
    let trackedDownloadStatus: String?
    let series: Ref?
    let episode: Episode?
    let movie: Ref?

    struct Ref: Decodable {
        let title: String?
        let year: Int?
    }

    struct Episode: Decodable {
        let title: String?
        let seasonNumber: Int?
        let episodeNumber: Int?
    }

    func toEntry() -> ArrQueueEntry {
        let total = size ?? 0
        let left = sizeleft ?? 0
        var detail: String?
        if let episode {
            detail = episodeCode(episode.seasonNumber, episode.episodeNumber)
            if let name = episode.title, !name.isEmpty { detail = (detail ?? "") + " · " + name }
        } else if let year = movie?.year {
            detail = String(year)
        }
        let heading = series?.title ?? movie?.title ?? title ?? "Unknown"
        return ArrQueueEntry(
            id: id ?? abs((title ?? "").hashValue),
            title: heading,
            detail: detail,
            status: (status ?? "").capitalized,
            progress: total > 0 ? min(max(1 - left / total, 0), 1) : 0,
            timeLeft: timeleft,
            warning: trackedDownloadStatus == "warning" ? (errorMessage ?? "Warning") : nil
        )
    }
}
