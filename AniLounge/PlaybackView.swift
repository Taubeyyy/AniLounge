import SwiftUI
import WebKit
import AVKit
import AniCore

struct PlaybackRequest: Identifiable {
    let id = UUID()
    let anime: Anime
    let episode: Episode
    let profileID: UUID
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
    let request: PlaybackRequest
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
    private var nativeDisabled = false
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
        guard hosts.isEmpty, !loadingHosts else { return }
        loadingHosts = true; error = nil; startedAt = Date(); status = "Verfügbare Quellen werden gesucht …"
        defer { loadingHosts = false }
        do {
            hosts = try await AniClient.shared.hosts(path: request.episode.path)
            guard !closed, !Task.isCancelled else { return }
            let preference = UserDefaults.standard.dictionary(forKey: preferenceKey)
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
    func select(_ host: StreamHost?, remember: Bool = true) {
        guard let url = host?.url ?? AniURL.page(request.episode.path) else { return }
        checkpoint(); stopNative()
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
        }
    }
    func setAdBlockEnabled(_ enabled: Bool) {
        adBlockEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "web.adblock.enabled")
        if !choosingHost, let host = selectedHost { select(host, remember: false) }
    }
    func chooseHost() {
        checkpoint(); stopNative(); loadTask?.cancel(); token = UUID().uuidString
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
    }
    private func record(seconds: Double, duration: Double, completed: Bool) {
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
            let asset = AVURLAsset(url: url, options: [AVURLAssetHTTPCookiesKey: matching])
            let item = AVPlayerItem(asset: asset)
            let player = AVPlayer(playerItem: item)
            self.player = player
            self.itemObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
                Task { @MainActor [weak self] in
                    guard let self, self.generation == attempt, self.player?.currentItem === item else { return }
                    if item.status == .readyToPlay { self.activateNative(item) }
                    else if item.status == .failed { self.useWebPlayer("Dieser Anbieter lässt sich hier nicht nativ abspielen. Starte das Video im Webplayer oder wähle einen anderen Anbieter.") }
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
                    self.captureNative(ended: true)
                }
            }
            self.timeout = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                guard !Task.isCancelled, let self, self.generation == attempt, !self.nativeReady else { return }
                self.useWebPlayer("Der native Player antwortet nicht. Du kannst im Webplayer weiterschauen.")
            }
        }
    }
    private func activateNative(_ item: AVPlayerItem) {
        guard !nativeReady, !closed else { return }
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
        checkpoint(); stopNative(); nativeDisabled = true; preparing = false; revealTask?.cancel()
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
        checkpoint(); closed = true; loadTask?.cancel(); revealTask?.cancel(); stopNative()
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
        if (error as NSError).code != NSURLErrorCancelled { self.error = error.localizedDescription; preparing = false }
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
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var phase
    init(request: PlaybackRequest, library: LibraryStore) {
        _model = StateObject(wrappedValue: PlayerModel(request: request, store: library))
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
                                Button("Quelle ändern") { model.chooseHost() }.buttonStyle(.bordered)
                            }.padding(30).frame(maxWidth: .infinity, maxHeight: .infinity).background(Theme.background)
                        }
                        if model.nativeReady, let player = model.player { NativePlayerView(player: player) }
                    }
                    VStack(spacing: 6) {
                        if let time = model.savedLabel { Label(time, systemImage: "checkmark.circle.fill").foregroundColor(Theme.accent).font(.caption.monospacedDigit()) }
                        Text(model.error ?? model.status).font(.caption).foregroundColor(.secondary).multilineTextAlignment(.center)
                        if !model.nativeReady {
                            HStack {
                                Image(systemName: model.adBlockEnabled ? "shield.lefthalf.filled" : "shield.slash")
                                Text(model.blockerStatus).font(.caption2)
                                Spacer()
                                Button(model.adBlockEnabled ? "Ohne Blocker neu laden" : "Blocker aktivieren") { model.setAdBlockEnabled(!model.adBlockEnabled) }.font(.caption2)
                            }.foregroundColor(Theme.accent)
                        }
                        if model.player != nil { Button("Webplayer verwenden") { model.useWebPlayer() }.font(.caption) }
                    }.padding(12).frame(maxWidth: .infinity).background(Theme.panel)
                }
            }.background(Theme.background)
                .navigationTitle("Folge \(model.request.episode.number)").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        if !model.choosingHost { Button("Quelle") { model.chooseHost() } }
                    }
                    ToolbarItem(placement: .navigationBarTrailing) { Button("Fertig") { model.finish(); dismiss() } }
                }
                .task { await model.loadHosts() }
                .onChange(of: phase) { if $0 != .active { model.checkpoint() } }
                .onDisappear { model.finish() }
        }.tint(Theme.accent)
    }
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
    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) { controller.player = player }
}

