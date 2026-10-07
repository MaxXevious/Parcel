import Foundation

// MARK: - Results

struct NZBResult: Identifiable, Hashable {
    let id: String
    var title: String
    var downloadURL: String
    var sizeBytes: Int64
    var date: Date?
    var category: String
    var grabs: Int?
    var indexer: String
}

enum IndexerCategory: String, CaseIterable, Identifiable {
    case all = "All"
    case movies = "Movies"
    case tv = "TV"
    case audio = "Audio"
    case books = "Books"

    var id: String { rawValue }

    /// Newznab top-level category codes.
    var code: String? {
        switch self {
        case .all: return nil
        case .movies: return "2000"
        case .tv: return "5000"
        case .audio: return "3000"
        case .books: return "7000"
        }
    }
}

// MARK: - Client (Newznab protocol)

struct IndexerClient: Sendable {
    let name: String
    let baseURL: String
    let apiKey: String
    let http: HTTPClient

    private func url(_ params: [(String, String)]) throws -> URL {
        var base = URLBuilder.normalizedBase(baseURL)
        if base.lowercased().hasSuffix("/api") { base = String(base.dropLast(4)) }
        return try URLBuilder.make(base: base, path: "/api", query: params + [("apikey", apiKey)])
    }

    func testConnection() async throws -> String {
        let data = try await http.send(URLRequest(url: try url([("t", "caps")])))
        let text = String(decoding: data, as: UTF8.self)
        if text.contains("<error") {
            let parsed = try NewznabParser.parse(data)
            throw APIError.message(parsed.error ?? "The indexer rejected the request.")
        }
        guard text.contains("<caps") else {
            throw APIError.message("That doesn't look like a Newznab indexer.")
        }
        return "Indexer reachable"
    }

    func search(_ term: String, category: String?, limit: Int = 100) async throws -> [NZBResult] {
        var params: [(String, String)] = [
            ("t", "search"),
            ("q", term),
            ("limit", String(limit)),
            ("extended", "1")
        ]
        if let category { params.append(("cat", category)) }

        let data = try await http.send(URLRequest(url: try url(params)))
        let parsed = try NewznabParser.parse(data)
        if let error = parsed.error, parsed.items.isEmpty { throw APIError.message(error) }

        return parsed.items.compactMap { raw in
            let link = raw.enclosureURL.isEmpty ? raw.link : raw.enclosureURL
            guard !link.isEmpty else { return nil }
            let size = Int64(raw.attrs["size"] ?? raw.enclosureLength) ?? 0
            let identity = raw.guid.isEmpty ? link : raw.guid
            return NZBResult(
                id: "\(name)|\(identity)",
                title: raw.title,
                downloadURL: link,
                sizeBytes: size,
                date: DateParse.rfc822(raw.pubDate),
                category: raw.category,
                grabs: raw.attrs["grabs"].flatMap { Int($0) },
                indexer: name
            )
        }
    }
}

// MARK: - XML parsing

final class NewznabParser: NSObject, XMLParserDelegate {
    struct Raw {
        var title = ""
        var link = ""
        var guid = ""
        var pubDate = ""
        var category = ""
        var enclosureURL = ""
        var enclosureLength = ""
        var attrs: [String: String] = [:]
    }

    private var items: [Raw] = []
    private var error: String?
    private var current: Raw?
    private var text = ""

    static func parse(_ data: Data) throws -> (items: [Raw], error: String?) {
        let handler = NewznabParser()
        let parser = XMLParser(data: data)
        parser.delegate = handler
        let finished = parser.parse()
        if !finished && handler.items.isEmpty && handler.error == nil {
            throw APIError.message("The indexer's reply couldn't be read. Check the address and API key.")
        }
        return (handler.items, handler.error)
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        text = ""
        switch elementName {
        case "item":
            current = Raw()
        case "enclosure":
            current?.enclosureURL = attributeDict["url"] ?? ""
            current?.enclosureLength = attributeDict["length"] ?? ""
        case "newznab:attr", "attr":
            if let key = attributeDict["name"], let value = attributeDict["value"] {
                current?.attrs[key] = value
            }
        case "error":
            error = attributeDict["description"] ?? "The indexer returned an error."
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        text += String(decoding: CDATABlock, as: UTF8.self)
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        guard current != nil else { return }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch elementName {
        case "title": current?.title = value
        case "link": current?.link = value
        case "guid": current?.guid = value
        case "pubDate": current?.pubDate = value
        case "category":
            if current?.category.isEmpty == true { current?.category = value }
        case "item":
            if let finished = current { items.append(finished) }
            current = nil
        default:
            break
        }
    }
}
