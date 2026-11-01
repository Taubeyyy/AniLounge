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
                    Artwork(url: detail?.backdrop ?? currentAnime.poster).blur(radius: detail?.backdrop == nil ? 18 : 0)
                    LinearGradient(colors: [Theme.background.opacity(0.4), .clear, Theme.background.opacity(0.7), Theme.background], startPoint: .top, endPoint: .bottom)
                    HStack(alignment: .bottom, spacing: 16) {
                        AnimeArtwork(anime: currentAnime).frame(width: 104, height: 156).clipShape(RoundedRectangle(cornerRadius: 12))
                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.stroke)).shadow(color: .black.opacity(0.5), radius: 16, y: 8)
                        VStack(alignment: .leading, spacing: 8) {
                            Text(currentAnime.title).font(.system(size: 26, weight: .heavy, design: .rounded)).lineLimit(3).minimumScaleFactor(0.75)
                            if let detail {
                                Text(([detail.year] + detail.genres.prefix(3)).filter { !$0.isEmpty }.joined(separator: " · "))
                                    .font(.caption.weight(.semibold)).foregroundColor(Theme.muted).lineLimit(2)
                            }
                        }
                    }.padding(.horizontal, 20).padding(.bottom, 8)
                }.frame(height: 340).clipped()
                if let detail {
                    detailContent(detail)
                } else if let error {
                    ProblemView(message: error) { Task { await loadDetail() } }
                } else { ProgressView("Anime wird geladen …").frame(maxWidth: .infinity).padding(32) }
            }.padding(.bottom, 30)
        }
        .background(Theme.background.ignoresSafeArea()).navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .task { if detail == nil { await loadDetail() } }
        .task(id: selectedSeason) { if !selectedSeason.isEmpty { await loadSeason(selectedSeason) } }
        .fullScreenCover(item: $playback) { request in PlaybackView(request: request, library: library) }
        .sheet(item: $editingProgress) { episode in ProgressEditor(anime: currentAnime, episode: episode, profileID: library.profile.id).environmentObject(library) }
    }
    private func detailContent(_ detail: AnimeDetail) -> some View {
        VStack(alignment: .leading, spacing: 22) {
            if let action = primaryAction {
                Button { open(action.episode) } label: {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Image(systemName: "play.fill")
                            Text(action.title).font(.headline)
                            Spacer()
                            if let label = action.detail { Text(label).font(.caption.monospacedDigit()).opacity(0.75) }
                        }
                        if let fraction = action.fraction {
                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(.black.opacity(0.15))
                                    Capsule().fill(Theme.accent).frame(width: geo.size.width * CGFloat(fraction))
                                }
                            }.frame(height: 4)
                        }
                    }.padding(.horizontal, 18).padding(.vertical, 15).frame(maxWidth: .infinity)
                        .background(Color.white).foregroundColor(.black).clipShape(RoundedRectangle(cornerRadius: 14))
                }.buttonStyle(LoungePressStyle())
            }
            HStack(spacing: 10) {
                Button { UIImpactFeedbackGenerator(style: .light).impactOccurred(); library.toggle(currentAnime) } label: {
                    Label(library.contains(currentAnime) ? "Gemerkt" : "Watchlist", systemImage: library.contains(currentAnime) ? "checkmark" : "plus")
                        .font(.subheadline.bold()).frame(maxWidth: .infinity).padding(.vertical, 13).loungeCard()
                }.buttonStyle(LoungePressStyle()).foregroundColor(.white)
                if let url = AniURL.page(anime.path) {
                    ShareLink(item: url) {
                        Label("Teilen", systemImage: "square.and.arrow.up").font(.subheadline.bold()).frame(maxWidth: .infinity).padding(.vertical, 13).loungeCard()
                    }.foregroundColor(.white)
                }
            }
            if !detail.synopsis.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text(detail.synopsis).font(.subheadline).foregroundColor(.white.opacity(0.8)).lineSpacing(5).lineLimit(expanded ? nil : 4)
                    Button(expanded ? "Weniger anzeigen" : "Mehr anzeigen") { expanded.toggle() }.font(.caption.bold()).tint(.white)
                }
            }
            HStack {
                Text("Episoden").font(.system(.title2, design: .rounded).bold())
                Spacer()
                if !detail.seasons.isEmpty {
                    Menu {
                        ForEach(detail.seasons) { season in
                            Button(season.title) { selectedSeason = season.path }
                        }
                    } label: {
                        HStack(spacing: 8) {
                            Text(detail.seasons.first(where: { $0.path == selectedSeason })?.title ?? "Staffel")
                            Image(systemName: "chevron.down").font(.caption.bold())
                        }.font(.subheadline.bold()).padding(.horizontal, 16).padding(.vertical, 10).loungeCard()
                    }.tint(Theme.accent)
                }
            }
            if loadingEpisodes {
                ProgressView("Folgen laden …").frame(maxWidth: .infinity).padding()
            } else if let episodeError {
                ProblemView(message: episodeError) { Task { await loadSeason(selectedSeason) } }
            } else if episodes.isEmpty {
                Text("Für diese Auswahl sind noch keine Folgen verfügbar.").foregroundColor(.secondary).padding(.vertical)
            } else {
                LazyVStack(spacing: 10) {
                    ForEach(episodes) { episode in
                        let seen = library.watched.contains(episode.id)
                        let current = primaryAction?.episode.id == episode.id
                        HStack(spacing: 12) {
                            Button { open(episode) } label: {
                                HStack(spacing: 14) {
                                    ZStack {
                                        RoundedRectangle(cornerRadius: 12).fill(current ? AnyShapeStyle(Theme.accentGradient) : AnyShapeStyle(Theme.panelHigh))
                                        if current { Image(systemName: "play.fill").font(.subheadline) }
                                        else { Text(episode.number).font(.system(.headline, design: .rounded).bold()).foregroundColor(seen ? Theme.muted : .white) }
                                    }.frame(width: 46, height: 46)
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(episode.title).font(.subheadline.bold()).foregroundColor(seen ? Theme.muted : .white).multilineTextAlignment(.leading).lineLimit(2)
                                        Text(episode.languages.joined(separator: " · ")).font(.caption2).foregroundColor(Theme.muted).lineLimit(1)
                                        if let progress = library.progress(for: episode), !progress.completed, progress.seconds > 0 {
                                            HStack(spacing: 8) {
                                                if let fraction = progress.fraction { ProgressView(value: fraction).tint(Theme.accent) }
                                                Text(progress.timeLabel).font(.caption2.monospacedDigit()).foregroundColor(Theme.accentSoft)
                                            }
                                        }
                                    }
                                    Spacer(minLength: 0)
                                }.contentShape(Rectangle())
                            }.buttonStyle(LoungePressStyle())
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
                        }.padding(10).loungeCard()
                            .overlay(RoundedRectangle(cornerRadius: 22).stroke(current ? Theme.accent.opacity(0.5) : .clear))
                    }
                }
            }
        }.padding(.horizontal, 20)
    }
    /// Netflix-style main button: resume, next unwatched episode, or start from the beginning.
    private var primaryAction: (episode: Episode, title: String, detail: String?, fraction: Double?)? {
        if let progress = library.active.latest(for: currentAnime) {
            if !progress.completed, progress.seconds > 0 {
                return (progress.episode, "Weiterschauen · Folge \(progress.episode.number)", progress.timeLabel, progress.fraction)
            }
            if let index = episodes.firstIndex(where: { $0.id == progress.episode.id }), episodes.indices.contains(index + 1) {
                let next = episodes[index + 1]
                return (next, "Folge \(next.number) ansehen", "Als Nächstes", nil)
            }
        }
        guard !loadingEpisodes else { return nil }
        if let next = episodes.first(where: { !library.watched.contains($0.id) }), next.id != episodes.first?.id {
            return (next, "Folge \(next.number) ansehen", "Als Nächstes", nil)
        }
        guard let first = episodes.first else { return nil }
        return (first, "Folge \(first.number) abspielen", nil, nil)
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

