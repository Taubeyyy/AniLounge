import XCTest
import UIKit
@testable import AniLounge

private actor ArtworkRequests {
    let data: Data
    private(set) var count = 0
    init(data: Data) { self.data = data }
    func fetch(_ request: URLRequest) async throws -> (Data, URLResponse) {
        count += 1
        try await Task.sleep(nanoseconds: 80_000_000)
        return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

@MainActor final class ArtworkCacheTests: XCTestCase {
    private func fixture() throws -> (URL, URL, ArtworkRequests) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 600, height: 900), format: format).image { context in
            UIColor.purple.setFill(); context.fill(CGRect(x: 0, y: 0, width: 600, height: 900))
        }
        return (directory, URL(string: "https://example.invalid/poster.png")!, ArtworkRequests(data: try XCTUnwrap(image.pngData())))
    }

    func testDifferentSizesShareDownloadAndRestartUsesDiskOffline() async throws {
        let (directory, url, requests) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = ArtworkCache(directory: directory, download: { try await requests.fetch($0) })
        async let small = cache.image(for: url, filling: CGSize(width: 60, height: 90))
        async let hero = cache.image(for: url, filling: CGSize(width: 600, height: 900))
        let (first, second) = await (small, hero)
        XCTAssertNotNil(first); XCTAssertNotNil(second)
        let count = await requests.count
        XCTAssertEqual(count, 1, "Poster and hero must share the same transfer")

        let offlineRequests = ArtworkRequests(data: Data())
        let restarted = ArtworkCache(directory: directory, download: { try await offlineRequests.fetch($0) })
        let restored = await restarted.image(for: url, filling: CGSize(width: 300, height: 450))
        XCTAssertNotNil(restored)
        let offlineCount = await offlineRequests.count
        XCTAssertEqual(offlineCount, 0, "Valid disk images must not contact the network")
    }

    func testOriginalResolutionIsReusedEvenInAnOversizedFrame() async throws {
        let (directory, url, requests) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = ArtworkCache(directory: directory, download: { try await requests.fetch($0) })
        let full = await cache.image(for: url, filling: CGSize(width: 1200, height: 1800))
        let first = try XCTUnwrap(full)
        XCTAssertTrue(cache.memoryImage(url, filling: CGSize(width: 2400, height: 3600)) === first)
        let again = await cache.image(for: url, filling: CGSize(width: 2400, height: 3600))
        XCTAssertTrue(again === first, "A small original must not be decoded again on every appearance")
    }

    func testLoaderKeepsPreviewDuringUpgradeAndNeverShowsAnotherURL() async throws {
        let (directory, url, requests) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = ArtworkCache(directory: directory, download: { try await requests.fetch($0) })
        let loader = CoverLoader(cache: cache)
        await loader.load(url, filling: CGSize(width: 60, height: 90))
        XCTAssertNotNil(loader.image(for: url))
        let upgrade = Task { await loader.load(url, filling: CGSize(width: 600, height: 900)) }
        await Task.yield()
        XCTAssertNotNil(loader.image(for: url), "The preview stays visible during a larger disk decode")
        await upgrade.value
        XCTAssertNil(loader.image(for: URL(string: "https://example.invalid/other.png")))
        await loader.load(nil)
        XCTAssertNil(loader.image)
        let count = await requests.count
        XCTAssertEqual(count, 1)
    }
}
