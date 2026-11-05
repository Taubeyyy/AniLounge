import XCTest
@testable import AniCore

final class SeriesPlaybackStateTests: XCTestCase {
    private let anime = Anime(path: "/anime/stream/test", title: "Test")
    private func episode(_ season: Int, _ number: Int) -> Episode {
        Episode(path: "/anime/stream/test/staffel-\(season)/episode-\(number)", number: "\(number)", title: "Episode", languages: ["Deutsch"])
    }
    private func catalog() -> SeriesCatalog {
        var catalog = SeriesCatalog()
        catalog.seasons = [Season(path: "/anime/stream/test/staffel-1", title: "Staffel 1"),
                           Season(path: "/anime/stream/test/staffel-2", title: "Staffel 2")]
        catalog.episodesBySeason[catalog.seasons[0].path] = [episode(1, 1), episode(1, 2)]
        return catalog
    }
    func testResumeDoesNotRequireAnyOnlineCatalog() throws {
        var profile = ProfileLibrary()
        try profile.saveProgress(episode(1, 1), anime: anime, seconds: 750, duration: 1440, completed: false)
        let result = SeriesPlaybackState.start(anime: anime, profile: profile, catalog: nil)
        XCTAssertEqual(result, .resume(try XCTUnwrap(profile.latest(for: anime))))
    }
    func testCompletedEpisodeOffersNextAndNeverRestartsFirst() throws {
        var profile = ProfileLibrary()
        try profile.saveProgress(episode(1, 1), anime: anime, seconds: 1440, duration: 1440, completed: true)
        XCTAssertEqual(SeriesPlaybackState.start(anime: anime, profile: profile, catalog: catalog()), .play(episode(1, 2)))
        XCTAssertEqual(SeriesPlaybackState.next(after: episode(1, 1), catalog: catalog()), .play(episode(1, 2)))
    }
    func testSeasonBoundaryRequiresMissingCatalogThenOffersNextSeason() {
        var catalog = catalog()
        let last = episode(1, 2), next = episode(2, 1)
        XCTAssertEqual(SeriesPlaybackState.next(after: last, catalog: catalog), .needsSeason(catalog.seasons[1].path))
        catalog.episodesBySeason[catalog.seasons[1].path] = [next]
        XCTAssertEqual(SeriesPlaybackState.next(after: last, catalog: catalog), .play(next))
    }
    func testCaughtUpAndLaterNewEpisode() throws {
        var catalog = catalog()
        catalog.episodesBySeason[catalog.seasons[1].path] = [episode(2, 1)]
        var profile = ProfileLibrary()
        try profile.saveProgress(episode(2, 1), anime: anime, seconds: 1440, duration: 1440, completed: true)
        XCTAssertEqual(SeriesPlaybackState.start(anime: anime, profile: profile, catalog: catalog), .caughtUp)
        catalog.episodesBySeason[catalog.seasons[1].path]?.append(episode(2, 2))
        XCTAssertEqual(SeriesPlaybackState.start(anime: anime, profile: profile, catalog: catalog), .play(episode(2, 2)))
    }
    func testLegacyWatchedMarksSkipKnownEpisodesAndNeedUnloadedSeason() {
        var profile = ProfileLibrary()
        profile.watched = [episode(1, 1).id, episode(1, 2).id]
        XCTAssertEqual(SeriesPlaybackState.start(anime: anime, profile: profile, catalog: catalog()), .needsSeason("/anime/stream/test/staffel-2"))
    }
    func testPlayerAndStartSkipTheSameWatchedEpisodes() throws {
        var profile = ProfileLibrary()
        try profile.saveProgress(episode(1, 1), anime: anime, seconds: 1440, duration: 1440, completed: true)
        profile.watched.insert(episode(1, 2).id)
        let start = SeriesPlaybackState.start(anime: anime, profile: profile, catalog: catalog())
        let next = SeriesPlaybackState.next(after: episode(1, 1), catalog: catalog(), watched: profile.watched)
        XCTAssertEqual(start, .needsSeason("/anime/stream/test/staffel-2"))
        XCTAssertEqual(start, next)
    }
    func testRemovedEpisodeDoesNotBecomeFirstEpisode() {
        XCTAssertEqual(SeriesPlaybackState.next(after: episode(1, 9), catalog: catalog()), .unavailable)
    }
    func testFilmDoesNotAdvanceIntoTVSeason() {
        var catalog = catalog()
        let film = Episode(path: "/anime/stream/test/filme/film-1", number: "1", title: "Film", languages: [])
        catalog.seasons.insert(Season(path: "/anime/stream/test/filme", title: "Filme"), at: 0)
        catalog.episodesBySeason["/anime/stream/test/filme"] = [film]
        XCTAssertEqual(SeriesPlaybackState.next(after: film, catalog: catalog), .caughtUp)
    }
    func testSeasonPageCanSeedCatalogAfterDirectResume() {
        let known = catalog()
        let detail = AnimeDetail(anime: anime, synopsis: "", genres: [], year: "", seasons: known.seasons,
                                 episodes: [episode(1, 1), episode(1, 2)], backdrop: nil)
        var fresh = SeriesCatalog()
        fresh.record(detail, path: "/anime/stream/test/staffel-1", isRoot: false)
        XCTAssertEqual(SeriesPlaybackState.next(after: episode(1, 1), catalog: fresh), .play(episode(1, 2)))
        XCTAssertEqual(SeriesPlaybackState.next(after: episode(1, 2), catalog: fresh), .needsSeason("/anime/stream/test/staffel-2"))
    }
    func testCatalogRoundTripAndRootRefreshInvalidatesOldSeasonLists() throws {
        var catalog = catalog()
        catalog.episodesBySeason[catalog.seasons[1].path] = [episode(2, 1)]
        let restored = try JSONDecoder().decode(SeriesCatalog.self, from: JSONEncoder().encode(catalog))
        XCTAssertEqual(SeriesPlaybackState.next(after: episode(1, 2), catalog: restored), .play(episode(2, 1)))
        let detail = AnimeDetail(anime: anime, synopsis: "", genres: [], year: "", seasons: catalog.seasons,
                                 episodes: [episode(1, 1), episode(1, 2)], backdrop: nil)
        catalog.record(detail, path: anime.path, isRoot: true)
        XCTAssertEqual(SeriesPlaybackState.next(after: episode(1, 2), catalog: catalog), .needsSeason("/anime/stream/test/staffel-2"))
    }
}
