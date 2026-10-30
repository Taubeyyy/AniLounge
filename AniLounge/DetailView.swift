import SwiftUI

import AniCore

struct DetailView: View {
    let anime: Anime
    var resumeEpisode: Episode? = nil
    @EnvironmentObject private var library: LibraryStore
    @State private var detail: AnimeDetail?
    @State private var episodes: [Episode] = []
    @State private var selectedSeason = ""
    @State private var error: String?
    @State private var episodeError: String?
    @State private var loadingEpisodes = false
    @State private var playback: PlaybackRequest?
    @State private var editingProgress: Episode?
    @State private var expanded = false
    private var currentAnime: Anime { detail?.anime ?? anime }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                ZStack(alignment: .bottomLeading) {
                    Artwork(url: detail?.backdrop ?? currentAnime.poster)
                    LinearGradient(colors: [.clear, Theme.background], startPoint: .top, endPoint: .bottom)
                    Text(currentAnime.title).font(.system(size: 32, weight: .heavy, design: .rounded)).padding(20)
                }.frame(height: 320).clipped()
                if let detail {
                    detailContent(detail)
                } else if let error {
                    ProblemView(message: error) { Task { await loadDetail() } }
                } else { ProgressView("Anime wird geladen …").frame(maxWidth: .infinity).padding(32) }
            }.padding(.bottom, 30)
        }
        .background(Theme.background).navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                if let url = AniURL.page(anime.path) { ShareLink(item: url).tint(.white) }
            }
        }
        .task { if detail == nil { await loadDetail() } }
        .task(id: selectedSeason) { if !selectedSeason.isEmpty { await loadSeason(selectedSeason) } }
        .sheet(item: $playback) { request in PlaybackView(request: request, library: library) }
        .sheet(item: $editingProgress) { episode in ProgressEditor(anime: currentAnime, episode: episode, profileID: library.profile.id).environmentObject(library) }
    }
    private func detailContent(_ detail: AnimeDetail) -> some View {
        VStack(alignment: .leading, spacing: 22) {
            Text(([detail.year] + detail.genres.prefix(3)).filter { !$0.isEmpty }.joined(separator: "  ·  "))
                .font(.caption).foregroundColor(.secondary)
            if let progress = library.active.latest(for: currentAnime), !progress.completed, progress.seconds > 0 {
                Button { open(progress.episode) } label: {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Weiterschauen · Folge \(progress.episode.number)", systemImage: "play.fill").font(.headline)
                        Text("Gemerkte Position: \(progress.timeLabel)").font(.caption)
                        if let fraction = progress.fraction { ProgressView(value: fraction).tint(.white) }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
                }.background(Theme.accent).foregroundColor(.white).cornerRadius(12)
            }
            HStack(spacing: 12) {
                if let first = episodes.first, !loadingEpisodes {
                    Button { open(first) } label: {
                        Label("Folge \(first.number) öffnen", systemImage: "play.fill").font(.subheadline.bold()).frame(maxWidth: .infinity).padding(.vertical, 14)
                    }.background(Theme.accent).foregroundColor(.white).cornerRadius(8)
                }
                Button { library.toggle(currentAnime) } label: {
                    Label(library.contains(currentAnime) ? "Gemerkt" : "Watchlist", systemImage: library.contains(currentAnime) ? "checkmark" : "plus")
                        .font(.subheadline.bold()).frame(maxWidth: .infinity).padding(.vertical, 14)
                }.background(Theme.panel).foregroundColor(.white).cornerRadius(8)
            }
            if !detail.synopsis.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text(detail.synopsis).font(.subheadline).foregroundColor(.white.opacity(0.8)).lineSpacing(5).lineLimit(expanded ? nil : 4)
                    Button(expanded ? "Weniger anzeigen" : "Mehr anzeigen") { expanded.toggle() }.font(.caption.bold()).tint(.white)
                }
            }
            HStack {
                Text("Episoden").font(.title2.bold())
                Spacer()
                if !detail.seasons.isEmpty {
                    Picker("Staffel", selection: $selectedSeason) {
                        ForEach(detail.seasons) { season in Text(season.title).tag(season.path) }
                    }.pickerStyle(.menu).tint(.white)
                }
            }
            Text("Positionen werden bei unterstützten Videos automatisch gespeichert. Du kannst sie auch manuell eintragen.").font(.caption).foregroundColor(.secondary)
            if loadingEpisodes {
                ProgressView("Folgen laden …").frame(maxWidth: .infinity).padding()
            } else if let episodeError {
                ProblemView(message: episodeError) { Task { await loadSeason(selectedSeason) } }
            } else if episodes.isEmpty {
                Text("Für diese Auswahl sind noch keine Folgen verfügbar.").foregroundColor(.secondary).padding(.vertical)
            } else {
                LazyVStack(spacing: 12) {
                    ForEach(episodes) { episode in
                        HStack(spacing: 12) {
                            Button { open(episode) } label: {
                                HStack(spacing: 14) {
                                    Text(episode.number).font(.title3.bold()).foregroundColor(.secondary).frame(width: 30)
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text(episode.title).font(.subheadline.bold()).foregroundColor(.white).multilineTextAlignment(.leading)
                                        Text(episode.languages.joined(separator: " · ")).font(.caption2).foregroundColor(.secondary).lineLimit(2)
                                        if let progress = library.progress(for: episode), !progress.completed, progress.seconds > 0 {
                                            Text("Bis \(progress.timeLabel) geschaut").font(.caption).foregroundColor(Theme.accent)
                                            if let fraction = progress.fraction { ProgressView(value: fraction).tint(Theme.accent) }
                                        }
                                    }
                                    Spacer(minLength: 0)
                                    Image(systemName: "play.circle").font(.title2).foregroundColor(.white)
                                }
                            }.buttonStyle(.plain)
                            Menu {
                                Button { editingProgress = episode } label: { Label("Fortschritt bearbeiten", systemImage: "clock") }
                                Button { library.toggleWatched(episode, anime: currentAnime) } label: {
                                    Label(library.watched.contains(episode.id) ? "Als ungesehen markieren" : "Als gesehen markieren", systemImage: "checkmark.circle")
                                }
                            } label: {
                                Image(systemName: library.watched.contains(episode.id) ? "checkmark.circle.fill" : "circle")
                                    .foregroundColor(library.watched.contains(episode.id) ? Theme.accent : .secondary)
                                    .frame(width: 36, height: 44)
                            }.accessibilityLabel("Fortschritt für Folge \(episode.number)")
                        }.padding(14).background(Theme.panel).cornerRadius(10)
                    }
                }
            }
        }.padding(.horizontal, 20)
    }
    private func loadDetail() async {
        error = nil
        do {
            let loaded = try await AniClient.shared.detail(path: anime.path)
            guard !Task.isCancelled else { return }
            detail = loaded; episodes = loaded.episodes
            let remembered = resumeEpisode ?? library.active.latest(for: anime)?.episode ?? library.history.first(where: { $0.id == anime.id })?.episode
            selectedSeason = loaded.seasons.first(where: { remembered?.path.hasPrefix($0.path + "/") == true })?.path
                ?? loaded.seasons.first(where: { loaded.episodes.first?.path.hasPrefix($0.path + "/") == true })?.path ?? loaded.seasons.first?.path ?? ""
        } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
    }
    private func loadSeason(_ path: String) async {
        guard !path.isEmpty else { return }
        loadingEpisodes = true; episodeError = nil; episodes = []
        do {
            let loaded = try await AniClient.shared.detail(path: path)
            guard !Task.isCancelled, selectedSeason == path else { return }
            episodes = loaded.episodes; loadingEpisodes = false
        } catch {
            guard !Task.isCancelled, selectedSeason == path else { return }
            episodeError = error.localizedDescription; loadingEpisodes = false
        }
    }
    private func open(_ episode: Episode) {
        guard AniURL.page(episode.path) != nil else { return }
        library.opened(episode, anime: currentAnime)
        playback = PlaybackRequest(anime: currentAnime, episode: episode, profileID: library.profile.id)
    }
}
