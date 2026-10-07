import Foundation

struct NZBGetClient: DownloaderClient {
    let baseURL: String
    let username: String
    let password: String
    let http: HTTPClient

    // MARK: Plumbing

    private struct RPCResponse<Result: Decodable>: Decodable {
        let result: Result
    }

    private func rpc(_ method: String, _ params: [Any] = []) async throws -> Data {
        let url = try URLBuilder.make(base: baseURL, path: "/jsonrpc")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let token = Data("\(username):\(password)".utf8).base64EncodedString()
        request.setValue("Basic \(token)", forHTTPHeaderField: "Authorization")
        let body: [String: Any] = ["method": method, "params": params, "id": 1]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await http.send(request)
    }

    private func result<R: Decodable>(_ type: R.Type, _ method: String, _ params: [Any] = []) async throws -> R {
        let data = try await rpc(method, params)
        return try http.decode(RPCResponse<R>.self, from: data).result
    }

    private func edit(_ command: String, id: String) async throws {
        guard let number = Int(id) else { throw APIError.badResponse }
        let ok = try await result(Bool.self, "editqueue", [command, "", [number]])
        if !ok { throw APIError.message("NZBGet rejected that action.") }
    }

    private struct QueueGroup: Decodable {
        let NZBID: Int?
        let NZBName: String?
        let Status: String?
        let FileSizeMB: Flex?
        let RemainingSizeMB: Flex?
        let Category: String?
    }

    private struct ServerStatus: Decodable {
        let RemainingSizeMB: Flex?
        let DownloadRate: Flex?
        let DownloadPaused: Flex?
        let DownloadLimit: Flex?
    }

    private struct HistoryEntry: Decodable {
        let NZBID: Int?
        let Name: String?
        let Status: String?
        let FileSizeMB: Flex?
        let Category: String?
        let HistoryTime: Flex?
    }

    private static func prettify(_ status: String) -> String {
        status.replacingOccurrences(of: "_", with: " ").capitalized
    }

    // MARK: DownloaderClient

    func testConnection() async throws -> String {
        let version = try await result(String.self, "version")
        return "NZBGet \(version)"
    }

    func fetchQueue() async throws -> DownloaderSnapshot {
        async let groupsTask = result([QueueGroup].self, "listgroups")
        async let statusTask = result(ServerStatus.self, "status")
        let (groups, server) = try await (groupsTask, statusTask)

        let rate = server.DownloadRate?.int64 ?? 0
        let items = groups.map { group -> DownloadItem in
            let total = (group.FileSizeMB?.int64 ?? 0) * 1_048_576
            let remaining = (group.RemainingSizeMB?.int64 ?? 0) * 1_048_576
            let raw = group.Status ?? ""
            var eta: String?
            if raw == "DOWNLOADING", rate > 0, remaining > 0 {
                let seconds = Int(remaining / rate)
                eta = String(format: "%d:%02d:%02d", seconds / 3600, (seconds % 3600) / 60, seconds % 60)
            }
            return DownloadItem(
                id: String(group.NZBID ?? 0),
                name: group.NZBName ?? "Unknown",
                status: Self.prettify(raw),
                progress: total > 0 ? min(max(1 - Double(remaining) / Double(total), 0), 1) : 0,
                sizeBytes: total,
                remainingBytes: remaining,
                eta: eta,
                category: group.Category,
                isPaused: raw == "PAUSED"
            )
        }

        let status = DownloaderStatus(
            speedBytesPerSec: rate,
            isPaused: server.DownloadPaused?.bool ?? false,
            remainingBytes: (server.RemainingSizeMB?.int64 ?? 0) * 1_048_576,
            speedLimitBytesPerSec: server.DownloadLimit?.int64 ?? 0
        )
        return DownloaderSnapshot(status: status, items: items)
    }

    func fetchHistory(limit: Int) async throws -> [HistoryItem] {
        let entries = try await result([HistoryEntry].self, "history", [false])
        return entries.prefix(limit).map { entry in
            let status = entry.Status ?? ""
            return HistoryItem(
                id: String(entry.NZBID ?? 0),
                name: entry.Name ?? "Unknown",
                status: Self.prettify(status),
                sizeBytes: (entry.FileSizeMB?.int64 ?? 0) * 1_048_576,
                category: entry.Category,
                completed: entry.HistoryTime.map { Date(timeIntervalSince1970: $0.double) },
                failed: status.hasPrefix("FAILURE")
            )
        }
    }

    func pauseAll() async throws {
        _ = try await result(Bool.self, "pausedownload")
    }

    func resumeAll() async throws {
        _ = try await result(Bool.self, "resumedownload")
    }

    func pause(id: String) async throws { try await edit("GroupPause", id: id) }
    func resume(id: String) async throws { try await edit("GroupResume", id: id) }
    func delete(id: String) async throws { try await edit("GroupDelete", id: id) }
    var deletesFilesWithHistory: Bool { false }

    func deleteHistory(id: String, deleteFiles: Bool) async throws {
        try await edit("HistoryDelete", id: id)
    }

    func setSpeedLimit(bytesPerSec: Int64) async throws {
        // NZBGet's `rate` call takes KB/s; 0 removes the limit.
        _ = try await result(Bool.self, "rate", [Int(max(bytesPerSec, 0) / 1024)])
    }

    func addURL(_ url: String, name: String?) async throws {
        let cleaned = (name ?? "download").replacingOccurrences(of: "/", with: "-")
        let params: [Any] = [
            cleaned + ".nzb",   // NZBFilename
            url,                // NZBContent (a URL is fetched by NZBGet)
            "",                 // Category
            0,                  // Priority
            false,              // AddToTop
            false,              // AddPaused
            "",                 // DupeKey
            0,                  // DupeScore
            "SCORE",            // DupeMode
            [Any]()             // PPParameters
        ]
        let id = try await result(Int.self, "append", params)
        if id <= 0 { throw APIError.message("NZBGet couldn't add that download.") }
    }
}
