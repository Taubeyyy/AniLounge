import XCTest
import SwiftUI
import AVKit
import AniCore
@testable import AniLounge

@MainActor final class PlaybackLifecycleTests: XCTestCase {
    func testFullscreenCoverKeepsItemUntilPlaybackScreenIsRemoved() async throws {
        let suite = "PlaybackLifecycleTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let library = LibraryStore(defaults: defaults)
        let episode = try JSONDecoder().decode(Episode.self, from: Data("""
        {"path":"/anime/stream/test/staffel-1/episode-1","number":"1","title":"Test","languages":[]}
        """.utf8))
        let request = PlaybackRequest(anime: Anime(path: "/anime/stream/test", title: "Test"), episode: episode, profileID: library.profile.id)
        let model = PlayerModel(request: request, store: library)
        // No provider or network is needed for the lifecycle regression.
        model.hosts = try AniParser.hosts("""
        <div class="hosterSiteVideo"><li data-link-target="/redirect/1" data-lang-key="1"><h4>Fixture</h4></li></div>
        """)
        let item = AVPlayerItem(asset: AVMutableComposition())
        let player = AVPlayer(playerItem: item)
        model.player = player; model.nativeReady = true; model.preparing = false
        model.savedLabel = "10:00 / 24:00"
        let host = UIHostingController(rootView: AnyView(PlaybackView(model: model)))
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { model.finish(); window.isHidden = true; window.rootViewController = nil }
        try await Task.sleep(nanoseconds: 300_000_000)
        // Fullscreen presentation drives the same host disappearance callback as AVKit.
        let fullscreen = UIViewController()
        fullscreen.modalPresentationStyle = .fullScreen
        await withCheckedContinuation { continuation in
            host.present(fullscreen, animated: false) { continuation.resume() }
        }
        XCTAssertTrue(model.player === player)
        XCTAssertTrue(player.currentItem === item, "Fullscreen must not clear the AVPlayerItem")
        XCTAssertTrue(model.nativeReady)
        XCTAssertEqual(model.savedLabel, "10:00 / 24:00")
        await withCheckedContinuation { continuation in
            fullscreen.dismiss(animated: false) { continuation.resume() }
        }
        XCTAssertTrue(player.currentItem === item, "Returning to inline must retain the same item")
        // Removing the owning SwiftUI view must still release the player.
        host.rootView = AnyView(EmptyView())
        for _ in 0..<30 {
            if model.player == nil { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertNil(model.player)
        XCTAssertNil(player.currentItem)
        model.finish() // Repeated explicit close remains harmless.
    }
}
