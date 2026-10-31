import XCTest
@testable import AniCore

final class PlaybackQueueTests: XCTestCase {
    func testReplacementNeverChangesLanguageOrRepeatsAnAttempt() {
        let a = StreamHost(name: "A", language: "Deutsch", url: URL(string: "https://aniworld.to/redirect/1")!)
        let b = StreamHost(name: "B", language: "English", url: URL(string: "https://aniworld.to/redirect/2")!)
        let c = StreamHost(name: "C", language: "Deutsch", url: URL(string: "https://aniworld.to/redirect/3")!)
        XCTAssertEqual(PlaybackQueue.replacement(in: [a,b,c], current: a, attempted: [a.id]), c)
        XCTAssertNil(PlaybackQueue.replacement(in: [a,b,c], current: a, attempted: [a.id,c.id]))
        XCTAssertNil(PlaybackQueue.replacement(in: [a,b,c], current: a, attempted: [a.id,"x","y"]))
    }
    func testNextUsesCatalogOrderAndStopsAtSeasonEnd() {
        let a = Episode(path: "/a", number: "1", title: "First", languages: [])
        let special = Episode(path: "/special", number: "1.5", title: "Special", languages: [])
        let b = Episode(path: "/b", number: "2", title: "Second", languages: [])
        XCTAssertEqual(PlaybackQueue.next(after: a, in: [a,special,b]), special)
        XCTAssertNil(PlaybackQueue.next(after: b, in: [a,special,b]))
        XCTAssertNil(PlaybackQueue.next(after: a, in: []))
    }
}
