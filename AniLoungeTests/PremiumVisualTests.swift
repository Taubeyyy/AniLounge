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

    func testWatchlistListsAndTrophyCabinet() async throws {
        let suite = "PremiumWatchlist.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let now = Date(), day: TimeInterval = 86_400
        func series(_ slug: String, _ title: String) -> Anime { Anime(path: "/anime/stream/\(slug)", title: title) }
        func episode(_ anime: Anime, _ season: Int, _ number: Int) throws -> Episode {
            try JSONDecoder().decode(Episode.self, from: Data("""
            {"path":"\(anime.path)/staffel-\(season)/episode-\(number)","number":"\(number)","title":"Folge \(number)","languages":["Deutsch"]}
            """.utf8))
        }
        let current = series("frieren", "Frieren – Nach dem Ende der Reise")
        let recent = series("dandadan", "Dandadan")
        let resting = series("vinland-saga", "Vinland Saga")
        let planned = [series("solo-leveling", "Solo Leveling"), series("kaiju-8", "Kaiju No. 8"),
                       series("oshi-no-ko", "Oshi no Ko"), series("spy-family", "Spy x Family")]
        let finished = [(series("one-piece", "One Piece"), 120), (series("jjk", "Jujutsu Kaisen"), 47),
                        (series("mob", "Mob Psycho 100"), 25), (series("chainsaw", "Chainsaw Man"), 12)]
        let halfway = try episode(current, 1, 5), done = try episode(recent, 2, 3), stopped = try episode(resting, 1, 9)
        var snapshot = LibrarySnapshot()
        try snapshot.update(snapshot.activeProfileID) { library in
            try library.saveProgress(halfway, anime: current, seconds: 700, duration: 1440, completed: false, date: now.addingTimeInterval(-3600))
            try library.saveProgress(done, anime: recent, seconds: 1440, duration: 1440, completed: true, date: now.addingTimeInterval(-2 * day))
            try library.saveProgress(stopped, anime: resting, seconds: 300, duration: 1440, completed: false, date: now.addingTimeInterval(-24 * day))
            for anime in planned.reversed() { library.setStatus(.planned, for: anime) }
            for (anime, count) in finished {
                for number in 1...count { library.watched.insert("\(anime.path)/staffel-1/episode-\(number)") }
                library.setStatus(.completed, for: anime)
            }
        }
        try LibraryPersistence(defaults: defaults).save(snapshot)
        let library = LibraryStore(defaults: defaults, catalogs: SeriesCatalogStore(defaults: defaults))
        XCTAssertEqual(library.status(for: current), .watching)
        XCTAssertEqual(library.status(for: recent), .watching)
        XCTAssertEqual(library.status(for: resting), .paused, "24 days without an episode")
        XCTAssertEqual(library.status(for: planned[0]), .planned)
        XCTAssertEqual(finished.map { library.entry(for: $0.0)?.trophy }, [.platinum, .gold, .silver, .bronze])

        for (status, name) in [(WatchStatus.watching, "Schaue-ich"), (.planned, "Geplant"), (.paused, "Pausiert"), (.completed, "Trophaeen")] {
            await capture("Watchlist-Premium-\(name)", size: CGSize(width: 393, height: 852), settle: 1.3,
                          view: NavigationStack { SavedView(initialFilter: status) }.environmentObject(library))
        }
        let emptySuite = suite + ".empty"
        let emptyDefaults = try XCTUnwrap(UserDefaults(suiteName: emptySuite))
        defer { emptyDefaults.removePersistentDomain(forName: emptySuite) }
        let empty = LibraryStore(defaults: emptyDefaults, catalogs: SeriesCatalogStore(defaults: emptyDefaults))
        await capture("Watchlist-Premium-leer", size: CGSize(width: 393, height: 700), settle: 1.0,
                      view: NavigationStack { SavedView(initialFilter: .completed) }.environmentObject(empty))
        await capture("Trophaee-Banner", size: CGSize(width: 393, height: 150), settle: 1.0,
                      view: VStack {
                          TrophyBanner(unlock: TrophyCenter.Unlock(anime: current, tier: .gold, episodes: 28)).padding(16)
                          Spacer()
                      }.background(Theme.background))
    }

    func testFinishingTheLastEpisodeUnlocksATrophyWhileOldSeriesStayQuiet() throws {
        let suite = "PremiumTrophy.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        func detail(_ slug: String) throws -> AnimeDetail {
            try AniParser.detail("""
            <div class="series-title"><h1>\(slug)</h1></div>
            <a href="/anime/stream/\(slug)/staffel-1">1</a>
            <table><tr data-episode-id="1"><td><a href="/anime/stream/\(slug)/staffel-1/episode-1">Folge</a></td>
            <td><meta itemprop="episodeNumber" content="1"><span class="seasonEpisodeTitle"><strong>Finale</strong></span></td></tr></table>
            """, path: "/anime/stream/\(slug)")
        }
        let center = TrophyCenter.shared
        func announced(_ anime: Anime) -> Bool {
            center.current?.anime.id == anime.id || center.queue.contains { $0.anime.id == anime.id }
        }
        // Finished two days ago; the catalog only arrives now, as after an app start: no banner.
        let quiet = try detail("trophy-quiet")
        let old = try XCTUnwrap(quiet.episodes.first)
        var snapshot = LibrarySnapshot()
        try snapshot.update(snapshot.activeProfileID) {
            try $0.saveProgress(old, anime: quiet.anime, seconds: 1200, duration: 1200, completed: true, date: Date().addingTimeInterval(-2 * 86_400))
        }
        try LibraryPersistence(defaults: defaults).save(snapshot)
        let catalogs = SeriesCatalogStore(defaults: defaults)
        let library = LibraryStore(defaults: defaults, catalogs: catalogs)
        catalogs.remember(quiet, path: quiet.anime.path, isRoot: true)
        XCTAssertEqual(library.status(for: quiet.anime), .completed)
        XCTAssertFalse(announced(quiet.anime))
        // Watching the last episode to its end now unlocks the trophy.
        let loud = try detail("trophy-loud")
        let finale = try XCTUnwrap(loud.episodes.first)
        library.saveProgress(finale, anime: loud.anime, seconds: 600, duration: 1200, completed: false, profileID: library.profile.id)
        catalogs.remember(loud, path: loud.anime.path, isRoot: true)
        XCTAssertEqual(library.status(for: loud.anime), .watching)
        XCTAssertFalse(announced(loud.anime))
        library.saveProgress(finale, anime: loud.anime, seconds: 1200, duration: 1200, completed: true, profileID: library.profile.id)
        XCTAssertEqual(library.status(for: loud.anime), .completed)
        XCTAssertTrue(announced(loud.anime))
        XCTAssertEqual(library.entry(for: loud.anime)?.trophy, .bronze)
    }

    private func capture<V: View>(_ name: String, size: CGSize, settle: Double = 0.4, view: V) async {
        let host = UIHostingController(rootView: view.preferredColorScheme(.dark))
        let window = UIWindow(frame: CGRect(origin: .zero, size: size))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        host.view.frame = window.bounds
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        try? await Task.sleep(nanoseconds: UInt64(settle * 1_000_000_000))
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
