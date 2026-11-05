import SwiftUI
import AniCore

struct DetailView: View {
    let anime: Anime
    var resumeEpisode: Episode? = nil
    @EnvironmentObject private var library: LibraryStore
    @ObservedObject private var catalogs = SeriesCatalogStore.shared
    @State private var continuationError: String?
    @State private var detail: AnimeDetail?
    @State private var episodes: [Episode] = []
    @State private var selectedSeason = ""
    @State private var error: String?
    @State private var episodeError: String?
    @State private var loadingEpisodes = false
    @State private var editingProgress: Episode?
    @State private var actionsFor: Episode?
    @State private var expanded = false
    @State private var extras: AnimeExtras?
    @State private var episodeExtras: [String: EpisodeExtras] = [:]
    @State private var similar: [Anime] = []
    private var currentAnime: Anime { detail?.anime ?? anime }
    var body: some View {
        LoungeScroll(title: currentAnime.title, underBar: true, threshold: 300) {
            VStack(alignment: .leading, spacing: 0) {
                header
                if let detail {
                    detailContent(detail)
                    if !similar.isEmpty { AnimeShelf(title: "Ähnliche Anime", items: similar).padding(.top, 34) }
                } else if let error {
                    ProblemView(message: error) { Task { await loadDetail() } }
                } else { ProgressView().tint(Theme.accent).frame(maxWidth: .infinity).padding(40) }
            }
        } leading: {
            BackButton()
        } trailing: {
            if let url = AniURL.page(anime.path) {
                ShareLink(item: url) { CircleIcon(systemName: "square.and.arrow.up") }.accessibilityLabel("Teilen")
            }
        }
        .task { if detail == nil { await loadDetail() } }
        .task(id: selectedSeason) { if !selectedSeason.isEmpty { await loadSeason(selectedSeason) } }
        .task(id: detail?.imdb) { await loadExtras() }
        .task(id: continuationKey) { if detail != nil { await resolveContinuation() } }
        .task(id: (detail?.imdb ?? "") + selectedSeason) { await loadEpisodeExtras() }
        .sheet(item: $editingProgress) { episode in ProgressEditor(anime: currentAnime, episode: episode, profileID: library.profile.id).environmentObject(library) }
        .loungeSheet(isPresented: Binding(get: { actionsFor != nil }, set: { if !$0 { actionsFor = nil } }), height: 250) {
            if let episode = actionsFor { episodeActions(episode) }
        }
    }

    // MARK: Header
    /// Stretches when pulled down, like streaming apps; scrolls normally otherwise.
    private var header: some View {
        GeometryReader { geo in
            let pull = max(0, geo.frame(in: .named("lounge.scroll")).minY)
            headerContent.frame(width: geo.size.width, height: 420 + pull).clipped().offset(y: -pull)
        }.frame(height: 420)
    }
    private var headerContent: some View {
        ZStack(alignment: .bottomLeading) {
            // AniWorld's backdrop fits the tall header; AniList banners are a fallback.
            Artwork(url: detail?.backdrop ?? extras?.banner ?? currentAnime.poster)
                .blur(radius: detail?.backdrop == nil && extras?.banner == nil ? 20 : 0)
            LinearGradient(stops: [.init(color: .black.opacity(0.45), location: 0), .init(color: .clear, location: 0.3),
                                   .init(color: Theme.background.opacity(0.75), location: 0.7), .init(color: Theme.background, location: 1)],
                           startPoint: .top, endPoint: .bottom)
            HStack(alignment: .bottom, spacing: 16) {
                Group { if let cover = extras?.cover { Artwork(url: cover) } else { AnimeArtwork(anime: currentAnime) } }
                    .frame(width: 100, height: 150).clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.stroke)).shadow(color: .black.opacity(0.5), radius: 16, y: 8)
                VStack(alignment: .leading, spacing: 8) {
                    Text(currentAnime.title).font(.system(size: 26, weight: .heavy, design: .rounded)).lineLimit(3).minimumScaleFactor(0.7)
                    if let extras { ExtrasBadges(extras: extras) }
                    if let detail {
                        Text(([detail.year] + detail.genres.prefix(3)).filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.caption.weight(.semibold)).foregroundColor(Theme.muted).lineLimit(2)
                    }
                }
            }.padding(.horizontal, 20).padding(.bottom, 4)
        }
    }

    // MARK: Content
    private func detailContent(_ detail: AnimeDetail) -> some View {
        VStack(alignment: .leading, spacing: 24) {
            if let action = primaryAction {
                Button { open(action.episode) } label: {
                    VStack(spacing: 9) {
                        HStack(spacing: 10) {
                            Image(systemName: "play.fill")
                            Text(action.title).font(.headline).lineLimit(1)
                        }.frame(maxWidth: .infinity)
                        if let fraction = action.fraction {
                            HStack(spacing: 10) {
                                ProgressBar(value: fraction, track: .black.opacity(0.12))
                                if let label = action.detail { Text(label).font(.caption2.monospacedDigit()).opacity(0.65) }
                            }
                        }
                    }.padding(.horizontal, 18).padding(.vertical, 14)
                        .background(Color.white).foregroundColor(.black).clipShape(RoundedRectangle(cornerRadius: 12))
                }.buttonStyle(LoungePressStyle())
            } else {
                switch primaryDecision {
                case .caughtUp:
                    Label("Alle bekannten Folgen gesehen", systemImage: "checkmark.circle")
                        .font(.headline).foregroundColor(Theme.accentSoft)
                case .unavailable:
                    Text("Die gemerkte Folge ist nicht mehr in der geladenen Folgenliste. Wähle unten eine Folge.")
                        .font(.subheadline).foregroundColor(Theme.muted)
                default:
                    if let continuationError {
                        Text(continuationError).font(.footnote).foregroundColor(.orange)
                        Button("Weitere Folgen prüfen") { Task { await resolveContinuation() } }
                    } else {
                        ProgressView("Weitere Folgen werden geprüft …").tint(Theme.accent)
                    }
                }
            }
            HStack(spacing: 0) {
                ActionColumn(title: "Watchlist", icon: library.contains(currentAnime) ? "checkmark" : "plus") {
                    library.toggleWatchlist(currentAnime)
                }
                if let trailer = extras?.trailer {
                    Link(destination: trailer) { ActionColumnLabel(title: "Trailer", icon: "play.rectangle") }.buttonStyle(LoungePressStyle())
                }
                if let url = AniURL.page(anime.path) {
                    ShareLink(item: url) { ActionColumnLabel(title: "Teilen", icon: "square.and.arrow.up") }.buttonStyle(LoungePressStyle())
                }
            }.foregroundColor(.white)
            VStack(alignment: .leading, spacing: 10) {
                if !detail.synopsis.isEmpty {
                    Text(detail.synopsis).font(.subheadline).foregroundColor(.white.opacity(0.8)).lineSpacing(4).lineLimit(expanded ? nil : 3)
                        .onTapGesture { withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() } }
                    if !expanded { Text("Mehr").font(.caption.bold()).foregroundColor(Theme.accentSoft).onTapGesture { withAnimation { expanded = true } } }
                }
                if let studio = extras?.studio { InfoLine(icon: "building.2", text: "Studio: \(studio)") }
                if let episode = extras?.nextEpisode, let date = extras?.nextAiring, date > Date() {
                    InfoLine(icon: "calendar", text: "Folge \(episode) in Japan: " + date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute()))
                }
            }
            episodesSection(detail)
        }.padding(.horizontal, 20).padding(.top, 14)
    }
    private func episodesSection(_ detail: AnimeDetail) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Folgen").font(.system(.title3, design: .rounded).bold())
            if detail.seasons.count > 1 {
                ScrollViewReader { reader in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(detail.seasons) { season in
                                let active = season.path == selectedSeason
                                Button {
                                    UISelectionFeedbackGenerator().selectionChanged()
                                    withAnimation(.easeInOut(duration: 0.2)) { selectedSeason = season.path }
                                } label: {
                                    Text(season.title).font(.subheadline.bold()).padding(.horizontal, 16).padding(.vertical, 9)
                                        .background(active ? AnyShapeStyle(Color.white) : AnyShapeStyle(Theme.panelHigh))
                                        .foregroundColor(active ? .black : .white).clipShape(Capsule())
                                }.buttonStyle(LoungePressStyle()).id(season.path)
                            }
                        }.padding(.horizontal, 20)
                    }.padding(.horizontal, -20)
                        .onChange(of: selectedSeason) { path in withAnimation { reader.scrollTo(path, anchor: .center) } }
                        .onAppear { reader.scrollTo(selectedSeason, anchor: .center) }
                }
            }
            if loadingEpisodes {
                VStack(spacing: 14) { ForEach(0..<4, id: \.self) { _ in EpisodeRowSkeleton() } }
            } else if let episodeError {
                ProblemView(message: episodeError) { Task { await loadSeason(selectedSeason) } }
            } else if episodes.isEmpty {
                Text("Für diese Auswahl sind noch keine Folgen verfügbar.").foregroundColor(Theme.muted).padding(.vertical)
            } else {
                LazyVStack(spacing: 14) {
                    ForEach(episodes) { episode in
                        EpisodeRow(episode: episode, info: episodeExtras[episode.number], title: title(of: episode, info: episodeExtras[episode.number]),
                                   progress: library.progress(for: episode), seen: isSeen(episode), current: primaryAction?.episode.id == episode.id,
                                   play: { open(episode) }, more: { actionsFor = episode })
                    }
                }
            }
        }
    }
    private func episodeActions(_ episode: Episode) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Folge \(episode.number) · \(title(of: episode, info: episodeExtras[episode.number]))").font(.headline).lineLimit(1).padding(.horizontal, 20).padding(.bottom, 8)
            SheetRow(title: "Abspielen", icon: "play.fill") { actionsFor = nil; open(episode) }
            SheetRow(title: isSeen(episode) ? "Als ungesehen markieren" : "Als gesehen markieren", icon: isSeen(episode) ? "eye.slash" : "checkmark") {
                actionsFor = nil; library.setWatched(!isSeen(episode), episode: episode, anime: currentAnime)
            }
            SheetRow(title: "Fortschritt bearbeiten", icon: "clock") {
                actionsFor = nil
                Task { try? await Task.sleep(nanoseconds: 350_000_000); editingProgress = episode }
            }
        }
    }
    private func isSeen(_ episode: Episode) -> Bool {
        library.watched.contains(episode.id) || library.progress(for: episode)?.isFinished == true
    }
    /// AniWorld's own (German) title wins; generic "Folge N" titles use the TVDB title.
    private func title(of episode: Episode, info: EpisodeExtras?) -> String {
        guard let better = info?.title, episode.title == "Folge \(episode.number)" || episode.title.isEmpty else { return episode.title }
        return better
    }
    private func loadExtras() async {
        guard let imdb = detail?.imdb else { return }
        // Extra data is optional: failures only hide the additions.
        guard let loaded = try? await MetadataClient.shared.extras(imdb: imdb), !Task.isCancelled else { return }
        withAnimation(.easeOut(duration: 0.25)) { extras = loaded }
        guard !loaded.recommendations.isEmpty, let catalog = try? await AniClient.shared.catalog(), !Task.isCancelled else { return }
        let matched = SimilarMatcher.match(loaded.recommendations, in: catalog).filter { $0.id != currentAnime.id }
        withAnimation(.easeOut(duration: 0.25)) { similar = Array(matched.prefix(12)) }
    }
    private func loadEpisodeExtras() async {
        episodeExtras = [:]
        guard let imdb = detail?.imdb, let number = SeasonNumber.from(selectedSeason) else { return }
        guard let loaded = try? await MetadataClient.shared.episodes(imdb: imdb, season: number), !Task.isCancelled else { return }
        withAnimation(.easeOut(duration: 0.2)) { episodeExtras = loaded }
    }
    private var primaryDecision: SeriesPlaybackDecision {
        SeriesPlaybackState.start(anime: currentAnime, profile: library.active, catalog: catalogs.catalogs[currentAnime.id])
    }
    private var continuationKey: String {
        let latest = library.active.latest(for: currentAnime)
        return "\(detail?.anime.id ?? "")|\(latest?.episode.id ?? "")|\(latest?.completed ?? false)|\(library.watched.count)"
    }
    private func resolveContinuation() async {
        continuationError = nil
        do { _ = try await catalogs.resolveStart(anime: currentAnime, profile: library.active) }
        catch { if !Task.isCancelled { continuationError = "Weitere Folgen konnten nicht geprüft werden. Deine gespeicherten Daten bleiben erhalten." } }
    }
    private var primaryAction: (episode: Episode, title: String, detail: String?, fraction: Double?)? {
        switch primaryDecision {
        case .resume(let progress):
            let remaining = progress.duration.map { "noch " + EpisodeProgress.format(max(0, $0 - progress.seconds)) }
            return (progress.episode, "Weiterschauen · Folge \(progress.episode.number)", remaining, progress.fraction)
        case .play(let episode):
            return (episode, "Folge \(episode.number) abspielen", nil, nil)
        default: return nil
        }
    }
    private func loadDetail() async {
        error = nil
        do {
            let loaded = try await AniClient.shared.detail(path: anime.path)
            guard !Task.isCancelled else { return }
            detail = loaded; episodes = loaded.episodes
            catalogs.remember(loaded, path: anime.path, isRoot: true)
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
            catalogs.remember(loaded, path: path, isRoot: false)
        } catch {
            guard !Task.isCancelled, selectedSeason == path else { return }
            episodeError = error.localizedDescription; loadingEpisodes = false
        }
    }
    private func open(_ episode: Episode) {
        guard AniURL.page(episode.path) != nil else { return }
        library.opened(episode, anime: currentAnime)
        PlaybackCenter.shared.open(PlaybackRequest(anime: currentAnime, episode: episode, profileID: library.profile.id), library: library)
    }
}

enum SeasonNumber {
    /// `/anime/stream/x/staffel-3` becomes 3; films and other paths have none.
    static func from(_ path: String) -> Int? {
        guard let range = path.range(of: "/staffel-") else { return nil }
        return Int(path[range.upperBound...].prefix { $0.isNumber })
    }
}
struct EpisodeRow: View {
    let episode: Episode
    let info: EpisodeExtras?
    let title: String
    let progress: EpisodeProgress?
    let seen: Bool
    let current: Bool
    let play: () -> Void
    let more: () -> Void
    var body: some View {
        HStack(spacing: 14) {
            Button(action: play) {
                HStack(spacing: 14) {
                    ZStack {
                        if let still = info?.image { Artwork(url: still) }
                        else {
                            Theme.panelHigh
                            Text(episode.number).font(.system(.title2, design: .rounded).bold()).foregroundColor(.white.opacity(0.35))
                        }
                        Image(systemName: "play.fill").font(.caption).foregroundColor(.white).frame(width: 30, height: 30)
                            .background(.black.opacity(0.45)).clipShape(Circle()).overlay(Circle().stroke(.white.opacity(0.5)))
                            .opacity(current || info?.image != nil ? 1 : 0)
                        if let fraction = progress.flatMap({ $0.isFinished ? nil : $0.fraction }), fraction > 0 {
                            ProgressBar(value: fraction, track: .black.opacity(0.4), height: 3).frame(maxHeight: .infinity, alignment: .bottom)
                        }
                    }
                    .frame(width: 128, height: 72).clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(current ? Theme.accent : Theme.stroke, lineWidth: current ? 2 : 1))
                    .overlay(alignment: .topTrailing) {
                        if seen {
                            Image(systemName: "checkmark").font(.system(size: 9, weight: .black)).frame(width: 18, height: 18)
                                .background(Theme.accent).clipShape(Circle()).padding(5)
                        }
                    }
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Folge \(episode.number)").font(.caption.bold()).foregroundColor(current ? Theme.accentSoft : Theme.muted)
                        Text(title).font(.subheadline.bold()).foregroundColor(seen ? .white.opacity(0.6) : .white)
                            .multilineTextAlignment(.leading).lineLimit(2)
                        HStack(spacing: 6) {
                            if let runtime = info?.runtime { Text("\(runtime) Min").font(.caption2).foregroundColor(Theme.muted) }
                            LanguageChips(languages: episode.languages)
                        }
                    }
                    Spacer(minLength: 0)
                }.contentShape(Rectangle())
            }.buttonStyle(LoungePressStyle())
            Button(action: more) {
                Image(systemName: "ellipsis").font(.body.weight(.bold)).foregroundColor(Theme.muted).frame(width: 30, height: 44).contentShape(Rectangle())
            }.accessibilityLabel("Optionen für Folge \(episode.number)")
        }
    }
}
struct EpisodeRowSkeleton: View {
    var body: some View {
        HStack(spacing: 14) {
            RoundedRectangle(cornerRadius: 8).fill(Theme.panel).frame(width: 128, height: 72)
            VStack(alignment: .leading, spacing: 8) {
                RoundedRectangle(cornerRadius: 3).fill(Theme.panel).frame(width: 60, height: 10)
                RoundedRectangle(cornerRadius: 3).fill(Theme.panel).frame(width: 150, height: 12)
            }
            Spacer()
        }.shimmer()
    }
}
struct ProgressBar: View {
    let value: Double
    var track: Color = .white.opacity(0.2)
    var height: CGFloat = 4
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(track)
                Capsule().fill(Theme.accent).frame(width: geo.size.width * CGFloat(min(1, max(0, value))))
            }
        }.frame(height: height)
    }
}
private struct ActionColumnLabel: View {
    let title: String
    let icon: String
    var body: some View {
        VStack(spacing: 7) {
            Image(systemName: icon).font(.system(size: 21, weight: .medium)).frame(height: 24)
            Text(title).font(.caption2.weight(.semibold)).foregroundColor(Theme.muted)
        }.frame(maxWidth: .infinity).contentShape(Rectangle())
    }
}
private struct ActionColumn: View {
    let title: String
    let icon: String
    let action: () -> Void
    var body: some View {
        Button(action: action) { ActionColumnLabel(title: title, icon: icon) }.buttonStyle(LoungePressStyle())
    }
}
private struct InfoLine: View {
    let icon: String
    let text: String
    var body: some View {
        Label { Text(text) } icon: { Image(systemName: icon).foregroundColor(Theme.accentSoft) }
            .font(.caption).foregroundColor(Theme.muted)
    }
}
struct ExtrasBadges: View {
    let extras: AnimeExtras
    var body: some View {
        HStack(spacing: 6) {
            if let score = extras.score {
                Label("\(score) %", systemImage: "star.fill").font(.caption2.bold()).padding(.horizontal, 7).padding(.vertical, 4)
                    .background(Color.yellow.opacity(0.16)).foregroundColor(.yellow).clipShape(Capsule()).fixedSize()
            }
            if let status = statusText {
                Text(status).font(.caption2.bold()).padding(.horizontal, 8).padding(.vertical, 4).background(Theme.panelHigh.opacity(0.9))
                    .foregroundColor(Theme.accentSoft).clipShape(Capsule()).fixedSize()
            }
        }
    }
    private var statusText: String? {
        switch extras.status {
        case "RELEASING": return "Läuft"
        case "FINISHED": return "Abgeschlossen"
        case "NOT_YET_RELEASED": return "Bald"
        case "HIATUS": return "Pause"
        default: return nil
        }
    }
}
/// Finds AniList recommendations in AniWorld's catalog by normalised title.
enum SimilarMatcher {
    static func key(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).filter { $0.isLetter || $0.isNumber }
    }
    static func match(_ recommendations: [[String]], in catalog: [Anime]) -> [Anime] {
        var index: [String: Anime] = [:]
        for anime in catalog {
            for name in [anime.title] + anime.aliases.split(separator: ",").map(String.init) {
                let k = key(name); if k.count >= 3 && index[k] == nil { index[k] = anime }
            }
        }
        var seen = Set<String>()
        return recommendations.compactMap { names in names.lazy.compactMap { index[key($0)] }.first }.filter { seen.insert($0.id).inserted }
    }
}
