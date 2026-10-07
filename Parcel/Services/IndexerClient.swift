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

/// A Newznab category (for example TV, id 5000) and its sub-categories (HD, id 5040).
struct NZBCategory: Identifiable, Hashable {
    let id: String
    var name: String
    var children: [NZBCategory] = []

    /// Standard Newznab categories, used when an indexer doesn't report its own list.
    static let standard: [NZBCategory] = [
        NZBCategory(id: "2000", name: "Movies", children: [
            NZBCategory(id: "2030", name: "SD"),
            NZBCategory(id: "2040", name: "HD"),
            NZBCategory(id: "2045", name: "UHD"),
            NZBCategory(id: "2050", name: "BluRay")
        ]),
        NZBCategory(id: "3000", name: "Audio", children: [
            NZBCategory(id: "3010", name: "MP3"),
            NZBCategory(id: "3030", name: "Audiobook"),
            NZBCategory(id: "3040", name: "Lossless")
        ]),
        NZBCategory(id: "4000", name: "PC"),
        NZBCategory(id: "5000", name: "TV", children: [
            NZBCategory(id: "5030", name: "SD"),
            NZBCategory(id: "5040", name: "HD"),
            NZBCategory(id: "5045", name: "UHD"),
            NZBCategory(id: "5070", name: "Anime"),
            NZBCategory(id: "5080", name: "Documentary")
        ]),
        NZBCategory(id: "7000", name: "Books", children: [
            NZBCategory(id: "7010", name: "Mags"),
            NZBCategory(id: "7020", name: "EBook"),
            NZBCategory(id: "7030", name: "Comics")
        ]),
        NZBCategory(id: "8000", name: "Other")
    ]

    /// Combines the category lists reported by several indexers, matching on id.
    static func merge(_ lists: [[NZBCategory]]) -> [NZBCategory] {
        var parents: [String: NZBCategory] = [:]
        for list in lists {
            for parent in list {
                if var existing = parents[parent.id] {
                    for child in parent.children where !existing.children.contains(where: { $0.id == child.id }) {
                        existing.children.append(child)
                    }
                    parents[parent.id] = existing
                } else {
                    parents[parent.id] = parent
                }
            }
        }
        let ordered = parents.values.sorted { (Int($0.id) ?? 0) < (Int($1.id) ?? 0) }
        return ordered.map { parent -> NZBCategory in
            var sorted = parent
            sorted.children.sort { (Int($0.id) ?? 0) < (Int($1.id) ?? 0) }
            return sorted
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

    /// The categories this indexer offers, read from its capabilities document.
    func categories() async throws -> [NZBCategory] {
        let data = try await http.send(URLRequest(url: try url([("t", "caps")])))
        return CapsParser.parse(data)
    }

    /// With an empty `term` and a `category`, this returns the indexer's latest releases in that category.
    func search(_ term: String, category: String?, limit: Int = 100) async throws -> [NZBResult] {
        var params: [(String, String)] = [("t", "search")]
        if !term.isEmpty { params.append(("q", term)) }
        params.append(("limit", String(limit)))
        params.append(("extended", "1"))
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

/// Reads the `<categories>` block of a Newznab `t=caps` reply.
final class CapsParser: NSObject, XMLParserDelegate {
    private var categories: [NZBCategory] = []
    private var current: NZBCategory?

    static func parse(_ data: Data) -> [NZBCategory] {
        let handler = CapsParser()
        let parser = XMLParser(data: data)
        parser.delegate = handler
        _ = parser.parse()
        return handler.categories
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        switch elementName {
        case "category":
            if let id = attributeDict["id"] {
                current = NZBCategory(id: id, name: attributeDict["name"] ?? id)
            }
        case "subcat":
            if let id = attributeDict["id"] {
                current?.children.append(NZBCategory(id: id, name: attributeDict["name"] ?? id))
            }
        default:
            break
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        if elementName == "category", let finished = current {
            categories.append(finished)
            current = nil
        }
    }
}
