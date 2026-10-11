import Foundation

enum MediaKind {
    case tv, movie, unknown
}

struct MediaLink: Identifiable, Hashable {
    let title: String
    let systemImage: String
    let url: URL

    var id: String { url.absoluteString }
    /// True for a title search rather than a link straight to the page.
    var isSearch: Bool { title.hasPrefix("Search") }
}

/// Builds links to TheTVDB (TV), TMDB (movies) and IMDb for a search result.
enum MediaLinks {

    // MARK: Direct links

    static func tvdbSeries(_ id: Int) -> URL? {
        // TheTVDB redirects this id-based address to the show's page.
        URL(string: "https://thetvdb.com/dereferrer/series/\(id)")
    }

    static func tmdbMovie(_ id: Int) -> URL? {
        URL(string: "https://www.themoviedb.org/movie/\(id)")
    }

    static func imdbTitle(_ digits: String) -> URL? {
        URL(string: "https://www.imdb.com/title/tt\(digits)/")
    }

    // MARK: Search fallbacks

    static func tvdbSearch(_ term: String) -> URL? {
        URL(string: "https://thetvdb.com/search?query=\(URLBuilder.encode(term))")
    }

    static func tmdbSearch(_ term: String) -> URL? {
        URL(string: "https://www.themoviedb.org/search?query=\(URLBuilder.encode(term))")
    }

    // MARK: Library items (Sonarr / Radarr lookups)

    static func link(for kind: ServerKind, externalID: Int) -> MediaLink? {
        guard externalID > 0 else { return nil }
        switch kind {
        case .sonarr:
            return tvdbSeries(externalID).map { MediaLink(title: "View on TheTVDB", systemImage: "tv", url: $0) }
        case .radarr:
            return tmdbMovie(externalID).map { MediaLink(title: "View on TMDB", systemImage: "film", url: $0) }
        default:
            return nil
        }
    }

    // MARK: Indexer results

    /// Works out whether a release is TV or a movie: category ids first, then the category name,
    /// then a TVDB id, and finally clues in the release name.
    static func kind(of result: NZBResult) -> MediaKind {
        for id in result.categoryIDs {
            switch (Int(id) ?? 0) / 1000 {
            case 5: return .tv
            case 2: return .movie
            default: continue
            }
        }

        let name = result.category.lowercased()
        if name.hasPrefix("tv") { return .tv }
        if name.hasPrefix("movie") { return .movie }
        if result.tvdbID != nil { return .tv }

        // Underscores count as letters in a regex word boundary, so turn them into spaces first.
        let spaced = result.title.replacingOccurrences(of: "_", with: " ")
        if matches(spaced, #"\bS\d{1,2}(E\d{1,3})?\b|\b\d{1,2}x\d{2,3}\b|\bSeason[ .]\d+\b"#) { return .tv }
        if matches(spaced, #"\b(19|20)\d{2}\b"#) { return .movie }
        return .unknown
    }

    /// "The.Show.Name.S02E05.1080p.WEB-DL.x264-GRP" becomes "The Show Name".
    static func cleanTitle(_ release: String) -> String {
        var text = release.replacingOccurrences(of: "[._]+", with: " ", options: .regularExpression)

        let cutPatterns = [
            #"\bS\d{1,2}(E\d{1,3})?\b"#,
            #"\b\d{1,2}x\d{2,3}\b"#,
            #"\bSeason \d+\b"#,
            #"\b(19|20)\d{2}\b"#,
            #"\b(480p|576p|720p|1080p|2160p|4K|UHD|BluRay|BDRip|WEB-?DL|WEBRip|HDTV|DVDRip|REMUX|x264|x265|H ?264|H ?265|HEVC)\b"#
        ]

        var cut = text.endIndex
        for pattern in cutPatterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let whole = NSRange(text.startIndex..., in: text)
            for match in regex.matches(in: text, range: whole) {
                guard let range = Range(match.range, in: text) else { continue }
                // Skip a match at the very start, so titles like "1917" or "2012" survive.
                if range.lowerBound > text.startIndex {
                    if range.lowerBound < cut { cut = range.lowerBound }
                    break
                }
            }
        }

        text = String(text[..<cut])
        let trim = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "-–—([{"))
        text = text.trimmingCharacters(in: trim)
        return text.isEmpty ? release : text
    }

    static func links(for result: NZBResult) -> [MediaLink] {
        let title = cleanTitle(result.title)
        var links: [MediaLink] = []

        func addTV() {
            if let id = result.tvdbID, let url = tvdbSeries(id) {
                links.append(MediaLink(title: "View on TheTVDB", systemImage: "tv", url: url))
            } else if let url = tvdbSearch(title) {
                links.append(MediaLink(title: "Search TheTVDB for “\(title)”", systemImage: "magnifyingglass", url: url))
            }
        }

        func addMovie() {
            if let id = result.tmdbID, let url = tmdbMovie(id) {
                links.append(MediaLink(title: "View on TMDB", systemImage: "film", url: url))
                return
            }
            if let digits = result.imdbID, let url = imdbTitle(digits) {
                links.append(MediaLink(title: "View on IMDb", systemImage: "film", url: url))
            }
            if let url = tmdbSearch(title) {
                links.append(MediaLink(title: "Search TMDB for “\(title)”", systemImage: "magnifyingglass", url: url))
            }
        }

        switch kind(of: result) {
        case .tv:
            addTV()
        case .movie:
            addMovie()
        case .unknown:
            addTV()
            addMovie()
        }
        return links
    }

    private static func matches(_ text: String, _ pattern: String) -> Bool {
        text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }
}
