import XCTest
@testable import AniCore

final class ProfileLibraryTests: XCTestCase {
    private let anime = Anime(path: "/anime/stream/test", title: "Test")
    private let episode = Episode(path: "/anime/stream/test/staffel-2/episode-3", number: "3", title: "Drei", languages: ["Deutsch"])
    private var defaults: UserDefaults!
    private var suite: String!
    override func setUp() {
        suite = "AniLoungeTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
    }
    override func tearDown() { defaults.removePersistentDomain(forName: suite) }
    func testV1MigrationKeepsWatchlistHistoryAndWatchedAndRunsOnce() throws {
        let history = [HistoryEntry(anime: anime, episode: episode, openedAt: Date())]
        defaults.set(try JSONEncoder().encode([anime]), forKey: "favorites.v1")
        defaults.set(try JSONEncoder().encode(history), forKey: "history.v1")
        defaults.set([episode.id], forKey: "watched.v1")
        let persistence = LibraryPersistence(defaults: defaults)
        var snapshot = try persistence.load()
        XCTAssertEqual(snapshot.active.favorites, [anime])
        XCTAssertEqual(snapshot.active.history.first?.episode, episode)
        XCTAssertTrue(snapshot.active.watched.contains(episode.id))
        XCTAssertTrue(snapshot.active.progress.isEmpty) // Do not invent timestamps for old history.
        snapshot.update(snapshot.activeProfileID) { $0.favorites = [] }
        try persistence.save(snapshot)
        XCTAssertTrue(try persistence.load().active.favorites.isEmpty)
        XCTAssertNotNil(defaults.data(forKey: "favorites.v1"))
    }
    func testProfilesRemainIsolatedAfterRelaunchAndLatePlaybackSave() throws {
        let persistence = LibraryPersistence(defaults: defaults)
        var snapshot = try persistence.load()
        let firstID = snapshot.activeProfileID
        snapshot.update(firstID) { $0.toggleFavorite(anime) }
        try snapshot.addProfile(name: " Zweites Profil ", avatar: "moon.stars.fill")
        let secondID = snapshot.activeProfileID
        XCTAssertTrue(snapshot.active.favorites.isEmpty)
        // A player opened under profile one must not update a newly selected profile.
        try snapshot.update(firstID) { try $0.saveProgress(episode, anime: anime, seconds: 623, duration: 1440, completed: false) }
        try persistence.save(snapshot)
        let restored = try LibraryPersistence(defaults: defaults).load()
        XCTAssertEqual(restored.activeProfileID, secondID)
        XCTAssertEqual(restored.active.profile.name, "Zweites Profil")
        XCTAssertTrue(restored.active.progress.isEmpty)
        XCTAssertEqual(restored.profiles[0].favorites, [anime])
        XCTAssertEqual(restored.profiles[0].continueWatching.first?.seconds, 623)
        XCTAssertEqual(restored.profiles[0].continueWatching.first?.episode.path, episode.path)
    }
    func testLatestEpisodeCompletionAndReplayControlContinueWatching() throws {
        var profile = ProfileLibrary()
        let next = Episode(path: "/anime/stream/test/staffel-2/episode-4", number: "4", title: "Vier", languages: [])
        try profile.saveProgress(episode, anime: anime, seconds: 500, duration: 1440, completed: false, date: Date(timeIntervalSince1970: 1))
        try profile.saveProgress(next, anime: anime, seconds: 1440, duration: 1440, completed: true, date: Date(timeIntervalSince1970: 2))
        XCTAssertTrue(profile.continueWatching.isEmpty)
        XCTAssertTrue(profile.watched.contains(next.id))
        try profile.saveProgress(next, anime: anime, seconds: 10, duration: 1440, completed: false, date: Date(timeIntervalSince1970: 3))
        XCTAssertEqual(profile.continueWatching.map(\.id), [next.id])
        XCTAssertFalse(profile.watched.contains(next.id))
        XCTAssertEqual(profile.history.count, 1)
        try profile.setWatched(false, episode: next, anime: anime)
        XCTAssertEqual(profile.progress[next.id]?.seconds, 0)
        XCTAssertTrue(profile.continueWatching.isEmpty)
    }

    func testHidingSurvivesRelaunchWithoutChangingProgressOrWatchedState() throws {
        var snapshot = LibrarySnapshot()
        try snapshot.update(snapshot.activeProfileID) {
            $0.toggleFavorite(anime)
            try $0.saveProgress(episode, anime: anime, seconds: 750, duration: 1440, completed: false)
            $0.hideContinueWatching(anime)
        }
        let persistence = LibraryPersistence(defaults: defaults)
        try persistence.save(snapshot)
        var restored = try persistence.load()
        XCTAssertTrue(restored.active.continueWatching.isEmpty)
        XCTAssertTrue(restored.active.continuationCandidates.isEmpty)
        XCTAssertEqual(restored.active.progress[episode.id]?.seconds, 750)
        XCTAssertEqual(restored.active.favorites, [anime])
        XCTAssertEqual(restored.active.history.first?.episode.id, episode.id)
        try restored.update(restored.activeProfileID) {
            try $0.saveProgress(episode, anime: anime, seconds: 755, duration: 1440, completed: false)
        }
        XCTAssertTrue(restored.active.continuationCandidates.isEmpty)
        restored.update(restored.activeProfileID) { $0.revealContinueWatching(anime) }
        XCTAssertEqual(restored.active.continueWatching.first?.seconds, 755)
    }

    func testOldV2WithoutHiddenFieldKeepsDataAndExplicitCompletion() throws {
        var profile = ProfileLibrary()
        try profile.saveProgress(episode, anime: anime, seconds: 1400, duration: 1440, completed: true)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(profile)) as? [String: Any])
        json.removeValue(forKey: "hiddenContinueWatching")
        let restored = try JSONDecoder().decode(ProfileLibrary.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertTrue(restored.hiddenContinueWatching.isEmpty)
        XCTAssertEqual(restored.progress[episode.id]?.seconds, 1400)
        XCTAssertTrue(restored.watched.contains(episode.id))
        XCTAssertTrue(restored.progress[episode.id]?.isFinished == true)
    }

    func testSeekingIntoCreditsDoesNotFinishEpisode() throws {
        var profile = ProfileLibrary()
        try profile.saveProgress(episode, anime: anime, seconds: 1430, duration: 1440, completed: false)
        XCTAssertFalse(try XCTUnwrap(profile.progress[episode.id]).isFinished)
        XCTAssertEqual(profile.continueWatching.first?.seconds, 1430)
        try profile.saveProgress(episode, anime: anime, seconds: 1440, duration: 1440, completed: true)
        XCTAssertTrue(profile.continueWatching.isEmpty)
        XCTAssertEqual(profile.continuationCandidates.count, 1)
    }

    func testInvalidProgressDoesNotOverwriteSavedPosition() throws {
        var profile = ProfileLibrary()
        try profile.saveProgress(episode, anime: anime, seconds: 100, duration: 90, completed: true)
        XCTAssertEqual(profile.progress[episode.id]?.seconds, 90)
        for invalid in [Double.nan, .infinity, -1, 86401] {
            XCTAssertThrowsError(try profile.saveProgress(episode, anime: anime, seconds: invalid, duration: 90, completed: false))
        }
        XCTAssertThrowsError(try profile.saveProgress(episode, anime: anime, seconds: 1, duration: .infinity, completed: false))
        XCTAssertEqual(profile.progress[episode.id]?.seconds, 90)
    }
    func testCorruptDataIsPreservedInsteadOfSilentlyReset() {
        let corrupt = Data("not-json".utf8)
        defaults.set(corrupt, forKey: LibraryPersistence.key)
        XCTAssertThrowsError(try LibraryPersistence(defaults: defaults).load())
        XCTAssertEqual(defaults.data(forKey: LibraryPersistence.key), corrupt)
        defaults.removeObject(forKey: LibraryPersistence.key)
        defaults.set(corrupt, forKey: "favorites.v1")
        XCTAssertThrowsError(try LibraryPersistence(defaults: defaults).load())
        XCTAssertNil(defaults.data(forKey: LibraryPersistence.key))
    }
    func testProfileLimitsAndInvalidActiveID() throws {
        var snapshot = LibrarySnapshot()
        XCTAssertThrowsError(try snapshot.addProfile(name: "   ", avatar: "sparkles"))
        XCTAssertThrowsError(try snapshot.addProfile(name: String(repeating: "a", count: 25), avatar: "sparkles"))
        for i in 1...5 { try snapshot.addProfile(name: "Profil \(i)", avatar: "sparkles") }
        XCTAssertThrowsError(try snapshot.addProfile(name: "Siebtes", avatar: "sparkles"))
        snapshot.activeProfileID = UUID()
        try LibraryPersistence(defaults: defaults).save(snapshot)
        XCTAssertThrowsError(try LibraryPersistence(defaults: defaults).load())
    }
}
