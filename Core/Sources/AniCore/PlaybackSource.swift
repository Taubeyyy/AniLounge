import Foundation

public struct StreamHost: Identifiable, Hashable, Sendable {
    public var id: String { url.absoluteString }
    public let name: String
    public let language: String
    public let url: URL
}
public enum PlaybackSource {
    public static func preferredHost(in hosts: [StreamHost], name: String?, language: String?) -> StreamHost? {
        let preferredLanguage = language ?? "Deutsch"
        let sameLanguage = hosts.filter { $0.language == preferredLanguage }
        let pool = sameLanguage.isEmpty ? hosts : sameLanguage
        return pool.first { $0.name == (name ?? "VOE") } ?? pool.first
    }

    /// Only hand ordinary secure media URLs to AVPlayer; blob URLs belong to WebKit.
    public static func directURL(_ value: String, mimeType: String? = nil) -> URL? {
        guard let url = URL(string: value), url.scheme == "https", let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil else { return nil }
        let mediaTypes = ["video/mp4", "video/x-m4v", "application/vnd.apple.mpegurl", "application/x-mpegurl"]
        let mime = mimeType?.lowercased().components(separatedBy: ";").first ?? ""
        guard ["mp4", "m4v", "m3u8"].contains(url.pathExtension.lowercased()) || mediaTypes.contains(mime) else { return nil }
        return url
    }
    public static func resumePosition(saved: Double, savedDuration: Double?, duration: Double) -> Double {
        guard saved.isFinite, saved > 0, duration.isFinite, duration > 0 else { return 0 }
        if let previous = savedDuration, abs(previous - duration) > max(45, previous * 0.08) { return 0 }
        return min(saved, max(0, duration - 1))
    }
}

