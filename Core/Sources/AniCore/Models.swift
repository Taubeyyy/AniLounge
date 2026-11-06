import Foundation

public struct Anime: Identifiable, Codable, Hashable, Sendable {
    public var id: String { path }
    public let path: String
    public var title: String
    public var poster: URL?
    public var aliases: String
    public init(path: String, title: String, poster: URL? = nil, aliases: String = "") {
        self.path = path; self.title = title; self.poster = poster; self.aliases = aliases
    }
}
public struct Season: Identifiable, Codable, Hashable, Sendable {
    public var id: String { path }
    public let path: String
    public let title: String
}
public struct Episode: Identifiable, Codable, Hashable, Sendable {
    public var id: String { path }
    public let path: String
    public let number: String
    public let title: String
    public let languages: [String]
}
public struct AnimeDetail: Sendable {
    public let anime: Anime
    public let synopsis: String
    public let genres: [String]
    public let year: String
    public let seasons: [Season]
    public let episodes: [Episode]
    public let backdrop: URL?
    public var imdb: String? = nil
}
public struct HomeFeed: Sendable {
    public let featured: [Anime]
    public let popular: [Anime]
    public let recent: [Anime]
}
public enum AniError: LocalizedError {
    case invalidURL, http(Int), unexpectedPage, missingContent, invalidEncoding
    public var errorDescription: String? {
        switch self {
        case .invalidURL: return "Dieser Link wird nicht unterstützt."
        case .http(let code): return "AniWorld antwortet mit HTTP \(code). Bitte später erneut versuchen."
        case .unexpectedPage: return "Die Website verlangt möglicherweise eine Browser-Prüfung. Öffne AniWorld im Browser und versuche es später erneut."
        case .missingContent: return "Die erwarteten Inhalte fehlen. Möglicherweise wurde die Website geändert."
        case .invalidEncoding: return "Die Seite konnte nicht gelesen werden."
        }
    }
}
public enum AniURL {
    public static let base = URL(string: "https://aniworld.to")!
    public static func page(_ value: String) -> URL? {
        guard let url = URL(string: value, relativeTo: base)?.absoluteURL,
              url.scheme == "https", url.host == base.host,
              url.user == nil, url.password == nil else { return nil }
        return url
    }
    public static func animePath(_ value: String) -> String? {
        guard let url = page(value) else { return nil }
        let parts = url.path.split(separator: "/")
        guard parts.count >= 3, parts[0] == "anime", parts[1] == "stream" else { return nil }
        return "/anime/stream/\(parts[2])"
    }
    public static func image(_ value: String) -> URL? {
        guard !value.isEmpty, let url = URL(string: value, relativeTo: base)?.absoluteURL,
              url.scheme == "https" else { return nil }
        return url
    }
}
