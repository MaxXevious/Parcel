import Foundation

struct SonarrClient: ArrClient {
    let api: ArrHTTP

    private struct Series: Decodable {
        let id: Int?
        let title: String?
        let year: Int?
        let status: String?
        let network: String?
        let overview: String?
        let monitored: Bool?
        let tvdbId: Int?
        let images: [ArrImage]?
        let statistics: Statistics?

        struct Statistics: Decodable {
            let episodeFileCount: Int?
            let episodeCount: Int?
            let sizeOnDisk: Int64?
        }
    }

    private struct Episode: Decodable {
        let id: Int?
        let seriesId: Int?
        let title: String?
        let seasonNumber: Int?
        let episodeNumber: Int?
        let airDateUtc: String?
        let hasFile: Bool?
        let monitored: Bool?
        let series: SeriesRef?

        struct SeriesRef: Decodable {
            let title: String?
        }
    }

    private func item(from series: Series) -> ArrItem {
        let have = series.statistics?.episodeFileCount ?? 0
        let total = series.statistics?.episodeCount ?? 0
        let parts = [series.network, series.status?.capitalized].compactMap { $0 }.filter { !$0.isEmpty }
        return ArrItem(
            arrID: series.id ?? 0,
            externalID: series.tvdbId ?? 0,
            title: series.title ?? "Untitled",
            year: series.year,
            subtitle: parts.isEmpty ? nil : parts.joined(separator: " · "),
            overview: series.overview,
            posterURL: api.poster(from: series.images),
            monitored: series.monitored ?? false,
            statusText: total > 0 ? "\(have)/\(total) episodes" : "No episodes yet",
            progress: total > 0 ? Double(have) / Double(total) : nil,
            sizeOnDisk: series.statistics?.sizeOnDisk ?? 0,
            lookupPayload: nil
        )
    }

    private func entry(from episode: Episode, seriesTitle: String? = nil) -> ArrEntry {
        var detail = episodeCode(episode.seasonNumber, episode.episodeNumber)
        if let name = episode.title, !name.isEmpty { detail += " · " + name }
        return ArrEntry(
            id: "ep-\(episode.id ?? 0)",
            itemID: episode.seriesId ?? 0,
            episodeID: episode.id,
            title: episode.series?.title ?? seriesTitle ?? "Unknown series",
            detail: detail,
            date: DateParse.iso(episode.airDateUtc),
            hasFile: episode.hasFile ?? false,
            monitored: episode.monitored ?? false,
            season: episode.seasonNumber,
            number: episode.episodeNumber
        )
    }

    // MARK: ArrClient

    func testConnection() async throws -> String {
        let status = try await api.fetch(ArrSystemStatus.self, "/api/v3/system/status")
        return "Sonarr \(status.version ?? "")".trimmingCharacters(in: .whitespaces)
    }

    func library() async throws -> [ArrItem] {
        let list = try await api.fetch([Series].self, "/api/v3/series")
        return list.map(item(from:)).sorted {
            $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
    }

    func calendar(start: Date, end: Date) async throws -> [ArrEntry] {
        let episodes = try await api.fetch([Episode].self, "/api/v3/calendar", query: [
            ("start", DateParse.day(start)),
            ("end", DateParse.day(end)),
            ("includeSeries", "true"),
            ("unmonitored", "false")
        ])
        return episodes.map { entry(from: $0) }.sorted {
            ($0.date ?? .distantFuture) < ($1.date ?? .distantFuture)
        }
    }

    func wanted() async throws -> [ArrEntry] {
        let page = try await api.fetch(ArrPage<Episode>.self, "/api/v3/wanted/missing", query: [
            ("page", "1"),
            ("pageSize", "100"),
            ("sortKey", "airDateUtc"),
            ("sortDirection", "descending"),
            ("includeSeries", "true"),
            ("monitored", "true")
        ])
        return (page.records ?? []).map { entry(from: $0) }
    }

    func queue() async throws -> [ArrQueueEntry] {
        let page = try await api.fetch(ArrPage<ArrQueueRecord>.self, "/api/v3/queue", query: [
            ("page", "1"),
            ("pageSize", "100"),
            ("includeSeries", "true"),
            ("includeEpisode", "true")
        ])
        return (page.records ?? []).map { $0.toEntry() }
    }

    func lookup(_ term: String) async throws -> [ArrItem] {
        let data = try await api.get("/api/v3/series/lookup", query: [("term", term)])
        guard let raw = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return raw.compactMap { object in
            guard let payload = try? JSONSerialization.data(withJSONObject: object),
                  let series = try? JSONDecoder().decode(Series.self, from: payload) else { return nil }
            var result = item(from: series)
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
            throw APIError.message("The series details are missing. Search for it again.")
        }
        object["qualityProfileId"] = qualityProfileID
        object["rootFolderPath"] = rootFolder
        object["monitored"] = true
        object["seasonFolder"] = true
        object["addOptions"] = ["monitor": "all", "searchForMissingEpisodes": true] as [String: Any]
        // Sonarr v3 still requires a language profile; v4 removed the endpoint (404), so this is best-effort.
        if let languages = try? await api.fetch([ArrQualityProfile].self, "/api/v3/languageprofile"),
           let first = languages.first {
            object["languageProfileId"] = first.id
        }
        try await api.send("POST", "/api/v3/series", json: object)
    }

    func search(item: ArrItem) async throws {
        try await api.command(["name": "SeriesSearch", "seriesId": item.arrID])
    }

    func search(entry: ArrEntry) async throws {
        if let episodeID = entry.episodeID {
            try await api.command(["name": "EpisodeSearch", "episodeIds": [episodeID]])
        } else {
            try await api.command(["name": "SeriesSearch", "seriesId": entry.itemID])
        }
    }

    func searchAllMissing() async throws {
        try await api.command(["name": "MissingEpisodeSearch"])
    }

    func episodes(for item: ArrItem) async throws -> [ArrEntry] {
        let list = try await api.fetch([Episode].self, "/api/v3/episode", query: [("seriesId", String(item.arrID))])
        return list.map { entry(from: $0, seriesTitle: item.title) }
    }

    func setMonitored(_ monitored: Bool, for item: ArrItem) async throws {
        try await api.setMonitored(monitored, path: "/api/v3/series/\(item.arrID)")
    }

    func delete(_ item: ArrItem, deleteFiles: Bool) async throws {
        try await api.send("DELETE", "/api/v3/series/\(item.arrID)", query: [
            ("deleteFiles", deleteFiles ? "true" : "false"),
            ("addImportListExclusion", "false")
        ])
    }
}
