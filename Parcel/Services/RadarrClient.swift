import Foundation

struct RadarrClient: ArrClient {
    let api: ArrHTTP

    private struct Movie: Decodable {
        let id: Int?
        let title: String?
        let year: Int?
        let overview: String?
        let studio: String?
        let monitored: Bool?
        let hasFile: Bool?
        let isAvailable: Bool?
        let tmdbId: Int?
        let sizeOnDisk: Int64?
        let images: [ArrImage]?
        let inCinemas: String?
        let digitalRelease: String?
        let physicalRelease: String?

        /// Picks the release date that falls inside `range` if there is one, otherwise the first known date.
        func release(in range: ClosedRange<Date>? = nil) -> (date: Date, label: String)? {
            let candidates: [(Date?, String)] = [
                (DateParse.iso(digitalRelease), "Digital"),
                (DateParse.iso(physicalRelease), "Physical"),
                (DateParse.iso(inCinemas), "Cinemas")
            ]
            let valid: [(date: Date, label: String)] = candidates.compactMap { pair in
                guard let date = pair.0 else { return nil }
                return (date: date, label: pair.1)
            }
            if let range, let hit = valid.first(where: { range.contains($0.date) }) { return hit }
            return valid.first
        }
    }

    private func item(from movie: Movie) -> ArrItem {
        let hasFile = movie.hasFile ?? false
        let status: String
        if hasFile {
            status = "Downloaded"
        } else if movie.isAvailable == false {
            status = "Not released yet"
        } else {
            status = movie.monitored == true ? "Missing" : "Unmonitored"
        }
        return ArrItem(
            arrID: movie.id ?? 0,
            externalID: movie.tmdbId ?? 0,
            title: movie.title ?? "Untitled",
            year: movie.year,
            subtitle: movie.studio,
            overview: movie.overview,
            posterURL: api.poster(from: movie.images),
            monitored: movie.monitored ?? false,
            statusText: status,
            progress: hasFile ? 1 : nil,
            sizeOnDisk: movie.sizeOnDisk ?? 0,
            lookupPayload: nil
        )
    }

    private func entry(from movie: Movie, range: ClosedRange<Date>? = nil) -> ArrEntry {
        let release = movie.release(in: range)
        var detail = release?.label ?? ""
        if let year = movie.year {
            detail = detail.isEmpty ? String(year) : "\(detail) · \(year)"
        }
        return ArrEntry(
            id: "movie-\(movie.id ?? 0)",
            itemID: movie.id ?? 0,
            episodeID: nil,
            title: movie.title ?? "Untitled",
            detail: detail.isEmpty ? nil : detail,
            date: release?.date,
            hasFile: movie.hasFile ?? false,
            monitored: movie.monitored ?? false,
            season: nil,
            number: nil
        )
    }

    // MARK: ArrClient

    func testConnection() async throws -> String {
        let status = try await api.fetch(ArrSystemStatus.self, "/api/v3/system/status")
        return "Radarr \(status.version ?? "")".trimmingCharacters(in: .whitespaces)
    }

    func library() async throws -> [ArrItem] {
        let list = try await api.fetch([Movie].self, "/api/v3/movie")
        return list.map(item(from:)).sorted {
            $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
    }

    func calendar(start: Date, end: Date) async throws -> [ArrEntry] {
        let movies = try await api.fetch([Movie].self, "/api/v3/calendar", query: [
            ("start", DateParse.day(start)),
            ("end", DateParse.day(end)),
            ("unmonitored", "false")
        ])
        return movies.map { entry(from: $0, range: start...end) }.sorted {
            ($0.date ?? .distantFuture) < ($1.date ?? .distantFuture)
        }
    }

    func wanted() async throws -> [ArrEntry] {
        let page = try await api.fetch(ArrPage<Movie>.self, "/api/v3/wanted/missing", query: [
            ("page", "1"),
            ("pageSize", "100"),
            ("monitored", "true")
        ])
        return (page.records ?? []).map { entry(from: $0) }
    }

    func queue() async throws -> [ArrQueueEntry] {
        let page = try await api.fetch(ArrPage<ArrQueueRecord>.self, "/api/v3/queue", query: [
            ("page", "1"),
            ("pageSize", "100"),
            ("includeMovie", "true")
        ])
        return (page.records ?? []).map { $0.toEntry() }
    }

    func lookup(_ term: String) async throws -> [ArrItem] {
        let data = try await api.get("/api/v3/movie/lookup", query: [("term", term)])
        guard let raw = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return raw.compactMap { object in
            guard let payload = try? JSONSerialization.data(withJSONObject: object),
                  let movie = try? JSONDecoder().decode(Movie.self, from: payload) else { return nil }
            var result = item(from: movie)
            result.lookupPayload = payload
            return result
        }
    }

    func addOptions() async throws -> ArrAddOptions {
        try await api.addOptions()
    }

    func add(_ item: ArrItem, qualityProfileID: Int, rootFolder: String) async throws {
        guard let payload = item.lookupPayload,
              var object = try JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
            throw APIError.message("The movie details are missing. Search for it again.")
        }
        object["qualityProfileId"] = qualityProfileID
        object["rootFolderPath"] = rootFolder
        object["monitored"] = true
        object["minimumAvailability"] = "released"
        object["addOptions"] = ["searchForMovie": true] as [String: Any]
        try await api.send("POST", "/api/v3/movie", json: object)
    }

    func search(item: ArrItem) async throws {
        try await api.command(["name": "MoviesSearch", "movieIds": [item.arrID]])
    }

    func search(entry: ArrEntry) async throws {
        try await api.command(["name": "MoviesSearch", "movieIds": [entry.itemID]])
    }

    func searchAllMissing() async throws {
        try await api.command(["name": "MissingMoviesSearch"])
    }

    func episodes(for item: ArrItem) async throws -> [ArrEntry] {
        []
    }

    func episodeInfo(episodeID: Int, seriesID: Int) async throws -> EpisodeInfo {
        throw APIError.message("Episode details are only available for TV shows.")
    }

    func setMonitored(_ monitored: Bool, for item: ArrItem) async throws {
        try await api.setMonitored(monitored, path: "/api/v3/movie/\(item.arrID)")
    }

    func delete(_ item: ArrItem, deleteFiles: Bool) async throws {
        try await api.send("DELETE", "/api/v3/movie/\(item.arrID)", query: [
            ("deleteFiles", deleteFiles ? "true" : "false"),
            ("addImportExclusion", "false")
        ])
    }
}
