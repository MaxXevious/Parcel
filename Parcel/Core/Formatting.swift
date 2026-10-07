import Foundation

extension Int64 {
    var byteString: String {
        ByteCountFormatter.string(fromByteCount: self, countStyle: .binary)
    }

    var speedString: String {
        "\(byteString)/s"
    }
}

extension Date {
    var relativeString: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: self, relativeTo: Date())
    }
}

func episodeCode(_ season: Int?, _ episode: Int?) -> String {
    String(format: "S%02dE%02d", season ?? 0, episode ?? 0)
}
