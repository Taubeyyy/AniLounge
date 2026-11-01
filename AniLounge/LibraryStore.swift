import SwiftUI
import AniCore

@MainActor final class LibraryStore: ObservableObject {
    @Published private(set) var snapshot: LibrarySnapshot
    @Published var storageError: String?
    private let persistence: LibraryPersistence
    private var writable = true
    var active: ProfileLibrary { snapshot.active }
    var profile: UserProfile { active.profile }
    var favorites: [Anime] { active.favorites }
    var history: [HistoryEntry] { active.history }
    var watched: Set<String> { active.watched }
    var continueWatching: [EpisodeProgress] { active.continueWatching }
    init(defaults: UserDefaults = .standard) {
        persistence = LibraryPersistence(defaults: defaults)
        do { snapshot = try persistence.load() }
        catch { snapshot = LibrarySnapshot(); storageError = error.localizedDescription; writable = false }
    }
    private func change(_ body: (inout LibrarySnapshot) throws -> Void) {
        guard writable else { storageError = LibraryError.unreadable.localizedDescription; return }
        do {
            var next = snapshot
            try body(&next)
            try persistence.save(next)
            snapshot = next
        } catch { storageError = error.localizedDescription }
    }
    func contains(_ anime: Anime) -> Bool { favorites.contains { $0.id == anime.id } }
    /// Watchlist toggle with haptic and a short confirmation.
    func toggleWatchlist(_ anime: Anime) {
        let adding = !contains(anime)
        toggle(anime)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        ToastCenter.shared.show(adding ? "Zur Watchlist hinzugefügt" : "Von der Watchlist entfernt", icon: adding ? "bookmark.fill" : "bookmark.slash")
    }
    func toggle(_ anime: Anime) { change { $0.update(profile.id) { $0.toggleFavorite(anime) } } }
    func opened(_ episode: Episode, anime: Anime) { change { $0.update(profile.id) { $0.opened(episode, anime: anime) } } }
    func clearHistory() { change { $0.update(profile.id) { $0.clearHistory() } } }
    func resetProgress() { change { $0.update(profile.id) { $0.resetProgress() } } }
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
