import XCTest
@testable import AniCore

final class WatchlistEntryTests: XCTestCase {
    private let anime = Anime(path: "/anime/stream/test", title: "Test")
    private func episode(_ season: Int = 1, _ number: Int = 1, in series: Anime? = nil) -> Episode {
        Episode(path: "\((series ?? anime).path)/staffel-\(season)/episode-\(number)", number: "\(number)", title: "Folge", languages: [])
    }
    private func catalog(_ episodes: [Episode]) -> SeriesCatalog {
        var result = SeriesCatalog()
        result.episodesBySeason = Dictionary(grouping: episodes, by: SeriesCatalog.seasonPath)
        result.seasons = result.episodesBySeason.keys.sorted().map { Season(path: $0, title: "Staffel") }
        result.refreshedAt = Date()
        return result
    }
    private let day: TimeInterval = 86_400

    func testTwoWeeksWithoutAnEpisodePausesAndWatchingAgainResumes() throws {
        var profile = ProfileLibrary()
        let now = Date()
        try profile.saveProgress(episode(), anime: anime, seconds: 300, duration: 1200, completed: false, date: now.addingTimeInterval(-13 * day))
        XCTAssertEqual(profile.listStatuses(now: now)[anime.id], .watching)
        XCTAssertEqual(profile.listStatuses(now: now.addingTimeInterval(2 * day))[anime.id], .paused)
        try profile.saveProgress(episode(1, 2), anime: anime, seconds: 30, duration: 1200, completed: false, date: now.addingTimeInterval(2 * day))
        XCTAssertEqual(profile.listStatuses(now: now.addingTimeInterval(2 * day))[anime.id], .watching)
    }

    func testFinishedSeriesNeverTurnsPausedAndManualStatusesWin() throws {
        var profile = ProfileLibrary()
        let first = episode(), long = Date().addingTimeInterval(-60 * day)
        try profile.saveProgress(first, anime: anime, seconds: 1200, duration: 1200, completed: true, date: long)
        XCTAssertEqual(profile.listStatuses(catalogs: [anime.id: catalog([first])])[anime.id], .completed)
        XCTAssertEqual(profile.listStatuses()[anime.id], .paused, "Without a catalog an old series only looks paused")
        profile.setStatus(.watching, for: anime)
        let entry = try XCTUnwrap(profile.watchlistEntries().first)
        XCTAssertEqual(entry.status, .watching)
        XCTAssertTrue(entry.manual)
    }

    func testEntryCountsOnlyItsOwnEpisodesAndKnowsTheSeriesLength() throws {
        var profile = ProfileLibrary()
        let sibling = Anime(path: "/anime/stream/test-2", title: "Test 2")
        let season1 = (1...12).map { episode(1, $0) }, season2 = (1...12).map { episode(2, $0) }
        for item in season1 { try profile.setWatched(true, episode: item, anime: anime) }
        try profile.setWatched(true, episode: episode(1, 1, in: sibling), anime: sibling)
        var entry = try XCTUnwrap(profile.watchlistEntries(catalogs: [anime.id: catalog(season1 + season2)]).first { $0.id == anime.id })
        XCTAssertEqual(entry.seenEpisodes, 12)
        XCTAssertEqual(entry.totalEpisodes, 24)
        XCTAssertEqual(entry.status, .watching)
        XCTAssertNil(entry.trophy, "Only finished series earn a trophy")
        for item in season2 { try profile.setWatched(true, episode: item, anime: anime) }
        entry = try XCTUnwrap(profile.watchlistEntries(catalogs: [anime.id: catalog(season1 + season2)]).first { $0.id == anime.id })
        XCTAssertEqual(entry.status, .completed)
        XCTAssertEqual(entry.trophy, .silver)
    }

    func testFinishedElsewhereGetsItsTrophyOnceTheLengthIsKnown() throws {
        var profile = ProfileLibrary()
        profile.setStatus(.completed, for: anime)
        var entry = try XCTUnwrap(profile.watchlistEntries().first)
        XCTAssertEqual(entry.status, .completed)
        XCTAssertNil(entry.trophy)
        entry = try XCTUnwrap(profile.watchlistEntries(catalogs: [anime.id: catalog((1...110).map { episode(1, $0) })]).first)
        XCTAssertEqual(entry.trophy, .platinum)
    }

    func testTrophyTiersFollowTheSeriesLength() {
        XCTAssertEqual(TrophyTier(episodes: 1), .bronze)
        XCTAssertEqual(TrophyTier(episodes: 12), .bronze)
        XCTAssertEqual(TrophyTier(episodes: 13), .silver)
        XCTAssertEqual(TrophyTier(episodes: 26), .silver)
        XCTAssertEqual(TrophyTier(episodes: 27), .gold)
        XCTAssertEqual(TrophyTier(episodes: 99), .gold)
        XCTAssertEqual(TrophyTier(episodes: 100), .platinum)
        XCTAssertTrue(TrophyTier.bronze < .platinum)
    }
}
