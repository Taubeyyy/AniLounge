import XCTest
@testable import AniCore

final class DownloadRestorationTests: XCTestCase {
    func testBothHLSSessionsMustAnswerBeforeMissingTasksAreDecided() {
        let cellular = UUID(), wifi = UUID(), missing = UUID(), newlyAdded = UUID()
        for order in [["files", "hls", "wifi"], ["wifi", "files", "hls"], ["hls", "wifi", "files"]] {
            var state = DownloadRestoration(sessionIDs: ["files", "hls", "wifi"], downloadIDs: [cellular, wifi, missing])
            for (index, session) in order.enumerated() {
                let found: Set<UUID> = session == "hls" ? [cellular, newlyAdded] : session == "wifi" ? [wifi] : []
                let result = state.received(sessionID: session, downloadIDs: found)
                if index < 2 { XCTAssertNil(result) }
                else { XCTAssertEqual(result, [missing]) }
            }
            XCTAssertNil(state.received(sessionID: order[0], downloadIDs: []))
        }
    }
    func testUnexpectedSessionDoesNotFinishRestoration() {
        var state = DownloadRestoration(sessionIDs: ["expected"], downloadIDs: [UUID()])
        XCTAssertNil(state.received(sessionID: "unexpected", downloadIDs: []))
        XCTAssertEqual(state.received(sessionID: "expected", downloadIDs: [])?.count, 1)
    }
}
