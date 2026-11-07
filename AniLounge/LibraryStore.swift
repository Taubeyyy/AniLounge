import SwiftUI
import Combine
import AniCore

@MainActor final class LibraryStore: ObservableObject {
    @Published private(set) var snapshot: LibrarySnapshot { didSet { refreshList() } }
    @Published var storageError: String?
    @Published private(set) var listStatuses: [String: WatchStatus] = [:]
    /// Every watchlist series with its status, progress and trophy, computed once per change.
    @Published private(set) var watchlist: [WatchlistEntry] = []
    private var entryIndex: [String: WatchlistEntry] = [:]
    private var listProfileID: UUID?
    private var foregroundSubscription: AnyCancellable?
    private var listedAnime: [Anime] = []
    private var knownCatalogs: [String: SeriesCatalog] = [:]
    private var catalogSubscription: AnyCancellable?
    private let persistence: LibraryPersistence
    private var writable = true
    var active: ProfileLibrary { snapshot.active }
    var profile: UserProfile { active.profile }
    var favorites: [Anime] { listedAnime }
    var history: [HistoryEntry] { active.history }
    var watched: Set<String> { active.watched }
    var continueWatching: [EpisodeProgress] { active.continueWatching }
    init(defaults: UserDefaults = .standard, catalogs: SeriesCatalogStore? = nil) {
        persistence = LibraryPersistence(defaults: defaults)
        do { snapshot = try persistence.load() }
        catch { snapshot = LibrarySnapshot(); storageError = error.localizedDescription; writable = false }
        refreshList()
        catalogSubscription = (catalogs ?? .shared).$catalogs.sink { [weak self] catalogs in
            self?.knownCatalogs = catalogs
            self?.refreshList()
        }
        // "Paused" depends on the date: back in the app after a while, look again.
        foregroundSubscription = NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)
            .sink { [weak self] _ in self?.refreshList() }
    }
    private func refreshList() {
        let previous = listStatuses
        let sameProfile = listProfileID == profile.id
        let entries = active.watchlistEntries(catalogs: knownCatalogs)
        listedAnime = entries.map(\.anime)
        entryIndex = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
        listStatuses = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0.status) })
        watchlist = entries
        listProfileID = profile.id
        if sameProfile { announceTrophies(after: previous, in: entries) }
    }
    func entry(for anime: Anime) -> WatchlistEntry? { entryIndex[anime.id] }
    /// A series finished just now by watching it earns a trophy banner. Series that only turn
    /// out to be finished because a catalog arrived (app start, refresh) stay quiet.
    private func announceTrophies(after previous: [String: WatchStatus], in entries: [WatchlistEntry]) {
        for entry in entries where entry.status == .completed && !entry.manual {
            guard let before = previous[entry.id], before != .completed,
                  let latest = entry.latest, latest.completed, Date().timeIntervalSince(latest.updatedAt) < 600 else { continue }
            TrophyCenter.shared.unlock(entry)
        }
    }
    /// Applies and saves a change; false when nothing was saved (the error is shown already).
    @discardableResult private func change(_ body: (inout LibrarySnapshot) throws -> Void) -> Bool {
        guard writable else { storageError = LibraryError.unreadable.localizedDescription; return false }
        do {
            var next = snapshot
            try body(&next)
            try persistence.save(next)
            snapshot = next
            return true
        } catch { storageError = error.localizedDescription; return false }
    }
    func contains(_ anime: Anime) -> Bool { favorites.contains { $0.id == anime.id } }
    /// Watchlist toggle with haptic and a short confirmation.
    func toggleWatchlist(_ anime: Anime) {
        let adding = !contains(anime)
        toggle(anime)
        guard contains(anime) == adding else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        ToastCenter.shared.show(adding ? "Zur Watchlist hinzugefügt" : "Von der Watchlist entfernt", icon: adding ? "bookmark.fill" : "bookmark.slash")
    }
    func toggle(_ anime: Anime) { change { $0.update(profile.id) { $0.toggleFavorite(anime) } } }
    func opened(_ episode: Episode, anime: Anime, profileID: UUID? = nil) { change { $0.update(profileID ?? profile.id) { $0.opened(episode, anime: anime) } } }
    func hideContinueWatching(_ anime: Anime) { change { $0.update(profile.id) { $0.hideContinueWatching(anime) } } }
    func beginPlayback(_ episode: Episode, anime: Anime, profileID: UUID) {
        change { $0.update(profileID) { profile in
            profile.revealContinueWatching(anime)
            profile.opened(episode, anime: anime)
        } }
    }
    func clearHistory() { change { $0.update(profile.id) { $0.clearHistory() } } }
    func resetProgress() { change { $0.update(profile.id) { $0.resetProgress() } } }
    /// Marks several episodes at once, e.g. "up to here" or a whole season, in one save.
    func markWatched(_ episodes: [Episode], anime: Anime) {
        guard change({ snapshot in try snapshot.update(profile.id) { library in for episode in episodes { try library.setWatched(true, episode: episode, anime: anime) } } }) else { return }
        ToastCenter.shared.show(episodes.count == 1 ? "Als gesehen markiert" : "\(episodes.count) Folgen als gesehen markiert", icon: "checkmark.circle.fill")
    }
    /// All profiles, watchlists and progress as JSON, for a backup outside the app.
    func exportBackup() throws -> URL {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        let stamp = Date().formatted(.iso8601.year().month().day())
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("AniLounge-Sicherung-\(stamp).json")
        try encoder.encode(snapshot).write(to: url, options: .atomic)
        return url
    }
    /// Replaces everything with a backup, after checking it is a complete AniLounge library.
    func importBackup(_ data: Data) throws {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        // Exactly the rules of the next launch's load(); anything else would lock the library.
        guard let imported = try? decoder.decode(LibrarySnapshot.self, from: data), LibraryPersistence.isValid(imported) else { throw LibraryError.unreadable }
        guard change({ $0 = imported }) else { throw LibraryError.unreadable }
    }
    func status(for anime: Anime) -> WatchStatus {
        listStatuses[anime.id] ?? active.watchStatus[anime.id] ?? .planned
    }
    /// Takes a series off the watchlist and forgets its status, in one save and one message.
    func removeFromList(_ anime: Anime) {
        guard change({ $0.update(profile.id) { $0.removeFromWatchlist(anime) } }) else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        ToastCenter.shared.show("Aus der Liste entfernt", icon: "bookmark.slash")
    }
    /// Sets a list status (nil = automatic) and keeps the series on the watchlist.
    func setStatus(_ status: WatchStatus?, for anime: Anime) {
        guard change({ $0.update(profile.id) { $0.setStatus(status, for: anime) } }) else { return }
        UISelectionFeedbackGenerator().selectionChanged()
        ToastCenter.shared.show(status.map { "Status: \($0.label)" } ?? "Status automatisch", icon: status?.symbol ?? "wand.and.stars")
    }
    func setWatched(_ value: Bool, episode: Episode, anime: Anime) {
        change { try $0.update(profile.id) { try $0.setWatched(value, episode: episode, anime: anime) } }
    }
    func toggleWatched(_ episode: Episode, anime: Anime) {
        let value = !watched.contains(episode.id)
        change { try $0.update(profile.id) { try $0.setWatched(value, episode: episode, anime: anime) } }
    }
    func progress(for episode: Episode, profileID: UUID? = nil) -> EpisodeProgress? {
        snapshot.profiles.first { $0.profile.id == (profileID ?? profile.id) }?.progress[episode.id]
    }
    func saveProgress(_ episode: Episode, anime: Anime, seconds: Double, duration: Double?, completed: Bool, profileID: UUID) {
        change { try $0.update(profileID) { try $0.saveProgress(episode, anime: anime, seconds: seconds, duration: duration, completed: completed) } }
    }
    func addProfile(name: String, avatar: String) { change { try $0.addProfile(name: name, avatar: avatar) } }
    func selectProfile(_ id: UUID) {
        guard snapshot.profiles.contains(where: { $0.profile.id == id }) else { return }
        change { $0.activeProfileID = id }
    }
    func editProfile(name: String, avatar: String) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean.count <= 24 else { return }
        change { $0.update(profile.id) { $0.profile.name = clean; $0.profile.avatar = avatar } }
    }
}
