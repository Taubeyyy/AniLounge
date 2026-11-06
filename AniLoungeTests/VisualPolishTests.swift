import XCTest
import SwiftUI
import AniCore
@testable import AniLounge

@MainActor final class VisualPolishTests: XCTestCase {
    func testCompactAndAccessibleLayouts() async throws {
        let suite = "VisualPolish.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let library = LibraryStore(defaults: defaults)
        await capture("Profiluebersicht-leer-iPhone-320", size: CGSize(width: 320, height: 440),
                      view: ProfileSummaryView(openProfile: {}).environmentObject(library))
        let anime = Anime(path: "preview://series", title: "Eine Reise unter dem Sternenhimmel")
        library.toggle(anime)
        let episode = try JSONDecoder().decode(Episode.self, from: Data("""
        {"path":"preview://series/episode-1","number":"1","title":"Ein unerwarteter Aufbruch in eine neue Welt","languages":["Deutsch","Mit deutschem Untertitel"]}
        """.utf8))
        library.setStatus(.completed, for: anime)
        library.saveProgress(episode, anime: anime, seconds: 1440, duration: 1440,
                             completed: true, profileID: library.profile.id)
        await capture("Profiluebersicht-iPhone", size: CGSize(width: 393, height: 440),
                      view: ProfileSummaryView(openProfile: {}).environmentObject(library))
        await capture("Profiluebersicht-grosse-Schrift", size: CGSize(width: 393, height: 852),
                      view: ProfileSummaryView(openProfile: {}).environmentObject(library).dynamicTypeSize(.accessibility2))
        await capture("Watchlist-iPhone-320", size: CGSize(width: 320, height: 640),
                      view: NavigationStack { SavedView() }.environmentObject(library))
        await capture("Watchlist-grosse-Schrift", size: CGSize(width: 393, height: 852),
                      view: NavigationStack { SavedView() }.environmentObject(library).dynamicTypeSize(.accessibility2))
        await capture("Startkarte-iPhone-320", size: CGSize(width: 320, height: 440),
                      view: HeroView(anime: anime).environmentObject(library).padding(20).background(Theme.background))
        await capture("Folge-grosse-Schrift", size: CGSize(width: 393, height: 600),
                      view: VStack {
                          EpisodeRow(episode: episode, info: nil, title: episode.title, progress: nil,
                                     seen: false, current: true, play: {}, more: {})
                          Spacer()
                      }.padding(20).background(Theme.background).dynamicTypeSize(.accessibility2))
        let player = PlayerModel(request: PlaybackRequest(anime: anime, episode: episode, profileID: library.profile.id), store: library)
        defer { player.finish() }
        player.clock.seconds = 750; player.clock.duration = 1440; player.clock.buffered = 900
        await capture("Player-iPhone-320", size: CGSize(width: 320, height: 240),
                      view: PlayerControls(model: player, clock: player.clock, theater: false,
                                           close: {}, more: {}, toggleFullscreen: {}, interactionLocked: false).background(.black))
        await capture("Player-Querformat", size: CGSize(width: 812, height: 375),
                      view: PlayerControls(model: player, clock: player.clock, theater: true,
                                           close: {}, more: {}, toggleFullscreen: {}, interactionLocked: false).background(.black))
    }

    private func capture<V: View>(_ name: String, size: CGSize, view: V) async {
        let host = UIHostingController(rootView: view.preferredColorScheme(.dark))
        let window = UIWindow(frame: CGRect(origin: .zero, size: size))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        host.view.frame = window.bounds
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        try? await Task.sleep(nanoseconds: 350_000_000)
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { _ in
            XCTAssertTrue(host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true), name)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
