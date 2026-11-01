import XCTest
import AniCore
@testable import AniLounge

final class SimilarMatcherTests: XCTestCase {
    func testMatchesAliasesIgnoringCaseAndPunctuationWithoutDuplicates() {
        let catalog = [Anime(path: "/anime/stream/mushishi", title: "Mushishi", aliases: "Mushi-Shi, 蟲師"),
                       Anime(path: "/anime/stream/frieren", title: "Frieren: Beyond Journey’s End", aliases: "Sousou no Frieren")]
        let result = SimilarMatcher.match([["Sousou no Frieren"], ["MUSHI-SHI"], ["Mushishi"], ["Unknown Show"]], in: catalog)
        XCTAssertEqual(result.map(\.path), ["/anime/stream/frieren", "/anime/stream/mushishi"])
    }
}
