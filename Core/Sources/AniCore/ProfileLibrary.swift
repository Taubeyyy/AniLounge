import Foundation

public struct UserProfile: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    public var avatar: String
    public init(id: UUID = UUID(), name: String = "Mein Profil", avatar: String = "sparkles") {
        self.id = id; self.name = name; self.avatar = avatar
    }
}
public struct HistoryEntry: Identifiable, Codable, Sendable {
    public var id: String { anime.id }
    public let anime: Anime
    public let episode: Episode
    public let openedAt: Date
}
public struct EpisodeProgress: Identifiable, Codable, Equatable, Sendable {
    public var id: String { episode.id }
    public let anime: Anime
    public let episode: Episode
    public let seconds: Double
    public let duration: Double?
    public let completed: Bool
    public let updatedAt: Date
    public var fraction: Double? {
        guard let duration, duration > 0 else { return nil }
        return min(1, max(0, seconds / duration))
    }
    public var timeLabel: String { Self.format(seconds) }
    /// Only an actual end event or an explicit watched action completes an episode.
    public var isFinished: Bool { completed }
    public static func format(_ seconds: Double) -> String {
        let value = Int(max(0, min(86400, seconds.isFinite ? seconds : 0)))
        return value >= 3600 ? String(format: "%d:%02d:%02d", value / 3600, value / 60 % 60, value % 60) : String(format: "%d:%02d", value / 60, value % 60)
    }
}
/// Personal list status, like AniList's lists.
public enum WatchStatus: String, Codable, CaseIterable, Sendable {
    case planned, watching, paused, completed
    public var label: String {
        switch self {
        case .planned: return "Geplant"
        case .watching: return "Schaue ich"
        case .paused: return "Pausiert"
        case .completed: return "Fertig"
        }
    }
    public var symbol: String {
        switch self {
        case .planned: return "bookmark"
        case .watching: return "play.circle"
        case .paused: return "pause.circle"
        case .completed: return "checkmark.circle"
        }
    }
}
public struct ProfileLibrary: Codable, Sendable {
    public var profile: UserProfile
    public var favorites: [Anime] = []
    public var history: [HistoryEntry] = []
    public var watched: Set<String> = []
    public var progress: [String: EpisodeProgress] = [:]
    public var hiddenContinueWatching: Set<String> = []
    /// Statuses the viewer set by hand; everything else is derived from progress.
    public var watchStatus: [String: WatchStatus] = [:]
    /// Explicit removals also hide automatically collected playback entries.
    public var hiddenWatchlist: Set<String> = []
    public init(profile: UserProfile = UserProfile()) { self.profile = profile }
    private enum CodingKeys: String, CodingKey { case profile, favorites, history, watched, progress, hiddenContinueWatching, watchStatus, hiddenWatchlist }
    public init(from decoder: Decoder) throws {
        let data = try decoder.container(keyedBy: CodingKeys.self)
        profile = try data.decode(UserProfile.self, forKey: .profile)
        favorites = try data.decode([Anime].self, forKey: .favorites)
        history = try data.decode([HistoryEntry].self, forKey: .history)
        watched = try data.decode(Set<String>.self, forKey: .watched)
        progress = try data.decode([String: EpisodeProgress].self, forKey: .progress)
        // Additive v2 field: old installations keep every existing position and watched mark.
        hiddenContinueWatching = try data.decodeIfPresent(Set<String>.self, forKey: .hiddenContinueWatching) ?? []
        watchStatus = try data.decodeIfPresent([String: WatchStatus].self, forKey: .watchStatus) ?? [:]
        hiddenWatchlist = try data.decodeIfPresent(Set<String>.self, forKey: .hiddenWatchlist) ?? []
    }
    public func status(for anime: Anime) -> WatchStatus {
        listStatuses()[anime.id] ?? watchStatus[anime.id] ?? .planned
    }
    /// Existing progress is included too, without rewriting older libraries or adding mere page visits.
    public var watchlistItems: [Anime] {
        var seen = Set<String>()
        let started = progress.values.filter { $0.seconds > 0 || $0.completed }.sorted {
            $0.updatedAt == $1.updatedAt ? $0.id < $1.id : $0.updatedAt > $1.updatedAt
        }.map(\.anime)
        return (favorites + started).filter { !hiddenWatchlist.contains($0.id) && seen.insert($0.id).inserted }
    }
    /// Compute once per library/catalog change, rather than scanning progress for each drawn card.
    public func listStatuses(catalogs: [String: SeriesCatalog] = [:]) -> [String: WatchStatus] {
        let grouped = Dictionary(grouping: progress.values.filter { $0.seconds > 0 || $0.completed }, by: { $0.anime.id })
        return Dictionary(uniqueKeysWithValues: watchlistItems.map { anime -> (String, WatchStatus) in
            let entries = grouped[anime.id] ?? []
            if let manual = watchStatus[anime.id] { return (anime.id, manual) }
            guard !entries.isEmpty else { return (anime.id, .planned) }
            guard let catalog = catalogs[anime.id], catalog.refreshedAt != nil, !catalog.seasons.isEmpty else { return (anime.id, .watching) }
            let television = catalog.seasons.filter { $0.path.contains("/staffel-") }
            let seasons = television.isEmpty ? catalog.seasons : television
            let finished = watched.union(entries.filter(\.completed).map(\.id))
            let allSeen = seasons.allSatisfy { season in
                guard let episodes = catalog.episodesBySeason[season.path], !episodes.isEmpty else { return false }
                return episodes.allSatisfy { finished.contains($0.id) }
            }
            return (anime.id, allSeen ? .completed : .watching)
        })
    }
    /// nil returns to the automatic status.
    public mutating func setStatus(_ status: WatchStatus?, for anime: Anime) {
        watchStatus[anime.id] = status
        hiddenWatchlist.remove(anime.id)
        if !favorites.contains(where: { $0.id == anime.id }) { favorites.insert(anime, at: 0) }
    }
    public mutating func removeFromWatchlist(_ anime: Anime) {
        favorites.removeAll { $0.id == anime.id }
        watchStatus[anime.id] = nil
        hiddenWatchlist.insert(anime.id)
    }
    public mutating func hideContinueWatching(_ anime: Anime) { hiddenContinueWatching.insert(anime.id) }
    public mutating func revealContinueWatching(_ anime: Anime) { hiddenContinueWatching.remove(anime.id) }
    /// Also includes finished series so a known next episode can be offered.
    public var continuationCandidates: [EpisodeProgress] {
        var seen = Set<String>()
        return progress.values.sorted { $0.updatedAt > $1.updatedAt }.filter {
            seen.insert($0.anime.id).inserted && !hiddenContinueWatching.contains($0.anime.id)
                && ($0.seconds > 0 || $0.completed)
        }
    }
    public var continueWatching: [EpisodeProgress] {
        var seen = Set<String>()
        // The newest progress per anime decides whether it is still in progress.
        return progress.values.sorted { $0.updatedAt > $1.updatedAt }.filter {
            guard seen.insert($0.anime.id).inserted else { return false }
            return !$0.isFinished && $0.seconds > 0 && !hiddenContinueWatching.contains($0.anime.id)
        }
    }
    public func latest(for anime: Anime) -> EpisodeProgress? {
        progress.values.filter { $0.anime.id == anime.id }.max { $0.updatedAt < $1.updatedAt }
    }
    public mutating func toggleFavorite(_ anime: Anime) {
        if watchlistItems.contains(where: { $0.id == anime.id }) { removeFromWatchlist(anime) }
        else { hiddenWatchlist.remove(anime.id); favorites.insert(anime, at: 0) }
    }
    public mutating func opened(_ episode: Episode, anime: Anime, date: Date = Date()) {
        history.removeAll { $0.id == anime.id }
        history.insert(HistoryEntry(anime: anime, episode: episode, openedAt: date), at: 0)
        history = Array(history.prefix(50))
    }
    public mutating func saveProgress(_ episode: Episode, anime: Anime, seconds: Double, duration: Double?, completed: Bool, date: Date = Date()) throws {
        guard seconds.isFinite, seconds >= 0, seconds <= 86400,
              duration == nil || (duration!.isFinite && duration! > 0 && duration! <= 86400) else { throw LibraryError.invalidProgress }
        let position = min(seconds, duration ?? seconds)
        if (position > 0 || completed), watchStatus[anime.id] == .planned { watchStatus[anime.id] = nil }
        progress[episode.id] = EpisodeProgress(anime: anime, episode: episode, seconds: position, duration: duration, completed: completed, updatedAt: date)
        if completed { watched.insert(episode.id) } else { watched.remove(episode.id) }
        opened(episode, anime: anime, date: date)
    }
    public mutating func clearHistory() { history.removeAll() }
    /// Forgets progress and watched marks; watchlist and history stay.
    public mutating func resetProgress() {
        favorites = watchlistItems
        progress.removeAll(); watched.removeAll(); hiddenContinueWatching.removeAll(); watchStatus.removeAll()
    }
    /// Time spent watching: finished episodes count fully, started ones up to their position.
    public var watchedSeconds: Double {
        progress.values.reduce(0) { total, item in total + (item.isFinished ? (item.duration ?? item.seconds) : item.seconds) }
    }
    public var finishedEpisodes: Int { Set(progress.values.filter(\.isFinished).map(\.id)).union(watched).count }
    public mutating func setWatched(_ value: Bool, episode: Episode, anime: Anime) throws {
        let old = progress[episode.id]
        try saveProgress(episode, anime: anime, seconds: value ? (old?.duration ?? old?.seconds ?? 0) : 0,
                         duration: old?.duration, completed: value)
    }
}
public struct LibrarySnapshot: Codable, Sendable {
    public var schemaVersion = 2
    public var activeProfileID: UUID
    public var profiles: [ProfileLibrary]
    public init(profile: UserProfile = UserProfile()) {
        activeProfileID = profile.id; profiles = [ProfileLibrary(profile: profile)]
    }
    public var active: ProfileLibrary { profiles.first { $0.profile.id == activeProfileID } ?? profiles[0] }
    public mutating func update(_ id: UUID, body: (inout ProfileLibrary) throws -> Void) rethrows {
        guard let index = profiles.firstIndex(where: { $0.profile.id == id }) else { return }
        try body(&profiles[index])
    }
    public mutating func addProfile(name: String, avatar: String) throws {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean.count <= 24, profiles.count < 6 else { throw LibraryError.invalidProfile }
        let profile = UserProfile(name: clean, avatar: avatar)
        profiles.append(ProfileLibrary(profile: profile)); activeProfileID = profile.id
    }
}
public enum LibraryError: LocalizedError {
    case invalidProfile, invalidProgress, unreadable
    public var errorDescription: String? {
        switch self {
        case .invalidProfile: return "Bitte wähle einen Namen mit 1 bis 24 Zeichen. Bis zu sechs Profile sind möglich."
        case .invalidProgress: return "Bitte gib eine gültige Wiedergabezeit an."
        case .unreadable: return "Deine gespeicherten Profile konnten nicht geladen werden. Die Daten bleiben erhalten; Speichern ist vorerst deaktiviert."
        }
    }
}
public final class LibraryPersistence {
    public static let key = "library.v2"
    private let defaults: UserDefaults
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    /// The rules every stored or imported library must meet; load() refuses anything else.
    public static func isValid(_ snapshot: LibrarySnapshot) -> Bool {
        snapshot.schemaVersion == 2 && !snapshot.profiles.isEmpty
            && Set(snapshot.profiles.map { $0.profile.id }).count == snapshot.profiles.count
            && snapshot.profiles.contains(where: { $0.profile.id == snapshot.activeProfileID })
    }
    public func load() throws -> LibrarySnapshot {
        if let data = defaults.data(forKey: Self.key) {
            guard let snapshot = try? JSONDecoder().decode(LibrarySnapshot.self, from: data), Self.isValid(snapshot) else { throw LibraryError.unreadable }
            return snapshot
        }
        // Import v0.1 exactly once, into the initial local profile. Keep legacy keys intact.
        var snapshot = LibrarySnapshot()
        do {
            if let data = defaults.data(forKey: "favorites.v1") { snapshot.profiles[0].favorites = try JSONDecoder().decode([Anime].self, from: data) }
            if let data = defaults.data(forKey: "history.v1") { snapshot.profiles[0].history = try JSONDecoder().decode([HistoryEntry].self, from: data) }
            snapshot.profiles[0].watched = Set(defaults.stringArray(forKey: "watched.v1") ?? [])
        } catch { throw LibraryError.unreadable }
        try save(snapshot)
        return snapshot
    }
    public func save(_ snapshot: LibrarySnapshot) throws {
        let data = try JSONEncoder().encode(snapshot)
        defaults.set(data, forKey: Self.key)
    }
}
