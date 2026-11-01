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
public struct EpisodeProgress: Identifiable, Codable, Sendable {
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
    /// Watched, or close enough to the end that only credits remain (like streaming apps).
    public var isFinished: Bool { completed || Self.finished(seconds: seconds, duration: duration) }
    public static func finished(seconds: Double, duration: Double?) -> Bool {
        guard let duration, duration.isFinite, duration >= 90, seconds.isFinite else { return false }
        return seconds >= min(duration - 10, max(duration * 0.9, duration - 120))
    }
    public static func format(_ seconds: Double) -> String {
        let value = Int(max(0, min(86400, seconds.isFinite ? seconds : 0)))
        return value >= 3600 ? String(format: "%d:%02d:%02d", value / 3600, value / 60 % 60, value % 60) : String(format: "%d:%02d", value / 60, value % 60)
    }
}
public struct ProfileLibrary: Codable, Sendable {
    public var profile: UserProfile
    public var favorites: [Anime] = []
    public var history: [HistoryEntry] = []
    public var watched: Set<String> = []
    public var progress: [String: EpisodeProgress] = [:]
    public init(profile: UserProfile = UserProfile()) { self.profile = profile }
    public var continueWatching: [EpisodeProgress] {
        var seen = Set<String>()
        // The newest progress per anime decides whether it is still in progress.
        return progress.values.sorted { $0.updatedAt > $1.updatedAt }.filter {
            guard seen.insert($0.anime.id).inserted else { return false }
            return !$0.isFinished && $0.seconds > 0
        }
    }
    public func latest(for anime: Anime) -> EpisodeProgress? {
        progress.values.filter { $0.anime.id == anime.id }.max { $0.updatedAt < $1.updatedAt }
    }
    public mutating func toggleFavorite(_ anime: Anime) {
        if favorites.contains(where: { $0.id == anime.id }) { favorites.removeAll { $0.id == anime.id } }
        else { favorites.insert(anime, at: 0) }
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
        progress[episode.id] = EpisodeProgress(anime: anime, episode: episode, seconds: position, duration: duration, completed: completed, updatedAt: date)
        if completed { watched.insert(episode.id) } else { watched.remove(episode.id) }
        opened(episode, anime: anime, date: date)
    }
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
    public func load() throws -> LibrarySnapshot {
        if let data = defaults.data(forKey: Self.key) {
            guard let snapshot = try? JSONDecoder().decode(LibrarySnapshot.self, from: data),
                  snapshot.schemaVersion == 2, !snapshot.profiles.isEmpty,
                  Set(snapshot.profiles.map { $0.profile.id }).count == snapshot.profiles.count,
                  snapshot.profiles.contains(where: { $0.profile.id == snapshot.activeProfileID }) else { throw LibraryError.unreadable }
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
