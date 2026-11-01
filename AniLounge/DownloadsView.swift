import SwiftUI
import AniCore

struct DownloadsView: View {
    @EnvironmentObject private var library: LibraryStore
    @ObservedObject private var downloads = DownloadStore.shared
    @State private var playback: PlaybackRequest?
    @State private var actionsFor: EpisodeDownload?
    @State private var deleting: EpisodeDownload?
    private var entries: [EpisodeDownload] { downloads.items.filter { $0.profileID == library.profile.id } }
    private var ready: Int { entries.filter { downloads.localURL(for: $0) != nil }.count }
    var body: some View {
        LoungeScroll(title: "Downloads", largeTitle: true) {
            LazyVStack(alignment: .leading, spacing: 16) {
                if entries.isEmpty {
                    VStack(spacing: 14) {
                        Image(systemName: "arrow.down.to.line.circle").font(.system(size: 56, weight: .light)).foregroundStyle(Theme.accent.gradient)
                        Text("Noch keine Downloads").font(.title3.bold())
                        Text("Starte eine Folge und tippe im Player auf „Download“. Fertige Folgen laufen hier auch ohne Internet.")
                            .font(.subheadline).foregroundColor(Theme.muted).multilineTextAlignment(.center)
                    }.frame(maxWidth: .infinity).padding(.horizontal, 30).padding(.top, 70)
                } else {
                    HStack(spacing: 8) {
                        Chip(text: "\(ready) offline bereit", icon: "checkmark.circle.fill")
                        Chip(text: ByteCountFormatter.string(fromByteCount: downloads.usedBytes(profileID: library.profile.id), countStyle: .file), icon: "internaldrive")
                    }
                    ForEach(entries) { entry in row(entry) }
                    Text("MP4 und geeignete HLS-Streams. Nicht jede Quelle erlaubt Downloads. Nach erzwungenem Beenden der App können laufende Downloads abbrechen.")
                        .font(.caption).foregroundColor(Theme.muted).padding(.top, 8)
                }
            }.padding(.horizontal, 20)
        }
        .task { downloads.start() }
        .fullScreenCover(item: $playback) { PlaybackView(request: $0, library: library) }
        .loungeSheet(isPresented: Binding(get: { actionsFor != nil }, set: { if !$0 { actionsFor = nil } }), height: 260) {
            if let entry = actionsFor { actions(entry) }
        }
        .confirmationDialog("Download löschen?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button("Vom Gerät löschen", role: .destructive) { if let entry = deleting { downloads.delete(entry.id) }; deleting = nil }
            Button("Abbrechen", role: .cancel) { deleting = nil }
        }
        .alert("Download-Speicher", isPresented: Binding(get: { downloads.storageError != nil }, set: { if !$0 { downloads.storageError = nil } })) { Button("OK", role: .cancel) {} } message: { Text(downloads.storageError ?? "") }
    }
    private func row(_ entry: EpisodeDownload) -> some View {
        let local = downloads.localURL(for: entry)
        return HStack(spacing: 14) {
            Button { open(entry) } label: {
                HStack(spacing: 14) {
                    ZStack {
                        WideArtwork(anime: entry.anime).opacity(local == nil ? 0.55 : 1)
                        switch entry.state {
                        case .downloading:
                            ProgressRing(value: entry.progress).frame(width: 34, height: 34)
                        case .checking:
                            ProgressView().tint(.white)
                        case .ready where local != nil:
                            Image(systemName: "play.fill").font(.caption).frame(width: 30, height: 30)
                                .background(.black.opacity(0.45)).clipShape(Circle()).overlay(Circle().stroke(.white.opacity(0.5)))
                        default:
                            Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
                        }
                    }.frame(width: 128, height: 72).clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.stroke))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(entry.anime.title).font(.caption.bold()).foregroundColor(Theme.accentSoft).lineLimit(1)
                        Text("Folge \(entry.episode.number) · \(entry.episode.title)").font(.subheadline.bold()).lineLimit(2).multilineTextAlignment(.leading)
                        Text(status(entry, local: local)).font(.caption.monospacedDigit()).foregroundColor(Theme.muted).lineLimit(2)
                    }
                    Spacer(minLength: 0)
                }.contentShape(Rectangle())
            }.buttonStyle(LoungePressStyle()).foregroundColor(.white)
            Button { actionsFor = entry } label: {
                Image(systemName: "ellipsis").font(.body.weight(.bold)).foregroundColor(Theme.muted).frame(width: 30, height: 44).contentShape(Rectangle())
            }.accessibilityLabel("Optionen")
        }
    }
    private func status(_ entry: EpisodeDownload, local: URL?) -> String {
        switch entry.state {
        case .downloading:
            let size = entry.bytes > 0 ? " · " + ByteCountFormatter.string(fromByteCount: entry.bytes, countStyle: .file) : ""
            return entry.progress > 0 ? "\(Int(entry.progress * 100)) %" + size : "Verbindung zur Quelle …"
        case .checking: return "Offline-Datei wird geprüft …"
        case .ready where local != nil: return "Offline bereit · " + entry.source
        default: return entry.message ?? "Nicht verfügbar"
        }
    }
    private func open(_ entry: EpisodeDownload) {
        if let url = downloads.localURL(for: entry) {
            playback = PlaybackRequest(anime: entry.anime, episode: entry.episode, profileID: entry.profileID, localURL: url)
        } else if entry.state == .downloading || entry.state == .checking {
            actionsFor = entry
        } else {
            playback = PlaybackRequest(anime: entry.anime, episode: entry.episode, profileID: entry.profileID)
        }
    }
    private func actions(_ entry: EpisodeDownload) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Folge \(entry.episode.number) · \(entry.anime.title)").font(.headline).lineLimit(1).padding(.horizontal, 20).padding(.bottom, 8)
            if downloads.localURL(for: entry) != nil {
                SheetRow(title: "Offline abspielen", icon: "play.fill") { actionsFor = nil; open(entry) }
            } else {
                SheetRow(title: "Online öffnen", icon: "globe") {
                    actionsFor = nil; playback = PlaybackRequest(anime: entry.anime, episode: entry.episode, profileID: entry.profileID)
                }
            }
            if entry.state == .downloading || entry.state == .checking {
                SheetRow(title: "Download abbrechen", icon: "xmark") { actionsFor = nil; downloads.cancel(entry.id) }
            }
            SheetRow(title: "Vom Gerät löschen", icon: "trash", role: .destructive) {
                actionsFor = nil
                Task { try? await Task.sleep(nanoseconds: 350_000_000); deleting = entry }
            }
        }
    }
}
struct ProgressRing: View {
    let value: Double
    var body: some View {
        ZStack {
            Circle().fill(.black.opacity(0.45))
            Circle().stroke(.white.opacity(0.25), lineWidth: 3)
            Circle().trim(from: 0, to: CGFloat(max(0.02, min(1, value)))).stroke(Theme.accent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90)).animation(.easeOut(duration: 0.3), value: value)
            Image(systemName: "arrow.down").font(.caption2.bold())
        }
    }
}
