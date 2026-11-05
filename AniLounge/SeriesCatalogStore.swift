import Foundation
import Combine
import AniCore

/// A disposable local catalog cache. Personal progress remains in LibraryStore.
@MainActor final class SeriesCatalogStore: ObservableObject {
    static let shared = SeriesCatalogStore()
    @Published private(set) var catalogs: [String: SeriesCatalog]
    private let defaults: UserDefaults
    private let fetch: (String) async throws -> AnimeDetail
    private static let key = "series.catalog.v1"

    init(defaults: UserDefaults = .standard,
         fetch: @escaping (String) async throws -> AnimeDetail = { try await AniClient.shared.detail(path: $0) }) {
        self.defaults = defaults; self.fetch = fetch
        catalogs = defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode([String: SeriesCatalog].self, from: $0) } ?? [:]
    }

    func remember(_ detail: AnimeDetail, path: String, isRoot: Bool) {
        var catalog = catalogs[detail.anime.id] ?? SeriesCatalog()
        catalog.record(detail, path: path, isRoot: isRoot)
        catalogs[detail.anime.id] = catalog
        if let data = try? JSONEncoder().encode(catalogs) { defaults.set(data, forKey: Self.key) }
    }

    func resolveStart(anime: Anime, profile: ProfileLibrary, refresh: Bool = false) async throws -> SeriesPlaybackDecision {
        try await resolve(anime: anime, refresh: refresh) {
            SeriesPlaybackState.start(anime: anime, profile: profile, catalog: $0)
        }
    }

    func resolveNext(after episode: Episode, anime: Anime, watched: Set<String> = []) async throws -> SeriesPlaybackDecision {
        try await resolve(anime: anime) { SeriesPlaybackState.next(after: episode, catalog: $0, watched: watched) }
    }

    private func resolve(anime: Anime, refresh: Bool = false,
                         decision: (SeriesCatalog?) -> SeriesPlaybackDecision) async throws -> SeriesPlaybackDecision {
        if refresh {
            let detail = try await fetch(anime.path)
            try Task.checkCancellation()
            remember(detail, path: anime.path, isRoot: true)
        }
        var visited = Set<String>()
        while true {
            try Task.checkCancellation()
            let result = decision(catalogs[anime.id])
            let path: String
            let root: Bool
            switch result {
            case .needsCatalog: path = anime.path; root = true
            case .needsSeason(let season): path = season; root = false
            default: return result
            }
            guard visited.insert(path).inserted else { return .unavailable }
            let detail = try await fetch(path)
            try Task.checkCancellation()
            remember(detail, path: path, isRoot: root)
        }
    }

    func refreshContinuations(_ profile: ProfileLibrary, force: Bool = false) async {
        for item in profile.continuationCandidates.prefix(12) {
            guard !Task.isCancelled else { return }
            // Unfinished episodes can always be resumed immediately, including without a catalog.
            guard item.completed else { continue }
            let fresh = catalogs[item.anime.id]?.refreshedAt.map { Date().timeIntervalSince($0) < 300 } ?? false
            do { _ = try await resolveStart(anime: item.anime, profile: profile, refresh: force || !fresh) }
            catch { /* Keep local data and let the detail screen offer a retry. */ }
        }
    }
}
