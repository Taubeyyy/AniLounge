import XCTest
import SwiftUI
import AniCore
@testable import AniLounge

/// Screenshots of the 1.1 premium pass (tab bar, billboard, shelves, full-screen player) and
/// the small pieces of player logic behind it.
@MainActor final class PremiumVisualTests: XCTestCase {
    private let tabs = [
        LoungeTab(title: "Start", icon: "house", selectedIcon: "house.fill"),
        LoungeTab(title: "Suche", icon: "magnifyingglass", selectedIcon: "magnifyingglass"),
        LoungeTab(title: "Watchlist", icon: "bookmark", selectedIcon: "bookmark.fill"),
        LoungeTab(title: "Downloads", icon: "arrow.down.circle", selectedIcon: "arrow.down.circle.fill"),
        LoungeTab(title: "Profil", icon: "person.crop.circle", selectedIcon: "person.crop.circle.fill")
    ]

    func testPremiumScreens() async throws {
        let suite = "PremiumVisual.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let library = LibraryStore(defaults: defaults)
        let anime = Anime(path: "preview://premium", title: "Eine Reise unter dem Sternenhimmel")
        let shelf = (1...9).map { Anime(path: "preview://premium/\($0)", title: "Abenteuer Nummer \($0) im Sternenmeer") }
        let episodes = try (1...6).map { number in
            try JSONDecoder().decode(Episode.self, from: Data("""
            {"path":"preview://premium/episode-\(number)","number":"\(number)","title":"Folge \(number)","languages":["Deutsch"]}
            """.utf8))
        }
        library.saveProgress(episodes[0], anime: anime, seconds: 1440, duration: 1440, completed: true, profileID: library.profile.id)
        library.saveProgress(episodes[2], anime: anime, seconds: 500, duration: 1440, completed: false, profileID: library.profile.id)

        await capture("Premium-Tabbar", size: CGSize(width: 393, height: 110),
                      view: VStack(spacing: 0) { Spacer(); LoungeTabBar(tabs: tabs, selected: .constant(2)) }.background(Theme.background))
        await capture("Premium-Startkarte", size: CGSize(width: 393, height: 480),
                      view: NavigationStack {
                          HeroView(anime: anime).frame(height: 440).clipShape(RoundedRectangle(cornerRadius: 16))
                              .padding(.horizontal, 20).frame(maxHeight: .infinity).background(Theme.background)
                              .toolbar(.hidden, for: .navigationBar)
                      }.environmentObject(library))
        await capture("Premium-Regal", size: CGSize(width: 393, height: 300),
                      view: NavigationStack {
                          AnimeShelf(title: "Beliebt diese Woche", items: shelf).frame(maxHeight: .infinity, alignment: .top)
                              .background(Theme.background).toolbar(.hidden, for: .navigationBar)
                      }.environmentObject(library))

        let player = PlayerModel(request: PlaybackRequest(anime: anime, episode: episodes[1], profileID: library.profile.id), store: library)
        defer { player.finish() }
        player.nextEpisode = episodes[2]
        // 40 s in, without AniSkip times: the intro button is in its prominent moment.
        player.clock.seconds = 40; player.clock.duration = 1440; player.clock.buffered = 300
        await capture("Premium-Player-Querformat", size: CGSize(width: 844, height: 390),
                      view: PlayerControls(model: player, clock: player.clock, theater: true, close: {}, more: {}, toggleFullscreen: {},
                                           interactionLocked: false, showEpisodes: {}, episodesAvailable: true).background(.black))
        await capture("Premium-Player-Hochformat", size: CGSize(width: 393, height: 221),
                      view: PlayerControls(model: player, clock: player.clock, theater: false, close: {}, more: {}, toggleFullscreen: {},
                                           interactionLocked: false).background(.black))
        await capture("Premium-Folgenleiste", size: CGSize(width: 844, height: 390),
                      view: ZStack { Color.black; EpisodeStrip(model: player, episodes: episodes, theater: true, close: {}) })
        await capture("Premium-Folgenleiste-Hochformat", size: CGSize(width: 393, height: 852),
                      view: ZStack { Color.black; EpisodeStrip(model: player, episodes: episodes, theater: false, close: {}) })
        player.clock.seconds = 1400
        player.countdown = 7
        await capture("Premium-Player-Countdown", size: CGSize(width: 844, height: 390),
                      view: PlayerControls(model: player, clock: player.clock, theater: true, close: {}, more: {}, toggleFullscreen: {},
                                           interactionLocked: false, showEpisodes: {}, episodesAvailable: true).background(.black))
    }

    func testSpeedButtonCyclesAndWraps() throws {
        let suite = "PremiumSpeed.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let stored = AppSettings.shared.speed
        defer { AppSettings.shared.speed = stored }
        let library = LibraryStore(defaults: defaults)
        let episode = try JSONDecoder().decode(Episode.self, from: Data("""
        {"path":"preview://speed/episode-1","number":"1","title":"Folge 1","languages":["Deutsch"]}
        """.utf8))
        let player = PlayerModel(request: PlaybackRequest(anime: Anime(path: "preview://speed", title: "Tempo"), episode: episode,
                                                          profileID: library.profile.id), store: library)
        defer { player.finish() }
        player.setSpeed(1)
        player.cycleSpeed()
        XCTAssertEqual(player.speed, 1.25)
        player.setSpeed(2)
        player.cycleSpeed()
        XCTAssertEqual(player.speed, 0.75)
        player.cycleSpeed()
        XCTAssertEqual(player.speed, 1)
        XCTAssertEqual(player.toast, "Tempo 1x")
    }

    func testEpisodeTitleFallsBackToMetadataOnlyForGenericNames() throws {
        let suite = "PremiumTitle.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let library = LibraryStore(defaults: defaults)
        let named = try JSONDecoder().decode(Episode.self, from: Data("""
        {"path":"preview://title/episode-2","number":"2","title":"Der Sturm","languages":["Deutsch"]}
        """.utf8))
        let player = PlayerModel(request: PlaybackRequest(anime: Anime(path: "preview://title", title: "Titel"), episode: named,
                                                          profileID: library.profile.id), store: library)
        defer { player.finish() }
        XCTAssertEqual(player.displayTitle(of: named), "Der Sturm")
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
        try? await Task.sleep(nanoseconds: 400_000_000)
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
