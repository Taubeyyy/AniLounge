import Foundation

public enum PlaybackQueue {
    public static func replacement(in hosts: [StreamHost], current: StreamHost, attempted: Set<String>) -> StreamHost? {
        guard attempted.count < 3 else { return nil }
        return hosts.first { PlaybackLanguage.matches($0.language, current.language) && !attempted.contains($0.id) }
    }
    public static func next(after episode: Episode, in episodes: [Episode]) -> Episode? {
        guard let index = episodes.firstIndex(where: { $0.id == episode.id }), episodes.indices.contains(index + 1) else { return nil }
        return episodes[index + 1]
    }
}
