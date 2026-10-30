import SwiftUI
import AniCore

struct HistoryEntry: Identifiable, Codable {
    var id: String { anime.id }
    let anime: Anime
    let episode: Episode
    let openedAt: Date
}
@MainActor final class LibraryStore: ObservableObject {
    @Published private(set) var favorites: [Anime]
    @Published private(set) var history: [HistoryEntry]
    @Published private(set) var watched: Set<String>
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        favorites = defaults.data(forKey: "favorites.v1").flatMap { try? JSONDecoder().decode([Anime].self, from: $0) } ?? []
        history = defaults.data(forKey: "history.v1").flatMap { try? JSONDecoder().decode([HistoryEntry].self, from: $0) } ?? []
        watched = Set(defaults.stringArray(forKey: "watched.v1") ?? [])
    }
    func contains(_ anime: Anime) -> Bool { favorites.contains { $0.id == anime.id } }
    func toggle(_ anime: Anime) {
        if contains(anime) { favorites.removeAll { $0.id == anime.id } } else { favorites.insert(anime, at: 0) }
        defaults.set(try? JSONEncoder().encode(favorites), forKey: "favorites.v1")
    }
    func opened(_ episode: Episode, anime: Anime) {
        history.removeAll { $0.id == anime.id }
        history.insert(HistoryEntry(anime: anime, episode: episode, openedAt: Date()), at: 0)
        history = Array(history.prefix(30))
        defaults.set(try? JSONEncoder().encode(history), forKey: "history.v1")
    }
    func toggleWatched(_ episode: Episode) {
        if watched.contains(episode.id) { watched.remove(episode.id) } else { watched.insert(episode.id) }
        defaults.set(Array(watched), forKey: "watched.v1")
    }
}
