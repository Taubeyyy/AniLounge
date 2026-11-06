import Foundation
import Combine
import AVFoundation
import UIKit
import AniCore

struct EpisodeDownload: Codable, Identifiable {
    enum State: String, Codable { case downloading, checking, ready, failed, cancelled }
    let id: UUID
    let anime: Anime
    let episode: Episode
    let profileID: UUID
    let source: String
    let isHLS: Bool
    var state: State = .downloading
    var progress: Double = 0
    var bytes: Int64 = 0
    var relativePath: String?
    var message: String?
    var sessionID: String? = nil
    var language: String? = nil
    var editionLanguage: String? {
        if let language { return language }
        // Migrate the old display string only when it actually includes a language component.
        let parts = source.components(separatedBy: " · ")
        return parts.count > 1 ? parts.last : nil
    }
}

struct OfflinePlaybackOption {
    let request: PlaybackRequest
    let language: String?
    let requiresConfirmation: Bool
}

/// All delegate callbacks use the main queue, matching the store's isolation.
@MainActor final class DownloadStore: NSObject, ObservableObject, URLSessionDownloadDelegate, AVAssetDownloadDelegate {
    static let shared = DownloadStore()
    static let fileSessionID = "app.anilounge.download.files.v2"
    static let hlsSessionID = "app.anilounge.download.hls.v2"
    static let hlsWifiSessionID = "app.anilounge.download.hls.wifi.v1"
    @Published private(set) var items: [EpisodeDownload] = []
    @Published var storageError: String?
    private let home: URL
    private let directory: URL
    private let manifest: URL
    private var tasks: [UUID: URLSessionTask] = [:]
    /// Bytes on disk per finished download; walking HLS packages on every render was slow.
    private var sizes: [UUID: Int64] = [:]
    private var validations: [UUID: Task<Void, Never>] = [:]
    private var completions: [String: () -> Void] = [:]
    private var finishedEvents = Set<String>()
    private var restoration: DownloadRestoration?
    private var started = false
    private var canSave = true
    private lazy var files = URLSession(configuration: configuration(Self.fileSessionID), delegate: self, delegateQueue: .main)
    private lazy var streams = AVAssetDownloadURLSession(configuration: configuration(Self.hlsSessionID), assetDownloadDelegate: self, delegateQueue: .main)
    // HLS tasks cannot opt out of cellular per request, so Wi-Fi-only downloads use their own session.
    private lazy var wifiStreams = AVAssetDownloadURLSession(configuration: configuration(Self.hlsWifiSessionID, cellular: false), assetDownloadDelegate: self, delegateQueue: .main)

    init(home: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)) {
        self.home = home.standardizedFileURL
        directory = home.appendingPathComponent("Library/Application Support/EpisodeDownloads", isDirectory: true)
        manifest = directory.appendingPathComponent("index.json")
        super.init()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var dir = directory; var values = URLResourceValues(); values.isExcludedFromBackup = true
            try dir.setResourceValues(values)
            if FileManager.default.fileExists(atPath: manifest.path) {
                items = try JSONDecoder().decode([EpisodeDownload].self, from: Data(contentsOf: manifest))
            }
        } catch { canSave = false; storageError = "Download-Speicher konnte nicht geöffnet werden. Bestehende Daten bleiben erhalten." }
    }
    private func configuration(_ identifier: String, cellular: Bool = true) -> URLSessionConfiguration {
        let config = URLSessionConfiguration.background(withIdentifier: identifier)
        config.sessionSendsLaunchEvents = true
        config.isDiscretionary = false
        // Viewers expect downloads to start right away, also on mobile data.
        config.allowsCellularAccess = cellular
        config.allowsExpensiveNetworkAccess = cellular
        config.allowsConstrainedNetworkAccess = cellular
        config.waitsForConnectivity = true
        return config
    }
    func start() {
        guard !started, canSave else { return }; started = true
        beginRestoration(sessionIDs: [Self.fileSessionID, Self.hlsSessionID, Self.hlsWifiSessionID])
        for session in [files, streams as URLSession, wifiStreams as URLSession] {
            let sessionID = session.configuration.identifier!
            session.getAllTasks { [weak self] restored in
                Task { @MainActor in self?.restoreTasks(restored, sessionID: sessionID) }
            }
        }
        for entry in items where entry.state == .checking { validate(entry.id) }
        for entry in items where entry.state == .ready && localURL(for: entry) == nil {
            fail(entry.id, "Lokale Datei fehlt. Bitte erneut herunterladen.")
        }
    }
    // Internal entry points allow testing callback order without starting background transfers.
    func beginRestoration(sessionIDs: Set<String>) {
        restoration = DownloadRestoration(sessionIDs: sessionIDs,
                                           downloadIDs: Set(items.filter { $0.state == .downloading }.map(\.id)))
    }
    func restoreTasks(_ restored: [URLSessionTask], sessionID: String) {
        var found = Set<UUID>()
        for task in restored {
            guard let id = id(task), let entry = items.first(where: { $0.id == id && $0.state == .downloading }),
                  entry.sessionID == nil || entry.sessionID == sessionID else { task.cancel(); continue }
            tasks[id] = task; found.insert(id)
            change(id) { $0.sessionID = sessionID }
        }
        guard let missing = restoration?.received(sessionID: sessionID, downloadIDs: found) else { return }
        restoration = nil
        for id in missing where active(id) && tasks[id] == nil {
            fail(id, "Download unterbrochen. Folge online öffnen und erneut herunterladen.")
        }
    }
    func offlineOption(for request: PlaybackRequest, preferredLanguage: String) -> OfflinePlaybackOption? {
        let candidates = items.filter { $0.profileID == request.profileID && $0.episode.id == request.episode.id && localURL(for: $0) != nil }
        guard let entry = candidates.first(where: { PlaybackLanguage.matches($0.editionLanguage ?? "", preferredLanguage) }) ?? candidates.first,
              let url = localURL(for: entry) else { return nil }
        var local = request; local.localURL = url; local.localLanguage = entry.editionLanguage
        return OfflinePlaybackOption(request: local, language: entry.editionLanguage,
                                     requiresConfirmation: !PlaybackLanguage.matches(entry.editionLanguage ?? "", preferredLanguage))
    }
    func backgroundEvents(_ identifier: String, completion: @escaping () -> Void) {
        completions[identifier] = completion; start(); completeEventsIfPossible()
    }
    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        if let id = session.configuration.identifier { finishedEvents.insert(id) }
        completeEventsIfPossible()
    }
    private func completeEventsIfPossible() {
        guard validations.isEmpty else { return }
        for id in Array(finishedEvents) {
            if let completion = completions.removeValue(forKey: id) { finishedEvents.remove(id); completion() }
        }
    }
    func existing(_ request: PlaybackRequest) -> EpisodeDownload? {
        items.first { $0.profileID == request.profileID && $0.episode.path == request.episode.path && ($0.state == .downloading || $0.state == .checking || ($0.state == .ready && localURL(for: $0) != nil)) }
    }
    func enqueue(request: PlaybackRequest, asset: AVURLAsset, cookies: [HTTPCookie], headers: [String: String] = [:], source: String, language: String? = nil) {
        guard canSave, existing(request) == nil, asset.url.scheme == "https" else { return }
        start()
        let ext = asset.url.pathExtension.lowercased()
        let hls = ext == "m3u8"
        guard hls || ["mp4", "m4v"].contains(ext) else {
            storageError = "Diese Quelle bietet keinen unterstützten Download-Link. Bitte eine andere Quelle wählen."; return
        }
        var entry = EpisodeDownload(id: UUID(), anime: request.anime, episode: request.episode, profileID: request.profileID, source: source, isHLS: hls)
        entry.language = language
        let task: URLSessionTask
        if hls {
            // Reuse the playing asset: it already carries the hoster's cookies and referer.
            let session = AppSettings.shared.wifiOnlyDownloads ? wifiStreams : streams
            entry.sessionID = session.configuration.identifier
            guard let download = session.makeAssetDownloadTask(asset: asset, assetTitle: request.anime.title + " · " + request.episode.number, assetArtworkData: nil, options: nil) else {
                storageError = "Dieser HLS-Stream lässt sich nicht herunterladen."; return
            }
            task = download
        } else {
            var urlRequest = URLRequest(url: asset.url)
            // Only cookies scoped to this asset were supplied by PlayerModel.
            urlRequest.allHTTPHeaderFields = HTTPCookie.requestHeaderFields(with: cookies).merging(headers) { current, _ in current }
            urlRequest.allowsCellularAccess = !AppSettings.shared.wifiOnlyDownloads
            task = files.downloadTask(with: urlRequest)
            entry.sessionID = Self.fileSessionID
        }
        task.taskDescription = entry.id.uuidString
        items.insert(entry, at: 0)
        guard save() else { items.removeAll { $0.id == entry.id }; task.cancel(); return }
        tasks[entry.id] = task; task.resume()
    }
    func cancel(_ id: UUID) {
        tasks.removeValue(forKey: id)?.cancel(); validations.removeValue(forKey: id)?.cancel()
        removeFile(id)
        change(id) { $0.state = .cancelled; $0.message = "Abgebrochen"; $0.relativePath = nil }
        completeEventsIfPossible()
    }
    func delete(_ id: UUID) { cancel(id); items.removeAll { $0.id == id }; save() }
    func deleteAll(profileID: UUID) {
        for entry in items where entry.profileID == profileID { cancel(entry.id) }
        items.removeAll { $0.profileID == profileID }; save()
    }
    /// Bytes on disk for one profile's finished downloads (HLS packages are folders).
    func usedBytes(profileID: UUID) -> Int64 {
        items.filter { $0.profileID == profileID && $0.state == .ready }.reduce(0) { total, entry in
            if let known = sizes[entry.id] { return total + known }
            guard let url = localURL(for: entry) else { return total }
            let files = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey])
            var size = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            while let file = files?.nextObject() as? URL { size += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
            sizes[entry.id] = size
            return total + size
        }
    }
    private func id(_ task: URLSessionTask) -> UUID? { task.taskDescription.flatMap(UUID.init(uuidString:)) }
    private func active(_ id: UUID) -> Bool { items.contains { $0.id == id && $0.state == .downloading } }
    private func change(_ id: UUID, persist: Bool = true, _ mutate: (inout EpisodeDownload) -> Void) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }; mutate(&items[i]); if persist { save() }
    }
    @discardableResult private func save() -> Bool {
        guard canSave else { return false }
        do { try JSONEncoder().encode(items).write(to: manifest, options: .atomic); return true }
        catch { storageError = "Download-Status konnte nicht gespeichert werden. Prüfe den freien Speicher."; return false }
    }
    // Paths survive app-container relocation. Never read or delete outside our media roots.
    func fileURL(relativePath: String) -> URL? {
        guard !relativePath.hasPrefix("/"), !relativePath.split(separator: "/").contains("..") else { return nil }
        let url = home.appendingPathComponent(relativePath).standardizedFileURL.resolvingSymlinksInPath()
        let components = relativePath.split(separator: "/")
        let isPackage = components.count == 3 && components[0] == "Library" &&
            (components[1] == "com.apple.UserManagedAssets" || components[1].hasPrefix("com.apple.UserManagedAssets.")) && url.pathExtension == "movpkg"
        let ownFile = url.deletingLastPathComponent() == directory.resolvingSymlinksInPath() && url.pathExtension == "mp4"
        guard (ownFile || isPackage), url.path.hasPrefix(home.resolvingSymlinksInPath().path + "/") else { return nil }
        return url
    }
    func localURL(for item: EpisodeDownload) -> URL? {
        guard item.state == .ready, let path = item.relativePath, let url = fileURL(relativePath: path), FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }
    private func remember(_ location: URL, id: UUID) -> Bool {
        let prefix = home.path + "/"
        guard location.standardizedFileURL.path.hasPrefix(prefix) else { return false }
        let relative = String(location.standardizedFileURL.path.dropFirst(prefix.count))
        guard fileURL(relativePath: relative) != nil else { return false }
        change(id) { $0.relativePath = relative }; return true
    }
    private func removeFile(_ id: UUID) {
        sizes[id] = nil
        if let path = items.first(where: { $0.id == id })?.relativePath, let url = fileURL(relativePath: path) { try? FileManager.default.removeItem(at: url) }
    }
    private func fail(_ id: UUID, _ message: String) {
        removeFile(id); change(id) { $0.state = .failed; $0.message = message; $0.relativePath = nil }
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let id = id(downloadTask), active(id) else { return }
        change(id, persist: false) { $0.bytes = totalBytesWritten; $0.progress = totalBytesExpectedToWrite > 0 ? min(0.99, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)) : 0 }
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let id = id(downloadTask), active(id) else { return }
        guard let response = downloadTask.response as? HTTPURLResponse, response.statusCode == 200,
              !(response.mimeType ?? "").contains("html") else { fail(id, "Die Quelle lieferte keine Videodatei. Bitte andere Quelle wählen."); return }
        do {
            let target = directory.appendingPathComponent(id.uuidString + ".mp4")
            try FileManager.default.moveItem(at: location, to: target)
            guard remember(target, id: id) else { try? FileManager.default.removeItem(at: target); fail(id, "Datei konnte nicht gespeichert werden."); return }
        } catch { fail(id, "Datei konnte nicht gespeichert werden. Prüfe den freien Speicher.") }
    }
    func urlSession(_ session: URLSession, assetDownloadTask: AVAssetDownloadTask, didLoad timeRange: CMTimeRange, totalTimeRangesLoaded loadedTimeRanges: [NSValue], timeRangeExpectedToLoad: CMTimeRange) {
        guard let id = id(assetDownloadTask), active(id) else { return }
        let expected = timeRangeExpectedToLoad.duration.seconds
        let loaded = loadedTimeRanges.reduce(0.0) { $0 + $1.timeRangeValue.duration.seconds }
        if expected.isFinite, expected > 0, loaded.isFinite { change(id, persist: false) { $0.progress = min(0.99, max(0, loaded / expected)) } }
    }
    func urlSession(_ session: URLSession, assetDownloadTask: AVAssetDownloadTask, didFinishDownloadingTo location: URL) {
        guard let id = id(assetDownloadTask) else { return }
        guard active(id) else {
            // A cancelled HLS task can still deliver its partial package.
            let relative = String(location.standardizedFileURL.path.dropFirst(home.path.count + 1))
            if let safe = fileURL(relativePath: relative), safe == location.standardizedFileURL { try? FileManager.default.removeItem(at: safe) }; return
        }
        if !remember(location, id: id) { fail(id, "iOS hat keinen unterstützten lokalen Speicherort geliefert.") }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let id = id(task) else { return }; tasks.removeValue(forKey: id)
        guard active(id) else { return }
        if let error = error as NSError? {
            fail(id, error.code == NSURLErrorCancelled ? "Download unterbrochen. Bitte erneut starten." : "Download fehlgeschlagen (\(error.code)). Folge online öffnen und Quelle erneut versuchen."); return
        }
        change(id) { $0.state = .checking; $0.message = "Offline-Datei wird geprüft …" }; validate(id)
    }
    private func validate(_ id: UUID) {
        guard let entry = items.first(where: { $0.id == id }), let path = entry.relativePath, let url = fileURL(relativePath: path) else { fail(id, "Download ist unvollständig."); return }
        validations[id] = Task { @MainActor [weak self] in
            let asset = AVURLAsset(url: url)
            var valid = false
            do {
                let playable = try await asset.load(.isPlayable)
                let protected = try await asset.load(.hasProtectedContent)
                let duration = try await asset.load(.duration)
                valid = playable && !protected && duration.seconds.isFinite && duration.seconds > 0
                if entry.isHLS { valid = valid && asset.assetCache?.isPlayableOffline == true }
            } catch { valid = false }
            guard let self, !Task.isCancelled, self.items.contains(where: { $0.id == id && $0.state == .checking }) else { return }
            self.validations.removeValue(forKey: id)
            if valid {
                self.change(id) { $0.state = .ready; $0.progress = 1; $0.message = nil }
            } else { self.fail(id, "Diese Quelle liefert keinen vollständig offline abspielbaren Download. Bitte andere Quelle versuchen.") }
            self.completeEventsIfPossible()
        }
    }
}

@MainActor final class DownloadAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        // A cold start from a home screen quick action carries the action here.
        if let item = options.shortcutItem { QuickActions.shared.pending = item.type }
        let configuration = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        configuration.delegateClass = QuickActionSceneDelegate.self
        return configuration
    }
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        OrientationLock.mask
    }
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String, completionHandler: @escaping () -> Void) {
        DownloadStore.shared.backgroundEvents(identifier, completion: completionHandler)
    }
}
