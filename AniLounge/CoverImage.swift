import SwiftUI
import ImageIO
import CryptoKit
import AniCore

struct AnimeArtwork: View {
    let anime: Anime
    @State private var resolved: URL?
    var body: some View {
        Artwork(url: resolved ?? anime.poster)
            .task(id: anime.id) {
                resolved = await AniClient.shared.cover(for: anime)
            }
    }
}

/// Artwork cache in three layers: decoded images in memory, the original files on disk
/// (Library/Caches, survives restarts) and the network. Images are decoded and downsampled
/// off the main thread, and parallel requests for the same picture share one download.
final class ArtworkCache: @unchecked Sendable {
    static let shared = ArtworkCache()
    /// Upper bound when no display size is known (e.g. colour sampling or prefetching).
    private static let defaultPixel: CGFloat = 1000
    private static let diskLimit: Int64 = 300 * 1024 * 1024
    private let memory = NSCache<NSURL, UIImage>()
    private let directory: URL
    private let lock = NSLock()
    private var inflight: [String: Task<UIImage?, Never>] = [:]
    private let session: URLSession
    init() {
        directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Artwork", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        memory.totalCostLimit = 120 * 1024 * 1024
        let config = URLSessionConfiguration.default
        config.urlCache = nil // The disk cache below replaces URLCache for artwork.
        config.timeoutIntervalForRequest = 15
        config.httpMaximumConnectionsPerHost = 6
        session = URLSession(configuration: config)
    }
    /// Instant lookup for views that are about to draw. With a target size (in pixels) only an
    /// image sharp enough to fill it counts; a smaller cached copy is decoded again from disk.
    func memoryImage(_ url: URL, filling target: CGSize? = nil) -> UIImage? {
        guard let image = memory.object(forKey: url as NSURL) else { return nil }
        guard let target, target.width > 0, target.height > 0 else { return image }
        let pixels = CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
        return max(target.width / pixels.width, target.height / pixels.height) <= 1.05 ? image : nil
    }
    func image(for url: URL, filling target: CGSize? = nil) async -> UIImage? {
        if let image = memoryImage(url, filling: target) { return image }
        // Requests of a similar size share one decode.
        let bucket = target.map { Int(max($0.width, $0.height) / 200) } ?? -1
        let key = url.absoluteString + "#" + String(bucket)
        lock.lock()
        let task: Task<UIImage?, Never>
        if let running = inflight[key] { task = running } else {
            task = Task.detached(priority: .userInitiated) { [self] in await resolve(url, target: target) }
            inflight[key] = task
        }
        lock.unlock()
        let image = await task.value
        lock.lock(); inflight[key] = nil; lock.unlock()
        return image
    }
    /// Warms the cache for pictures that will be shown soon, e.g. the rest of a shelf.
    func prefetch(_ urls: [URL]) {
        for url in urls where memoryImage(url) == nil {
            Task.detached(priority: .utility) { [self] in _ = await image(for: url) }
        }
    }
    private func resolve(_ url: URL, target: CGSize?) async -> UIImage? {
        let file = fileURL(for: url)
        if let data = try? Data(contentsOf: file), let image = Self.decode(data, filling: target) {
            // Fresh modification date: trimming removes the least recently used files first.
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
            remember(image, for: url)
            return image
        }
        for attempt in 0..<2 {
            if Task.isCancelled { return nil }
            var request = URLRequest(url: url, timeoutInterval: 15)
            request.setValue("https://aniworld.to/", forHTTPHeaderField: "Referer")
            if let result = try? await session.data(for: request),
               let http = result.1 as? HTTPURLResponse, (200...299).contains(http.statusCode), let image = Self.decode(result.0, filling: target) {
                try? result.0.write(to: file, options: .atomic)
                remember(image, for: url)
                return image
            }
            if attempt == 0 { try? await Task.sleep(nanoseconds: 800_000_000) }
        }
        return nil
    }
    private func remember(_ image: UIImage, for url: URL) {
        // Keep the sharpest copy decoded so far.
        if let current = memory.object(forKey: url as NSURL), current.size.width * current.scale >= image.size.width * image.scale { return }
        let pixels = image.size.width * image.size.height * image.scale * image.scale
        memory.setObject(image, forKey: url as NSURL, cost: Int(pixels * 4))
    }
    /// Fully decoded image, downsampled to just cover the target size (never scaled up), so
    /// scrolling never decodes on the main thread and memory holds only what is shown.
    private static func decode(_ data: Data, filling target: CGSize?) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = CGFloat((properties?[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue ?? 0)
        let height = CGFloat((properties?[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue ?? 0)
        let longEdge = max(width, height)
        var maxPixel = min(longEdge > 0 ? longEdge : defaultPixel, defaultPixel)
        if let target, width > 0, height > 0, target.width > 0, target.height > 0 {
            // Scale needed so the picture fills the frame (scaledToFill), capped at the source size.
            let fill = min(1, max(target.width / width, target.height / height))
            maxPixel = (longEdge * fill).rounded(.up)
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: image)
    }
    private func fileURL(for url: URL) -> URL {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(digest)
    }
    private var files: [(url: URL, size: Int64, date: Date)] {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        let list = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys)) ?? []
        return list.map { file in
            let values = try? file.resourceValues(forKeys: Set(keys))
            return (file, Int64(values?.fileSize ?? 0), values?.contentModificationDate ?? .distantPast)
        }
    }
    var diskSize: Int64 { files.reduce(0) { $0 + $1.size } }
    /// Keeps the disk cache under its limit by removing the least recently used pictures.
    func trim() {
        var all = files.sorted { $0.date < $1.date }
        var total = all.reduce(0) { $0 + $1.size }
        while total > Self.diskLimit, let oldest = all.first {
            try? FileManager.default.removeItem(at: oldest.url)
            total -= oldest.size
            all.removeFirst()
        }
    }
    func clear() {
        memory.removeAllObjects()
        for file in files { try? FileManager.default.removeItem(at: file.url) }
    }
}

@MainActor final class CoverLoader: ObservableObject {
    @Published var image: UIImage?
    static func clearCache() { ArtworkCache.shared.clear() }
    /// The cached image, or a one-off load for callers outside a view (e.g. colour sampling).
    static func image(for url: URL) async -> UIImage? { await ArtworkCache.shared.image(for: url) }
    func load(_ url: URL?, filling target: CGSize? = nil) async {
        guard let url else { image = nil; return }
        if let cached = ArtworkCache.shared.memoryImage(url, filling: target) { image = cached; return }
        // A smaller cached copy stays visible while the sharp one is decoded.
        image = ArtworkCache.shared.memoryImage(url)
        let loaded = await ArtworkCache.shared.image(for: url, filling: target)
        guard !Task.isCancelled else { return }
        image = loaded
    }
}
