import XCTest
import AVFoundation
import AniCore
@testable import AniLounge

@MainActor final class DownloadTests: XCTestCase {
    private func entry(state: EpisodeDownload.State = .downloading, path: String? = nil, hls: Bool = false, profileID: UUID? = nil) throws -> EpisodeDownload {
        let episode = try JSONDecoder().decode(Episode.self, from: Data("""
        {"path":"/anime/stream/test/staffel-1/episode-1","number":"1","title":"Fixture","languages":[]}
        """.utf8))
        var item = EpisodeDownload(id: UUID(), anime: Anime(path: "/anime/stream/test", title: "Test"), episode: episode, profileID: profileID ?? UUID(), source: "Fixture", isHLS: hls)
        item.state = state; item.relativePath = path
        return item
    }
    private func fixture(_ entries: [EpisodeDownload]) throws -> (DownloadStore, URL) {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let directory = home.appendingPathComponent("Library/Application Support/EpisodeDownloads")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(entries).write(to: directory.appendingPathComponent("index.json"))
        return (DownloadStore(home: home), home)
    }
    func testPathsRejectTraversalManifestAndForeignFiles() throws {
        let (store, home) = try fixture([]); defer { try? FileManager.default.removeItem(at: home) }
        for path in ["../outside.mp4", "/tmp/movie.mp4", "Library/Application Support/EpisodeDownloads/index.json", "Documents/private.mp4", "Library/com.apple.UserManagedAssets/../../private.movpkg"] {
            XCTAssertNil(store.fileURL(relativePath: path), path)
        }
        XCTAssertNotNil(store.fileURL(relativePath: "Library/Application Support/EpisodeDownloads/clip.mp4"))
        XCTAssertNotNil(store.fileURL(relativePath: "Library/com.apple.UserManagedAssets.123/clip.movpkg"))
    }
    func testCancelAndLateCompletionCannotResurrectDownload() throws {
        let item = try entry()
        let (store, home) = try fixture([item]); defer { try? FileManager.default.removeItem(at: home) }
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = session.downloadTask(with: URL(string: "https://example.invalid/movie.mp4")!); task.taskDescription = item.id.uuidString
        store.cancel(item.id)
        store.urlSession(session, task: task, didCompleteWithError: nil)
        XCTAssertEqual(store.items.first?.state, .cancelled)
        store.delete(item.id)
        store.urlSession(session, task: task, didCompleteWithError: nil)
        XCTAssertTrue(store.items.isEmpty)
        XCTAssertTrue(DownloadStore(home: home).items.isEmpty)
    }
    func testInvalidVideoIsNeverReady() async throws {
        let relative = "Library/Application Support/EpisodeDownloads/invalid.mp4"
        let item = try entry(path: relative)
        let (store, home) = try fixture([item]); defer { try? FileManager.default.removeItem(at: home) }
        try Data("<html>Error</html>".utf8).write(to: home.appendingPathComponent(relative))
        let session = URLSession(configuration: .ephemeral); defer { session.invalidateAndCancel() }
        let task = session.downloadTask(with: URL(string: "https://example.invalid/movie.mp4")!); task.taskDescription = item.id.uuidString
        store.urlSession(session, task: task, didCompleteWithError: nil)
        for _ in 0..<100 { if store.items.first?.state != .checking { break }; try await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertEqual(store.items.first?.state, .failed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent(relative).path))
    }
    func testVerifiedVideoPersistsAndOfflinePlayerSkipsHostDiscovery() async throws {
        let relative = "Library/Application Support/EpisodeDownloads/fixture.mp4"
        let item = try entry(path: relative)
        let (store, home) = try fixture([item]); defer { try? FileManager.default.removeItem(at: home) }
        let url = home.appendingPathComponent(relative)
        try XCTUnwrap(Data(base64Encoded: Self.video)).write(to: url)
        let session = URLSession(configuration: .ephemeral); defer { session.invalidateAndCancel() }
        let task = session.downloadTask(with: URL(string: "https://example.invalid/movie.mp4")!); task.taskDescription = item.id.uuidString
        store.urlSession(session, task: task, didCompleteWithError: nil)
        for _ in 0..<100 { if store.items.first?.state != .checking { break }; try await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertEqual(store.items.first?.state, .ready)
        let restored = DownloadStore(home: home)
        let saved = try XCTUnwrap(restored.items.first)
        XCTAssertEqual(restored.localURL(for: saved), url)
        let suite = "DownloadTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
        let library = LibraryStore(defaults: defaults)
        let request = PlaybackRequest(anime: item.anime, episode: item.episode, profileID: library.profile.id, localURL: url)
        let player = PlayerModel(request: request, store: library); defer { player.finish() }
        await player.loadHosts()
        for _ in 0..<100 { if player.nativeReady { break }; try await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertTrue(player.nativeReady)
        XCTAssertTrue(player.hosts.isEmpty)
        XCTAssertNil(player.nextEpisode)
        XCTAssertFalse(player.loadingHosts)
        XCTAssertNil(player.webView.url)
        XCTAssertEqual((player.player?.currentItem?.asset as? AVURLAsset)?.url, url)
        player.checkpoint()
        XCTAssertNotNil(library.progress(for: item.episode, profileID: library.profile.id))
        store.delete(item.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }
    func testProfileIsolationAndMissingFile() throws {
        let item = try entry(state: .ready, path: "Library/Application Support/EpisodeDownloads/missing.mp4")
        let (store, home) = try fixture([item]); defer { try? FileManager.default.removeItem(at: home) }
        XCTAssertNil(store.localURL(for: item))
        XCTAssertNil(store.existing(PlaybackRequest(anime: item.anime, episode: item.episode, profileID: UUID())))
    }

    func testRestorationWaitsForBothHLSSessionsAndKeepsCancelledTaskCancelled() throws {
        for wifiFirst in [true, false] {
            let cellular = try entry(hls: true), wifi = try entry(hls: true), missing = try entry(hls: true)
            let cancelled = try entry(hls: true)
            let (store, home) = try fixture([cellular, wifi, missing, cancelled])
            defer { try? FileManager.default.removeItem(at: home) }
            let session = URLSession(configuration: .ephemeral)
            defer { session.invalidateAndCancel() }
            func task(_ id: UUID) -> URLSessionTask {
                let task = session.downloadTask(with: URL(string: "https://example.invalid/fixture.m3u8")!)
                task.taskDescription = id.uuidString
                return task
            }
            store.beginRestoration(sessionIDs: [DownloadStore.fileSessionID, DownloadStore.hlsSessionID, DownloadStore.hlsWifiSessionID])
            store.cancel(cancelled.id)
            let firstID = wifiFirst ? DownloadStore.hlsWifiSessionID : DownloadStore.hlsSessionID
            let secondID = wifiFirst ? DownloadStore.hlsSessionID : DownloadStore.hlsWifiSessionID
            store.restoreTasks([task(wifiFirst ? wifi.id : cellular.id)], sessionID: firstID)
            store.restoreTasks([], sessionID: DownloadStore.fileSessionID)
            XCTAssertEqual(store.items.first { $0.id == missing.id }?.state, .downloading)
            store.restoreTasks([task(wifiFirst ? cellular.id : wifi.id), task(cancelled.id)], sessionID: secondID)
            XCTAssertEqual(store.items.first { $0.id == cellular.id }?.state, .downloading)
            XCTAssertEqual(store.items.first { $0.id == wifi.id }?.state, .downloading)
            XCTAssertEqual(store.items.first { $0.id == missing.id }?.state, .failed)
            XCTAssertEqual(store.items.first { $0.id == cancelled.id }?.state, .cancelled)
            XCTAssertEqual(store.items.first { $0.id == cellular.id }?.sessionID, DownloadStore.hlsSessionID)
            XCTAssertEqual(store.items.first { $0.id == wifi.id }?.sessionID, DownloadStore.hlsWifiSessionID)
        }
    }

    func testCommonPlaybackEntryUsesOfflineCopyAndConfirmsOtherEdition() throws {
        let suite = "OfflineEntryTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let library = LibraryStore(defaults: defaults)
        var item = try entry(state: .ready, path: "Library/Application Support/EpisodeDownloads/offline.mp4", profileID: library.profile.id)
        item.language = AppSettings.shared.language(for: library.profile.id)
        let (store, home) = try fixture([item])
        defer { try? FileManager.default.removeItem(at: home) }
        try XCTUnwrap(Data(base64Encoded: Self.video)).write(to: home.appendingPathComponent(item.relativePath!))
        let request = PlaybackRequest(anime: item.anime, episode: item.episode, profileID: item.profileID)
        let center = PlaybackCenter(downloads: store)
        center.open(request, library: library)
        let model = try XCTUnwrap(center.presented)
        defer { model.finish() }
        XCTAssertEqual(model.request.localURL, home.appendingPathComponent(item.relativePath!))
        XCTAssertTrue(model.hosts.isEmpty)
        XCTAssertNil(model.webView.url)
        XCTAssertNil(center.pendingOffline)
        XCTAssertNil(store.offlineOption(for: PlaybackRequest(anime: item.anime, episode: item.episode, profileID: UUID()), preferredLanguage: item.language!))

        // Unknown metadata must never silently stand in for the preferred language.
        var unknown = item; unknown.language = nil
        let (unknownStore, otherHome) = try fixture([unknown])
        defer { try? FileManager.default.removeItem(at: otherHome) }
        try XCTUnwrap(Data(base64Encoded: Self.video)).write(to: otherHome.appendingPathComponent(unknown.relativePath!))
        let confirmation = PlaybackCenter(downloads: unknownStore)
        confirmation.open(request, library: library)
        XCTAssertNil(confirmation.presented)
        let prompt = try XCTUnwrap(confirmation.pendingOffline)
        confirmation.confirmOffline(prompt)
        XCTAssertNotNil(confirmation.presented?.request.localURL)
        confirmation.presented?.finish()
    }

    func testLegacyDownloadManifestWithoutNewFieldsAndDifferentLanguage() throws {
        var item = try entry(state: .ready, path: "Library/Application Support/EpisodeDownloads/legacy.mp4")
        item.language = "DE-Sub"
        let (store, home) = try fixture([item])
        defer { try? FileManager.default.removeItem(at: home) }
        try Data("fixture".utf8).write(to: home.appendingPathComponent(item.relativePath!))
        let request = PlaybackRequest(anime: item.anime, episode: item.episode, profileID: item.profileID)
        XCTAssertTrue(try XCTUnwrap(store.offlineOption(for: request, preferredLanguage: "DE")).requiresConfirmation)
        XCTAssertFalse(try XCTUnwrap(store.offlineOption(for: request, preferredLanguage: "Mit deutschem Untertitel")).requiresConfirmation)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(item)) as? [String: Any])
        json.removeValue(forKey: "sessionID"); json.removeValue(forKey: "language")
        let old = try JSONDecoder().decode(EpisodeDownload.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(old.id, item.id)
        XCTAssertNil(old.language)
        XCTAssertNil(old.sessionID)
    }

    // Locally generated 64x64 purple H.264 video, two seconds. No provider or external media.
    private static let video = "AAAAIGZ0eXBpc29tAAACAGlzb21pc28yYXZjMW1wNDEAAAQibW9vdgAAAGxtdmhkAAAAAAAAAAAAAAAAAAAD6AAAB9AAAQAAAQAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAgAAA0x0cmFrAAAAXHRraGQAAAADAAAAAAAAAAAAAAABAAAAAAAAB9AAAAAAAAAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAABAAAAAAEAAAABAAAAAAAAkZWR0cwAAABxlbHN0AAAAAAAAAAEAAAfQAAAIAAABAAAAAALEbWRpYQAAACBtZGhkAAAAAAAAAAAAAAAAAAAoAAAAUABVxAAAAAAALWhkbHIAAAAAAAAAAHZpZGUAAAAAAAAAAAAAAABWaWRlb0hhbmRsZXIAAAACb21pbmYAAAAUdm1oZAAAAAEAAAAAAAAAAAAAACRkaW5mAAAAHGRyZWYAAAAAAAAAAQAAAAx1cmwgAAAAAQAAAi9zdGJsAAAAv3N0c2QAAAAAAAAAAQAAAK9hdmMxAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAAAAEAAQABIAAAASAAAAAAAAAABFUxhdmM2MC4zMS4xMDIgbGlieDI2NAAAAAAAAAAAAAAAGP//AAAANWF2Y0MBZAAK/+EAGGdkAAqs2UQmwEQAAAMABAAAAwBQPEiWWAEABmjr48siwP34+AAAAAAQcGFzcAAAAAEAAAABAAAAFGJ0cnQAAAAAAAAPrAAAD6wAAAAYc3R0cwAAAAAAAAABAAAAFAAABAAAAAAUc3RzcwAAAAAAAAABAAAAAQAAAKhjdHRzAAAAAAAAABMAAAABAAAIAAAAAAEAABQAAAAAAQAACAAAAAABAAAAAAAAAAEAAAQAAAAAAQAAFAAAAAABAAAIAAAAAAEAAAAAAAAAAQAABAAAAAABAAAUAAAAAAEAAAgAAAAAAQAAAAAAAAABAAAEAAAAAAEAABQAAAAAAQAACAAAAAABAAAAAAAAAAEAAAQAAAAAAQAAEAAAAAACAAAEAAAAABxzdHNjAAAAAAAAAAEAAAABAAAAFAAAAAEAAABkc3RzegAAAAAAAAAAAAAAFAAAAt0AAAAOAAAADAAAAAwAAAAMAAAAFAAAAA4AAAAMAAAADAAAABQAAAAOAAAADAAAAAwAAAAUAAAADgAAAAwAAAAMAAAAFAAAAA4AAAAMAAAAFHN0Y28AAAAAAAAAAQAABFIAAABidWR0YQAAAFptZXRhAAAAAAAAACFoZGxyAAAAAAAAAABtZGlyYXBwbAAAAAAAAAAAAAAAAC1pbHN0AAAAJal0b28AAAAdZGF0YQAAAAEAAAAATGF2ZjYwLjE2LjEwMAAAAAhmcmVlAAAD821kYXQAAAKuBgX//6rcRem95tlIt5Ys2CDZI+7veDI2NCAtIGNvcmUgMTY0IHIzMTA4IDMxZTE5ZjkgLSBILjI2NC9NUEVHLTQgQVZDIGNvZGVjIC0gQ29weWxlZnQgMjAwMy0yMDIzIC0gaHR0cDovL3d3dy52aWRlb2xhbi5vcmcveDI2NC5odG1sIC0gb3B0aW9uczogY2FiYWM9MSByZWY9MyBkZWJsb2NrPTE6MDowIGFuYWx5c2U9MHgzOjB4MTEzIG1lPWhleCBzdWJtZT03IHBzeT0xIHBzeV9yZD0xLjAwOjAuMDAgbWl4ZWRfcmVmPTEgbWVfcmFuZ2U9MTYgY2hyb21hX21lPTEgdHJlbGxpcz0xIDh4OGRjdD0xIGNxbT0wIGRlYWR6b25lPTIxLDExIGZhc3RfcHNraXA9MSBjaHJvbWFfcXBfb2Zmc2V0PS0yIHRocmVhZHM9MiBsb29rYWhlYWRfdGhyZWFkcz0xIHNsaWNlZF90aHJlYWRzPTAgbnI9MCBkZWNpbWF0ZT0xIGludGVybGFjZWQ9MCBibHVyYXlfY29tcGF0PTAgY29uc3RyYWluZWRfaW50cmE9MCBiZnJhbWVzPTMgYl9weXJhbWlkPTIgYl9hZGFwdD0xIGJfYmlhcz0wIGRpcmVjdD0xIHdlaWdodGI9MSBvcGVuX2dvcD0wIHdlaWdodHA9MiBrZXlpbnQ9MjUwIGtleWludF9taW49MTAgc2NlbmVjdXQ9NDAgaW50cmFfcmVmcmVzaD0wIHJjX2xvb2thaGVhZD00MCByYz1jcmYgbWJ0cmVlPTEgY3JmPTIzLjAgcWNvbXA9MC42MCBxcG1pbj0wIHFwbWF4PTY5IHFwc3RlcD00IGlwX3JhdGlvPTEuNDAgYXE9MToxLjAwAIAAAAAnZYiEABH//ufj/ApseRHEvgWQBjam13Ki6Nce2KM2pLx924Q9sRn9AAAACkGaJGxBH/61K+8AAAAIQZ5CeId/Bb0AAAAIAZ5hdEN/B3wAAAAIAZ5jakN/B30AAAAQQZpoSahBaJlMCCP//rUr7wAAAApBnoZFESw7/wW9AAAACAGepXRDfwd9AAAACAGep2pDfwd8AAAAEEGarEmoQWyZTAgh//6qV94AAAAKQZ7KRRUsO/8FvQAAAAgBnul0Q38HfAAAAAgBnutqQ38HfAAAABBBmvBJqEFsmUwIf//+qZ01AAAACkGfDkUVLDv/Bb0AAAAIAZ8tdEN/B30AAAAIAZ8vakN/B3wAAAAQQZszSahBbJlMCG///qePiAAAAApBn1FFFSw3/wd9AAAACAGfcmpDfwd8"
}
