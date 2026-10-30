import XCTest
@testable import AniCore

final class PlaybackSourceTests: XCTestCase {
    func testNativeHostSelectionPreservesLanguageAndRejectsForeignRedirects() throws {
        let html = """
        <div class="hosterSiteVideo">
        <div class="changeLanguageBox"><img data-lang-key="1" title="Deutsch"><img data-lang-key="3" title="mit Untertitel Deutsch"></div>
        <ul>
        <li data-lang-key="1" data-link-target="/redirect/123"><h4>Host A</h4></li>
        <li data-lang-key="1" data-link-target="/redirect/123"><h4>Duplicate</h4></li>
        <li data-lang-key="3" data-link-target="/redirect/456"><h4>Host A</h4></li>
        <li data-lang-key="1" data-link-target="https://other.example/redirect/789"><h4>Advertisement</h4></li>
        <li data-lang-key="1" data-link-target="/advertisement"><h4>Advertisement</h4></li>
        </ul></div>
        """
        let hosts = try AniParser.hosts(html)
        XCTAssertEqual(hosts.map(\.language), ["Deutsch", "mit Untertitel Deutsch"])
        XCTAssertEqual(hosts.map(\.url.path), ["/redirect/123", "/redirect/456"])
        XCTAssertThrowsError(try AniParser.hosts("<p>Changed markup</p>"))
    }
    func testNativeSourceValidationKeepsSignedQueriesAndChecksType() {
        let signed = "https://cdn.example/video.m3u8?token=123&expires=456"
        XCTAssertEqual(PlaybackSource.directURL(signed)?.absoluteString, signed)
        XCTAssertNotNil(PlaybackSource.directURL("https://cdn.example/stream?id=1", mimeType: "video/mp4"))
        for value in ["blob:https://cdn.example/123", "javascript:alert(1)", "file:///video.mp4", "http://cdn.example/v.mp4", "https://user:secret@cdn.example/v.mp4", "https://cdn.example/page"] {
            XCTAssertNil(PlaybackSource.directURL(value), value)
        }
    }
    func testResumeClampsAndRejectsUnrelatedDuration() {
        XCTAssertEqual(PlaybackSource.resumePosition(saved: 600, savedDuration: 1440, duration: 1445), 600)
        XCTAssertEqual(PlaybackSource.resumePosition(saved: 600, savedDuration: 1440, duration: 120), 0)
        XCTAssertEqual(PlaybackSource.resumePosition(saved: 1500, savedDuration: nil, duration: 1440), 1439)
        XCTAssertEqual(PlaybackSource.resumePosition(saved: .nan, savedDuration: nil, duration: 1440), 0)
    }
}
