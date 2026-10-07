import Foundation

// MARK: - Errors

enum APIError: LocalizedError {
    case badURL
    case badResponse
    case status(Int)
    case message(String)
    case decoding(String)

    var errorDescription: String? {
        switch self {
        case .badURL:
            return "That server address doesn't look valid."
        case .badResponse:
            return "The server sent a reply Parcel couldn't understand."
        case .status(let code):
            switch code {
            case 401, 403: return "Authentication failed (HTTP \(code)). Check the API key or login."
            case 404: return "Not found (HTTP 404). Check the address and any URL base path."
            default: return "The server returned HTTP \(code)."
            }
        case .message(let text):
            return text
        case .decoding(let detail):
            return "Couldn't read the server's reply. \(detail)"
        }
    }
}

func isCancellation(_ error: Error) -> Bool {
    if error is CancellationError { return true }
    if let urlError = error as? URLError, urlError.code == .cancelled { return true }
    return false
}

// MARK: - URL building

enum URLBuilder {
    private static let allowed: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-._~")
        return set
    }()

    static func encode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    static func normalizedBase(_ base: String) -> String {
        var root = base.trimmingCharacters(in: .whitespacesAndNewlines)
        if !root.isEmpty && !root.contains("://") { root = "http://" + root }
        while root.hasSuffix("/") { root.removeLast() }
        return root
    }

    /// Builds `base + path ? query`, percent-encoding every query value strictly
    /// (so `&`, `+` and `=` inside NZB links survive).
    static func make(base: String, path: String, query: [(String, String)] = []) throws -> URL {
        let root = normalizedBase(base)
        guard !root.isEmpty else { throw APIError.badURL }
        var text = root + path
        if !query.isEmpty {
            text += "?" + query.map { "\(encode($0.0))=\(encode($0.1))" }.joined(separator: "&")
        }
        guard let url = URL(string: text) else { throw APIError.badURL }
        return url
    }
}

// MARK: - HTTP client

final class SelfSignedDelegate: NSObject, URLSessionDelegate {
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}

final class HTTPClient: @unchecked Sendable {
    static let standard = HTTPClient(allowSelfSigned: false)
    static let selfSigned = HTTPClient(allowSelfSigned: true)

    static func shared(allowSelfSigned: Bool) -> HTTPClient {
        allowSelfSigned ? selfSigned : standard
    }

    private let session: URLSession

    private init(allowSelfSigned: Bool) {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        session = URLSession(
            configuration: config,
            delegate: allowSelfSigned ? SelfSignedDelegate() : nil,
            delegateQueue: nil
        )
    }

    func send(_ request: URLRequest) async throws -> Data {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw APIError.badResponse }
            guard (200..<300).contains(http.statusCode) else { throw APIError.status(http.statusCode) }
            return data
        } catch let error as URLError where error.code != .cancelled {
            throw APIError.message(error.localizedDescription)
        }
    }

    func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch let error as DecodingError {
            throw APIError.decoding(Self.describe(error))
        }
    }

    private static func describe(_ error: DecodingError) -> String {
        switch error {
        case .keyNotFound(let key, _):
            return "Missing field “\(key.stringValue)”."
        case .typeMismatch(_, let context), .valueNotFound(_, let context), .dataCorrupted(let context):
            return context.debugDescription
        @unknown default:
            return ""
        }
    }
}

// MARK: - Lenient JSON value

/// Several of these APIs return numbers as strings (or vice versa). `Flex` accepts either.
struct Flex: Decodable, Hashable {
    let string: String

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let text = try? container.decode(String.self) {
            string = text
        } else if let whole = try? container.decode(Int64.self) {
            string = String(whole)
        } else if let number = try? container.decode(Double.self) {
            string = String(number)
        } else if let flag = try? container.decode(Bool.self) {
            string = flag ? "true" : "false"
        } else {
            string = ""
        }
    }

    var double: Double { Double(string) ?? 0 }
    var int64: Int64 { Int64(double) }
    var bool: Bool { string == "true" || string == "1" }
}

// MARK: - Dates

enum DateParse {
    private static let isoPlain: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static let isoFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static let rfc822Formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return formatter
    }()

    static func iso(_ text: String?) -> Date? {
        guard let text, !text.isEmpty else { return nil }
        return isoPlain.date(from: text)
            ?? isoFractional.date(from: text)
            ?? dayFormatter.date(from: String(text.prefix(10)))
    }

    static func rfc822(_ text: String?) -> Date? {
        guard let text, !text.isEmpty else { return nil }
        return rfc822Formatter.date(from: text)
    }

    static func day(_ date: Date) -> String {
        dayFormatter.string(from: date)
    }
}
