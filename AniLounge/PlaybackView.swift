import SwiftUI
import WebKit
import AVKit
import AniCore

struct PlaybackRequest: Identifiable {
    let id = UUID()
    let anime: Anime
    let episode: Episode
    let profileID: UUID
    var localURL: URL? = nil
}
@MainActor private final class WeakProgressHandler: NSObject, WKScriptMessageHandler {
    weak var target: PlayerModel?
    init(_ target: PlayerModel) { self.target = target }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(userContentController, didReceive: message)
    }
}
/// Keeps a playback session alive while it runs in Picture in Picture after its screen was closed,
/// and re-presents it when the viewer restores the floating window.
@MainActor final class PlaybackCenter: ObservableObject {
    static let shared = PlaybackCenter()
    @Published var restored: PlayerModel?
    private(set) var current: PlayerModel?
    func activate(_ model: PlayerModel) {
        if let current, current !== model { current.finish() }
        current = model
    }
    func ended(_ model: PlayerModel) {
        if current === model { current = nil }
        if restored === model { restored = nil }
    }
}
@MainActor final class PlayerModel: NSObject, ObservableObject, Identifiable, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate, AVPlayerViewControllerDelegate {
    let webView: WKWebView
    @Published private(set) var request: PlaybackRequest
    private let store: LibraryStore
    private let world = WKContentWorld.world(name: "AniLoungeProgress")
    private var token = UUID().uuidString
    private var lastPosition: Double?
    private var lastDuration: Double?
    private var lastCompleted = false
    private var mediaOrigin: String?
    private var mediaFrame: WKFrameInfo?
    private var attempted = Set<URL>()
    private var generation = UUID()
    private var closed = false
    private var triedHosts = Set<String>()
    private var startupWatchdog: Task<Void, Never>?
    private var nextTask: Task<Void, Never>?
    private var countdownTask: Task<Void, Never>?
    private var handledEnd = false
    @Published var nextEpisode: Episode?
    @Published var nextEpisodeError: String?
    @Published var countdown: Int?
    @Published var autoNext = UserDefaults.standard.bool(forKey: "playback.autoNext")
    @Published var recoveryMessage: String?
    @Published private(set) var inPictureInPicture = false
    @Published private(set) var playhead: Double = 0
    /// The screen was closed while Picture in Picture kept playing.
    var detached = false
    private var restoringInterface = false
    private(set) lazy var playerController: AVPlayerViewController = {
        let controller = AVPlayerViewController()
        controller.allowsPictureInPicturePlayback = true
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        controller.delegate = self
        return controller
    }()

    private var nativeDisabled = false
    private var downloadCookies: [HTTPCookie] = []
    private var downloadHeaders: [String: String] = [:]
    private func mediaHeaders() -> [String: String] {
        guard let page = mediaFrame?.request.url ?? webView.url, page.scheme == "https", let host = page.host else { return [:] }
        return ["Referer": page.absoluteString, "Origin": "https://" + host]
    }
    var isOffline: Bool { request.localURL != nil }
    func download() {
        guard nativeReady, let asset = player?.currentItem?.asset as? AVURLAsset, !isOffline else { return }
        DownloadStore.shared.enqueue(request: request, asset: asset, cookies: downloadCookies, headers: downloadHeaders, source: selectedHost.map { "\($0.name) · \($0.language)" } ?? "Video")
    }
    private var itemObservation: NSKeyValueObservation?
    private var endObservation: NSObjectProtocol?
    private var timeObserver: Any?
    private var timeout: Task<Void, Never>?
    private var restoring = false
    private var loadTask: Task<Void, Never>?
    @Published var startedAt = Date()
    @Published var adBlockEnabled = UserDefaults.standard.object(forKey: "web.adblock.enabled") as? Bool ?? true
    @Published var blockerStatus = "Werbeblocker wird vorbereitet"
    private var revealTask: Task<Void, Never>?
    @Published var preparing = true
    private var preferenceKey: String { "playback.preference." + request.profileID.uuidString }

    @Published var hosts: [StreamHost] = []
    @Published var choosingHost = false
    @Published var loadingHosts = false
    @Published var selectedHost: StreamHost?
    @Published var player: AVPlayer?
    @Published var nativeReady = false
    @Published var status = "Wähle Sprache und Videoanbieter."
    @Published var error: String?
    @Published var savedLabel: String?
    init(request: PlaybackRequest, store: LibraryStore) {
        self.request = request; self.store = store
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.allowsPictureInPictureMediaPlayback = true
        configuration.websiteDataStore = .default()
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self; webView.uiDelegate = self
        configuration.userContentController.add(WeakProgressHandler(self), contentWorld: world, name: "aniProgress")
    }
    func loadHosts() async {
        if let url = request.localURL { if player == nil { startNative(url) }; return }
        guard hosts.isEmpty, !loadingHosts else { return }
        loadingHosts = true; error = nil; startedAt = Date(); status = "Verfügbare Quellen werden gesucht …"
        defer { loadingHosts = false }
        do {
            hosts = try await AniClient.shared.hosts(path: request.episode.path)
            guard !closed, !Task.isCancelled else { return }
            let preference = UserDefaults.standard.dictionary(forKey: preferenceKey)
            loadNextEpisode()
            if let host = PlaybackSource.preferredHost(in: hosts, name: preference?["name"] as? String, language: preference?["language"] as? String) {
                select(host, remember: false)
            } else { choosingHost = true; preparing = false }
        }
        catch { if !Task.isCancelled { self.error = error.localizedDescription; choosingHost = true; preparing = false } }
    }
    private func installTracker() {
        token = UUID().uuidString
        let old = store.progress(for: request.episode, profileID: request.profileID)
        let config: [String: Any] = ["autoPlay": true, "token": token, "seconds": old?.completed == true ? 0 : (old?.seconds ?? 0), "duration": old?.duration ?? 0]
        let controller = webView.configuration.userContentController
        controller.removeAllUserScripts()
        if let scriptURL = Bundle.main.url(forResource: "PlaybackTracker", withExtension: "js"),
           let template = try? String(contentsOf: scriptURL),
           let data = try? JSONSerialization.data(withJSONObject: config), let json = String(data: data, encoding: .utf8) {
            let script = template.replacingOccurrences(of: "__ANILOUNGE_CONFIG__", with: json)
            controller.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentEnd, forMainFrameOnly: false, in: world))
        } else { error = "Automatische Videoerkennung fehlt. Fortschritt kann in der Folgenliste eingetragen werden." }
    }
    func select(_ host: StreamHost?, remember: Bool = true, automatic: Bool = false) {
        guard let url = host?.url ?? AniURL.page(request.episode.path) else { return }
        checkpoint(); stopNative(); startupWatchdog?.cancel(); cancelCountdown()
        if !automatic { triedHosts.removeAll(); recoveryMessage = nil }
        if let host { triedHosts.insert(host.id) }
        handledEnd = false
        selectedHost = host; choosingHost = false; error = nil; preparing = true; startedAt = Date()
        if remember, let host { UserDefaults.standard.set(["name": host.name, "language": host.language], forKey: preferenceKey) }
        revealTask?.cancel()
        revealTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 12_000_000_000)
            guard !Task.isCancelled, let self, !self.closed, !self.nativeReady else { return }
            self.preparing = false
            self.status = "Der Anbieter braucht eventuell einen weiteren Start-Tipp. Alternativ Quelle wechseln."
        }
        lastPosition = nil; lastDuration = nil; lastCompleted = false; mediaOrigin = nil; mediaFrame = nil
        attempted.removeAll(); nativeDisabled = false; savedLabel = nil
        installTracker()
        status = "Dein Video wird vorbereitet …"
        loadTask?.cancel()
        let navigationToken = token
        loadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let rules = self.adBlockEnabled ? await WebAdBlocker.rules() : nil
            guard !Task.isCancelled, !self.closed, self.token == navigationToken else { return }
            let controller = self.webView.configuration.userContentController
            controller.removeAllContentRuleLists()
            if self.adBlockEnabled, let rules {
                controller.add(rules); self.blockerStatus = "Werbeblocker aktiv"
            } else if self.adBlockEnabled {
                self.blockerStatus = "Werbeblocker konnte nicht geladen werden"
            } else { self.blockerStatus = "Werbeblocker aus" }
            self.status = "Verbindung zum Anbieter wird aufgebaut …"
            self.webView.load(URLRequest(url: url))
            self.startupWatchdog = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 35_000_000_000)
                guard !Task.isCancelled, let self, !self.closed, self.token == navigationToken, !self.nativeReady, self.lastPosition == nil, !self.nativeDisabled else { return }
                self.recover("Die Quelle hat innerhalb von 35 Sekunden kein Video geliefert.")
            }
        }
    }
    func recover(_ reason: String) {
        guard !closed, !choosingHost else { return }
        if isOffline { stopNative(); preparing = false; error = "Die lokale Datei konnte nicht abgespielt werden. Lade die Folge erneut herunter."; return }
        if let host = selectedHost, let replacement = PlaybackQueue.replacement(in: hosts, current: host, attempted: triedHosts) {
            let notice = reason + " Versuche " + replacement.name + " in " + replacement.language + "."
            select(replacement, remember: false, automatic: true)
            recoveryMessage = notice
        } else {
            startupWatchdog?.cancel()
            useWebPlayer(reason)
            error = reason + " Keine weitere automatische Ersatzquelle in dieser Sprache verfügbar."
        }
    }
    func retry() {
        if isOffline { stopNative(); attempted.removeAll(); preparing = true; Task { await loadHosts() }; return }
        if let host = selectedHost { select(host, remember: false) }
        else { Task { await loadHosts() } }
    }
    func loadNextEpisode() {
        nextTask?.cancel(); nextEpisode = nil; nextEpisodeError = nil
        let episode = request.episode
        let anime = request.anime
        nextTask = Task { @MainActor [weak self] in
            do {
                guard let separator = episode.path.lastIndex(of: "/") else { return }
                let seasonPath = String(episode.path.prefix(upTo: separator))
                let season = try await AniClient.shared.detail(path: seasonPath)
                var next = PlaybackQueue.next(after: episode, in: season.episodes)
                if next == nil, season.episodes.last?.id == episode.id, seasonPath.contains("/staffel-") {
                    let detail = try await AniClient.shared.detail(path: anime.path)
                    let seasons = detail.seasons.filter { $0.path.contains("/staffel-") }
                    if let index = seasons.firstIndex(where: { $0.path == seasonPath }), seasons.indices.contains(index + 1) {
                        next = try await AniClient.shared.detail(path: seasons[index + 1].path).episodes.first
                    }
                }
                guard !Task.isCancelled, let self, !self.closed, self.request.episode.id == episode.id else { return }
                self.nextEpisode = next
                if self.handledEnd { self.scheduleNext() }
            } catch {
                guard !Task.isCancelled, let self, !self.closed else { return }
                self.nextEpisodeError = "Nächste Folge konnte nicht geladen werden."
            }
        }
    }
    func playNext() {
        guard let episode = nextEpisode, !closed else { return }
        checkpoint(); stopNative(); loadTask?.cancel(); startupWatchdog?.cancel(); nextTask?.cancel(); cancelCountdown()
        token = UUID().uuidString
        webView.stopLoading(); webView.loadHTMLString("", baseURL: nil)
        request = PlaybackRequest(anime: request.anime, episode: episode, profileID: request.profileID)
        nextEpisode = nil; nextEpisodeError = nil; hosts = []; selectedHost = nil
        lastPosition = nil; lastDuration = nil; lastCompleted = false; savedLabel = nil
        handledEnd = false; choosingHost = false; preparing = true; error = nil
        Task { await loadHosts() }
    }
    func setAutoNext(_ value: Bool) {
        autoNext = value; UserDefaults.standard.set(value, forKey: "playback.autoNext")
        if !value { cancelCountdown() }
    }
    func cancelCountdown() { countdownTask?.cancel(); countdownTask = nil; countdown = nil }
    private func episodeEnded() {
        guard !handledEnd else { return }
        handledEnd = true; scheduleNext()
    }
    private func scheduleNext() {
        guard autoNext, nextEpisode != nil, countdownTask == nil else { return }
        countdown = 10
        countdownTask = Task { @MainActor [weak self] in
            for remaining in stride(from: 9, through: 0, by: -1) {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled, let self, !self.closed else { return }
                self.countdown = remaining
            }
            self?.playNext()
        }
    }
    func setAdBlockEnabled(_ enabled: Bool) {
        adBlockEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "web.adblock.enabled")
        if !choosingHost, let host = selectedHost { select(host, remember: false) }
    }
    func chooseHost() {
        checkpoint(); stopNative(); loadTask?.cancel(); startupWatchdog?.cancel(); cancelCountdown(); token = UUID().uuidString
        webView.stopLoading(); webView.loadHTMLString("", baseURL: nil)
        choosingHost = true; error = nil; preparing = false; revealTask?.cancel()
    }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard !closed, !choosingHost, let body = message.body as? [String: Any], body["token"] as? String == token else { return }
        if body["kind"] as? String == "source" {
            if let value = body["url"] as? String, let url = PlaybackSource.directURL(value) { mediaFrame = message.frameInfo; startNative(url) }
            return
        }
        guard !nativeReady, let seconds = body["seconds"] as? Double, let duration = body["duration"] as? Double,
              seconds.isFinite, duration.isFinite, seconds >= 0, seconds <= duration + 1,
              duration >= 90, duration <= 86400 else { return }
        let origin = message.frameInfo.securityOrigin.host
        if let mediaOrigin, mediaOrigin != origin, let lastDuration, duration < lastDuration * 0.8 { return }
        mediaOrigin = origin; mediaFrame = message.frameInfo
        record(seconds: seconds, duration: duration, completed: body["ended"] as? Bool == true || seconds >= duration - 10)
        if body["ended"] as? Bool == true { episodeEnded() }
    }
    private func record(seconds: Double, duration: Double, completed: Bool) {
        startupWatchdog?.cancel()
        if handledEnd && !completed { handledEnd = false; cancelCountdown() }
        lastPosition = min(seconds, duration); lastDuration = duration; lastCompleted = completed; playhead = min(seconds, duration)
        persist()
        savedLabel = "\(EpisodeProgress.format(seconds)) / \(EpisodeProgress.format(duration))"
    }
    private func persist() {
        guard let seconds = lastPosition else { return }
        store.saveProgress(request.episode, anime: request.anime, seconds: seconds, duration: lastDuration,
                           completed: lastCompleted, profileID: request.profileID)
    }
    private func startNative(_ url: URL) {
        guard !closed, !nativeDisabled, player == nil, attempted.insert(url).inserted else { return }
        let attempt = generation
        status = "iOS-Player wird vorbereitet …"
        // Cookie transfer uses Apple's documented asset option. No cookies are logged or exported.
        webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
            guard let self, self.generation == attempt, !self.closed, !self.nativeDisabled, self.player == nil else { return }
            let host = url.host ?? ""
            let matching = cookies.filter {
                let domain = $0.domain.hasPrefix(".") ? String($0.domain.dropFirst()) : $0.domain
                return (host == domain || host.hasSuffix("." + domain)) && url.path.hasPrefix($0.path)
            }
            self.downloadCookies = matching
            var options: [String: Any] = [AVURLAssetHTTPCookiesKey: matching]
            // Many hosters reject media requests without the embedding page as referer.
            let headers = self.mediaHeaders()
            if !headers.isEmpty { options["AVURLAssetHTTPHeaderFieldsKey"] = headers }
            self.downloadHeaders = headers
            let asset = AVURLAsset(url: url, options: options)
            let item = AVPlayerItem(asset: asset)
            let player = AVPlayer(playerItem: item)
            self.player = player
            self.itemObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
                Task { @MainActor [weak self] in
                    guard let self, self.generation == attempt, self.player?.currentItem === item else { return }
                    if item.status == .readyToPlay { self.activateNative(item) }
                    else if item.status == .failed { self.recover("Der Videolink konnte nicht abgespielt werden.") }
                }
            }
            self.timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 5, preferredTimescale: 600), queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, self.generation == attempt else { return }
                    self.captureNative()
                }
            }
            self.endObservation = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, self.generation == attempt else { return }
                    self.captureNative(ended: true); self.episodeEnded()
                }
            }
            self.timeout = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                guard !Task.isCancelled, let self, self.generation == attempt, !self.nativeReady else { return }
                self.recover("Der native Player konnte die Quelle nicht rechtzeitig laden.")
            }
        }
    }
    private func activateNative(_ item: AVPlayerItem) {
        guard !nativeReady, !closed else { return }
        startupWatchdog?.cancel()
        nativeReady = true; preparing = false; revealTask?.cancel(); restoring = true; timeout?.cancel(); error = nil
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)
        status = "iOS-Player · Fortschritt wird automatisch gespeichert."
        webView.setAllMediaPlaybackSuspended(true, completionHandler: nil)
        let old = store.progress(for: request.episode, profileID: request.profileID)
        let position = PlaybackSource.resumePosition(saved: old?.completed == true ? 0 : (old?.seconds ?? 0),
                                                     savedDuration: old?.duration, duration: item.duration.seconds.isFinite ? item.duration.seconds : (lastDuration ?? old?.duration ?? 0))
        let attempt = generation
        // Avoid a redundant seek at startup; resume may land within one second of the saved position.
        playhead = position
        if position == 0 { restoring = false; player?.play(); return }
        let tolerance = CMTime(seconds: 1, preferredTimescale: 600)
        player?.seek(to: CMTime(seconds: position, preferredTimescale: 600), toleranceBefore: tolerance, toleranceAfter: tolerance) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.generation == attempt, !self.closed else { return }
                self.restoring = false; self.player?.play()
            }
        }
    }
    private func captureNative(ended: Bool = false) {
        guard nativeReady, !restoring, let player else { return }
        let seconds = player.currentTime().seconds
        let duration = player.currentItem?.duration.seconds ?? 0
        guard seconds.isFinite, seconds >= 0, duration.isFinite, duration > 0, duration <= 86400 else { return }
        record(seconds: seconds, duration: duration, completed: ended || seconds >= duration - 10)
    }
    func checkpoint() { captureNative(); persist() }
    func skip(_ seconds: Double) {
        guard nativeReady, let player else { return }
        let target = max(0, player.currentTime().seconds + seconds)
        guard target.isFinite else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        playhead = target
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600)) { [weak self] _ in
            Task { @MainActor [weak self] in self?.checkpoint() }
        }
    }
    // MARK: Picture in Picture
    func playerViewControllerWillStartPictureInPicture(_ playerViewController: AVPlayerViewController) { inPictureInPicture = true }
    func playerViewControllerDidStopPictureInPicture(_ playerViewController: AVPlayerViewController) {
        inPictureInPicture = false
        if detached && !restoringInterface { finish() }
    }
    func playerViewController(_ playerViewController: AVPlayerViewController, restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        guard detached, !closed else { completionHandler(true); return }
        restoringInterface = true
        PlaybackCenter.shared.restored = self
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard let self else { completionHandler(false); return }
            self.restoringInterface = false
            completionHandler(!self.detached)
            // The app could not show the player (another sheet in the way): end the session cleanly.
            if self.detached && !self.inPictureInPicture { self.finish() }
        }
    }
    /// Called when the playback screen goes away. Picture in Picture keeps the session running.
    func screenRemoved() {
        if inPictureInPicture || restoringInterface { detached = true } else { finish() }
    }
    func useWebPlayer(_ reason: String = "Webplayer aktiv. Neue Fenster bleiben blockiert.") {
        checkpoint(); stopNative(); startupWatchdog?.cancel(); nativeDisabled = true; preparing = false; revealTask?.cancel()
        webView.setAllMediaPlaybackSuspended(false, completionHandler: nil)
        // Resume the existing document at the latest native position, if its video supports seeking.
        if let position = lastPosition {
            webView.evaluateJavaScript("window.aniLoungeSeek?.(\(position))", in: mediaFrame, in: world, completionHandler: nil)
        }
        status = reason
    }
    private func stopNative() {
        generation = UUID(); timeout?.cancel(); timeout = nil
        itemObservation?.invalidate(); itemObservation = nil
        if let timeObserver, let player { player.removeTimeObserver(timeObserver) }; timeObserver = nil
        if let endObservation { NotificationCenter.default.removeObserver(endObservation) }; endObservation = nil
        player?.pause(); player?.replaceCurrentItem(with: nil); player = nil; nativeReady = false; restoring = false; playhead = 0
        webView.setAllMediaPlaybackSuspended(false, completionHandler: nil)
    }
    func finish() {
        guard !closed else { return }
        checkpoint(); closed = true; startupWatchdog?.cancel(); nextTask?.cancel(); cancelCountdown(); loadTask?.cancel(); revealTask?.cancel(); stopNative()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        webView.stopLoading(); webView.loadHTMLString("", baseURL: nil)
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "aniProgress", contentWorld: world)
        playerController.player = nil; detached = false
        PlaybackCenter.shared.ended(self)
    }
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        guard !choosingHost, !nativeReady, webView.url?.scheme == "https" else { return }
        status = "Anbieter verbunden · Videolink wird gesucht …"
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard !choosingHost, !nativeReady, webView.url?.scheme == "https" else { return }
        if player == nil {
            preparing = false; revealTask?.cancel()
            status = "Anbieter geladen. Falls das Video nicht startet: Play antippen oder Quelle wechseln."
        }
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if (error as NSError).code != NSURLErrorCancelled {
            if (error as NSError).code == NSURLErrorNotConnectedToInternet {
                useWebPlayer("Keine Internetverbindung."); self.error = "Du bist offline. Verbindung prüfen und erneut versuchen."
            } else { recover("Die Verbindung zum Anbieter ist fehlgeschlagen.") }
        }
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url, ["https", "about"].contains(url.scheme ?? "") else { decisionHandler(.cancel); return }
        if adBlockEnabled, AdBlockRules.blocks(url) { decisionHandler(.cancel); return }
        // Providers open in this view only through our explicit host selection, never from popups.
        if navigationAction.targetFrame == nil { decisionHandler(.cancel); return }
        decisionHandler(.allow)
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        if navigationResponse.isForMainFrame, let responseURL = navigationResponse.response.url,
           let url = PlaybackSource.directURL(responseURL.absoluteString, mimeType: navigationResponse.response.mimeType) {
            startNative(url)
        }
        decisionHandler(.allow)
    }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        return nil
    }
}
struct PlaybackView: View {
    @StateObject private var model: PlayerModel
    @ObservedObject private var downloads = DownloadStore.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var phase
    @Environment(\.verticalSizeClass) private var verticalSize
    init(request: PlaybackRequest, library: LibraryStore) {
        _model = StateObject(wrappedValue: PlayerModel(request: request, store: library))
    }
    init(model: PlayerModel) {
        _model = StateObject(wrappedValue: model)
    }
    /// iPhone landscape: the video fills the screen like a streaming app.
    private var theater: Bool { verticalSize == .compact && !model.choosingHost }
    private var videoSized: Bool { model.nativeReady || model.preparing }
    var body: some View {
        NavigationStack {
            Group {
                if model.choosingHost {
                    hostPicker
                } else if theater {
                    stage.ignoresSafeArea()
                } else {
                    VStack(spacing: 0) {
                        if videoSized { stage.aspectRatio(16 / 9, contentMode: .fit) } else { stage }
                        infoPanel
                    }
                }
            }.background((theater ? Color.black : Theme.background).ignoresSafeArea())
                .navigationTitle(model.choosingHost ? "Quelle wählen" : "")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar(theater ? .hidden : .visible, for: .navigationBar)
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button { model.finish(); dismiss() } label: { Image(systemName: "chevron.down").font(.body.bold()) }.accessibilityLabel("Player schließen")
                    }
                    ToolbarItem(placement: .principal) {
                        if !model.choosingHost {
                            VStack(spacing: 0) {
                                Text(model.request.anime.title).font(.subheadline.bold()).lineLimit(1)
                                Text("Folge \(model.request.episode.number)").font(.caption2).foregroundColor(Theme.muted)
                            }
                        }
                    }
                    ToolbarItem(placement: .navigationBarTrailing) {
                        if model.choosingHost && model.selectedHost != nil { Button("Zurück") { model.select(model.selectedHost, remember: false) } }
                    }
                }
                .statusBarHidden(theater)
                .alert("Download", isPresented: Binding(get: { downloads.storageError != nil }, set: { if !$0 { downloads.storageError = nil } })) { Button("OK", role: .cancel) {} } message: { Text(downloads.storageError ?? "") }
                .task { PlaybackCenter.shared.activate(model); await model.loadHosts() }
                .onChange(of: phase) { if $0 != .active { model.checkpoint(); model.cancelCountdown() } }
                // Picture in Picture continues in a small window while the viewer keeps browsing.
                .onChange(of: model.inPictureInPicture) { if $0 { dismiss() } }
                // Covering this view (AVKit fullscreen) is not closing the playback session.
                .onDisappear { model.checkpoint() }
                .background(PlaybackLifetime(model: model).frame(width: 0, height: 0))
        }.tint(Theme.accent).preferredColorScheme(.dark)
    }

    // MARK: Video stage
    private var stage: some View {
        ZStack {
            Color.black
            PlayerWebView(webView: model.webView).opacity(model.nativeReady || model.preparing ? 0 : 1)
            if model.preparing { loadingCard }
            if model.nativeReady, let player = model.player { NativePlayerView(model: model, player: player) }
            if model.nativeReady { overlays }
        }.clipped()
    }
    private var loadingCard: some View {
        ZStack {
            AnimeArtwork(anime: model.request.anime).blur(radius: 28).opacity(0.45)
            LinearGradient(colors: [.black.opacity(0.2), .black.opacity(0.85)], startPoint: .top, endPoint: .bottom)
            VStack(spacing: 14) {
                ProgressView().controlSize(.large).tint(.white)
                Text(model.status).font(.footnote.weight(.semibold)).multilineTextAlignment(.center).foregroundColor(.white.opacity(0.85))
                HStack(spacing: 8) {
                    if let host = model.selectedHost { Text("\(host.name) · \(host.language)") }
                    TimelineView(.periodic(from: model.startedAt, by: 1)) { context in
                        Text("· \(max(0, Int(context.date.timeIntervalSince(model.startedAt)))) s").monospacedDigit()
                    }
                }.font(.caption).foregroundColor(Theme.muted)
            }.padding(24)
        }
    }
    /// Streaming-app style buttons above the AVKit controls.
    private var overlays: some View {
        VStack {
            Spacer()
            HStack(spacing: 10) {
                Spacer()
                if model.countdown == nil && model.playhead < 300 {
                    Button { model.skip(85) } label: { Label("Opening überspringen", systemImage: "forward.fill") }
                        .buttonStyle(OverlayButtonStyle())
                }
                if let next = model.nextEpisode, model.countdown == nil, model.savedLabel != nil, lateInEpisode {
                    Button { model.playNext() } label: { Label("Folge \(next.number)", systemImage: "forward.end.fill") }
                        .buttonStyle(OverlayButtonStyle(prominent: true))
                }
                if let seconds = model.countdown, let next = model.nextEpisode {
                    HStack(spacing: 10) {
                        Button { model.playNext() } label: {
                            HStack(spacing: 10) {
                                ZStack {
                                    Circle().stroke(.white.opacity(0.25), lineWidth: 3)
                                    Circle().trim(from: 0, to: CGFloat(10 - seconds) / 10).stroke(.white, style: StrokeStyle(lineWidth: 3, lineCap: .round)).rotationEffect(.degrees(-90))
                                        .animation(.linear(duration: 1), value: seconds)
                                    Image(systemName: "play.fill").font(.caption2)
                                }.frame(width: 26, height: 26)
                                Text("Folge \(next.number) in \(seconds) s").monospacedDigit()
                            }
                        }.buttonStyle(OverlayButtonStyle(prominent: true))
                        Button { model.cancelCountdown() } label: { Image(systemName: "xmark") }.buttonStyle(OverlayButtonStyle()).accessibilityLabel("Autoplay abbrechen")
                    }
                }
            }.padding(.trailing, 16).padding(.bottom, theater ? 76 : 58)
        }.animation(.easeInOut(duration: 0.25), value: model.countdown == nil)
    }
    private var lateInEpisode: Bool {
        guard let duration = model.player?.currentItem?.duration.seconds, duration.isFinite, duration > 0 else { return false }
        return model.playhead >= duration - 120
    }

    // MARK: Info panel
    private var infoPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(model.request.anime.title.uppercased()).font(.caption.bold()).tracking(1.5).foregroundColor(Theme.accentSoft).lineLimit(1)
                    Text("Folge \(model.request.episode.number) · \(model.request.episode.title)").font(.title3.bold()).lineLimit(3)
                    HStack(spacing: 8) {
                        if model.isOffline { Chip(text: "Offline", icon: "arrow.down.circle.fill") }
                        else if let host = model.selectedHost { Chip(text: "\(host.name) · \(host.language)", icon: model.nativeReady ? "play.tv.fill" : "globe") }
                        if let time = model.savedLabel { Chip(text: time, icon: "checkmark.circle.fill") }
                    }
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        if let next = model.nextEpisode {
                            ActionTile(title: "Folge \(next.number)", icon: "forward.end.fill", prominent: true) { model.playNext() }
                        }
                        if !model.isOffline { ActionTile(title: "Quelle", icon: "rectangle.stack.fill") { model.chooseHost() } }
                        downloadTile
                        if model.nativeReady { ActionTile(title: "10 s zurück", icon: "gobackward.10") { model.skip(-10) } }
                        if model.player != nil && !model.isOffline { ActionTile(title: "Webplayer", icon: "globe") { model.useWebPlayer() } }
                    }
                }
                if let notice = model.recoveryMessage { NoticeView(text: notice, icon: "arrow.triangle.2.circlepath", tint: Theme.accentSoft) }
                if let error = model.error {
                    VStack(alignment: .leading, spacing: 10) {
                        NoticeView(text: error, icon: "exclamationmark.triangle.fill", tint: .orange)
                        HStack {
                            Button("Erneut versuchen") { model.retry() }.buttonStyle(.borderedProminent)
                            if !model.isOffline { Button("Quelle wechseln") { model.chooseHost() }.buttonStyle(.bordered) }
                        }.font(.subheadline.bold())
                    }
                }
                if let next = model.nextEpisode {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Als Nächstes").font(.headline)
                        Button { model.playNext() } label: {
                            HStack(spacing: 14) {
                                AnimeArtwork(anime: model.request.anime).frame(width: 112, height: 63).clipShape(RoundedRectangle(cornerRadius: 10))
                                    .overlay(Image(systemName: "play.circle.fill").font(.title2).shadow(radius: 4))
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Folge \(next.number)").font(.caption.bold()).foregroundColor(Theme.accentSoft)
                                    Text(next.title).font(.subheadline.bold()).lineLimit(2).multilineTextAlignment(.leading)
                                }
                                Spacer(minLength: 0)
                            }.padding(10).loungeCard()
                        }.buttonStyle(LoungePressStyle()).foregroundColor(.white)
                        Toggle("Automatisch weiterschauen", isOn: Binding(get: { model.autoNext }, set: { model.setAutoNext($0) })).font(.subheadline).tint(Theme.accent)
                    }
                } else if let message = model.nextEpisodeError {
                    Button(message + " Erneut versuchen") { model.loadNextEpisode() }.font(.caption)
                }
                if !model.nativeReady && !model.isOffline && !model.preparing {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(model.status).font(.footnote).foregroundColor(Theme.muted)
                        HStack {
                            Label(model.blockerStatus, systemImage: model.adBlockEnabled ? "shield.lefthalf.filled" : "shield.slash").font(.caption)
                            Spacer()
                            Button(model.adBlockEnabled ? "Ohne Blocker laden" : "Blocker an") { model.setAdBlockEnabled(!model.adBlockEnabled) }.font(.caption.bold())
                        }.foregroundColor(Theme.accentSoft)
                    }.padding(14).loungeCard()
                }
            }.padding(20).foregroundColor(.white)
        }.background(Theme.background)
    }
    @ViewBuilder private var downloadTile: some View {
        if model.isOffline {
            EmptyView()
        } else if let existing = downloads.existing(model.request) {
            ActionTile(title: existing.state == .ready ? "Gespeichert" : "Lädt …", icon: existing.state == .ready ? "checkmark.circle.fill" : "arrow.down.circle.dotted") {}
                .disabled(true)
        } else if model.nativeReady {
            ActionTile(title: "Download", icon: "arrow.down.circle") { model.download() }
        } else {
            // Downloads need a direct video link, which only the iOS player exposes.
            ActionTile(title: "Download", icon: "arrow.down.circle") {}.disabled(true).opacity(0.4)
                .accessibilityHint("Nur verfügbar, wenn die Folge im iOS-Player läuft")
        }
    }

    // MARK: Source picker
    private var hostPicker: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(model.request.anime.title.uppercased()).font(.caption.bold()).tracking(1.5).foregroundColor(Theme.accentSoft)
                    Text("Folge \(model.request.episode.number) · \(model.request.episode.title)").font(.title2.bold())
                    Text("Deine Wahl gilt auch für die nächsten Folgen.").font(.subheadline).foregroundColor(Theme.muted)
                }
                if model.loadingHosts { ProgressView("Quellen werden gesucht …").frame(maxWidth: .infinity).padding(30) }
                ForEach(Array(Set(model.hosts.map(\.language))).sorted(), id: \.self) { language in
                    VStack(alignment: .leading, spacing: 10) {
                        Label(language, systemImage: "character.bubble.fill").font(.caption.bold()).foregroundColor(Theme.muted)
                        ForEach(model.hosts.filter { $0.language == language }) { host in
                            let current = model.selectedHost?.id == host.id
                            Button { model.select(host) } label: {
                                HStack(spacing: 14) {
                                    Text(String(host.name.prefix(1))).font(.headline.bold()).frame(width: 42, height: 42)
                                        .background(current ? AnyShapeStyle(Theme.accentGradient) : AnyShapeStyle(Theme.panelHigh)).clipShape(RoundedRectangle(cornerRadius: 12))
                                    Text(host.name).font(.headline)
                                    Spacer()
                                    Image(systemName: current ? "checkmark.circle.fill" : "play.fill").foregroundColor(current ? Theme.accent : Theme.muted)
                                }.padding(12).loungeCard()
                                    .overlay(RoundedRectangle(cornerRadius: 22).stroke(current ? Theme.accent.opacity(0.6) : .clear))
                            }.buttonStyle(LoungePressStyle()).foregroundColor(.white)
                        }
                    }
                }
                if let error = model.error {
                    NoticeView(text: error, icon: "exclamationmark.triangle.fill", tint: .orange)
                    Button("Erneut versuchen") { Task { await model.loadHosts() } }.buttonStyle(.borderedProminent)
                }
                VStack(alignment: .leading, spacing: 12) {
                    Text("Wiedergabe").font(.headline)
                    Toggle("Nächste Folge automatisch", isOn: Binding(get: { model.autoNext }, set: { model.setAutoNext($0) }))
                    Toggle("Werbeblocker", isOn: Binding(get: { model.adBlockEnabled }, set: { model.setAdBlockEnabled($0) }))
                    Text("Blockiert bekannte Werbeserver. Lädt eine Quelle nicht, probier sie ohne Blocker.").font(.caption).foregroundColor(Theme.muted)
                }.tint(Theme.accent).padding(16).loungeCard()
            }.padding(20).foregroundColor(.white)
        }.background(Theme.background)
    }
}
private struct OverlayButtonStyle: ButtonStyle {
    var prominent = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.subheadline.bold()).foregroundColor(prominent ? .black : .white)
            .padding(.horizontal, 16).padding(.vertical, 11)
            .background(prominent ? AnyShapeStyle(Color.white) : AnyShapeStyle(.ultraThinMaterial))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(prominent ? 0 : 0.25)))
            .scaleEffect(configuration.isPressed ? 0.96 : 1).opacity(configuration.isPressed ? 0.85 : 1)
    }
}
private struct ActionTile: View {
    let title: String
    let icon: String
    var prominent = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: icon).font(.system(size: 20, weight: .semibold))
                Text(title).font(.caption.bold()).lineLimit(1)
            }.frame(minWidth: 84).padding(.vertical, 14).padding(.horizontal, 10)
                .background(prominent ? AnyShapeStyle(Theme.accentGradient) : AnyShapeStyle(Theme.panel))
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(Theme.stroke))
        }.buttonStyle(LoungePressStyle()).foregroundColor(.white)
    }
}
struct Chip: View {
    let text: String
    let icon: String
    var body: some View {
        Label(text, systemImage: icon).font(.caption.weight(.semibold).monospacedDigit()).lineLimit(1)
            .padding(.horizontal, 10).padding(.vertical, 6).background(Theme.panelHigh).clipShape(Capsule()).foregroundColor(Theme.accentSoft)
    }
}
struct NoticeView: View {
    let text: String
    let icon: String
    let tint: Color
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).foregroundColor(tint)
            Text(text).font(.footnote).foregroundColor(.white.opacity(0.85)).fixedSize(horizontal: false, vertical: true)
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(tint.opacity(0.12)).clipShape(RoundedRectangle(cornerRadius: 12))
    }
}
/// SwiftUI dismantles this owner only when the playback screen is actually removed.
/// AVKit covering the screen must leave the player, its item and observers alive.
@MainActor private struct PlaybackLifetime: UIViewRepresentable {
    let model: PlayerModel
    final class Coordinator {
        let model: PlayerModel
        init(_ model: PlayerModel) { self.model = model }
    }
    func makeCoordinator() -> Coordinator { Coordinator(model) }
    func makeUIView(context: Context) -> UIView { model.detached = false; return UIView(frame: .zero) }
    func updateUIView(_ view: UIView, context: Context) {}
    static func dismantleUIView(_ view: UIView, coordinator: Coordinator) { coordinator.model.screenRemoved() }
}
private struct PlayerWebView: UIViewRepresentable {
    let webView: WKWebView
    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ view: WKWebView, context: Context) {}
}
private struct NativePlayerView: UIViewControllerRepresentable {
    let model: PlayerModel
    let player: AVPlayer
    func makeUIViewController(context: Context) -> AVPlayerViewController {
        // The model owns the controller so Picture in Picture survives closing this screen.
        let controller = model.playerController
        controller.removeFromParent()
        if controller.player !== player { controller.player = player }
        return controller
    }
    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        // Progress updates must not reattach the same player during an AVKit transition.
        if controller.player !== player { controller.player = player }
    }
}

