import SwiftUI
import AniCore

struct DownloadsView: View {
    @EnvironmentObject private var library: LibraryStore
    @ObservedObject private var downloads = DownloadStore.shared
    @State private var playback: PlaybackRequest?
    @State private var deleting: EpisodeDownload?
    private var entries: [EpisodeDownload] { downloads.items.filter { $0.profileID == library.profile.id } }
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Deine Folgen. Überall.").font(.largeTitle.bold())
                    Text("Downloads laufen über WLAN. Starte eine Folge und tippe unter dem nativen Player auf Herunterladen.").font(.subheadline).foregroundColor(.secondary)
                }.padding(.vertical, 12)
                if entries.isEmpty {
                    VStack(spacing: 14) {
                        Image(systemName: "arrow.down.circle").font(.system(size: 52)).foregroundStyle(Theme.accent.gradient)
                        Text("Noch keine Downloads").font(.headline)
                        Text("Fertige Folgen kannst du hier auch ohne Internet ansehen.").font(.subheadline).foregroundColor(.secondary).multilineTextAlignment(.center)
                    }.frame(maxWidth: .infinity).padding(30).loungeCard()
                }
                ForEach(entries) { entry in
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .top) {
                            Image(systemName: entry.state == .ready ? "play.rectangle.fill" : "arrow.down.circle.fill").font(.title).foregroundColor(Theme.accent)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(entry.anime.title).font(.headline)
                                Text("Folge \(entry.episode.number) · \(entry.episode.title)").font(.subheadline).lineLimit(2)
                                Text(entry.source + (entry.isHLS ? " · HLS" : " · MP4")).font(.caption).foregroundColor(.secondary)
                            }
                            Spacer(minLength: 0)
                        }
                        if entry.state == .downloading {
                            ProgressView(value: entry.progress).tint(Theme.accent)
                            HStack {
                                Text(entry.progress > 0 ? "\(Int(entry.progress * 100)) %" : "Wartet auf WLAN / Quelle …")
                                Spacer()
                                if entry.bytes > 0 { Text(ByteCountFormatter.string(fromByteCount: entry.bytes, countStyle: .file)) }
                                Button("Abbrechen") { downloads.cancel(entry.id) }
                            }.font(.caption.monospacedDigit())
                        } else if entry.state == .checking {
                            HStack { ProgressView(); Text("Offline-Datei wird geprüft …"); Spacer(); Button("Abbrechen") { downloads.cancel(entry.id) } }.font(.caption)
                        } else {
                            if let message = entry.message { Text(message).font(.caption).foregroundColor(.secondary) }
                            HStack {
                                if let url = downloads.localURL(for: entry) {
                                    Button { playback = PlaybackRequest(anime: entry.anime, episode: entry.episode, profileID: entry.profileID, localURL: url) } label: { Label("Offline abspielen", systemImage: "play.fill") }.buttonStyle(.borderedProminent)
                                } else {
                                    Button("Online öffnen / erneut laden") { playback = PlaybackRequest(anime: entry.anime, episode: entry.episode, profileID: entry.profileID) }.buttonStyle(.bordered)
                                }
                                Spacer()
                                Button(role: .destructive) { deleting = entry } label: { Image(systemName: "trash") }.accessibilityLabel("Download löschen")
                            }.font(.caption.bold())
                        }
                    }.padding(18).loungeCard()
                }
                Text("MP4 und geeignete HLS-Streams. Nicht jede Quelle unterstützt Offline-Speicherung. Nach erzwungenem Beenden der App können Downloads abbrechen.").font(.caption).foregroundColor(.secondary).padding(.vertical)
            }.padding(20)
        }.background(Theme.background).navigationTitle("Downloads").navigationBarTitleDisplayMode(.inline)
            .task { downloads.start() }
            .fullScreenCover(item: $playback) { PlaybackView(request: $0, library: library) }
            .confirmationDialog("Download löschen?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
                Button("Vom Gerät löschen", role: .destructive) { if let entry = deleting { downloads.delete(entry.id) }; deleting = nil }
                Button("Abbrechen", role: .cancel) { deleting = nil }
            }
            .alert("Download-Speicher", isPresented: Binding(get: { downloads.storageError != nil }, set: { if !$0 { downloads.storageError = nil } })) { Button("OK", role: .cancel) {} } message: { Text(downloads.storageError ?? "") }
    }
}
