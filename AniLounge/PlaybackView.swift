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
    @Published var hosts: [StreamHost] = []
    @Published var choosingHost = true
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
        configuration.allowsPictureInPictureMediaPlayback = true
        configuration.websiteDataStore = .default()
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self; webView.uiDelegate = self
        configuration.userContentController.add(WeakProgressHandler(self), contentWorld: world, name: "aniProgress")
    }
    func loadHosts() async {
        guard hosts.isEmpty, !loadingHosts else { return }
        loadingHosts = true; error = nil
        defer { loadingHosts = false }
        do { hosts = try await AniClient.shared.hosts(path: request.episode.path) }
        catch { if !Task.isCancelled { self.error = error.localizedDescription } }
    }
    private func installTracker() {
        token = UUID().uuidString
        let old = store.progress(for: request.episode, profileID: request.profileID)
        let config: [String: Any] = ["token": token, "seconds": old?.completed == true ? 0 : (old?.seconds ?? 0), "duration": old?.duration ?? 0]
        let controller = webView.configuration.userContentController
        controller.removeAllUserScripts()
        if let scriptURL = Bundle.main.url(forResource: "PlaybackTracker", withExtension: "js"),
           let template = try? String(contentsOf: scriptURL),
           let data = try? JSONSerialization.data(withJSONObject: config), let json = String(data: data, encoding: .utf8) {
            let script = template.replacingOccurrences(of: "__ANILOUNGE_CONFIG__", with: json)
            controller.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentEnd, forMainFrameOnly: false, in: world))
        } else { error = "Automatische Videoerkennung fehlt. Fortschritt kann in der Folgenliste eingetragen werden." }
    }
    func select(_ host: StreamHost?) {
        guard let url = host?.url ?? AniURL.page(request.episode.path) else { return }
        checkpoint(); stopNative()
        selectedHost = host; choosingHost = false; error = nil
        lastPosition = nil; lastDuration = nil; lastCompleted = false; mediaOrigin = nil; mediaFrame = nil
        attempted.removeAll(); nativeDisabled = false; savedLabel = nil
        installTracker()
        status = "Starte das Video. Nutzbare Videolinks werden im iOS-Player geöffnet."
        webView.load(URLRequest(url: url))
    }
    func chooseHost() {
        checkpoint(); stopNative(); token = UUID().uuidString
        webView.stopLoading(); webView.loadHTMLString("", baseURL: nil)
        choosingHost = true; error = nil
    }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard !closed, !choosingHost, let body = message.body as? [String: Any], body["token"] as? String == token else { return }
        if body["kind"] as? String == "source" {
            if let value = body["url"] as? String, let url = PlaybackSource.directURL(value) { startNative(url) }
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
        nativeReady = true; restoring = true; timeout?.cancel(); error = nil
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)
        status = "iOS-Player · Fortschritt wird automatisch gespeichert."
        webView.setAllMediaPlaybackSuspended(true, completionHandler: nil)
        let old = store.progress(for: request.episode, profileID: request.profileID)
        let position = PlaybackSource.resumePosition(saved: old?.completed == true ? 0 : (old?.seconds ?? 0),
                                                     savedDuration: old?.duration, duration: item.duration.seconds.isFinite ? item.duration.seconds : (lastDuration ?? old?.duration ?? 0))
        let attempt = generation
        player?.seek(to: CMTime(seconds: position, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
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
        checkpoint(); stopNative(); nativeDisabled = true
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
        checkpoint(); closed = true; stopNative()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        webView.stopLoading(); webView.loadHTMLString("", baseURL: nil)
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "aniProgress", contentWorld: world)
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if (error as NSError).code != NSURLErrorCancelled { self.error = error.localizedDescription }
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url, ["https", "about"].contains(url.scheme ?? "") else { decisionHandler(.cancel); return }
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
                    List {
                        Section {
                            Text(model.request.anime.title).font(.headline)
                            Text(model.request.episode.title).font(.subheadline).foregroundColor(.secondary)
                        }
                        if model.loadingHosts { ProgressView("Videoanbieter laden …") }
                        ForEach(Array(Set(model.hosts.map(\.language))).sorted(), id: \.self) { language in
                            Section(language) {
                                ForEach(model.hosts.filter { $0.language == language }) { host in
                                    Button { model.select(host) } label: {
                                        HStack { Label(host.name, systemImage: "play.circle.fill"); Spacer(); Image(systemName: "chevron.right") }
                                    }
                                }
                            }
                        }
                        if let error = model.error {
                            Section { Text(error).foregroundColor(.orange); Button("Erneut versuchen") { Task { await model.loadHosts() } } }
                        }
                        Section {
                            Text("Starte das Video beim Anbieter. Sobald ein nutzbarer MP4- oder HLS-Link erkannt wird, versucht AniLounge die native Wiedergabe. Neue Fenster werden blockiert.").font(.footnote).foregroundColor(.secondary)
                        }
                    }.scrollContentBackground(.hidden)
                } else {
                    ZStack {
                        PlayerWebView(webView: model.webView).opacity(model.nativeReady ? 0 : 1)
                        if model.nativeReady, let player = model.player { NativePlayerView(player: player) }
                    }
                    VStack(spacing: 6) {
                        if let time = model.savedLabel { Label(time, systemImage: "checkmark.circle.fill").foregroundColor(Theme.accent).font(.caption.monospacedDigit()) }
                        Text(model.error ?? model.status).font(.caption).foregroundColor(.secondary).multilineTextAlignment(.center)
                        if model.player != nil { Button("Webplayer verwenden") { model.useWebPlayer() }.font(.caption) }
                    }.padding(12).frame(maxWidth: .infinity).background(Theme.panel)
                }
            }.background(Theme.background)
                .navigationTitle("Folge \(model.request.episode.number)").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        if !model.choosingHost { Button("Anbieter") { model.chooseHost() } }
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
