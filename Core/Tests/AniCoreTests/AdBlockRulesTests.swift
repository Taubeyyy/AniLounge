import XCTest
@testable import AniCore

final class AdBlockRulesTests: XCTestCase {
    func testAdDomainsAndSubdomainsAreBlocked() throws {
        for domain in AdBlockRules.domains {
            XCTAssertTrue(AdBlockRules.blocks(try XCTUnwrap(URL(string: "https://" + domain + "/ad.js"))))
            XCTAssertTrue(AdBlockRules.blocks(try XCTUnwrap(URL(string: "https://cdn." + domain + "/ad.js"))))
        }
    }
    func testVideoHostsAndLookalikeNamesAreAllowed() throws {
        for value in ["https://aniworld.to/redirect/1", "https://voe.sx/e/video", "https://cdn.example/video.m3u8", "https://notdoubleclick.net/video", "https://doubleclick.net.example/video", "https://example.com/?ad=popads.net"] {
            XCTAssertFalse(AdBlockRules.blocks(try XCTUnwrap(URL(string: value))), value)
        }
    }
    func testEncodedRulesUseExactDomainBoundaries() throws {
        let rules = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(AdBlockRules.encoded().utf8)) as? [[String: Any]])
        XCTAssertEqual(rules.count, AdBlockRules.domains.count)
        let expressions = try rules.map { rule -> NSRegularExpression in
            let trigger = try XCTUnwrap(rule["trigger"] as? [String: String])
            return try NSRegularExpression(pattern: XCTUnwrap(trigger["url-filter"]))
        }
        func matches(_ value: String) -> Bool {
            expressions.contains { $0.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) != nil }
        }
        XCTAssertTrue(matches("https://cdn.popads.net/script.js"))
        XCTAssertTrue(matches("https://doubleclick.net:443/ad"))
        XCTAssertFalse(matches("https://doubleclick.net.example/video.mp4"))
        XCTAssertFalse(matches("https://cdn.example/video.m3u8?ref=popads.net"))
    }
}
