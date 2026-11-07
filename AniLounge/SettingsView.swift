import SwiftUI
import UniformTypeIdentifiers
import AVFoundation
import AniCore

/// App-wide preferences. Existing keys from earlier versions are kept so nothing resets.
@MainActor final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    private let defaults = UserDefaults.standard
    @Published var autoNext: Bool { didSet { defaults.set(autoNext, forKey: "playback.autoNext") } }
    @Published var autoSkipOpening: Bool { didSet { defaults.set(autoSkipOpening, forKey: "playback.autoSkipOpening") } }
    @Published var speed: Double { didSet { defaults.set(speed, forKey: "playback.speed") } }
    @Published var dataSaver: Bool { didSet { defaults.set(dataSaver, forKey: "playback.dataSaver") } }
    @Published var adBlock: Bool { didSet { defaults.set(adBlock, forKey: "web.adblock.enabled") } }
    @Published var preferredLanguage: String { didSet { defaults.set(preferredLanguage, forKey: "playback.language"); forgetRememberedSources() } }
    @Published var preferredHoster: String { didSet { defaults.set(preferredHoster, forKey: "playback.hoster"); forgetRememberedSources() } }
    @Published var wifiOnlyDownloads: Bool { didSet { defaults.set(wifiOnlyDownloads, forKey: "downloads.wifiOnly") } }
    @Published var heroAutoAdvance: Bool { didSet { defaults.set(heroAutoAdvance, forKey: "home.heroAutoAdvance") } }
    /// Episodes open in landscape full screen, like Netflix and Crunchyroll.
    @Published var startLandscape: Bool { didSet { defaults.set(startLandscape, forKey: "playback.startLandscape") } }
    static let speeds: [Double] = [0.75, 1, 1.25, 1.5, 2]
    static let languages = ["DE", "DE-Sub", "EN-Sub"]
    static let hosters = ["VOE", "Filemoon", "Vidmoly", "Doodstream"]
    private init() {
        autoNext = defaults.bool(forKey: "playback.autoNext")
        autoSkipOpening = defaults.bool(forKey: "playback.autoSkipOpening")
        let storedSpeed = defaults.double(forKey: "playback.speed")
        speed = Self.speeds.contains(storedSpeed) ? storedSpeed : 1
        dataSaver = defaults.bool(forKey: "playback.dataSaver")
        adBlock = defaults.object(forKey: "web.adblock.enabled") as? Bool ?? true
        preferredLanguage = defaults.string(forKey: "playback.language") ?? "DE"
        preferredHoster = defaults.string(forKey: "playback.hoster") ?? "VOE"
        wifiOnlyDownloads = defaults.bool(forKey: "downloads.wifiOnly")
        heroAutoAdvance = defaults.object(forKey: "home.heroAutoAdvance") as? Bool ?? false
        startLandscape = defaults.object(forKey: "playback.startLandscape") as? Bool ?? true
    }
    /// A new default should win over the source each profile remembered last.
    private func forgetRememberedSources() {
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix("playback.preference.") { defaults.removeObject(forKey: key) }
    }
    /// A missing edition is a user decision; only another provider in that edition is automatic.
    func selection(in hosts: [StreamHost], remembered: [String: Any]?) -> SourceSelection {
        PlaybackSource.selection(in: hosts, name: remembered?["name"] as? String ?? preferredHoster,
                                 language: remembered?["language"] as? String ?? preferredLanguage)
    }
    func language(for profileID: UUID) -> String {
        let remembered = defaults.dictionary(forKey: "playback.preference." + profileID.uuidString)
        return remembered?["language"] as? String ?? preferredLanguage
    }
    nonisolated static func speedLabel(_ value: Double) -> String {
        value == 1 ? "Normal" : String(format: value == value.rounded() ? "%.0fx" : "%gx", value)
    }
}

/// iPhone browsing stays upright; only the player may rotate. iPad keeps every orientation.
@MainActor enum OrientationLock {
    static var mask: UIInterfaceOrientationMask = UIDevice.current.userInterfaceIdiom == .pad ? .all : .portrait
    static func allowRotation(_ allowed: Bool) {
        guard UIDevice.current.userInterfaceIdiom != .pad else { return }
        mask = allowed ? .allButUpsideDown : .portrait
        refresh(prefer: allowed ? nil : .portrait)
    }
    static func rotate(toLandscape landscape: Bool) {
        guard UIDevice.current.userInterfaceIdiom != .pad else { return }
        refresh(prefer: landscape ? .landscapeRight : .portrait)
    }
    private static func refresh(prefer orientation: UIInterfaceOrientationMask?) {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { return }
        var controller = scene.windows.first(where: \.isKeyWindow)?.rootViewController
        while let current = controller {
            current.setNeedsUpdateOfSupportedInterfaceOrientations()
            controller = current.presentedViewController
        }
        if let orientation { scene.requestGeometryUpdate(.iOS(interfaceOrientations: orientation)) { _ in } }
    }
}

// MARK: Settings screen
struct SettingsView: View {
    @EnvironmentObject private var library: LibraryStore
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var downloads = DownloadStore.shared
    @State private var confirm: Confirmation?
    @State private var notice: String?
    @State private var artworkBytes: Int64 = 0
    @State private var backupURL: URL?
    @State private var importing = false
    @State private var pendingImport: Data?
    private enum Confirmation: Identifiable {
        case downloads, history, progress
        var id: Int { hashValue }
    }
    var body: some View {
        LoungeScroll(title: "Einstellungen", largeTitle: true) {
            VStack(alignment: .leading, spacing: 26) {
                SettingsSection(title: "Wiedergabe") {
                    SettingsToggle(title: "Nächste Folge automatisch", subtitle: "Countdown am Ende jeder Folge", icon: "forward.end.fill", isOn: $settings.autoNext)
                    SettingsToggle(title: "Opening automatisch überspringen", subtitle: "Wenn AniSkip die Zeiten kennt", icon: "forward.fill", isOn: $settings.autoSkipOpening)
                    SettingsToggle(title: "Im Querformat starten", subtitle: "Folgen öffnen im Vollbild; drehen geht jederzeit", icon: "iphone.landscape", isOn: $settings.startLandscape)
                    SettingsPills(title: "Geschwindigkeit", icon: "speedometer", options: AppSettings.speeds, label: AppSettings.speedLabel, selection: $settings.speed)
                    SettingsToggle(title: "Datensparmodus", subtitle: "Begrenzt HLS-Streams auf etwa 720p", icon: "leaf.fill", isOn: $settings.dataSaver)
                }
                SettingsSection(title: "Quellen") {
                    SettingsPills(title: "Bevorzugte Sprache", icon: "character.bubble.fill", options: AppSettings.languages, label: { $0 }, selection: $settings.preferredLanguage)
                    SettingsPills(title: "Bevorzugter Anbieter", icon: "server.rack", options: AppSettings.hosters, label: { $0 }, selection: $settings.preferredHoster)
                    SettingsToggle(title: "Werbeblocker", subtitle: "Blockiert bekannte Werbeserver im Webplayer", icon: "shield.lefthalf.filled", isOn: $settings.adBlock)
                }
                SettingsSection(title: "Startseite") {
                    SettingsToggle(title: "Highlights automatisch wechseln", subtitle: nil, icon: "rectangle.stack.fill", isOn: $settings.heroAutoAdvance)
                }
                SettingsSection(title: "Downloads") {
                    SettingsToggle(title: "Nur über WLAN laden", subtitle: "Gilt für neue Downloads", icon: "wifi", isOn: $settings.wifiOnlyDownloads)
                    SettingsValue(title: "Belegter Speicher", icon: "internaldrive.fill", value: ByteCountFormatter.string(fromByteCount: downloads.usedBytes(profileID: library.profile.id), countStyle: .file))
                    SettingsButton(title: "Alle Downloads dieses Profils löschen", icon: "trash.fill", destructive: true) { confirm = .downloads }
                }
                SettingsSection(title: "Daten") {
                    SettingsValue(title: "Gespeicherte Bilder", icon: "photo.stack.fill",
                                  value: ByteCountFormatter.string(fromByteCount: artworkBytes, countStyle: .file) + " von 300 MB")
                    SettingsButton(title: "Bild-Cache leeren", icon: "trash") {
                        CoverLoader.clearCache(); URLCache.shared.removeAllCachedResponses()
                        artworkBytes = 0
                        withAnimation { notice = "Bild-Cache geleert" }
                    }
                    SettingsButton(title: "Verlauf löschen", icon: "clock.arrow.circlepath", destructive: true) { confirm = .history }
                    SettingsButton(title: "Fortschritt zurücksetzen", icon: "arrow.counterclockwise", destructive: true) { confirm = .progress }
                }
                SettingsSection(title: "Sicherung") {
                    if let backupURL {
                        ShareLink(item: backupURL) {
                            HStack(spacing: 12) {
                                Image(systemName: "square.and.arrow.up").font(.system(size: 16, weight: .medium)).foregroundColor(Theme.accentSoft)
                                    .frame(width: 28, height: 28)
                                Text("Sicherung teilen oder speichern").font(.subheadline.weight(.semibold))
                                Spacer()
                            }.padding(.horizontal, 14).padding(.vertical, 11).contentShape(Rectangle())
                        }.foregroundColor(.white)
                    } else {
                        SettingsButton(title: "Sicherung erstellen", icon: "externaldrive.fill.badge.plus") {
                            do { backupURL = try library.exportBackup() } catch { notice = "Sicherung fehlgeschlagen" }
                        }
                    }
                    SettingsButton(title: "Sicherung wiederherstellen", icon: "externaldrive.fill.badge.timemachine") { importing = true }
                }
                SettingsSection(title: "Hilfe") {
                    NavigationLink { DebugLogView() } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "ladybug").font(.system(size: 16, weight: .medium)).foregroundColor(Theme.accentSoft)
                                .frame(width: 28, height: 28)
                            Text("Diagnose-Protokoll").font(.subheadline.weight(.semibold))
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption.bold()).foregroundColor(Theme.muted)
                        }.padding(.horizontal, 14).padding(.vertical, 11).contentShape(Rectangle())
                    }.buttonStyle(LoungePressStyle()).foregroundColor(.white)
                }
                SettingsSection(title: "Info") {
                    SettingsValue(title: "Version", icon: "app.badge.fill", value: AppInfo.version)
                    SettingsValue(title: "Daten von", icon: "square.stack.3d.up.fill", value: "AniWorld · AniList · ani.zip · AniSkip")
                }
                if let notice {
                    Text(notice).font(.footnote.bold()).foregroundColor(Theme.accentSoft).frame(maxWidth: .infinity)
                        .task { try? await Task.sleep(nanoseconds: 2_000_000_000); withAnimation { self.notice = nil } }
                }
            }.padding(.horizontal, 20)
        } leading: {
            BackButton()
        }
        .task { artworkBytes = await Task.detached(priority: .utility) { ArtworkCache.shared.diskSize }.value }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            guard case .success(let url) = result else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            pendingImport = try? Data(contentsOf: url)
            if pendingImport == nil { notice = "Datei konnte nicht gelesen werden" }
        }
        .confirmationDialog("Sicherung wiederherstellen?", isPresented: Binding(get: { pendingImport != nil }, set: { if !$0 { pendingImport = nil } }), titleVisibility: .visible) {
            Button("Alles ersetzen", role: .destructive) {
                if let data = pendingImport {
                    do { try library.importBackup(data); ToastCenter.shared.show("Sicherung wiederhergestellt") }
                    catch { notice = "Keine gültige AniLounge-Sicherung" }
                }
                pendingImport = nil
            }
            Button("Abbrechen", role: .cancel) { pendingImport = nil }
        } message: {
            Text("Profile, Watchlists und Fortschritt auf diesem Gerät werden durch die Sicherung ersetzt. Downloads bleiben.")
        }
        .confirmationDialog(confirmTitle, isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }), titleVisibility: .visible) {
            Button("Löschen", role: .destructive) {
                switch confirm {
                case .downloads: downloads.deleteAll(profileID: library.profile.id)
                case .history: library.clearHistory()
                case .progress: library.resetProgress()
                case nil: break
                }
                confirm = nil
            }
            Button("Abbrechen", role: .cancel) { confirm = nil }
        }
    }
    private var confirmTitle: String {
        switch confirm {
        case .downloads: return "Alle Downloads von „\(library.profile.name)“ löschen?"
        case .history: return "Verlauf von „\(library.profile.name)“ löschen?"
        case .progress: return "Fortschritt und Gesehen-Markierungen von „\(library.profile.name)“ zurücksetzen?"
        case nil: return ""
        }
    }
}
enum AppInfo {
    static var version: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(short) (\(build))"
    }
}
struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased()).font(.caption.bold()).tracking(1.2).foregroundColor(Theme.muted).padding(.leading, 4)
            VStack(alignment: .leading, spacing: 0) { content }
                .glassCard()
        }
    }
}
private struct SettingsIcon: View {
    let name: String
    var tint: Color = Theme.accent
    var body: some View {
        // Plain, consistent symbols; colour only marks destructive rows.
        Image(systemName: name).font(.system(size: 16, weight: .medium))
            .foregroundColor(tint == Theme.accent || tint == Theme.panelHigh ? Theme.accentSoft : tint)
            .frame(width: 28, height: 28)
    }
}
struct SettingsToggle: View {
    let title: String
    let subtitle: String?
    let icon: String
    @Binding var isOn: Bool
    var body: some View {
        Toggle(isOn: $isOn) {
            HStack(spacing: 12) {
                SettingsIcon(name: icon)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.subheadline.weight(.semibold))
                    if let subtitle { Text(subtitle).font(.caption).foregroundColor(Theme.muted) }
                }
            }
        }.tint(Theme.accent).padding(.horizontal, 14).padding(.vertical, 11)
    }
}
struct SettingsPills<Value: Hashable>: View {
    let title: String
    let icon: String
    let options: [Value]
    let label: (Value) -> String
    @Binding var selection: Value
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) { SettingsIcon(name: icon); Text(title).font(.subheadline.weight(.semibold)) }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(options, id: \.self) { option in
                        Button {
                            UISelectionFeedbackGenerator().selectionChanged()
                            withAnimation(.easeInOut(duration: 0.15)) { selection = option }
                        } label: {
                            Text(label(option)).font(.footnote.bold()).padding(.horizontal, 14).padding(.vertical, 8)
                                .background(option == selection ? AnyShapeStyle(Color.white) : AnyShapeStyle(Theme.panelHigh))
                                .foregroundColor(option == selection ? .black : .white).clipShape(Capsule())
                        }.buttonStyle(LoungePressStyle())
                    }
                }
            }
        }.padding(.horizontal, 14).padding(.vertical, 11)
    }
}
struct SettingsValue: View {
    let title: String
    let icon: String
    let value: String
    var body: some View {
        HStack(spacing: 12) {
            SettingsIcon(name: icon, tint: Theme.panelHigh)
            Text(title).font(.subheadline.weight(.semibold))
            Spacer(minLength: 8)
            Text(value).font(.footnote).foregroundColor(Theme.muted).multilineTextAlignment(.trailing).lineLimit(2)
        }.padding(.horizontal, 14).padding(.vertical, 11)
    }
}
struct SettingsButton: View {
    let title: String
    let icon: String
    var destructive = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                SettingsIcon(name: icon, tint: destructive ? .red.opacity(0.8) : Theme.panelHigh)
                Text(title).font(.subheadline.weight(.semibold)).foregroundColor(destructive ? Color(red: 1, green: 0.45, blue: 0.45) : .white)
                Spacer()
            }.padding(.horizontal, 14).padding(.vertical, 11).contentShape(Rectangle())
        }.buttonStyle(LoungePressStyle())
    }
}

// MARK: History
struct HistoryView: View {
    @EnvironmentObject private var library: LibraryStore
    @State private var confirmClear = false
    var body: some View {
        LoungeScroll(title: "Verlauf", largeTitle: true) {
            LazyVStack(alignment: .leading, spacing: 14) {
                if library.history.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "clock").font(.system(size: 40)).foregroundColor(Theme.accent)
                        Text("Noch nichts angesehen").font(.headline)
                        Text("Geöffnete Folgen erscheinen hier.").font(.subheadline).foregroundColor(Theme.muted)
                    }.frame(maxWidth: .infinity).padding(.top, 60)
                }
                ForEach(library.history) { entry in
                    NavigationLink { DetailView(anime: entry.anime, resumeEpisode: entry.episode) } label: {
                        HStack(spacing: 14) {
                            WideArtwork(anime: entry.anime).frame(width: 128, height: 72).clipShape(RoundedRectangle(cornerRadius: 8))
                                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.stroke))
                            VStack(alignment: .leading, spacing: 4) {
                                Text(entry.anime.title).font(.subheadline.bold()).lineLimit(2).multilineTextAlignment(.leading)
                                Text("Folge \(entry.episode.number) · " + entry.openedAt.formatted(.relative(presentation: .named)))
                                    .font(.caption).foregroundColor(Theme.muted)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right").font(.caption.bold()).foregroundColor(Theme.muted)
                        }.contentShape(Rectangle())
                    }.buttonStyle(LoungePressStyle()).foregroundColor(.white)
                }
            }.padding(.horizontal, 20)
        } leading: {
            BackButton()
        } trailing: {
            if !library.history.isEmpty {
                Button { confirmClear = true } label: { CircleIcon(systemName: "trash") }.buttonStyle(LoungePressStyle()).accessibilityLabel("Verlauf löschen")
            }
        }
        .confirmationDialog("Verlauf löschen?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Löschen", role: .destructive) { library.clearHistory() }
        }
    }
}
