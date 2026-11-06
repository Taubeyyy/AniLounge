import XCTest
@testable import AniCore

final class WatchlistTests: XCTestCase {
    private let anime = Anime(path: "/anime/stream/test", title: "Test")
    private func episode(_ season: Int = 1, _ number: Int = 1) -> Episode {
        Episode(path: "\(anime.path)/staffel-\(season)/episode-\(number)", number: "\(number)", title: "Folge", languages: [])
    }
    private func catalog(_ episodes: [Episode]) -> SeriesCatalog {
        var result = SeriesCatalog()
        result.episodesBySeason = Dictionary(grouping: episodes, by: SeriesCatalog.seasonPath)
        result.seasons = result.episodesBySeason.keys.sorted().map { Season(path: $0, title: "Staffel") }
        result.refreshedAt = Date()
        return result
    }
    func testOnlyRealPlaybackAddsAnimeAndBookmarksNeverDuplicateIt() throws {
        var profile = ProfileLibrary()
        profile.opened(episode(), anime: anime)
        XCTAssertTrue(profile.watchlistItems.isEmpty)
        try profile.saveProgress(episode(), anime: anime, seconds: 0, duration: 1200, completed: false)
        XCTAssertTrue(profile.watchlistItems.isEmpty)
        try profile.saveProgress(episode(), anime: anime, seconds: 45, duration: 1200, completed: false)
        XCTAssertEqual(profile.watchlistItems, [anime])
        XCTAssertEqual(profile.status(for: anime), .watching)
        profile.setStatus(.watching, for: anime)
        try profile.saveProgress(episode(1, 2), anime: anime, seconds: 50, duration: 1200, completed: false)
        XCTAssertEqual(profile.watchlistItems, [anime])
    }
    func testOldProgressAppearsAndExplicitRemovalSurvivesRestartAndMoreProgress() throws {
        var profile = ProfileLibrary()
        try profile.saveProgress(episode(), anime: anime, seconds: 45, duration: 1200, completed: false)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(profile)) as? [String: Any])
        json.removeValue(forKey: "hiddenWatchlist")
        var restored = try JSONDecoder().decode(ProfileLibrary.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(restored.watchlistItems, [anime])
        restored.removeFromWatchlist(anime)
        restored = try JSONDecoder().decode(ProfileLibrary.self, from: JSONEncoder().encode(restored))
        try restored.saveProgress(episode(), anime: anime, seconds: 90, duration: 1200, completed: false)
        XCTAssertTrue(restored.watchlistItems.isEmpty)
        XCTAssertEqual(restored.latest(for: anime)?.seconds, 90)
        restored.toggleFavorite(anime)
        XCTAssertEqual(restored.watchlistItems, [anime])
        XCTAssertEqual(restored.status(for: anime), .watching)
    }
    func testPlannedStartsAutomaticallyAndManualPauseOrFinishedRemainRespected() throws {
        var profile = ProfileLibrary()
        profile.setStatus(.planned, for: anime)
        try profile.saveProgress(episode(), anime: anime, seconds: 40, duration: 1200, completed: false)
        XCTAssertEqual(profile.status(for: anime), .watching)
        for status in [WatchStatus.paused, .completed] {
            profile.setStatus(status, for: anime)
            try profile.saveProgress(episode(), anime: anime, seconds: 50, duration: 1200, completed: false)
            XCTAssertEqual(profile.status(for: anime), status)
        }
        profile.setStatus(nil, for: anime)
        XCTAssertEqual(profile.status(for: anime), .watching)
    }
    func testFinishedNeedsEveryEpisodeAndAllKnownSeasons() throws {
        var profile = ProfileLibrary()
        let first = episode(), last = episode(2, 1)
        var known = catalog([first, last])
        try profile.setWatched(true, episode: last, anime: anime)
        XCTAssertEqual(profile.listStatuses(catalogs: [anime.id: known])[anime.id], .watching, "The last episode alone is not a complete series")
        try profile.setWatched(true, episode: first, anime: anime)
        XCTAssertEqual(profile.listStatuses(catalogs: [anime.id: known])[anime.id], .completed)
        known.episodesBySeason[SeriesCatalog.seasonPath(for: last)] = nil
        XCTAssertEqual(profile.listStatuses(catalogs: [anime.id: known])[anime.id], .watching)
        XCTAssertEqual(profile.listStatuses()[anime.id], .watching, "No completion guess without a catalog")
    }
    func testNewEpisodesReturnAutomaticFinishedSeriesToWatching() throws {
        var profile = ProfileLibrary()
        try profile.setWatched(true, episode: episode(), anime: anime)
        XCTAssertEqual(profile.listStatuses(catalogs: [anime.id: catalog([episode()])])[anime.id], .completed)
        XCTAssertEqual(profile.listStatuses(catalogs: [anime.id: catalog([episode(), episode(1, 2)])])[anime.id], .watching)
    }
    func testFinishedMovieDoesNotCompleteUnwatchedTelevisionSeasons() throws {
        var profile = ProfileLibrary()
        let movie = Episode(path: "\(anime.path)/filme/film-1", number: "1", title: "Film", languages: [])
        try profile.setWatched(true, episode: movie, anime: anime)
        XCTAssertEqual(profile.listStatuses(catalogs: [anime.id: catalog([movie])])[anime.id], .completed)
        XCTAssertEqual(profile.listStatuses(catalogs: [anime.id: catalog([movie, episode()])])[anime.id], .watching)
    }
    func testResetKeepsAutomaticallyCollectedAnimeAndProfilesStaySeparate() throws {
        var snapshot = LibrarySnapshot()
        let first = snapshot.activeProfileID
        try snapshot.update(first) { try $0.saveProgress(episode(), anime: anime, seconds: 60, duration: 1200, completed: false) }
        try snapshot.addProfile(name: "Zweitprofil", avatar: "sparkles")
        XCTAssertTrue(snapshot.active.watchlistItems.isEmpty)
        snapshot.activeProfileID = first
        snapshot.update(first) { $0.resetProgress() }
        XCTAssertEqual(snapshot.active.watchlistItems, [anime])
        XCTAssertEqual(snapshot.active.status(for: anime), .planned)
    }
}
