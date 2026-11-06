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
    /// MyAnimeList entry and its own episode number, used for AniSkip.
    public var malID: Int? = nil
    public var malEpisode: Int? = nil
}
/// Opening and ending intervals from AniSkip, in seconds of the episode.
public struct SkipTimes: Sendable, Equatable {
    public let opening: ClosedRange<Double>?
    public let ending: ClosedRange<Double>?
    /// Length of the video the times were measured on.
    public let episodeLength: Double?
    /// "Previously on" recap at the start of an episode, when AniSkip knows it.
    public var recap: ClosedRange<Double>? = nil
    /// Times are only trusted when the playing video has about the same length.
    public func fits(duration: Double?) -> Bool {
        guard let duration, duration.isFinite, duration > 0, let episodeLength, episodeLength > 0 else { return true }
        return abs(duration - episodeLength) <= 45
    }
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
        let json = try object(data)
        guard let episodes = json["episodes"] as? [String: Any] else { return [] }
        let mal = (json["mappings"] as? [String: Any])?["mal_id"] as? Int
        return episodes.compactMap { key, value in
            guard let entry = value as? [String: Any] else { return nil }
            let titles = entry["title"] as? [String: Any]
            let title = [titles?["de"], titles?["en"], titles?["x-jat"]].compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
            let overview = (entry["overview"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            // The dictionary key is the episode number inside this AniList/MAL entry ("S1" for specials).
            let relative = Int((entry["episode"] as? String) ?? key)
            return AniZipEpisode(season: entry["seasonNumber"] as? Int, number: entry["episodeNumber"] as? Int,
                                 absolute: entry["absoluteEpisodeNumber"] as? Int,
                                 extras: EpisodeExtras(title: title, image: secureURL(entry["image"]),
                                                       overview: overview?.isEmpty == false ? overview : nil,
                                                       runtime: entry["runtime"] as? Int, airDate: entry["airDate"] as? String,
                                                       malID: relative == nil ? nil : mal, malEpisode: relative))
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
    /// The next entry in the franchise. TV sequels win; specials and movies only bridge to
    /// the next season (e.g. Dr. Stone: Stone Wars → Ryuusui → New World).
    public static func sequel(fromAniList data: Data) throws -> Int? {
        guard let media = (try object(data)["data"] as? [String: Any])?["Media"] as? [String: Any],
              let edges = (media["relations"] as? [String: Any])?["edges"] as? [[String: Any]] else { return nil }
        let sequels = edges.compactMap { edge -> [String: Any]? in
            guard edge["relationType"] as? String == "SEQUEL", let node = edge["node"] as? [String: Any], node["type"] as? String == "ANIME",
                  node["format"] as? String != "MUSIC" else { return nil }
            return node
        }
        let series = sequels.first { ["TV", "TV_SHORT", "ONA"].contains($0["format"] as? String ?? "") }
        return (series ?? sequels.first)?["id"] as? Int
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
    public static func skipTimes(fromAniSkip data: Data) throws -> SkipTimes? {
        let json = try object(data)
        guard json["found"] as? Bool == true, let results = json["results"] as? [[String: Any]] else { return nil }
        var opening: ClosedRange<Double>?, ending: ClosedRange<Double>?, recap: ClosedRange<Double>?, length: Double?
        for result in results {
            guard let interval = result["interval"] as? [String: Any],
                  let start = (interval["startTime"] as? NSNumber)?.doubleValue, let end = (interval["endTime"] as? NSNumber)?.doubleValue,
                  start.isFinite, end.isFinite, start >= 0, end > start + 5, end - start < 400 else { continue }
            switch result["skipType"] as? String {
            case "op" where opening == nil: opening = start...end
            case "ed" where ending == nil: ending = start...end
            case "recap" where recap == nil: recap = start...end
            default: continue
            }
            if length == nil, let value = (result["episodeLength"] as? NSNumber)?.doubleValue, value > 0 { length = value }
        }
        guard opening != nil || ending != nil || recap != nil else { return nil }
        return SkipTimes(opening: opening, ending: ending, episodeLength: length, recap: recap)
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
    private static let sequelKey = "metadata.sequels.v1"
    private let session: URLSession
    private let defaults: UserDefaults
    private var anilistIDs: [String: Int] = [:]
    private var aniZip: [Int: [AniZipEpisode]] = [:]
    /// AniList relations rarely change; remembering them keeps later seasons fast and spares the rate limit.
    private var sequels: [Int: Int] = [:]
    private var extras: [Int: AnimeExtras] = [:]
    private var seasons: [String: [String: EpisodeExtras]] = [:]
    private var skips: [String: SkipTimes?] = [:]
    public init(defaults: UserDefaults = .standard) {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.requestCachePolicy = .useProtocolCachePolicy
        config.urlCache = URLCache(memoryCapacity: 8 * 1024 * 1024, diskCapacity: 40 * 1024 * 1024)
        session = URLSession(configuration: config)
        self.defaults = defaults
        // Stored as "id": next, where 0 means "no further season".
        for (key, value) in (defaults.dictionary(forKey: Self.sequelKey) as? [String: Int]) ?? [:] { if let id = Int(key) { sequels[id] = value } }
    }
    private func fetch(_ request: URLRequest) async throws -> Data {
        var request = request
        request.setValue("AniLounge/0.8 (personal iOS client)", forHTTPHeaderField: "User-Agent")
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
        if let cached = sequels[id] { return cached == 0 ? nil : cached }
        let data = try await aniList("query($id:Int){Media(id:$id){relations{edges{relationType node{id type format}}}}}", id: id)
        let next = try MetadataParser.sequel(fromAniList: data)
        sequels[id] = next ?? 0
        defaults.set(Dictionary(uniqueKeysWithValues: sequels.map { (String($0.key), $0.value) }), forKey: Self.sequelKey)
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
        while let id = current, visited.count < 14, visited.insert(id).inserted {
            // A missing entry ends the walk; what was found so far is still useful.
            guard let entries = try? await episodes(anilist: id) else { break }
            collected += entries
            if season == 1 || entries.contains(where: { ($0.season ?? 0) > season }) { break }
            current = try? await sequel(of: id)
        }
        let result = MetadataParser.season(season, from: collected, allowAbsolute: season == 1)
        seasons[key] = result
        return result
    }
    /// Opening/ending of one episode, or nil when AniSkip has no data for it.
    public func skipTimes(for episode: EpisodeExtras) async -> SkipTimes? {
        guard let mal = episode.malID, let number = episode.malEpisode, mal > 0, number > 0 else { return nil }
        let key = "\(mal)#\(number)"
        if let cached = skips[key] { return cached }
        guard let url = URL(string: "https://api.aniskip.com/v2/skip-times/\(mal)/\(number)?types=op&types=ed&types=recap&episodeLength=0") else { return nil }
        // AniSkip answers 404 when nobody submitted times yet; that is a normal "no data".
        let result = (try? await fetch(URLRequest(url: url))).flatMap { try? MetadataParser.skipTimes(fromAniSkip: $0) }
        skips[key] = result
        return result
    }
}
