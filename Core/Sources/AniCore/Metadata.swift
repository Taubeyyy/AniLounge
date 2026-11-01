import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Series data from AniList, found through the IMDb id that AniWorld publishes.
public struct AnimeExtras: Sendable {
    public let anilistID: Int
    public let banner: URL?
    public let cover: URL?
    public let color: String?
    public let score: Int?
    public let status: String?
    public let studio: String?
    public let trailer: URL?
    public let nextEpisode: Int?
    public let nextAiring: Date?
    /// Titles of similar anime; the app matches them against the AniWorld catalog.
    public let recommendations: [[String]]
}
public struct EpisodeExtras: Sendable, Hashable {
    public let title: String?
    public let image: URL?
    public let overview: String?
    public let runtime: Int?
    public let airDate: String?
}
struct AniZipEpisode: Sendable {
    let season: Int?
    let number: Int?
    let absolute: Int?
    let extras: EpisodeExtras
}

public enum MetadataParser {
    static func object(_ data: Data) throws -> [String: Any] {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw AniError.unexpectedPage }
        return json
    }
    static func secureURL(_ value: Any?) -> URL? {
        guard let raw = value as? String, let url = URL(string: raw), url.scheme == "https" else { return nil }
        return url
    }
    public static func anilistID(fromAniZip data: Data) throws -> Int? {
        (try object(data)["mappings"] as? [String: Any])?["anilist_id"] as? Int
    }
    static func episodes(fromAniZip data: Data) throws -> [AniZipEpisode] {
        guard let episodes = try object(data)["episodes"] as? [String: Any] else { return [] }
        return episodes.values.compactMap { value in
            guard let entry = value as? [String: Any] else { return nil }
            let titles = entry["title"] as? [String: Any]
            let title = [titles?["de"], titles?["en"], titles?["x-jat"]].compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
            let overview = (entry["overview"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return AniZipEpisode(season: entry["seasonNumber"] as? Int, number: entry["episodeNumber"] as? Int,
                                 absolute: entry["absoluteEpisodeNumber"] as? Int,
                                 extras: EpisodeExtras(title: title, image: secureURL(entry["image"]),
                                                       overview: overview?.isEmpty == false ? overview : nil,
                                                       runtime: entry["runtime"] as? Int, airDate: entry["airDate"] as? String))
        }
    }
    public static func extras(fromAniList data: Data) throws -> AnimeExtras {
        guard let media = (try object(data)["data"] as? [String: Any])?["Media"] as? [String: Any], let id = media["id"] as? Int else { throw AniError.missingContent }
        let cover = media["coverImage"] as? [String: Any]
        let studio = ((media["studios"] as? [String: Any])?["nodes"] as? [[String: Any]])?.first?["name"] as? String
        var trailer: URL?
        if let t = media["trailer"] as? [String: Any], t["site"] as? String == "youtube", let key = t["id"] as? String,
           key.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) {
            trailer = URL(string: "https://www.youtube.com/watch?v=" + key)
        }
        let next = media["nextAiringEpisode"] as? [String: Any]
        let nodes = ((media["recommendations"] as? [String: Any])?["nodes"] as? [[String: Any]]) ?? []
        let recommendations: [[String]] = nodes.compactMap { node in
            guard let rec = node["mediaRecommendation"] as? [String: Any] else { return nil }
            let title = rec["title"] as? [String: Any]
            let names = [title?["romaji"], title?["english"]].compactMap { $0 as? String } + ((rec["synonyms"] as? [String]) ?? [])
            return names.isEmpty ? nil : names
        }
        return AnimeExtras(anilistID: id, banner: secureURL(media["bannerImage"]), cover: secureURL(cover?["extraLarge"]),
                           color: cover?["color"] as? String, score: media["averageScore"] as? Int, status: media["status"] as? String,
                           studio: studio, trailer: trailer, nextEpisode: next?["episode"] as? Int,
                           nextAiring: (next?["airingAt"] as? Int).map { Date(timeIntervalSince1970: TimeInterval($0)) },
                           recommendations: recommendations)
    }
    /// The next TV entry in the franchise, used to walk from season 1 to later seasons.
    public static func sequel(fromAniList data: Data) throws -> Int? {
        guard let media = (try object(data)["data"] as? [String: Any])?["Media"] as? [String: Any],
              let edges = (media["relations"] as? [String: Any])?["edges"] as? [[String: Any]] else { return nil }
        return edges.first { edge in
            guard edge["relationType"] as? String == "SEQUEL", let node = edge["node"] as? [String: Any] else { return false }
            return node["type"] as? String == "ANIME" && ["TV", "TV_SHORT", "ONA"].contains(node["format"] as? String ?? "")
        }.flatMap { ($0["node"] as? [String: Any])?["id"] as? Int }
    }
    /// Picks the episodes of one AniWorld season, keyed by the episode number AniWorld shows.
    static func season(_ season: Int, from episodes: [AniZipEpisode], allowAbsolute: Bool) -> [String: EpisodeExtras] {
        var result: [String: EpisodeExtras] = [:]
        for episode in episodes where episode.season == season { if let number = episode.number { result[String(number)] = episode.extras } }
        if result.isEmpty && allowAbsolute {
            for episode in episodes { if let number = episode.absolute ?? episode.number { result[String(number)] = episode.extras } }
        }
        return result
    }
    /// AniWorld's IMDb link, e.g. `tt0388629`.
    public static func validIMDb(_ value: String) -> String? {
        let clean = value.trimmingCharacters(in: .whitespaces)
        guard clean.hasPrefix("tt"), clean.count <= 12, clean.dropFirst(2).allSatisfy(\.isNumber), clean.count > 3 else { return nil }
        return clean
    }
}

public actor MetadataClient {
    public static let shared = MetadataClient()
    private let session: URLSession
    private var anilistIDs: [String: Int] = [:]
    private var aniZip: [Int: [AniZipEpisode]] = [:]
    private var sequels: [Int: Int?] = [:]
    private var extras: [Int: AnimeExtras] = [:]
    private var seasons: [String: [String: EpisodeExtras]] = [:]
    public init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.requestCachePolicy = .useProtocolCachePolicy
        config.urlCache = URLCache(memoryCapacity: 8 * 1024 * 1024, diskCapacity: 40 * 1024 * 1024)
        session = URLSession(configuration: config)
    }
    private func fetch(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AniError.unexpectedPage }
        guard (200...299).contains(http.statusCode) else { throw AniError.http(http.statusCode) }
        return data
    }
    private func aniZip(_ query: URLQueryItem) async throws -> Data {
        var components = URLComponents(string: "https://api.ani.zip/mappings")!
        components.queryItems = [query]
        guard let url = components.url else { throw AniError.invalidURL }
        return try await fetch(URLRequest(url: url))
    }
    private func aniList(_ query: String, id: Int) async throws -> Data {
        guard let url = URL(string: "https://graphql.anilist.co") else { throw AniError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["query": query, "variables": ["id": id]])
        return try await fetch(request)
    }
    private func anilistID(imdb: String) async throws -> Int? {
        if let cached = anilistIDs[imdb] { return cached }
        let data = try await aniZip(URLQueryItem(name: "imdb_id", value: imdb))
        guard let id = try MetadataParser.anilistID(fromAniZip: data) else { return nil }
        anilistIDs[imdb] = id
        aniZip[id] = try MetadataParser.episodes(fromAniZip: data)
        return id
    }
    private func episodes(anilist id: Int) async throws -> [AniZipEpisode] {
        if let cached = aniZip[id] { return cached }
        let parsed = try MetadataParser.episodes(fromAniZip: try await aniZip(URLQueryItem(name: "anilist_id", value: String(id))))
        aniZip[id] = parsed
        return parsed
    }
    private func sequel(of id: Int) async throws -> Int? {
        if let cached = sequels[id] { return cached }
        let data = try await aniList("query($id:Int){Media(id:$id){relations{edges{relationType node{id type format}}}}}", id: id)
        let next = try MetadataParser.sequel(fromAniList: data)
        sequels[id] = next
        return next
    }
    public func extras(imdb: String) async throws -> AnimeExtras? {
        guard let id = try await anilistID(imdb: imdb) else { return nil }
        if let cached = extras[id] { return cached }
        let query = """
        query($id:Int){Media(id:$id){id bannerImage coverImage{extraLarge color} averageScore status studios(isMain:true){nodes{name}} trailer{site id} nextAiringEpisode{episode airingAt} recommendations(perPage:12,sort:RATING_DESC){nodes{mediaRecommendation{title{romaji english} synonyms}}}}}
        """
        let result = try MetadataParser.extras(fromAniList: try await aniList(query, id: id))
        extras[id] = result
        return result
    }
    /// Episode titles and stills for AniWorld's `staffel-N`. AniList splits seasons into cours,
    /// so the walk follows sequels and keeps the episodes whose TVDB season matches.
    public func episodes(imdb: String, season: Int) async throws -> [String: EpisodeExtras] {
        let key = imdb + "#" + String(season)
        if let cached = seasons[key] { return cached }
        guard season >= 1, let first = try await anilistID(imdb: imdb) else { return [:] }
        var collected: [AniZipEpisode] = []
        var current: Int? = first
        var visited = Set<Int>()
        while let id = current, visited.count < 10, visited.insert(id).inserted {
            let entries = try await episodes(anilist: id)
            collected += entries
            // Stop once later seasons appear; the requested season is complete.
            if season == 1 || entries.contains(where: { ($0.season ?? 0) > season }) { break }
            current = try await sequel(of: id)
        }
        let result = MetadataParser.season(season, from: collected, allowAbsolute: season == 1)
        seasons[key] = result
        return result
    }
}
