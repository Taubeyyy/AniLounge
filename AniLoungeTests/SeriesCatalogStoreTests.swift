import XCTest
import AniCore
@testable import AniLounge

@MainActor final class SeriesCatalogStoreTests: XCTestCase {
    private func detail(season: Int, number: Int) throws -> AnimeDetail {
        try AniParser.detail("""
        <div class="series-title"><h1>Test</h1></div>
        <a href="/anime/stream/test/staffel-1">1</a>
        <a href="/anime/stream/test/staffel-2">2</a>
        <table><tr data-episode-id="\(number)">
        <td><a href="/anime/stream/test/staffel-\(season)/episode-\(number)">Folge</a></td>
        <td><meta itemprop="episodeNumber" content="\(number)"><span class="seasonEpisodeTitle"><strong>Test</strong></span></td>
        </tr></table>
        """, path: "/anime/stream/test")
    }

    func testHomeDetailAndPlayerResolveSameSeasonBoundaryAndCacheSurvivesRestart() async throws {
        let suite = "SeriesCatalogTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = try detail(season: 1, number: 1), second = try detail(season: 2, number: 1)
        var requested: [String] = []
        let store = SeriesCatalogStore(defaults: defaults) { path in
            requested.append(path)
            return path.hasSuffix("staffel-2") ? second : first
        }
        var profile = ProfileLibrary()
        let episode = try XCTUnwrap(first.episodes.first)
        try profile.saveProgress(episode, anime: first.anime, seconds: 1440, duration: 1440, completed: true)
        let start = try await store.resolveStart(anime: first.anime, profile: profile)
        let next = try await store.resolveNext(after: episode, anime: first.anime)
        XCTAssertEqual(start, .play(try XCTUnwrap(second.episodes.first)))
        XCTAssertEqual(start, next)
        XCTAssertEqual(requested, ["/anime/stream/test", "/anime/stream/test/staffel-2"])
        let offline = SeriesCatalogStore(defaults: defaults) { _ in
            XCTFail("A cached continuation must not require the network")
            throw URLError(.notConnectedToInternet)
        }
        let cached = try await offline.resolveStart(anime: first.anime, profile: profile)
        XCTAssertEqual(cached, start)
    }

    func testOfflineResumeNeedsNoCatalogAndFailedRefreshKeepsCachedData() async throws {
        let suite = "SeriesCatalogOfflineTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = try detail(season: 1, number: 1)
        var profile = ProfileLibrary()
        try profile.saveProgress(XCTUnwrap(first.episodes.first), anime: first.anime, seconds: 750, duration: 1440, completed: false)
        var requests = 0
        let store = SeriesCatalogStore(defaults: defaults) { _ in
            requests += 1
            throw URLError(.notConnectedToInternet)
        }
        let decision = try await store.resolveStart(anime: first.anime, profile: profile)
        XCTAssertEqual(decision, .resume(try XCTUnwrap(profile.latest(for: first.anime))))
        XCTAssertEqual(requests, 0)
        store.remember(first, path: first.anime.path, isRoot: true)
        do {
            _ = try await store.resolveStart(anime: first.anime, profile: profile, refresh: true)
            XCTFail("Expected offline error")
        } catch {}
        XCTAssertNotNil(store.catalogs[first.anime.id])
    }
}
