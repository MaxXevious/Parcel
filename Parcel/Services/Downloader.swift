import Foundation

struct DownloadItem: Identifiable, Hashable {
    let id: String
    var name: String
    var status: String
    var progress: Double          // 0...1
    var sizeBytes: Int64
    var remainingBytes: Int64
    var eta: String?
    var category: String?
    var isPaused: Bool
}

struct HistoryItem: Identifiable, Hashable {
    let id: String
    var name: String
    var status: String
    var sizeBytes: Int64
    var category: String?
    var completed: Date?
    var failed: Bool
}

struct DownloaderStatus: Hashable {
    var speedBytesPerSec: Int64
    var isPaused: Bool
    var remainingBytes: Int64
    var speedLimitBytesPerSec: Int64   // 0 = unlimited
}

struct DownloaderSnapshot {
    var status: DownloaderStatus
    var items: [DownloadItem]
}

protocol DownloaderClient: Sendable {
    func testConnection() async throws -> String
    func fetchQueue() async throws -> DownloaderSnapshot
    func fetchHistory(limit: Int) async throws -> [HistoryItem]
    func pauseAll() async throws
    func resumeAll() async throws
    func pause(id: String) async throws
    func resume(id: String) async throws
    func delete(id: String) async throws
    func deleteHistory(id: String) async throws
    /// 0 means unlimited.
    func setSpeedLimit(bytesPerSec: Int64) async throws
    func addURL(_ url: String, name: String?) async throws
}
