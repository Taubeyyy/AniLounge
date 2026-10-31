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
@MainActor final class PlayerModel: NSObject, ObservableObject, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate {
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

    private var nativeDisabled = false
    private var downloadCookies: [HTTPCookie] = []
    var isOffline: Bool { request.localURL != nil }
    func download() {
        guard nativeReady, let asset = player?.currentItem?.asset as? AVURLAsset, !isOffline else { return }
        DownloadStore.shared.enqueue(request: request, asset: asset, cookies: downloadCookies, source: selectedHost.map { "\($0.name) · \($0.language)" } ?? "Video")
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
        lastPosition = min(seconds, duration); lastDuration = duration; lastCompleted = completed
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
            let asset = AVURLAsset(url: url, options: [AVURLAssetHTTPCookiesKey: matching])
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
        player?.pause(); player?.replaceCurrentItem(with: nil); player = nil; nativeReady = false; restoring = false
        webView.setAllMediaPlaybackSuspended(false, completionHandler: nil)
    }
    func finish() {
        guard !closed else { return }
        checkpoint(); closed = true; startupWatchdog?.cancel(); nextTask?.cancel(); cancelCountdown(); loadTask?.cancel(); revealTask?.cancel(); stopNative()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        webView.stopLoading(); webView.loadHTMLString("", baseURL: nil)
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "aniProgress", contentWorld: world)
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
    init(request: PlaybackRequest, library: LibraryStore) {
        _model = StateObject(wrappedValue: PlayerModel(request: request, store: library))
    }
    init(model: PlayerModel) {
        _model = StateObject(wrappedValue: model)
    }
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if model.choosingHost {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                            Text("DEINE WIEDERGABE").font(.caption.bold()).tracking(3).foregroundColor(Theme.accent)
                            Text(model.request.anime.title).font(.largeTitle.bold())
                            Text("Quelle & Sprache").font(.title3.bold())
                            Toggle("Nächste Folge automatisch", isOn: Binding(get: { model.autoNext }, set: { model.setAutoNext($0) })).tint(Theme.accent)
                            Toggle("Werbeblocker", isOn: Binding(get: { model.adBlockEnabled }, set: { model.setAdBlockEnabled($0) })).tint(Theme.accent)
                            Text("Blockiert bekannte Werbeserver. Bei Problemen ausschalten und eine Quelle öffnen.").font(.caption).foregroundColor(.secondary)
                            Text("Deine Auswahl wird für die nächsten Folgen gemerkt.").font(.subheadline).foregroundColor(.secondary)
                            ForEach(Array(Set(model.hosts.map(\.language))).sorted(), id: \.self) { language in
                                VStack(alignment: .leading, spacing: 10) {
                                    Text(language).font(.caption.bold()).foregroundColor(.secondary)
                                    ForEach(model.hosts.filter { $0.language == language }) { host in
                                        Button { model.select(host) } label: {
                                            HStack(spacing: 16) {
                                                Image(systemName: "play.fill").frame(width: 46, height: 46).background(Theme.accent.opacity(0.18)).clipShape(Circle())
                                                Text(host.name).font(.headline)
                                                Spacer()
                                                Image(systemName: model.selectedHost?.id == host.id ? "checkmark.circle.fill" : "arrow.up.right")
                                            }.padding(16).loungeCard()
                                        }.buttonStyle(LoungePressStyle())
                                    }
                                }
                            }
                            if let error = model.error {
                                Text(error).foregroundColor(.orange)
                                Button("Erneut versuchen") { Task { await model.loadHosts() } }.buttonStyle(.borderedProminent)
                            }
                        }.padding(24)
                    }
                } else {
                    ZStack {
                        PlayerWebView(webView: model.webView).opacity(model.nativeReady || model.preparing ? 0 : 1)
                        if model.preparing {
                            VStack(spacing: 22) {
                                Image(systemName: "play.rectangle.fill").font(.system(size: 64)).foregroundStyle(Theme.accent.gradient)
                                Text(model.request.anime.title).font(.title2.bold()).multilineTextAlignment(.center)
                                ProgressView().tint(Theme.accent)
                                TimelineView(.periodic(from: model.startedAt, by: 1)) { context in
                                    Text("Lädt seit \(max(0, Int(context.date.timeIntervalSince(model.startedAt)))) s").font(.caption.monospacedDigit()).foregroundColor(.secondary)
                                }
                                Text(model.selectedHost.map { "\($0.name) · \($0.language)" } ?? "Standardquelle wird gesucht …").font(.subheadline).foregroundColor(.secondary)
                                if !model.isOffline { Button("Quelle ändern") { model.chooseHost() }.buttonStyle(.bordered) }
                            }.padding(30).frame(maxWidth: .infinity, maxHeight: .infinity).background(Theme.background)
                        }
                        if model.nativeReady, let player = model.player { NativePlayerView(player: player) }
                    }
                    VStack(spacing: 8) {
                        if model.nativeReady && !model.isOffline {
                            if let existing = downloads.existing(model.request) {
                                Label(existing.state == .ready ? "Offline gespeichert" : "Download läuft · siehe Downloads", systemImage: existing.state == .ready ? "checkmark.circle.fill" : "arrow.down.circle").font(.caption).foregroundColor(Theme.accent)
                            } else {
                                Button { model.download() } label: { Label("Herunterladen · WLAN", systemImage: "arrow.down.circle.fill") }.font(.caption.bold())
                            }
                        }
                        if model.isOffline { Label("Offline-Wiedergabe", systemImage: "checkmark.icloud").font(.caption).foregroundColor(Theme.accent) }
                        if let notice = model.recoveryMessage { Text(notice).font(.caption).foregroundColor(Theme.accent).multilineTextAlignment(.center) }
                        if model.error != nil {
                            HStack { Button("Erneut versuchen") { model.retry() }; if !model.isOffline { Button("Quelle wechseln") { model.chooseHost() } } }.font(.caption.bold())
                        }
                        if let next = model.nextEpisode {
                            HStack {
                                Button { model.playNext() } label: { Label("Nächste Folge · \(next.number)", systemImage: "forward.end.fill") }
                                Spacer()
                                if let seconds = model.countdown {
                                    Text("\(seconds) s").monospacedDigit()
                                    Button("Abbrechen") { model.cancelCountdown() }
                                }
                            }.font(.caption.bold()).foregroundColor(Theme.accent)
                        }
                        if let message = model.nextEpisodeError {
                            Button(message + " Erneut versuchen") { model.loadNextEpisode() }.font(.caption2)
                        }
                        if let time = model.savedLabel { Label(time, systemImage: "checkmark.circle.fill").foregroundColor(Theme.accent).font(.caption.monospacedDigit()) }
                        Text(model.error ?? model.status).font(.caption).foregroundColor(.secondary).multilineTextAlignment(.center)
                        if !model.nativeReady && !model.isOffline {
                            HStack {
                                Image(systemName: model.adBlockEnabled ? "shield.lefthalf.filled" : "shield.slash")
                                Text(model.blockerStatus).font(.caption2)
                                Spacer()
                                Button(model.adBlockEnabled ? "Ohne Blocker neu laden" : "Blocker aktivieren") { model.setAdBlockEnabled(!model.adBlockEnabled) }.font(.caption2)
                            }.foregroundColor(Theme.accent)
                        }
                        if model.player != nil && !model.isOffline { Button("Webplayer verwenden") { model.useWebPlayer() }.font(.caption) }
                    }.padding(12).frame(maxWidth: .infinity).background(Theme.panel)
                }
            }.background(Theme.background)
                .navigationTitle("Folge \(model.request.episode.number)").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        if !model.choosingHost && !model.isOffline { Button("Quelle") { model.chooseHost() } }
                    }
                    ToolbarItem(placement: .navigationBarTrailing) { Button("Fertig") { model.finish(); dismiss() } }
                }
                .alert("Download", isPresented: Binding(get: { downloads.storageError != nil }, set: { if !$0 { downloads.storageError = nil } })) { Button("OK", role: .cancel) {} } message: { Text(downloads.storageError ?? "") }
                .task { await model.loadHosts() }
                .onChange(of: phase) { if $0 != .active { model.checkpoint(); model.cancelCountdown() } }
                // Covering this view (AVKit fullscreen) is not closing the playback session.
                .onDisappear { model.checkpoint() }
                .background(PlaybackLifetime(model: model).frame(width: 0, height: 0))
        }.tint(Theme.accent)
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
    func makeUIView(context: Context) -> UIView { UIView(frame: .zero) }
    func updateUIView(_ view: UIView, context: Context) {}
    static func dismantleUIView(_ view: UIView, coordinator: Coordinator) { coordinator.model.finish() }
}
private struct PlayerWebView: UIViewRepresentable {
    let webView: WKWebView
    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ view: WKWebView, context: Context) {}
}
private struct NativePlayerView: UIViewControllerRepresentable {
    let player: AVPlayer
    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.allowsPictureInPicturePlayback = true
        return controller
    }
    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        // Progress updates must not reattach the same player during an AVKit transition.
        if controller.player !== player { controller.player = player }
    }
}

