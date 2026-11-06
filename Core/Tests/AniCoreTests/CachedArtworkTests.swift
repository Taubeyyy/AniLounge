import XCTest
@testable import AniCore

final class CachedArtworkTests: XCTestCase {
    func testPersistedArtworkLinksAreAvailableBeforeAnyAsyncLoad() throws {
        let suite = "CachedArtwork.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let anime = Anime(path: "/anime/stream/fixture", title: "Fixture")
        let poster = try XCTUnwrap(URL(string: "https://example.invalid/poster.jpg"))
        let backdrop = try XCTUnwrap(URL(string: "https://example.invalid/wide.jpg"))
        defaults.set([anime.id: poster.absoluteString], forKey: "artwork.covers.v1")
        defaults.set([anime.id: backdrop.absoluteString], forKey: "artwork.backdrops.v1")
        let client = AniClient(defaults: defaults)
        XCTAssertEqual(client.cachedCover(for: anime), poster)
        XCTAssertEqual(client.cachedBackdrop(for: anime), backdrop)
        var fresh = anime
        fresh.poster = backdrop
        XCTAssertEqual(client.cachedCover(for: fresh), backdrop)
        XCTAssertNil(client.cachedCover(for: Anime(path: "/unknown", title: "Unknown")))
    }
}
