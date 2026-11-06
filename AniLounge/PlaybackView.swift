import SwiftUI
import WebKit
import AVKit
import MediaPlayer
import AniCore

struct PlaybackRequest: Identifiable {
    let id = UUID()
    let anime: Anime
    let episode: Episode
    let profileID: UUID
    var localURL: URL? = nil
    var localLanguage: String? = nil
}
@MainActor private final class WeakProgressHandler: NSObject, WKScriptMessageHandler {
    weak var target: PlayerModel?
    init(_ target: PlayerModel) { self.target = target }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(userContentController, didReceive: message)
    }
}
/// Fine-grained play position for overlays, kept apart so only they re-render every half second.
@MainActor final class PlayheadClock: ObservableObject {
    @Published var seconds: Double = 0
    @Published var duration: Double = 0
    @Published var buffered: Double = 0
}
/// Video surface owned by the model, so Picture in Picture survives closing the screen.
final class PlayerSurfaceView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        playerLayer.videoGravity = .resizeAspect
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
}
/// The one place the player is presented from, at the root of the app. Presenting from inside
/// scrolling lists broke when they rebuilt (rotation, lazy loading) and left a stray video behind.
/// Also keeps a Picture in Picture session alive after its screen closed and brings it back.
@MainActor final class PlaybackCenter: ObservableObject {
    static let shared = PlaybackCenter(downloads: .shared)
    struct OfflinePrompt: Identifiable {
        let id = UUID()
        let original: PlaybackRequest
        let option: OfflinePlaybackOption
        let library: LibraryStore
    }
    @Published var presented: PlayerModel?
    @Published var pendingOffline: OfflinePrompt?
    private(set) var current: PlayerModel?
    private let downloads: DownloadStore
    init(downloads: DownloadStore) { self.downloads = downloads }
    func open(_ request: PlaybackRequest, library: LibraryStore) {
        guard presented == nil, pendingOffline == nil else { return }
        if request.localURL == nil,
           let option = downloads.offlineOption(for: request, preferredLanguage: AppSettings.shared.language(for: request.profileID)) {
            if option.requiresConfirmation {
                pendingOffline = OfflinePrompt(original: request, option: option, library: library)
            } else { present(option.request, library: library) }
        } else { present(request, library: library) }
    }
    func confirmOffline(_ prompt: OfflinePrompt) {
        pendingOffline = nil
        present(prompt.option.request, library: prompt.library)
    }
    func chooseOnline(_ prompt: OfflinePrompt) {
        pendingOffline = nil
        present(prompt.original, library: prompt.library)
    }
    private func present(_ request: PlaybackRequest, library: LibraryStore) {
        guard presented == nil else { return }
        library.beginPlayback(request.episode, anime: request.anime, profileID: request.profileID)
        presented = PlayerModel(request: request, store: library)
    }
    func activate(_ model: PlayerModel) {
        if let current, current !== model { current.finish() }
        current = model
    }
    func ended(_ model: PlayerModel) {
        if current === model { current = nil }
        if presented === model { presented = nil }
    }
}
@MainActor final class PlayerModel: NSObject, ObservableObject, Identifiable, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate, AVPictureInPictureControllerDelegate {
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
    @Published private(set) var caughtUp = false
    @Published var countdown: Int?
    /// Position the episode resumed at; shown briefly with a "Von vorne" button.
    @Published var resumedFrom: Double?
    private var prefetchedNext = false
    /// Sleep timer: stop at the end of this episode or after a number of minutes.
    enum SleepTimer: Hashable { case off, episodeEnd, minutes(Int) }
    @Published private(set) var sleepTimer: SleepTimer = .off
    private var sleepDeadline: Date?
    func setSleepTimer(_ value: SleepTimer) {
        sleepTimer = value
        if case .minutes(let minutes) = value { sleepDeadline = Date().addingTimeInterval(TimeInterval(minutes * 60)) } else { sleepDeadline = nil }
        switch value {
        case .off: showToast("Schlaf-Timer aus")
        case .episodeEnd: showToast("Stoppt am Ende der Folge")
        case .minutes(let minutes): showToast("Stoppt in \(minutes) Minuten")
        }
    }
    private func sleepNow() {
        sleepTimer = .off; sleepDeadline = nil
        cancelCountdown(); player?.pause(); checkpoint()
        showToast("Schlaf-Timer: Wiedergabe angehalten")
    }
    @Published var autoNext = AppSettings.shared.autoNext
    @Published var recoveryMessage: String?
    @Published private(set) var inPictureInPicture = false
    @Published private(set) var playhead: Double = 0
    let clock = PlayheadClock()
    private var clockObserver: Any?
    /// Episodes of the playing season, with stills and AniSkip times when available.
    @Published private(set) var seasonEpisodes: [Episode] = []
    @Published private(set) var episodeExtras: [String: EpisodeExtras] = [:]
    @Published private(set) var skipTimes: SkipTimes?
    /// The screen was closed while Picture in Picture kept playing.
    var detached = false
    private var restoringInterface = false
    let surface = PlayerSurfaceView()
    private var pipController: AVPictureInPictureController?
    private var pipObservation: NSKeyValueObservation?
    private var controlObservation: NSKeyValueObservation?
    private var remoteTargets: [Any] = []
    private var autoSkippedOpening = false
    @Published private(set) var pipPossible = false
    @Published private(set) var isPlaying = false
    @Published private(set) var isBuffering = false
    @Published private(set) var speed = AppSettings.shared.speed
    @Published var fillScreen = false
    /// Short confirmation shown on the video, e.g. after an automatic skip.
    @Published var toast: String?

    private var nativeDisabled = false
    private var downloadCookies: [HTTPCookie] = []
    private var downloadHeaders: [String: String] = [:]
    private func mediaHeaders() -> [String: String] {
        guard let page = mediaFrame?.request.url ?? webView.url, page.scheme == "https", let host = page.host else { return [:] }
        var headers = ["Referer": page.absoluteString, "Origin": "https://" + host]
        if let webUserAgent { headers["User-Agent"] = webUserAgent }
        return headers
    }
    var isOffline: Bool { request.localURL != nil }
    func download() {
        guard nativeReady, let asset = player?.currentItem?.asset as? AVURLAsset, !isOffline else { return }
        DownloadStore.shared.enqueue(request: request, asset: asset, cookies: downloadCookies, headers: downloadHeaders, source: selectedHost.map { "\($0.name) · \($0.language)" } ?? "Video", language: selectedHost?.language)
        if DownloadStore.shared.existing(request) != nil { showToast("Download gestartet") }
    }
    private var itemObservation: NSKeyValueObservation?
    private var endObservation: NSObjectProtocol?
    private var timeObserver: Any?
    private var timeout: Task<Void, Never>?
    private var restoring = false
    private var loadTask: Task<Void, Never>?
    @Published var startedAt = Date()
    @Published var adBlockEnabled = AppSettings.shared.adBlock
    @Published var blockerStatus = "Werbeblocker wird vorbereitet"
    private var revealTask: Task<Void, Never>?
    private var webRevealTask: Task<Void, Never>?
    /// The hoster page stays hidden behind the loading screen until our player has the video.
    @Published var preparing = true
    /// Shown on the loading screen when a start takes unusually long.
    @Published private(set) var offerWebPlayer = false
    /// The video already plays inside the hoster page (seen through the tracker).
    private var webPlaybackSeen = false
    private var webUserAgent: String?
    private var preferenceKey: String { "playback.preference." + request.profileID.uuidString }

    @Published var hosts: [StreamHost] = []
    @Published var choosingHost = false
    @Published private(set) var languageNotice: String?
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
        // Never flash white behind hoster pages or during layout changes.
        webView.isOpaque = false; webView.backgroundColor = .black; webView.scrollView.backgroundColor = .black
        super.init()
        // Media requests from AVPlayer use the same browser identity as the hoster page.
        webView.evaluateJavaScript("navigator.userAgent") { [weak self] value, _ in
            Task { @MainActor [weak self] in self?.webUserAgent = value as? String }
        }
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
            switch AppSettings.shared.selection(in: hosts, remembered: preference) {
            case .selected(let host):
                select(host, remember: false)
            case .requiresLanguageChoice(let preferred):
                languageNotice = "Die bevorzugte Fassung \(preferred) ist für diese Folge nicht verfügbar. Wähle eine andere Fassung, um fortzufahren."
                cancelCountdown(); choosingHost = true; preparing = false
            case .unavailable:
                error = "Für diese Folge ist keine Quelle verfügbar."
                choosingHost = true; preparing = false
            }
        }
        catch { if !Task.isCancelled { self.error = error.localizedDescription; choosingHost = true; preparing = false } }
    }
    private func installTracker() {
        token = UUID().uuidString
        let old = store.progress(for: request.episode, profileID: request.profileID)
        let config: [String: Any] = ["autoPlay": true, "token": token, "seconds": old?.isFinished == true ? 0 : (old?.seconds ?? 0), "duration": old?.duration ?? 0]
        let controller = webView.configuration.userContentController
        controller.removeAllUserScripts()
        if let scriptURL = Bundle.main.url(forResource: "PlaybackTracker", withExtension: "js"),
           let template = try? String(contentsOf: scriptURL),
           let data = try? JSONSerialization.data(withJSONObject: config), let json = String(data: data, encoding: .utf8) {
            let script = template.replacingOccurrences(of: "__ANILOUNGE_CONFIG__", with: json)
            controller.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentEnd, forMainFrameOnly: false, in: world))
        } else { error = "Automatische Videoerkennung fehlt. Fortschritt kann in der Folgenliste eingetragen werden." }
        // Starting JW Player (VOE) and video.js needs their page-side API.
        if let kickURL = Bundle.main.url(forResource: "PlayerKick", withExtension: "js"), let kick = try? String(contentsOf: kickURL) {
            controller.addUserScript(WKUserScript(source: kick, injectionTime: .atDocumentEnd, forMainFrameOnly: false, in: .page))
        }
    }
    func select(_ host: StreamHost?, remember: Bool = true, automatic: Bool = false) {
        guard let url = host?.url ?? AniURL.page(request.episode.path) else { return }
        checkpoint(); stopNative(); startupWatchdog?.cancel(); cancelCountdown()
        if !automatic { triedHosts.removeAll(); recoveryMessage = nil }
        if let host { triedHosts.insert(host.id) }
        handledEnd = false
        languageNotice = nil
        selectedHost = host; choosingHost = false; error = nil; preparing = true; startedAt = Date()
        DebugLog.shared.add("player", "select \(host?.name ?? "AniWorld") \(host?.language ?? "") ep \(request.episode.number) of \(request.anime.title)")
        if remember, let host { UserDefaults.standard.set(["name": host.name, "language": host.language], forKey: preferenceKey) }
        revealTask?.cancel(); webRevealTask?.cancel(); offerWebPlayer = false; webPlaybackSeen = false
        revealTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 12_000_000_000)
            guard !Task.isCancelled, let self, !self.closed, !self.nativeReady, self.preparing else { return }
            self.offerWebPlayer = true
            self.status = "Das dauert länger als sonst."
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
        DebugLog.shared.add("player", "recover: " + reason)
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
        nextTask?.cancel(); nextEpisode = nil; nextEpisodeError = nil; caughtUp = false
        let episode = request.episode
        let anime = request.anime
        let watched = store.snapshot.profiles.first { $0.profile.id == request.profileID }?.watched ?? []
        nextTask = Task { @MainActor [weak self] in
            do {
                let seasonPath = SeriesCatalog.seasonPath(for: episode)
                let season = try await AniClient.shared.detail(path: seasonPath)
                SeriesCatalogStore.shared.remember(season, path: seasonPath, isRoot: false)
                let decision = try await SeriesCatalogStore.shared.resolveNext(after: episode, anime: anime, watched: watched)
                let next = decision.episode
                guard !Task.isCancelled, let self, !self.closed, self.request.episode.id == episode.id else { return }
                self.nextEpisode = next
                self.caughtUp = decision == .caughtUp
                if decision == .unavailable { self.nextEpisodeError = "Die nächste Folge konnte nicht zugeordnet werden." }
                self.seasonEpisodes = season.episodes
                if self.handledEnd { self.scheduleNext() }
                // Stills, titles and opening times are extras: failures only hide them.
                guard let imdb = season.imdb, let number = SeasonNumber.from(seasonPath),
                      let extras = try? await MetadataClient.shared.episodes(imdb: imdb, season: number),
                      !Task.isCancelled, self.request.episode.id == episode.id else { return }
                self.episodeExtras = extras
                if let info = extras[episode.number] {
                    let times = await MetadataClient.shared.skipTimes(for: info)
                    guard !Task.isCancelled, self.request.episode.id == episode.id else { return }
                    self.skipTimes = times
                }
            } catch {
                guard !Task.isCancelled, let self, !self.closed else { return }
                self.nextEpisodeError = "Nächste Folge konnte nicht geladen werden."
            }
        }
    }
    func playNext() {
        guard let episode = nextEpisode else { return }
        play(episode)
    }
    func play(_ episode: Episode) {
        guard !closed, episode.id != request.episode.id else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        skipTimes = nil; autoSkippedOpening = false; prefetchedNext = false; resumedFrom = nil
        revealTask?.cancel(); webRevealTask?.cancel(); offerWebPlayer = false; webPlaybackSeen = false
        store.opened(episode, anime: request.anime, profileID: request.profileID)
        checkpoint(); stopNative(); loadTask?.cancel(); startupWatchdog?.cancel(); nextTask?.cancel(); cancelCountdown()
        token = UUID().uuidString
        webView.stopLoading(); webView.loadHTMLString("", baseURL: nil)
        request = PlaybackRequest(anime: request.anime, episode: episode, profileID: request.profileID)
        nextEpisode = nil; nextEpisodeError = nil; caughtUp = false; hosts = []; selectedHost = nil
        lastPosition = nil; lastDuration = nil; lastCompleted = false; savedLabel = nil
        handledEnd = false; choosingHost = false; preparing = true; error = nil
        Task { await loadHosts() }
    }
    func setAutoNext(_ value: Bool) {
        autoNext = value; AppSettings.shared.autoNext = value
        if !value { cancelCountdown() }
    }
    func cancelCountdown() { countdownTask?.cancel(); countdownTask = nil; countdown = nil }
    private func episodeEnded() {
        guard !handledEnd else { return }
        handledEnd = true
        if sleepTimer == .episodeEnd { sleepNow(); return }
        scheduleNext()
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
        AppSettings.shared.adBlock = enabled
        if !choosingHost, let host = selectedHost { select(host, remember: false) }
    }
    func chooseHost() {
        checkpoint(); stopNative(); loadTask?.cancel(); startupWatchdog?.cancel(); cancelCountdown(); token = UUID().uuidString
        webView.stopLoading(); webView.loadHTMLString("", baseURL: nil)
        choosingHost = true; error = nil; preparing = false; revealTask?.cancel(); webRevealTask?.cancel(); offerWebPlayer = false
    }
    /// Lifts the loading screen and shows the hoster page, e.g. when it needs a tap.
    func showWebPlayer() {
        DebugLog.shared.add("player", "web player shown")
        preparing = false; offerWebPlayer = false
        revealTask?.cancel(); webRevealTask?.cancel(); startupWatchdog?.cancel()
        status = "Webplayer · falls nötig im Video auf Play tippen."
    }
    /// The native player could not take the link. If the page already plays it, stay there.
    private func nativeFailed(_ reason: String) {
        DebugLog.shared.add("player", "native failed: \(reason) item error: \(player?.currentItem?.error?.localizedDescription ?? "-")")
        if webPlaybackSeen && !isOffline {
            useWebPlayer(reason + " Die Folge läuft im Webplayer weiter.")
        } else { recover(reason) }
    }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard !closed, !choosingHost, let body = message.body as? [String: Any], body["token"] as? String == token else { return }
        if body["kind"] as? String == "debug" {
            if let text = body["text"] as? String { DebugLog.shared.add("web", String(text.prefix(200))) }
            // The hoster asks for a human check; only the viewer may answer it, so show the page.
            if message.frameInfo.securityOrigin.host == "challenges.cloudflare.com", preparing, !nativeReady {
                showWebPlayer(); status = "Der Anbieter möchte eine kurze Bestätigung. Danach startet das Video."
            }
            return
        }
        if body["kind"] as? String == "source" {
            DebugLog.shared.add("player", "source from page: " + ((body["url"] as? String).flatMap { URL(string: $0)?.host } ?? "?"))
            if let value = body["url"] as? String, let url = PlaybackSource.directURL(value) { mediaFrame = message.frameInfo; startNative(url) }
            return
        }
        guard !nativeReady, let seconds = body["seconds"] as? Double, let duration = body["duration"] as? Double,
              seconds.isFinite, duration.isFinite, seconds >= 0, seconds <= duration + 1,
              duration >= 90, duration <= 86400 else { return }
        let origin = message.frameInfo.securityOrigin.host
        if let mediaOrigin, mediaOrigin != origin, let lastDuration, duration < lastDuration * 0.8 { return }
        mediaOrigin = origin; mediaFrame = message.frameInfo
        if !webPlaybackSeen {
            webPlaybackSeen = true
            // The page plays the episode; give our player a moment to take over, else show the page.
            webRevealTask?.cancel()
            webRevealTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                guard !Task.isCancelled, let self, !self.closed, !self.nativeReady, self.preparing else { return }
                self.showWebPlayer()
            }
        }
        record(seconds: seconds, duration: duration, completed: body["ended"] as? Bool == true)
        if body["ended"] as? Bool == true { episodeEnded() }
    }
    private func record(seconds: Double, duration: Double, completed: Bool) {
        startupWatchdog?.cancel()
        // A checkpoint after the end notification must not undo completion. Seeking back does.
        let finished = completed || (lastCompleted && seconds >= duration - 0.5)
        if handledEnd && !finished { handledEnd = false; cancelCountdown() }
        lastPosition = min(seconds, duration); lastDuration = duration; lastCompleted = finished; playhead = min(seconds, duration)
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
            // About 720p when saving data; 0 lets HLS pick freely.
            item.preferredPeakBitRate = AppSettings.shared.dataSaver ? 2_500_000 : 0
            let player = AVPlayer(playerItem: item)
            player.defaultRate = Float(self.speed)
            self.player = player
            self.surface.playerLayer.player = player
            self.controlObservation = player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] player, _ in
                Task { @MainActor [weak self] in
                    guard let self, self.generation == attempt else { return }
                    self.isPlaying = player.timeControlStatus != .paused
                    self.isBuffering = player.timeControlStatus == .waitingToPlayAtSpecifiedRate
                    self.updateNowPlaying()
                }
            }
            self.itemObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
                Task { @MainActor [weak self] in
                    guard let self, self.generation == attempt, self.player?.currentItem === item else { return }
                    if item.status == .readyToPlay { self.activateNative(item) }
                    else if item.status == .failed { self.nativeFailed("Der Videolink konnte nicht abgespielt werden.") }
                }
            }
            self.timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 5, preferredTimescale: 600), queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, self.generation == attempt else { return }
                    self.captureNative()
                }
            }
            self.clockObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self] time in
                Task { @MainActor [weak self] in
                    guard let self, self.generation == attempt, time.seconds.isFinite else { return }
                    self.clock.seconds = time.seconds
                    if let item = self.player?.currentItem {
                        let duration = item.duration.seconds
                        if duration.isFinite, duration > 0, self.clock.duration != duration { self.clock.duration = duration }
                        if let range = item.loadedTimeRanges.last?.timeRangeValue { self.clock.buffered = range.end.seconds }
                    }
                    self.autoSkipIfNeeded(time.seconds)
                    self.prefetchNextIfNeeded(time.seconds)
                    if let deadline = self.sleepDeadline, Date() >= deadline { self.sleepNow() }
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
                self.nativeFailed("Der native Player konnte die Quelle nicht rechtzeitig laden.")
            }
        }
    }
    private func activateNative(_ item: AVPlayerItem) {
        guard !nativeReady, !closed else { return }
        startupWatchdog?.cancel()
        DebugLog.shared.add("player", "native ready after \(Int(Date().timeIntervalSince(startedAt))) s")
        nativeReady = true; preparing = false; offerWebPlayer = false; revealTask?.cancel(); webRevealTask?.cancel(); restoring = true; timeout?.cancel(); error = nil
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)
        status = "Fortschritt wird automatisch gespeichert."
        setUpPictureInPicture()
        setUpRemoteCommands()
        webView.setAllMediaPlaybackSuspended(true, completionHandler: nil)
        let old = store.progress(for: request.episode, profileID: request.profileID)
        let position = PlaybackSource.resumePosition(saved: old?.isFinished == true ? 0 : (old?.seconds ?? 0),
                                                     savedDuration: old?.duration, duration: item.duration.seconds.isFinite ? item.duration.seconds : (lastDuration ?? old?.duration ?? 0))
        let attempt = generation
        // Avoid a redundant seek at startup; resume may land within one second of the saved position.
        playhead = position
        if position > 5 {
            resumedFrom = position
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 7_000_000_000)
                if self?.resumedFrom == position { self?.resumedFrom = nil }
            }
        }
        if position == 0 { restoring = false; player?.playImmediately(atRate: Float(speed)); return }
        let tolerance = CMTime(seconds: 1, preferredTimescale: 600)
        player?.seek(to: CMTime(seconds: position, preferredTimescale: 600), toleranceBefore: tolerance, toleranceAfter: tolerance) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.generation == attempt, !self.closed else { return }
                self.restoring = false; self.player?.playImmediately(atRate: Float(self.speed))
            }
        }
    }
    private func captureNative(ended: Bool = false) {
        guard nativeReady, !restoring, let player else { return }
        let seconds = player.currentTime().seconds
        let duration = player.currentItem?.duration.seconds ?? 0
        guard seconds.isFinite, seconds >= 0, duration.isFinite, duration > 0, duration <= 86400 else { return }
        record(seconds: seconds, duration: duration, completed: ended)
    }
    func checkpoint() { captureNative(); persist() }
    func togglePlay() {
        guard let player else { return }
        if player.timeControlStatus == .paused {
            if let duration = player.currentItem?.duration.seconds, duration.isFinite, player.currentTime().seconds >= duration - 0.5 { seek(to: 0) }
            player.playImmediately(atRate: Float(speed))
        } else { player.pause(); checkpoint() }
        updateNowPlaying()
    }
    func setSpeed(_ value: Double) {
        speed = value; AppSettings.shared.speed = value
        player?.defaultRate = Float(value)
        if player?.timeControlStatus != .paused { player?.rate = Float(value) }
        updateNowPlaying()
    }
    private func autoSkipIfNeeded(_ now: Double) {
        guard AppSettings.shared.autoSkipOpening, !autoSkippedOpening, !restoring, let times = skipTimes,
              let opening = times.opening, times.fits(duration: player?.currentItem?.duration.seconds),
              now >= opening.lowerBound, now < opening.upperBound - 3 else { return }
        autoSkippedOpening = true
        seek(to: opening.upperBound)
        showToast("Opening übersprungen")
    }
    /// Near the end, warm the caches for the next episode: its hoster list, still and skip times.
    /// Autoplay then skips those requests. (The hoster page itself still loads on start.)
    private func prefetchNextIfNeeded(_ now: Double) {
        guard !prefetchedNext, let next = nextEpisode, let duration = player?.currentItem?.duration.seconds,
              duration.isFinite, duration > 120, now > max(duration * 0.85, duration - 240) else { return }
        prefetchedNext = true
        let extras = episodeExtras[next.number]
        DebugLog.shared.add("player", "prefetch next episode \(next.number)")
        Task {
            _ = try? await AniClient.shared.hosts(path: next.path)
            if let still = extras?.image { _ = await CoverLoader.image(for: still) }
            if let extras { _ = await MetadataClient.shared.skipTimes(for: extras) }
        }
    }
    func showToast(_ text: String) {
        toast = text
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if self?.toast == text { self?.toast = nil }
        }
    }
    // MARK: Lock screen and Control Center
    private func setUpRemoteCommands() {
        guard remoteTargets.isEmpty else { updateNowPlaying(); return }
        let center = MPRemoteCommandCenter.shared()
        center.skipForwardCommand.preferredIntervals = [10]
        center.skipBackwardCommand.preferredIntervals = [10]
        remoteTargets = [
            center.playCommand.addTarget { [weak self] _ in self?.remote { $0.player?.playImmediately(atRate: Float($0.speed)) }; return .success },
            center.pauseCommand.addTarget { [weak self] _ in self?.remote { $0.player?.pause() }; return .success },
            center.togglePlayPauseCommand.addTarget { [weak self] _ in self?.remote { $0.togglePlay() }; return .success },
            center.skipForwardCommand.addTarget { [weak self] _ in self?.remote { $0.skip(10) }; return .success },
            center.skipBackwardCommand.addTarget { [weak self] _ in self?.remote { $0.skip(-10) }; return .success },
            center.changePlaybackPositionCommand.addTarget { [weak self] event in
                guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
                self?.remote { $0.seek(to: event.positionTime) }; return .success
            }
        ]
        updateNowPlaying()
    }
    private nonisolated func remote(_ action: @escaping @MainActor (PlayerModel) -> Void) {
        Task { @MainActor [weak self] in if let self { action(self) } }
    }
    private func updateNowPlaying() {
        guard nativeReady, let player, let item = player.currentItem else { return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: "Folge \(request.episode.number) · \(request.episode.title)",
            MPMediaItemPropertyArtist: request.anime.title,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: player.currentTime().seconds,
            MPNowPlayingInfoPropertyPlaybackRate: player.timeControlStatus == .paused ? 0 : speed
        ]
        if item.duration.seconds.isFinite { info[MPMediaItemPropertyPlaybackDuration] = item.duration.seconds }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
    private func tearDownRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        for target in remoteTargets {
            [center.playCommand, center.pauseCommand, center.togglePlayPauseCommand, center.skipForwardCommand,
             center.skipBackwardCommand, center.changePlaybackPositionCommand].forEach { $0.removeTarget(target) }
        }
        remoteTargets = []
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }
    func isSeen(_ episode: Episode) -> Bool { store.progress(for: episode, profileID: request.profileID)?.isFinished == true }
    func progress(of episode: Episode) -> EpisodeProgress? { store.progress(for: episode, profileID: request.profileID) }
    func skip(_ seconds: Double) {
        guard nativeReady, let player else { return }
        seek(to: player.currentTime().seconds + seconds)
    }
    func seek(to position: Double) {
        guard nativeReady, let player else { return }
        let target = max(0, position)
        guard target.isFinite else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        playhead = target
        clock.seconds = target
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600)) { [weak self] _ in
            Task { @MainActor [weak self] in self?.checkpoint(); self?.updateNowPlaying() }
        }
    }
    // MARK: Picture in Picture
    private func setUpPictureInPicture() {
        guard pipController == nil, AVPictureInPictureController.isPictureInPictureSupported() else { return }
        let controller = AVPictureInPictureController(playerLayer: surface.playerLayer)
        controller?.delegate = self
        controller?.canStartPictureInPictureAutomaticallyFromInline = true
        pipController = controller
        pipObservation = controller?.observe(\.isPictureInPicturePossible, options: [.initial, .new]) { [weak self] controller, _ in
            Task { @MainActor [weak self] in self?.pipPossible = controller.isPictureInPicturePossible }
        }
    }
    func togglePictureInPicture() {
        guard let pipController else { return }
        if pipController.isPictureInPictureActive { pipController.stopPictureInPicture() } else { pipController.startPictureInPicture() }
    }
    func pictureInPictureControllerWillStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) { inPictureInPicture = true }
    func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        inPictureInPicture = false
        if detached && !restoringInterface { finish() }
    }
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        guard detached, !closed else { completionHandler(true); return }
        restoringInterface = true
        PlaybackCenter.shared.presented = self
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
        checkpoint(); stopNative(); startupWatchdog?.cancel(); nativeDisabled = true; preparing = false; offerWebPlayer = false; revealTask?.cancel(); webRevealTask?.cancel()
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
        if let clockObserver, let player { player.removeTimeObserver(clockObserver) }; clockObserver = nil
        clock.seconds = 0; clock.duration = 0; clock.buffered = 0
        controlObservation?.invalidate(); controlObservation = nil; isPlaying = false; isBuffering = false
        surface.playerLayer.player = nil
        if let endObservation { NotificationCenter.default.removeObserver(endObservation) }; endObservation = nil
        player?.pause(); player?.replaceCurrentItem(with: nil); player = nil; nativeReady = false; restoring = false; playhead = 0
        webView.setAllMediaPlaybackSuspended(false, completionHandler: nil)
    }
    func finish() {
        guard !closed else { return }
        checkpoint(); closed = true; startupWatchdog?.cancel(); nextTask?.cancel(); cancelCountdown(); loadTask?.cancel(); revealTask?.cancel(); webRevealTask?.cancel(); stopNative()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        webView.stopLoading(); webView.loadHTMLString("", baseURL: nil)
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "aniProgress", contentWorld: world)
        pipObservation?.invalidate(); pipObservation = nil; pipController = nil; tearDownRemoteCommands()
        detached = false
        PlaybackCenter.shared.ended(self)
    }
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        DebugLog.shared.add("web", "page " + (webView.url?.host ?? "?"))
        guard !choosingHost, !nativeReady, webView.url?.scheme == "https" else { return }
        status = "Anbieter verbunden · Videolink wird gesucht …"
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard !choosingHost, !nativeReady, webView.url?.scheme == "https" else { return }
        // Keep the loading screen; the page is only shown once it is clearly needed.
        if player == nil { status = "Anbieter geladen · Video wird gestartet …" }
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        DebugLog.shared.add("web", "load failed \((error as NSError).code)")
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
    @State private var showingMore = false
    @State private var expandedPlayer = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    init(request: PlaybackRequest, library: LibraryStore) {
        _model = StateObject(wrappedValue: PlayerModel(request: request, store: library))
    }
    init(model: PlayerModel) {
        _model = StateObject(wrappedValue: model)
    }
    /// iPhone landscape: the video fills the screen like a streaming app.
    private var theater: Bool { (expandedPlayer || verticalSize == .compact) && !model.choosingHost }
    private func toggleFullscreen() {
        if UIDevice.current.userInterfaceIdiom == .pad { expandedPlayer.toggle() }
        else { OrientationLock.rotate(toLandscape: !theater) }
    }
    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
            // One stable hierarchy for every orientation: the video surface and the web view are
            // never rebuilt when rotating, which used to leave a white, detached player behind.
            ZStack {
                // Landscape: the stage fills the whole screen, edges included. Portrait: a 16:9 band
                // across the full width. Only frame values change, never the view structure.
                VStack(spacing: 0) {
                    if !theater { topBar.transition(.opacity) }
                    stage
                        .frame(maxWidth: .infinity, maxHeight: theater ? .infinity : nil)
                        .frame(height: theater ? nil : min(max(240, geometry.size.width * 9 / 16), max(240, geometry.size.height * 0.62)))
                        .ignoresSafeArea(edges: theater ? .all : [])
                    if !theater { infoPanel.transition(.opacity) }
                }
                // Rotation: fade the panels and glide the video instead of jumping.
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: theater)
                if model.choosingHost {
                    VStack(spacing: 0) { topBar; hostPicker }.background(Theme.background.ignoresSafeArea())
                }
                if showingMore { settingsPanel.zIndex(2) }
            }
            .animation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.88), value: showingMore)
            .background((theater ? Color.black : Theme.background).ignoresSafeArea())
                .toolbar(.hidden, for: .navigationBar)
                .statusBarHidden(theater)
                // Nothing of iOS should sit on top of the video while watching.
                .persistentSystemOverlays(.hidden)
                .alert("Download", isPresented: Binding(get: { downloads.storageError != nil }, set: { if !$0 { downloads.storageError = nil } })) { Button("OK", role: .cancel) {} } message: { Text(downloads.storageError ?? "") }
                .task { PlaybackCenter.shared.activate(model); await model.loadHosts() }
                .onChange(of: phase) { if $0 != .active { model.checkpoint(); model.cancelCountdown() } }
                // Picture in Picture continues in a small window while the viewer keeps browsing.
                .onChange(of: model.inPictureInPicture) { if $0 { dismiss() } }
                .onDisappear { model.checkpoint() }
                .background(PlaybackLifetime(model: model).frame(width: 0, height: 0))
            }
        }
        // On the cover's root so UIKit reads it: the home indicator fades out while watching and
        // the first swipe from the bottom edge only brings it back instead of leaving the player.
        .persistentSystemOverlays(.hidden)
        .defersSystemGestures(on: .bottom)
        .tint(Theme.accent).preferredColorScheme(.dark)
    }
    private func close() { model.finish(); dismiss() }

    // MARK: Top bar
    private var topBar: some View {
        HStack(spacing: 12) {
            Button { close() } label: { CircleIcon(systemName: "chevron.down") }
                .buttonStyle(LoungePressStyle()).accessibilityLabel("Player schließen")
            VStack(alignment: .leading, spacing: 1) {
                Text(model.request.anime.title).font(.subheadline.bold()).lineLimit(1)
                Text(model.choosingHost ? "Quelle wählen" : "Folge \(model.request.episode.number)").font(.caption).foregroundColor(Theme.muted)
            }
            Spacer(minLength: 0)
            if model.choosingHost && model.selectedHost != nil {
                Button("Zurück") { model.select(model.selectedHost, remember: false) }.font(.subheadline.bold())
            }
        }.padding(.horizontal, 16).padding(.vertical, 8)
    }

    // MARK: Video stage
    private var stage: some View {
        ZStack {
            Color.black
            PlayerWebView(webView: model.webView).opacity(model.nativeReady ? 0 : 1)
            PlayerSurface(model: model, fill: model.fillScreen).opacity(model.nativeReady ? 1 : 0).allowsHitTesting(false)
            if model.preparing { loadingCard.transition(.opacity) }
            if theater && !model.nativeReady && !model.preparing {
                // Landscape web player: keep a way out.
                Button { close() } label: { CircleIcon(systemName: "chevron.down") }.buttonStyle(LoungePressStyle())
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding(.leading, 56).padding(.top, 16)
                    .accessibilityLabel("Player schließen")
            }
            if model.nativeReady {
                PlayerControls(model: model, clock: model.clock, theater: theater, close: close, more: { showingMore = true }, toggleFullscreen: toggleFullscreen, interactionLocked: showingMore)
            }
        }.clipped()
    }
    /// Opaque cover over the hoster page (ads, banners) until our player has the video.
    private var loadingCard: some View {
        ZStack {
            Color.black
            Group {
                if let still = model.episodeExtras[model.request.episode.number]?.image { Artwork(url: still) } else { WideArtwork(anime: model.request.anime) }
            }.blur(radius: 30).opacity(0.45).allowsHitTesting(false)
            LinearGradient(colors: [.black.opacity(0.35), .black.opacity(0.85)], startPoint: .top, endPoint: .bottom)
            VStack(spacing: theater ? 14 : 10) {
                if theater {
                    VStack(spacing: 4) {
                        Text(model.request.anime.title.uppercased()).font(.caption.bold()).tracking(1.4).foregroundColor(Theme.accentSoft)
                        Text("Folge \(model.request.episode.number) · \(model.request.episode.title)").font(.title3.bold()).lineLimit(1)
                    }.padding(.bottom, 6)
                }
                LoadingPulse()
                Text(model.status).font(.footnote.weight(.semibold)).multilineTextAlignment(.center).foregroundColor(.white.opacity(0.85))
                    .animation(.easeInOut(duration: 0.2), value: model.status)
                HStack(spacing: 6) {
                    if let host = model.selectedHost { Text("\(host.name) · \(LanguageLabel.short(host.language))") }
                    TimelineView(.periodic(from: model.startedAt, by: 1)) { context in
                        Text("\(max(0, Int(context.date.timeIntervalSince(model.startedAt)))) s").monospacedDigit()
                    }
                }.font(.caption).foregroundColor(Theme.muted)
                if model.offerWebPlayer {
                    HStack(spacing: 10) {
                        Button { model.showWebPlayer() } label: {
                            Label("Webplayer zeigen", systemImage: "globe").font(.footnote.bold()).padding(.horizontal, 14).padding(.vertical, 9)
                                .background(Color.white).foregroundColor(.black).clipShape(Capsule())
                        }
                        Button { model.retry() } label: {
                            Label("Neu laden", systemImage: "arrow.clockwise").font(.footnote.bold()).padding(.horizontal, 14).padding(.vertical, 9)
                                .background(.ultraThinMaterial).clipShape(Capsule())
                        }
                        Button { model.chooseHost() } label: {
                            Label("Andere Quelle", systemImage: "rectangle.stack").font(.footnote.bold()).padding(.horizontal, 14).padding(.vertical, 9)
                                .background(.ultraThinMaterial).clipShape(Capsule())
                        }
                    }.buttonStyle(LoungePressStyle()).foregroundColor(.white).padding(.top, 4).transition(.opacity.combined(with: .scale(scale: 0.95)))
                }
            }.padding(24).animation(.easeInOut(duration: 0.25), value: model.offerWebPlayer)
            if theater {
                Button { close() } label: { CircleIcon(systemName: "chevron.down") }.buttonStyle(LoungePressStyle())
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding(.leading, 56).padding(.top, 16)
                    .accessibilityLabel("Player schließen")
            }
        }
    }

    // MARK: Info panel
    private var infoPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(episodeTitle(model.request.episode)).font(.title3.bold()).lineLimit(3)
                    HStack(spacing: 8) {
                        if model.isOffline { Chip(text: "Offline", icon: "arrow.down.circle.fill") }
                        else if let host = model.selectedHost { Chip(text: "\(host.name) · \(LanguageLabel.short(host.language))", icon: model.nativeReady ? "play.tv.fill" : "globe") }
                        if let time = model.savedLabel { Chip(text: time, icon: "clock") }
                    }
                }
                HStack(spacing: 10) {
                    if model.nextEpisode != nil { ActionTile(title: "Nächste", icon: "forward.end.fill", prominent: true) { model.playNext() } }
                    if !model.isOffline { ActionTile(title: "Quelle", icon: "rectangle.stack") { model.chooseHost() } }
                    downloadTile
                    ActionTile(title: "Mehr", icon: "ellipsis") { showingMore = true }
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
                if !model.nativeReady && !model.isOffline && !model.preparing {
                    NoticeView(text: model.status, icon: "hand.tap", tint: Theme.accentSoft)
                }
                if !model.seasonEpisodes.isEmpty && !model.isOffline { episodeList }
                if model.caughtUp { Text("Keine weitere bekannte Folge").font(.caption).foregroundColor(Theme.muted) }
                if let message = model.nextEpisodeError {
                    Button(message + " Erneut versuchen") { model.loadNextEpisode() }.font(.caption)
                }
            }.padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 30).foregroundColor(.white)
        }.background(Theme.background)
    }
    /// Crunchyroll-style list of the season below the player; tap to switch episodes.
    private var episodeList: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Folgen").font(.headline)
                Spacer()
                Toggle(isOn: Binding(get: { model.autoNext }, set: { model.setAutoNext($0) })) {
                    Text("Autoplay").font(.caption.bold()).foregroundColor(Theme.muted)
                }.toggleStyle(.switch).tint(Theme.accent).fixedSize()
            }
            ScrollViewReader { reader in
                LazyVStack(spacing: 10) {
                    ForEach(model.seasonEpisodes) { episode in
                        let current = episode.id == model.request.episode.id
                        Button { model.play(episode) } label: {
                            HStack(spacing: 12) {
                                ZStack {
                                    if let still = model.episodeExtras[episode.number]?.image { Artwork(url: still) }
                                    else { Theme.panelHigh; Text(episode.number).font(.headline.bold()).foregroundColor(.white.opacity(0.35)) }
                                    if current {
                                        Color.black.opacity(0.45)
                                        Image(systemName: "waveform").font(.subheadline.bold()).foregroundColor(Theme.accentSoft)
                                    }
                                    if !current, let fraction = model.progress(of: episode).flatMap({ $0.isFinished ? nil : $0.fraction }), fraction > 0 {
                                        ProgressBar(value: fraction, track: .black.opacity(0.4), height: 3).frame(maxHeight: .infinity, alignment: .bottom)
                                    }
                                }.frame(width: 104, height: 58).clipShape(RoundedRectangle(cornerRadius: 8))
                                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(current ? Theme.accent : Theme.stroke, lineWidth: current ? 2 : 1))
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(current ? "Läuft gerade · Folge \(episode.number)" : "Folge \(episode.number)")
                                        .font(.caption2.bold()).foregroundColor(current ? Theme.accentSoft : Theme.muted)
                                    Text(episodeTitle(episode)).font(.subheadline.weight(.semibold)).lineLimit(2).multilineTextAlignment(.leading)
                                        .foregroundColor(model.isSeen(episode) && !current ? .white.opacity(0.55) : .white)
                                }
                                Spacer(minLength: 0)
                                if model.isSeen(episode) && !current { Image(systemName: "checkmark.circle.fill").foregroundColor(Theme.accent) }
                            }.contentShape(Rectangle())
                        }.buttonStyle(LoungePressStyle()).id(episode.id).disabled(current)
                    }
                }.onAppear { reader.scrollTo(model.request.episode.id, anchor: .center) }
            }
        }
    }
    private func episodeTitle(_ episode: Episode) -> String {
        let generic = episode.title == "Folge \(episode.number)" || episode.title.isEmpty
        return generic ? (model.episodeExtras[episode.number]?.title ?? episode.title) : episode.title
    }
    @ViewBuilder private var downloadTile: some View {
        if model.isOffline {
            EmptyView()
        } else if let existing = downloads.existing(model.request) {
            ActionTile(title: existing.state == .ready ? "Gespeichert" : "Lädt …", icon: existing.state == .ready ? "checkmark.circle" : "arrow.down.circle.dotted") {}
                .disabled(true)
        } else if model.nativeReady {
            ActionTile(title: "Download", icon: "arrow.down.circle") { model.download() }
        } else {
            // Downloads need a direct video link, which only the iOS player exposes.
            ActionTile(title: "Download", icon: "arrow.down.circle") {}.disabled(true).opacity(0.4)
                .accessibilityHint("Nur verfügbar, wenn die Folge im iOS-Player läuft")
        }
    }
    /// In-player settings: a side panel in landscape, a bottom panel in portrait, always with a close button.
    private var settingsPanel: some View {
        ZStack(alignment: theater ? .trailing : .bottom) {
            Color.black.opacity(0.45).ignoresSafeArea().onTapGesture { showingMore = false }.transition(.opacity)
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Einstellungen").font(.headline)
                    Spacer()
                    Button { showingMore = false } label: { CircleIcon(systemName: "xmark") }.buttonStyle(LoungePressStyle()).accessibilityLabel("Schließen")
                }.padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 6)
                ScrollView { moreSheet.padding(.bottom, 20) }
            }
            .frame(maxWidth: theater ? 380 : .infinity, maxHeight: theater ? .infinity : 480)
            .background(.ultraThinMaterial)
            .background(Theme.background.opacity(0.55))
            .clipShape(RoundedRectangle(cornerRadius: theater ? 0 : 24))
            .overlay(RoundedRectangle(cornerRadius: theater ? 0 : 24).stroke(Theme.stroke))
            .ignoresSafeArea(edges: theater ? [.vertical, .trailing] : .bottom)
            .transition(.move(edge: theater ? .trailing : .bottom))
        }
    }
    private var moreSheet: some View {
        VStack(alignment: .leading, spacing: 2) {
            if model.nativeReady {
                SettingsPills(title: "Geschwindigkeit", icon: "speedometer", options: AppSettings.speeds, label: AppSettings.speedLabel,
                              selection: Binding(get: { model.speed }, set: { model.setSpeed($0) }))
                SheetToggle(title: "Bildschirm füllen", icon: "arrow.up.left.and.arrow.down.right", isOn: $model.fillScreen)
            }
            SheetToggle(title: "Nächste Folge automatisch", icon: "forward.end", isOn: Binding(get: { model.autoNext }, set: { model.setAutoNext($0) }))
            SettingsPills(title: "Schlaf-Timer", icon: "moon.zzz.fill",
                          options: [PlayerModel.SleepTimer.off, .episodeEnd, .minutes(15), .minutes(30), .minutes(60)],
                          label: { timer in
                              switch timer {
                              case .off: return "Aus"
                              case .episodeEnd: return "Folgenende"
                              case .minutes(let minutes): return "\(minutes) Min"
                              }
                          },
                          selection: Binding(get: { model.sleepTimer }, set: { model.setSleepTimer($0) }))
            SheetToggle(title: "Opening automatisch überspringen", icon: "forward.fill", isOn: Binding(get: { AppSettings.shared.autoSkipOpening }, set: { AppSettings.shared.autoSkipOpening = $0 }))
            if !model.isOffline {
                SheetToggle(title: "Werbeblocker", icon: "shield.lefthalf.filled", isOn: Binding(get: { model.adBlockEnabled }, set: { model.setAdBlockEnabled($0) }))
            }
            if model.player != nil && !model.isOffline {
                SheetRow(title: "Webplayer verwenden", icon: "globe") { showingMore = false; model.useWebPlayer() }
            }
        }
    }

    // MARK: Source picker
    private var hostPicker: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(episodeTitle(model.request.episode)).font(.title2.bold())
                    Text("Wähle die Sprache bewusst. Deine Wahl gilt auch für die nächsten Folgen.").font(.subheadline).foregroundColor(Theme.muted)
                }
                if let notice = model.languageNotice {
                    NoticeView(text: notice, icon: "character.bubble.fill", tint: .orange)
                }
                if model.loadingHosts { ProgressView().tint(Theme.accent).frame(maxWidth: .infinity).padding(30) }
                ForEach(Array(Set(model.hosts.map(\.language))).sorted(), id: \.self) { language in
                    VStack(alignment: .leading, spacing: 10) {
                        Text(language).font(.caption.bold()).foregroundColor(Theme.muted)
                        ForEach(model.hosts.filter { $0.language == language }) { host in
                            let current = model.selectedHost?.id == host.id
                            Button { model.select(host) } label: {
                                HStack(spacing: 14) {
                                    Text(String(host.name.prefix(1))).font(.headline.bold()).frame(width: 44, height: 44)
                                        .background(current ? AnyShapeStyle(Theme.accentGradient) : AnyShapeStyle(Theme.panelHigh)).clipShape(RoundedRectangle(cornerRadius: 10))
                                    Text(host.name).font(.headline)
                                    Spacer()
                                    Text(LanguageLabel.short(host.language)).font(.caption.bold()).foregroundColor(Theme.muted)
                                    Image(systemName: current ? "checkmark.circle.fill" : "chevron.right").foregroundColor(current ? Theme.accent : Theme.muted)
                                }.padding(12).background(Theme.panel).clipShape(RoundedRectangle(cornerRadius: 14))
                                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(current ? Theme.accent.opacity(0.6) : Theme.stroke))
                            }.buttonStyle(LoungePressStyle()).foregroundColor(.white)
                        }
                    }
                }
                if let error = model.error {
                    NoticeView(text: error, icon: "exclamationmark.triangle.fill", tint: .orange)
                    Button("Erneut versuchen") { Task { await model.loadHosts() } }.buttonStyle(.borderedProminent)
                }
            }.padding(20).foregroundColor(.white)
        }.background(Theme.background)
    }
}
/// Streaming-app controls drawn over the video: tap to show/hide, double-tap a side to jump
/// 10 seconds, a scrubber with buffer, rotation, Picture in Picture and settings.
struct PlayerControls: View {
    @ObservedObject var model: PlayerModel
    @ObservedObject var clock: PlayheadClock
    let theater: Bool
    let close: () -> Void
    let more: () -> Void
    let toggleFullscreen: () -> Void
    let interactionLocked: Bool
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var visible = true
    @State private var hideTask: Task<Void, Never>?
    @State private var scrub: Double?
    @State private var flash: (text: String, forward: Bool)?
    @State private var flashID = UUID()
    @State private var locked = false
    @State private var showUnlock = false
    @State private var hud: (icon: String, value: Double)?
    @State private var dragBase: Double?
    @State private var hudID = UUID()
    @State private var seekTotal = 0
    var body: some View {
        ZStack {
            VolumeHost().frame(width: 1, height: 1).opacity(0.01).allowsHitTesting(false)
            if locked {
                lockLayer
            } else {
                HStack(spacing: 0) {
                    tapZone(forward: false)
                    tapZone(forward: true)
                }
                if visible { chrome.transition(.opacity.combined(with: .scale(scale: 1.02))) }
                SkipOverlay(model: model, clock: clock, bottom: visible ? (theater ? 96 : 58) : (theater ? 30 : 10))
                if let from = model.resumedFrom { resumePill(from) }
            }
            if !visible && model.isBuffering { ProgressView().controlSize(.large).tint(.white).allowsHitTesting(false) }
            if let hud {
                // The level bar sits at the edge of the side being swiped.
                hudView(hud)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: hud.icon.hasPrefix("sun") ? .trailing : .leading)
                    .padding(.horizontal, theater ? 64 : 18)
            }
            if let flash {
                Text(flash.text).font(.headline.bold()).padding(.horizontal, 16).padding(.vertical, 10)
                    .background(.ultraThinMaterial).clipShape(Capsule())
                    .frame(maxWidth: .infinity, alignment: flash.forward ? .trailing : .leading).padding(.horizontal, theater ? 80 : 30)
                    .allowsHitTesting(false).transition(.opacity)
            }
            if let toast = model.toast {
                Text(toast).font(.footnote.bold()).padding(.horizontal, 14).padding(.vertical, 8).background(.ultraThinMaterial).clipShape(Capsule())
                    .frame(maxHeight: .infinity, alignment: .top).padding(.top, theater ? 70 : 50).allowsHitTesting(false).transition(.opacity)
            }
        }
        .foregroundColor(.white)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: visible)
        .animation(.easeInOut(duration: 0.2), value: model.toast)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: locked)
        .animation(.easeInOut(duration: 0.25), value: model.resumedFrom)
        .onAppear { scheduleHide() }
        .onDisappear { hideTask?.cancel() }
        .onChange(of: voiceOverEnabled) { _ in visible = true; scheduleHide() }
        .onChange(of: interactionLocked) { _ in visible = true; scheduleHide() }
        .onChange(of: model.request.episode.id) { _ in visible = true; scheduleHide() }
        .onChange(of: model.isPlaying) { playing in
            if playing { scheduleHide() } else { hideTask?.cancel(); withAnimation { visible = true } }
        }
    }
    private func tapZone(forward: Bool) -> some View {
        Color.clear.contentShape(Rectangle()).accessibilityHidden(true)
            .onTapGesture(count: 2) {
                model.skip(forward ? 10 : -10)
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                // Repeated double taps add up, like YouTube and Crunchyroll: +10, +20, +30 …
                let sameSide = flash.map { $0.forward == forward } ?? false
                seekTotal = (sameSide ? seekTotal : 0) + 10
                let id = UUID(); flashID = id
                withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) { flash = (forward ? "+\(seekTotal) s" : "−\(seekTotal) s", forward) }
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 900_000_000)
                    if flashID == id { withAnimation { flash = nil }; seekTotal = 0 }
                }
            }
            .onTapGesture {
                guard !voiceOverEnabled, !interactionLocked else { return }
                if visible { hideTask?.cancel(); withAnimation { visible = false } } else { withAnimation { visible = true }; scheduleHide() }
            }
            // Vertical swipe: volume on the left, brightness on the right.
            .simultaneousGesture(DragGesture(minimumDistance: 16)
                .onChanged { adjust($0, volume: !forward) }
                .onEnded { _ in endAdjust() })
    }
    private func adjust(_ value: DragGesture.Value, volume: Bool) {
        guard !interactionLocked, abs(value.translation.height) > abs(value.translation.width) * 1.3 else { return }
        if dragBase == nil { dragBase = volume ? Double(SystemVolume.level) : Double(UIScreen.main.brightness) }
        let next = min(1, max(0, (dragBase ?? 0) - Double(value.translation.height) / 260))
        if volume { SystemVolume.set(Float(next)) } else { UIScreen.main.brightness = CGFloat(next) }
        hudID = UUID()
        hud = (volume ? (next == 0 ? "speaker.slash.fill" : next < 0.5 ? "speaker.wave.1.fill" : "speaker.wave.3.fill") : "sun.max.fill", next)
    }
    private func endAdjust() {
        dragBase = nil
        let id = hudID
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 700_000_000)
            if hudID == id { withAnimation(.easeOut(duration: 0.2)) { hud = nil } }
        }
    }
    private func hudView(_ hud: (icon: String, value: Double)) -> some View {
        VStack(spacing: 10) {
            Image(systemName: hud.icon).font(.title3.weight(.semibold)).frame(height: 26)
            GeometryReader { geo in
                ZStack(alignment: .bottom) {
                    Capsule().fill(.white.opacity(0.25))
                    Capsule().fill(Color.white).frame(height: geo.size.height * CGFloat(hud.value))
                }
            }.frame(width: 6, height: 110)
        }
        .padding(.vertical, 14).padding(.horizontal, 12).background(.ultraThinMaterial).clipShape(Capsule())
        .allowsHitTesting(false).transition(.opacity.combined(with: .scale(scale: 0.9)))
    }
    /// Locked: every tap only reveals the unlock hint; holding it unlocks.
    private var lockLayer: some View {
        ZStack {
            Color.clear.contentShape(Rectangle()).onTapGesture {
                withAnimation { showUnlock = true }
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 2_500_000_000)
                    withAnimation { showUnlock = false }
                }
            }
            if showUnlock {
                Label("Zum Entsperren gedrückt halten", systemImage: "lock.fill").font(.subheadline.bold())
                    .padding(.horizontal, 18).padding(.vertical, 12).background(.ultraThinMaterial).clipShape(Capsule())
                    .onLongPressGesture(minimumDuration: 0.6) {
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        withAnimation { locked = false; showUnlock = false; visible = true }
                        scheduleHide()
                    }
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
                    .accessibilityAction(named: "Entsperren") { locked = false; visible = true }
            }
        }
    }
    private func resumePill(_ from: Double) -> some View {
        HStack(spacing: 10) {
            Text("Fortgesetzt bei \(EpisodeProgress.format(from))").font(.footnote.weight(.semibold)).monospacedDigit()
            Button { model.seek(to: 0); model.resumedFrom = nil } label: {
                Text("Von vorne").font(.footnote.bold()).padding(.horizontal, 12).padding(.vertical, 7)
                    .background(Color.white).foregroundColor(.black).clipShape(Capsule())
            }.buttonStyle(LoungePressStyle())
        }
        .padding(.leading, 14).padding(.trailing, 6).padding(.vertical, 6).background(.ultraThinMaterial).clipShape(Capsule())
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        .padding(.leading, theater ? 56 : 12).padding(.bottom, visible ? (theater ? 96 : 58) : (theater ? 30 : 10))
        .transition(.opacity.combined(with: .move(edge: .leading)))
    }
    private func scheduleHide() {
        hideTask?.cancel()
        guard !voiceOverEnabled, !interactionLocked else { visible = true; return }
        hideTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_500_000_000)
            guard !Task.isCancelled, model.isPlaying, scrub == nil, !voiceOverEnabled, !interactionLocked else { return }
            withAnimation { visible = false }
        }
    }
    private var skipSegments: [ScrubberSegment] {
        guard let times = model.skipTimes, times.fits(duration: model.player?.currentItem?.duration.seconds) else { return [] }
        var list: [ScrubberSegment] = []
        if let recap = times.recap { list.append(ScrubberSegment(range: recap, color: .teal)) }
        if let opening = times.opening { list.append(ScrubberSegment(range: opening, color: .yellow)) }
        if let ending = times.ending { list.append(ScrubberSegment(range: ending, color: .orange)) }
        return list
    }
    /// Runs a control action and keeps the controls on screen a little longer.
    private func act(_ action: () -> Void) { action(); scheduleHide() }

    private var chrome: some View {
        ZStack {
            LinearGradient(stops: [.init(color: .black.opacity(0.7), location: 0), .init(color: .black.opacity(0.15), location: 0.3),
                                   .init(color: .black.opacity(0.15), location: 0.6), .init(color: .black.opacity(0.8), location: 1)],
                           startPoint: .top, endPoint: .bottom).allowsHitTesting(false)
            VStack(spacing: 0) {
                HStack(spacing: 14) {
                    if theater {
                        Button(action: close) { Image(systemName: "chevron.down").font(.title3.weight(.bold)).frame(width: 44, height: 44) }
                            .accessibilityLabel("Player schließen")
                        VStack(alignment: .leading, spacing: 2) {
                            Text(model.request.anime.title).font(.headline).lineLimit(1)
                            Text("Folge \(model.request.episode.number) · \(model.request.episode.title)").font(.caption).foregroundColor(.white.opacity(0.75)).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                    Button {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        hideTask?.cancel()
                        withAnimation { locked = true; visible = false }
                    } label: { Image(systemName: "lock.open.fill").font(theater ? .title3.weight(.semibold) : .body.weight(.semibold)).frame(width: 44, height: 44) }
                        .accessibilityLabel("Bildschirm sperren")
                    if model.pipPossible {
                        Button { model.togglePictureInPicture() } label: { Image(systemName: "pip.enter").font(theater ? .title3.weight(.semibold) : .body.weight(.semibold)).frame(width: 44, height: 44) }
                            .accessibilityLabel("Bild in Bild")
                    }
                    Button(action: more) { Image(systemName: "gearshape.fill").font(theater ? .title3.weight(.semibold) : .body.weight(.semibold)).frame(width: 44, height: 44) }
                        .accessibilityLabel("Wiedergabe-Einstellungen")
                }
                Spacer(minLength: 0)
                bottomBar
            }.padding(.horizontal, theater ? 56 : 10).padding(.top, theater ? 16 : 2).padding(.bottom, theater ? 18 : 2)
            HStack(spacing: theater ? 72 : 36) {
                Button { act { model.skip(-10) } } label: { Image(systemName: "gobackward.10").font(.system(size: theater ? 34 : 21, weight: .semibold)).frame(width: 44, height: 44).contentShape(Rectangle()) }
                    .accessibilityLabel("10 Sekunden zurück")
                ZStack {
                    if model.isBuffering { ProgressView().controlSize(.large).tint(.white) }
                    else {
                        Button { act { model.togglePlay() } } label: {
                            Image(systemName: model.isPlaying ? "pause.fill" : "play.fill").font(.system(size: theater ? 48 : 30, weight: .bold)).frame(width: 56, height: 56).contentShape(Rectangle())
                                .id(model.isPlaying).transition(.scale(scale: 0.6).combined(with: .opacity))
                                .animation(.spring(response: 0.28, dampingFraction: 0.6), value: model.isPlaying)
                        }.accessibilityLabel(model.isPlaying ? "Pause" : "Abspielen")
                    }
                }.frame(width: 56, height: 56)
                Button { act { model.skip(10) } } label: { Image(systemName: "goforward.10").font(.system(size: theater ? 34 : 21, weight: .semibold)).frame(width: 44, height: 44).contentShape(Rectangle()) }
                    .accessibilityLabel("10 Sekunden vor")
            }.shadow(color: .black.opacity(0.4), radius: 8)
        }.buttonStyle(LoungePressStyle())
    }
    private var bottomBar: some View {
        Group { if theater { fullBottomBar } else { compactBottomBar } }
    }
    /// Portrait: one row (time, timeline, full screen) so the small video keeps room for the centre buttons.
    private var compactBottomBar: some View {
        HStack(spacing: 10) {
            Text(EpisodeProgress.format(scrub ?? clock.seconds)).font(.caption2.weight(.semibold).monospacedDigit())
                .foregroundColor(.white.opacity(0.85)).fixedSize()
            Scrubber(value: scrub ?? clock.seconds, duration: clock.duration, buffered: clock.buffered,
                     changed: { scrub = $0; hideTask?.cancel() },
                     ended: { model.seek(to: $0); scrub = nil; scheduleHide() }, segments: skipSegments)
            Text(EpisodeProgress.format(clock.duration)).font(.caption2.weight(.semibold).monospacedDigit())
                .foregroundColor(.white.opacity(0.6)).fixedSize()
            Button { toggleFullscreen(); scheduleHide() } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right.rectangle").font(.body.weight(.semibold)).frame(width: 40, height: 40)
            }.accessibilityLabel("Vollbild")
        }
    }
    private var fullBottomBar: some View {
        VStack(spacing: theater ? 8 : 2) {
            Scrubber(value: scrub ?? clock.seconds, duration: clock.duration, buffered: clock.buffered,
                     changed: { scrub = $0; hideTask?.cancel() },
                     ended: { model.seek(to: $0); scrub = nil; scheduleHide() }, segments: skipSegments)
            HStack(spacing: 14) {
                Text("\(EpisodeProgress.format(scrub ?? clock.seconds)) / \(EpisodeProgress.format(clock.duration))")
                    .font(.caption.weight(.semibold).monospacedDigit()).foregroundColor(.white.opacity(0.85))
                Spacer(minLength: 0)
                if theater, let next = model.nextEpisode {
                    Button { act { model.playNext() } } label: {
                        Label("Folge \(next.number)", systemImage: "forward.end.fill").font(.footnote.bold())
                            .padding(.horizontal, 14).frame(minHeight: 40).background(.ultraThinMaterial).clipShape(Capsule())
                            .contentShape(Capsule())
                    }.accessibilityLabel("Nächste Folge, Folge \(next.number)")
                }
                if theater {
                    Button { act { model.fillScreen.toggle() } } label: {
                        Image(systemName: model.fillScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right").font(.body.weight(.semibold))
                    }.accessibilityLabel(model.fillScreen ? "Ganzes Bild zeigen" : "Bildschirm füllen")
                }
                Button { toggleFullscreen(); scheduleHide() } label: {
                    Image(systemName: theater ? "arrow.down.right.and.arrow.up.left.rectangle" : "arrow.up.left.and.arrow.down.right.rectangle")
                        .font(.body.weight(.semibold)).frame(width: 44, height: 44)
                }.accessibilityLabel(theater ? "Vollbild verlassen" : "Vollbild")
            }
        }
    }
}
private struct Scrubber: View {
    let value: Double
    let duration: Double
    let buffered: Double
    let changed: (Double) -> Void
    let ended: (Double) -> Void
    /// Recap, opening and ending, drawn in colour on the track (AniSkip).
    var segments: [ScrubberSegment] = []
    @State private var dragging = false
    var body: some View {
        GeometryReader { geo in
            let width = max(1, geo.size.width)
            let played = duration > 0 ? min(1, max(0, value / duration)) : 0
            let loaded = duration > 0 ? min(1, max(0, buffered / duration)) : 0
            let bar: CGFloat = dragging ? 6 : 4
            let knob: CGFloat = dragging ? 18 : 12
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.22)).frame(height: bar)
                Capsule().fill(.white.opacity(0.4)).frame(width: width * loaded, height: bar)
                ForEach(segments) { segment in
                    Capsule().fill(segment.color.opacity(0.85))
                        .frame(width: max(3, width * CGFloat((segment.range.upperBound - segment.range.lowerBound) / max(duration, 1))), height: bar)
                        .offset(x: width * CGFloat(segment.range.lowerBound / max(duration, 1)))
                }
                Capsule().fill(Theme.accent).frame(width: width * played, height: bar)
                Circle().fill(Theme.accent).frame(width: knob, height: knob).shadow(radius: 3)
                    .offset(x: width * played - knob / 2)
            }
            .frame(height: 44).contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { gesture in
                    if !dragging { dragging = true; UISelectionFeedbackGenerator().selectionChanged() }
                    changed(min(1, max(0, gesture.location.x / width)) * duration)
                }
                .onEnded { gesture in
                    dragging = false
                    ended(min(1, max(0, gesture.location.x / width)) * duration)
                })
            .animation(.easeOut(duration: 0.15), value: dragging)
        }
        .frame(height: 44)
        .allowsHitTesting(duration > 0)
        .accessibilityElement()
        .accessibilityLabel("Wiedergabeposition")
        .accessibilityValue("\(EpisodeProgress.format(value)) von \(EpisodeProgress.format(duration))")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: ended(min(duration, value + 10))
            case .decrement: ended(max(0, value - 10))
            @unknown default: break
            }
        }
    }
}
/// Skip buttons above the controls, only while they make sense:
/// during the real opening/ending (AniSkip) and for the autoplay countdown.
private struct SkipOverlay: View {
    @ObservedObject var model: PlayerModel
    @ObservedObject var clock: PlayheadClock
    let bottom: CGFloat
    private enum Kind: Equatable { case none, recap(Double), opening(Double), ending(Double), countdown(Int) }
    private var kind: Kind {
        if let seconds = model.countdown, model.nextEpisode != nil { return .countdown(seconds) }
        guard let times = model.skipTimes, times.fits(duration: model.player?.currentItem?.duration.seconds) else { return .none }
        let now = clock.seconds
        // With automatic skipping on, the opening is skipped for you; no button needed.
        if let recap = times.recap, now >= recap.lowerBound - 1, now < recap.upperBound - 3 { return .recap(recap.upperBound) }
        if let op = times.opening, !AppSettings.shared.autoSkipOpening, now >= op.lowerBound - 1, now < op.upperBound - 3 { return .opening(op.upperBound) }
        if let ed = times.ending, now >= ed.lowerBound, now < ed.upperBound - 3 { return .ending(ed.upperBound) }
        return .none
    }
    var body: some View {
        HStack(spacing: 10) {
            Spacer()
            switch kind {
            case .none:
                // Without AniSkip data, offer the classic 85-second intro jump early in the episode.
                if model.skipTimes?.opening == nil, clock.seconds > 5, clock.seconds < 240, model.countdown == nil {
                    Button { model.skip(85) } label: { Label("Intro +85 s", systemImage: "forward.fill") }
                        .buttonStyle(OverlayButtonStyle())
                }
            case .recap(let end):
                Button { model.seek(to: end) } label: { Label("Rückblick überspringen", systemImage: "forward.fill") }
                    .buttonStyle(OverlayButtonStyle())
            case .opening(let end):
                Button { model.seek(to: end) } label: { Label("Opening überspringen", systemImage: "forward.fill") }
                    .buttonStyle(OverlayButtonStyle())
            case .ending(let end):
                if let next = model.nextEpisode {
                    Button { model.playNext() } label: { Label("Folge \(next.number)", systemImage: "forward.end.fill") }
                        .buttonStyle(OverlayButtonStyle(prominent: true))
                } else {
                    Button { model.seek(to: end) } label: { Label("Abspann überspringen", systemImage: "forward.fill") }
                        .buttonStyle(OverlayButtonStyle())
                }
            case .countdown(let seconds):
                if let next = model.nextEpisode {
                    Button { model.playNext() } label: {
                        HStack(spacing: 10) {
                            ZStack {
                                Circle().stroke(.black.opacity(0.2), lineWidth: 3)
                                Circle().trim(from: 0, to: CGFloat(10 - seconds) / 10).stroke(.black, style: StrokeStyle(lineWidth: 3, lineCap: .round)).rotationEffect(.degrees(-90))
                                    .animation(.linear(duration: 1), value: seconds)
                                Image(systemName: "play.fill").font(.caption2)
                            }.frame(width: 24, height: 24)
                            Text("Folge \(next.number) in \(seconds) s").monospacedDigit()
                        }
                    }.buttonStyle(OverlayButtonStyle(prominent: true))
                    Button { model.cancelCountdown() } label: { Image(systemName: "xmark") }.buttonStyle(OverlayButtonStyle()).accessibilityLabel("Autoplay abbrechen")
                }
            }
        }
        .padding(.trailing, 16).padding(.bottom, bottom)
        .frame(maxHeight: .infinity, alignment: .bottom)
        .animation(.easeInOut(duration: 0.25), value: kind)
    }
}
private struct OverlayButtonStyle: ButtonStyle {
    var prominent = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.subheadline.bold()).foregroundColor(prominent ? .black : .white)
            .padding(.horizontal, 16).padding(.vertical, 11)
            .background(prominent ? AnyShapeStyle(Color.white) : AnyShapeStyle(.ultraThinMaterial))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(.white.opacity(prominent ? 0 : 0.25)))
            .scaleEffect(configuration.isPressed ? 0.96 : 1).opacity(configuration.isPressed ? 0.85 : 1)
            .transition(.opacity.combined(with: .move(edge: .trailing)))
    }
}
private struct ActionTile: View {
    let title: String
    let icon: String
    var prominent = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(spacing: 7) {
                Image(systemName: icon).font(.system(size: 19, weight: .semibold)).frame(height: 22)
                Text(title).font(.caption.bold()).lineLimit(1).minimumScaleFactor(0.8)
            }.frame(maxWidth: .infinity).padding(.vertical, 13)
                .background(prominent ? AnyShapeStyle(Theme.accentGradient) : AnyShapeStyle(Theme.panel))
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.stroke))
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
/// Anything covering the screen must leave the player, its item and observers alive.
@MainActor private struct PlaybackLifetime: UIViewRepresentable {
    let model: PlayerModel
    final class Coordinator {
        let model: PlayerModel
        init(_ model: PlayerModel) { self.model = model }
    }
    func makeCoordinator() -> Coordinator { Coordinator(model) }
    func makeUIView(context: Context) -> UIView {
        model.detached = false
        // Only the player may turn sideways; browsing stays upright on iPhone.
        DispatchQueue.main.async { OrientationLock.allowRotation(true) }
        return UIView(frame: .zero)
    }
    func updateUIView(_ view: UIView, context: Context) {}
    static func dismantleUIView(_ view: UIView, coordinator: Coordinator) {
        coordinator.model.screenRemoved()
        DispatchQueue.main.async { OrientationLock.allowRotation(false) }
    }
}
private struct PlayerWebView: UIViewRepresentable {
    let webView: WKWebView
    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ view: WKWebView, context: Context) {}
}
private struct PlayerSurface: UIViewRepresentable {
    let model: PlayerModel
    let fill: Bool
    func makeUIView(context: Context) -> PlayerSurfaceView { model.surface }
    func updateUIView(_ view: PlayerSurfaceView, context: Context) {
        let gravity: AVLayerVideoGravity = fill ? .resizeAspectFill : .resizeAspect
        if view.playerLayer.videoGravity != gravity { view.playerLayer.videoGravity = gravity }
    }
}


/// Calm loading indicator: a pulsing play glyph inside a turning accent ring.
private struct LoadingPulse: View {
    @State private var spin = false
    @State private var pulse = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        ZStack {
            Circle().stroke(.white.opacity(0.12), lineWidth: 3)
            Circle().trim(from: 0, to: 0.28).stroke(Theme.accentGradient, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(spin ? 360 : 0))
            Image(systemName: "play.fill").font(.system(size: 18, weight: .bold)).foregroundColor(.white)
                .scaleEffect(pulse ? 1.08 : 0.92).opacity(pulse ? 1 : 0.7)
        }
        .frame(width: 54, height: 54)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.linear(duration: 1).repeatForever(autoreverses: false)) { spin = true }
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { pulse = true }
        }
        .accessibilityLabel("Lädt")
    }
}

/// System volume for the swipe gesture. A hidden MPVolumeView changes it and keeps the
/// system volume HUD from covering the video.
@MainActor enum SystemVolume {
    static let view: MPVolumeView = {
        let view = MPVolumeView(frame: CGRect(x: -200, y: -200, width: 10, height: 10))
        view.alpha = 0.01
        return view
    }()
    static var level: Float { AVAudioSession.sharedInstance().outputVolume }
    static func set(_ value: Float) {
        guard let slider = view.subviews.compactMap({ $0 as? UISlider }).first else { return }
        slider.value = max(0, min(1, value))
    }
}
private struct VolumeHost: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let container = UIView(frame: .zero)
        container.addSubview(SystemVolume.view)
        return container
    }
    func updateUIView(_ view: UIView, context: Context) {}
}

struct ScrubberSegment: Identifiable {
    var id: Double { range.lowerBound }
    let range: ClosedRange<Double>
    let color: Color
}
