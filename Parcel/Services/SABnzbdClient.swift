import Foundation

struct SABnzbdClient: DownloaderClient {
    let baseURL: String
    let apiKey: String
    let http: HTTPClient

    // MARK: Plumbing

    @discardableResult
    private func call(_ mode: String, _ extra: [(String, String)] = []) async throws -> Data {
        var query: [(String, String)] = [("mode", mode), ("output", "json"), ("apikey", apiKey)]
        query.append(contentsOf: extra)
        let url = try URLBuilder.make(base: baseURL, path: "/api", query: query)
        let data = try await http.send(URLRequest(url: url))
        // SABnzbd reports bad keys etc. as HTTP 200 with {"status": false, "error": "..."}.
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let error = object["error"] as? String {
            throw APIError.message(error)
        }
        return data
    }

    private struct QueueEnvelope: Decodable {
        let queue: Queue

        struct Queue: Decodable {
            let paused: Flex?
            let kbpersec: Flex?
            let mbleft: Flex?
            let speedlimit_abs: Flex?
            let slots: [Slot]?
        }

        struct Slot: Decodable {
            let nzo_id: String?
            let filename: String?
            let status: String?
            let percentage: Flex?
            let mb: Flex?
            let mbleft: Flex?
            let timeleft: String?
            let cat: String?
        }
    }

    private struct HistoryEnvelope: Decodable {
        let history: History

        struct History: Decodable {
            let slots: [Slot]?
        }

        struct Slot: Decodable {
            let nzo_id: String?
            let name: String?
            let status: String?
            let bytes: Flex?
            let category: String?
            let completed: Flex?
        }
    }

    // MARK: DownloaderClient

    func testConnection() async throws -> String {
        let versionData = try await call("version")
        var version = ""
        if let object = try? JSONSerialization.jsonObject(with: versionData) as? [String: Any],
           let text = object["version"] as? String {
            version = text
        }
        // `version` doesn't need a key, so also hit an endpoint that does.
        try await call("queue", [("limit", "1")])
        return "SABnzbd \(version)".trimmingCharacters(in: .whitespaces)
    }

    func fetchQueue() async throws -> DownloaderSnapshot {
        let data = try await call("queue")
        let queue = try http.decode(QueueEnvelope.self, from: data).queue

        let items = (queue.slots ?? []).map { slot -> DownloadItem in
            let status = slot.status ?? ""
            return DownloadItem(
                id: slot.nzo_id ?? UUID().uuidString,
                name: slot.filename ?? "Unknown",
                status: status,
                progress: min(max((slot.percentage?.double ?? 0) / 100, 0), 1),
                sizeBytes: Int64((slot.mb?.double ?? 0) * 1_048_576),
                remainingBytes: Int64((slot.mbleft?.double ?? 0) * 1_048_576),
                eta: slot.timeleft,
                category: slot.cat,
                isPaused: status.lowercased() == "paused"
            )
        }

        let status = DownloaderStatus(
            speedBytesPerSec: Int64((queue.kbpersec?.double ?? 0) * 1024),
            isPaused: queue.paused?.bool ?? false,
            remainingBytes: Int64((queue.mbleft?.double ?? 0) * 1_048_576),
            speedLimitBytesPerSec: queue.speedlimit_abs?.int64 ?? 0
        )
        return DownloaderSnapshot(status: status, items: items)
    }

    func fetchHistory(limit: Int) async throws -> [HistoryItem] {
        let data = try await call("history", [("limit", String(limit))])
        let slots = try http.decode(HistoryEnvelope.self, from: data).history.slots ?? []
        return slots.map { slot in
            let status = slot.status ?? ""
            return HistoryItem(
                id: slot.nzo_id ?? UUID().uuidString,
                name: slot.name ?? "Unknown",
                status: status,
                sizeBytes: slot.bytes?.int64 ?? 0,
                category: slot.category,
                completed: slot.completed.map { Date(timeIntervalSince1970: $0.double) },
                failed: status.lowercased() == "failed"
            )
        }
    }

    func pauseAll() async throws { try await call("pause") }
    func resumeAll() async throws { try await call("resume") }

    func pause(id: String) async throws {
        try await call("queue", [("name", "pause"), ("value", id)])
    }

    func resume(id: String) async throws {
        try await call("queue", [("name", "resume"), ("value", id)])
    }

    func delete(id: String) async throws {
        try await call("queue", [("name", "delete"), ("value", id), ("del_files", "1")])
    }

    func deleteHistory(id: String) async throws {
        try await call("history", [("name", "delete"), ("value", id), ("del_files", "1")])
    }

    func setSpeedLimit(bytesPerSec: Int64) async throws {
        let value = bytesPerSec <= 0 ? "0" : "\(bytesPerSec / 1024)K"
        try await call("config", [("name", "speedlimit"), ("value", value)])
    }

    func addURL(_ url: String, name: String?) async throws {
        var extra: [(String, String)] = [("name", url)]
        if let name, !name.isEmpty { extra.append(("nzbname", name)) }
        try await call("addurl", extra)
    }
}
