import Foundation

/// Cached catalog data, separate from a person's watched state.
public struct SeriesCatalog: Codable, Sendable {
    public var seasons: [Season] = []
    public var episodesBySeason: [String: [Episode]] = [:]
    public var refreshedAt: Date?
    public init() {}

    public mutating func record(_ detail: AnimeDetail, path: String, isRoot: Bool, date: Date = Date()) {
        if isRoot {
            seasons = detail.seasons
            episodesBySeason = [:] // A successful refresh must discover additions to later seasons too.
            refreshedAt = date
        } else if !detail.seasons.isEmpty {
            // A direct resume may load a season before the series landing page.
            seasons = detail.seasons
        }
        let grouped = Dictionary(grouping: detail.episodes) { Self.seasonPath(for: $0) }
        for (key, episodes) in grouped { episodesBySeason[key] = episodes }
        if !isRoot && detail.episodes.isEmpty { episodesBySeason[path] = [] }
    }
    public static func seasonPath(for episode: Episode) -> String {
        String(episode.path.prefix(upTo: episode.path.lastIndex(of: "/") ?? episode.path.endIndex))
    }
}

public enum SeriesPlaybackDecision: Equatable, Sendable {
    case resume(EpisodeProgress)
    case play(Episode)
    case needsCatalog
    case needsSeason(String)
    case caughtUp
    case unavailable

    public var episode: Episode? {
        switch self {
        case .resume(let progress): return progress.episode
        case .play(let episode): return episode
        default: return nil
        }
    }
}

/// Used by the home shelf, series detail and the player's next-episode queue.
public enum SeriesPlaybackState {
    public static func start(anime: Anime, profile: ProfileLibrary, catalog: SeriesCatalog?) -> SeriesPlaybackDecision {
        if let latest = profile.latest(for: anime) {
            if !latest.isFinished {
                return latest.seconds > 0 ? .resume(latest) : .play(latest.episode)
            }
            return next(after: latest.episode, catalog: catalog, watched: profile.watched)
        }
        guard let catalog else { return .needsCatalog }
        let seasons = catalog.seasons.filter { $0.path.contains("/staffel-") }
        return firstAvailable(in: seasons.isEmpty ? catalog.seasons : seasons, catalog: catalog, watched: profile.watched)
    }

    public static func next(after episode: Episode, catalog: SeriesCatalog?, watched: Set<String> = []) -> SeriesPlaybackDecision {
        guard let catalog else { return .needsCatalog }
        let path = SeriesCatalog.seasonPath(for: episode)
        // Films do not automatically jump into a TV season or another content category.
        let seasons = path.contains("/staffel-") ? catalog.seasons.filter { $0.path.contains("/staffel-") }
            : catalog.seasons.filter { $0.path == path }
        guard let seasonIndex = seasons.firstIndex(where: { $0.path == path }) else { return .unavailable }
        guard let episodes = catalog.episodesBySeason[path] else { return .needsSeason(path) }
        guard let index = episodes.firstIndex(where: { $0.id == episode.id }) else { return .unavailable }
        if let next = episodes.dropFirst(index + 1).first(where: { !watched.contains($0.id) }) { return .play(next) }
        return firstAvailable(in: Array(seasons.dropFirst(seasonIndex + 1)), catalog: catalog, watched: watched)
    }

    private static func firstAvailable(in seasons: [Season], catalog: SeriesCatalog, watched: Set<String>) -> SeriesPlaybackDecision {
        for season in seasons {
            guard let episodes = catalog.episodesBySeason[season.path] else { return .needsSeason(season.path) }
            if let episode = episodes.first(where: { !watched.contains($0.id) }) { return .play(episode) }
        }
        return .caughtUp
    }
}
