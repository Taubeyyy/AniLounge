import XCTest
import AniCore
@testable import AniLounge

@MainActor final class WatchlistStoreTests: XCTestCase {
    func testCatalogUpdatesChangeVisibleStatusAndProfileSwitchRestoresItsOwnList() throws {
        let suite = "WatchlistStore.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let detail = try AniParser.detail("""
        <div class="series-title"><h1>Test</h1></div>
        <a href="/anime/stream/test/staffel-1">1</a>
        <table><tr data-episode-id="1"><td><a href="/anime/stream/test/staffel-1/episode-1">Folge</a></td>
        <td><meta itemprop="episodeNumber" content="1"><span class="seasonEpisodeTitle"><strong>Test</strong></span></td></tr></table>
        """, path: "/anime/stream/test")
        let catalogs = SeriesCatalogStore(defaults: defaults)
        let library = LibraryStore(defaults: defaults, catalogs: catalogs)
        let original = library.profile.id
        let episode = try XCTUnwrap(detail.episodes.first)
        library.saveProgress(episode, anime: detail.anime, seconds: 60, duration: 1200, completed: false, profileID: original)
        XCTAssertEqual(library.favorites, [detail.anime])
        XCTAssertEqual(library.status(for: detail.anime), .watching)
        library.saveProgress(episode, anime: detail.anime, seconds: 1200, duration: 1200, completed: true, profileID: original)
        XCTAssertEqual(library.status(for: detail.anime), .watching)
        catalogs.remember(detail, path: detail.anime.path, isRoot: true)
        XCTAssertEqual(library.status(for: detail.anime), .completed, "New catalog information updates the already visible list")
        library.addProfile(name: "Anderes Profil", avatar: "sparkles")
        XCTAssertTrue(library.favorites.isEmpty)
        library.selectProfile(original)
        XCTAssertEqual(library.status(for: detail.anime), .completed)
        let restored = LibraryStore(defaults: defaults, catalogs: catalogs)
        XCTAssertEqual(restored.favorites, [detail.anime])
        restored.removeFromList(detail.anime)
        XCTAssertTrue(restored.favorites.isEmpty)
        XCTAssertEqual(restored.progress(for: episode)?.seconds, 1200)
    }
}
