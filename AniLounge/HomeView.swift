import SwiftUI
import AniCore

struct HomeView: View {
    let onOpenProfileSummary: () -> Void
    @EnvironmentObject private var library: LibraryStore
    @State private var feed: HomeFeed?
    @State private var error: String?
    @State private var loading = false
    var body: some View {
        LoungeScroll(title: "", underBar: false, threshold: 40) {
            LazyVStack(alignment: .leading, spacing: 30) {
                // The stage comes first, like streaming apps; personal rows follow and stay
                // available even when the online feed has never loaded.
                if let feed { HeroCarousel(items: Array((feed.featured.isEmpty ? feed.popular : feed.featured).prefix(6))).transition(.opacity) }
                NewEpisodesShelf()
                ContinueWatchingShelf()
                TodaySimulcastShelf()
                RecentShelf()
                if feed == nil { AnimeShelf(title: "Meine Liste", items: library.favorites) }
                if let feed {
                    if let error { Text(error).font(.footnote).foregroundColor(.orange).padding(.horizontal, 20) }
                    BecauseYouWatchedShelf()
                    TopTenShelf(title: "Top 10 auf AniWorld", items: feed.popular)
                    AnimeShelf(title: "Beliebt auf AniWorld", items: Array(feed.popular.dropFirst(10)))
                    AnimeShelf(title: "Neue Folgen", items: Array(feed.recent.prefix(30)))
                    AnimeShelf(title: "Auf der Startseite", items: feed.featured)
                } else if let error {
                    ProblemView(message: error) { Task { await load() } }.padding(.top, 20)
                } else {
                    HomeSkeleton()
                }
            }
        } leading: {
            LoungeLogo()
        } trailing: {
            HStack(spacing: 10) {
                NavigationLink { CalendarView() } label: { CircleIcon(systemName: "calendar") }.accessibilityLabel("Simulcast-Kalender")
                Button(action: onOpenProfileSummary) { CircleIcon(systemName: library.profile.avatar) }
                    .accessibilityLabel("Profilübersicht: \(library.profile.name)")
                    .accessibilityHint("Zeigt deine Statistiken in einem kleinen Fenster")
            }
        }
        .task { if feed == nil { await load() } }
        .task(id: library.profile.id) {
            await SeriesCatalogStore.shared.refreshContinuations(library.active)
            NewEpisodeTracker.shared.evaluate(profile: library.active, catalogs: SeriesCatalogStore.shared.catalogs)
        }
        .onReceive(SeriesCatalogStore.shared.$catalogs) { NewEpisodeTracker.shared.evaluate(profile: library.active, catalogs: $0) }
        .task { await SimulcastStore.shared.load() }
        .onChange(of: library.active.continuationCandidates.first?.anime.id) { _ in
            QuickActions.refresh(continueTitle: library.active.continuationCandidates.first?.anime.title)
        }
        .onAppear { QuickActions.refresh(continueTitle: library.active.continuationCandidates.first?.anime.title) }
        .refreshable {
            await AniClient.shared.clearCache()
            await load()
            await SeriesCatalogStore.shared.refreshContinuations(library.active, force: true)
        }
    }
    private func load() async {
        guard !loading else { return }
        loading = true; error = nil
        defer { loading = false }
        do {
            let loaded = try await AniClient.shared.home()
            withAnimation(.easeOut(duration: 0.4)) { feed = loaded }
        }
        catch { if !Task.isCancelled { self.error = error.localizedDescription } }
    }
}
struct HeroCarousel: View {
    let items: [Anime]
    @State private var page = 0
    @State private var tint: Color?
    @ScaledMetric(relativeTo: .title) private var heroHeight = 440
    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        if !items.isEmpty {
            ZStack(alignment: .bottom) {
                TabView(selection: $page) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, anime in HeroView(anime: anime).tag(index) }
                }.tabViewStyle(.page(indexDisplayMode: .never))
                HStack(spacing: 6) {
                    ForEach(items.indices, id: \.self) { index in
                        Capsule().fill(index == page ? Color.white : .white.opacity(0.3)).frame(width: index == page ? 18 : 6, height: 6)
                    }
                }.padding(.bottom, 2).animation(.spring(response: 0.3), value: page).accessibilityHidden(true)
            }
            .frame(height: min(heroHeight, 520)).clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Theme.stroke))
            .shadow(color: .black.opacity(0.35), radius: 24, y: 12)
            .padding(.horizontal, 20)
            // The artwork's colour washes over the top of the screen and changes with each slide.
            .background(alignment: .top) {
                LinearGradient(colors: [(tint ?? Theme.panel).opacity(0.9), (tint ?? Theme.panel).opacity(0.35), .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: min(heroHeight, 520) + 340).offset(y: -170)
                    .allowsHitTesting(false).accessibilityHidden(true)
                    .animation(.easeInOut(duration: 0.8), value: tint)
            }
            .task(id: items.indices.contains(page) ? items[page].id : "") {
                guard items.indices.contains(page), let color = await AmbientColor.color(for: items[page]), !Task.isCancelled else { return }
                tint = color
            }
            // Gentle auto-advance like streaming apps; a manual swipe restarts the timer.
            .task(id: "\(page)|\(settings.heroAutoAdvance)|\(reduceMotion)|\(items.count)") {
                guard !reduceMotion, settings.heroAutoAdvance, items.count > 1 else { return }
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                guard !Task.isCancelled else { return }
                withAnimation(.easeInOut(duration: 0.6)) { page = (page + 1) % items.count }
            }
        }
    }
}
struct HeroView: View {
    let anime: Anime
    @EnvironmentObject private var library: LibraryStore
    @State private var genres: [String] = []
    @State private var starting = false
    var body: some View {
        ZStack(alignment: .bottom) {
            // The whole picture opens the details, like a Netflix billboard.
            NavigationLink { DetailView(anime: anime) } label: {
                ZStack {
                    WideArtwork(anime: anime)
                    LinearGradient(stops: [.init(color: .black.opacity(0.35), location: 0), .init(color: .clear, location: 0.3),
                                           .init(color: .black.opacity(0.45), location: 0.6), .init(color: .black.opacity(0.92), location: 1)],
                                   startPoint: .top, endPoint: .bottom)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Details zu \(anime.title)")
            VStack(spacing: 10) {
                Text(anime.title).font(.system(size: 30, weight: .heavy)).tracking(-0.8).multilineTextAlignment(.center)
                    .lineLimit(2).minimumScaleFactor(0.75).shadow(color: .black.opacity(0.5), radius: 12)
                    .allowsHitTesting(false)
                if !genres.isEmpty {
                    Text(genres.joined(separator: "  ·  ")).font(.footnote.weight(.semibold)).foregroundColor(.white.opacity(0.85))
                        .lineLimit(1).allowsHitTesting(false).transition(.opacity)
                }
                HStack(spacing: 10) {
                    Button(action: play) {
                        HStack(spacing: 8) {
                            if starting { ProgressView().tint(.black) } else { Image(systemName: "play.fill") }
                            Text("Abspielen")
                        }
                        .font(.subheadline.weight(.bold)).frame(maxWidth: .infinity).frame(minHeight: 46)
                        .background(Color.white).foregroundColor(.black).clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(LoungePressStyle()).disabled(starting)
                    .accessibilityLabel("\(anime.title) abspielen")
                    Button { library.toggleWatchlist(anime) } label: {
                        Label(library.contains(anime) ? "Gemerkt" : "Watchlist", systemImage: library.contains(anime) ? "checkmark" : "plus")
                            .font(.subheadline.weight(.bold)).frame(maxWidth: .infinity).frame(minHeight: 46)
                            .background(.ultraThinMaterial).foregroundColor(.white).clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(LoungePressStyle())
                }
                .padding(.top, 4)
            }
            .padding(.horizontal, 20).padding(.bottom, 26)
        }
        .clipped()
        .animation(.easeOut(duration: 0.3), value: genres)
        .task(id: anime.id) {
            // Genres come from the series page that the wide artwork already loads (cached).
            if let detail = try? await AniClient.shared.detail(path: anime.path), !Task.isCancelled {
                genres = Array(detail.genres.prefix(3))
            }
        }
    }
    /// Starts right away: the remembered episode, the next one, or episode 1.
    private func play() {
        guard !starting else { return }
        starting = true
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        Task { @MainActor in
            defer { starting = false }
            let decision = try? await SeriesCatalogStore.shared.resolveStart(anime: anime, profile: library.active)
            guard let episode = decision?.episode else {
                ToastCenter.shared.show("Folgen konnten nicht geladen werden. Tippe aufs Bild für Details.", icon: "exclamationmark.triangle")
                return
            }
            PlaybackCenter.shared.open(PlaybackRequest(anime: anime, episode: episode, profileID: library.profile.id), library: library)
        }
    }
}
struct InfoView: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                Section("AniLounge " + (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")) {
                    Text("Dein persönlicher Anime-Browser für iPhone und iPad.")
                    Text("Katalog, Suche, Watchlist und Anbieterauswahl sind nativ. Erkannte MP4-/HLS-Links laufen im iOS-Player mit Bild-in-Bild; der Webplayer bleibt als Alternative verfügbar.")
                }
                Section("Daten") {
                    Text("Profile, Watchlists und Wiedergabepositionen bleiben auf diesem Gerät. Es gibt keine Anmeldung oder Synchronisierung zwischen iPhone und iPad.")
                    Text("Bewertungen, Episodenbilder und Opening-Zeiten kommen von AniList, ani.zip und AniSkip. Fehlen sie, funktioniert alles andere weiter.")
                }
                Section("Verbindung") {
                    Link("AniWorld öffnen", destination: AniURL.base)
                    Text("Inoffizieller Client, unabhängig von AniWorld. Änderungen an der Website können die Datenanbindung beeinträchtigen.")
                }
            }.navigationTitle("Über AniLounge").toolbar { Button("Fertig") { dismiss() } }
        }
    }
}
/// Opened series without saved progress; those with progress live in "Weiterschauen".
struct RecentShelf: View {
    @EnvironmentObject private var library: LibraryStore
    var body: some View {
        let watching = Set(library.continueWatching.map(\.anime.id))
        let items = library.history.filter { !watching.contains($0.anime.id) }.prefix(15)
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                SectionHeader(title: "Zuletzt angesehen")
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 12) {
                        ForEach(Array(items)) { entry in
                            NavigationLink { DetailView(anime: entry.anime, resumeEpisode: entry.episode) } label: {
                                VStack(alignment: .leading, spacing: 7) {
                                    WideArtwork(anime: entry.anime).frame(width: 200, height: 112).clipShape(RoundedRectangle(cornerRadius: Theme.tileRadius))
                                        .overlay(RoundedRectangle(cornerRadius: Theme.tileRadius).stroke(Theme.stroke))
                                    Text(entry.anime.title).font(.subheadline.bold()).lineLimit(1)
                                    Text("Folge \(entry.episode.number)").font(.caption).foregroundColor(Theme.muted)
                                }.frame(width: 200).foregroundColor(.white)
                            }.buttonStyle(LoungePressStyle())
                        }
                    }.padding(.horizontal, 20)
                }
            }
        }
    }
}
struct ContinueWatchingShelf: View {
    @EnvironmentObject private var library: LibraryStore
    @ObservedObject private var catalogs = SeriesCatalogStore.shared
    @ObservedObject private var tracker = NewEpisodeTracker.shared
    private var items: [EpisodeProgress] {
        library.active.continuationCandidates.filter {
            let decision = SeriesPlaybackState.start(anime: $0.anime, profile: library.active, catalog: catalogs.catalogs[$0.anime.id])
            // New episodes have their own row above.
            return decision != .caughtUp && !tracker.isNew($0.anime, decision: decision)
        }
    }
    var body: some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                SectionHeader(title: "Weiterschauen", subtitle: "Für \(library.profile.name)")
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 12) {
                        ForEach(items) { item in
                            let decision = SeriesPlaybackState.start(anime: item.anime, profile: library.active, catalog: catalogs.catalogs[item.anime.id])
                            tile(item, decision: decision)
                                .contextMenu {
                                    if let episode = decision.episode {
                                        Button { library.setWatched(true, episode: episode, anime: item.anime) } label: {
                                            Label("Als gesehen markieren", systemImage: "checkmark")
                                        }
                                    }
                                    Button { library.hideContinueWatching(item.anime) } label: {
                                        Label("Aus Weiterschauen ausblenden", systemImage: "eye.slash")
                                    }
                                }
                        }
                    }.padding(.horizontal, 20)
                }
            }
        }
    }
    @ViewBuilder private func tile(_ item: EpisodeProgress, decision: SeriesPlaybackDecision) -> some View {
        if let episode = decision.episode {
            Button {
                PlaybackCenter.shared.open(PlaybackRequest(anime: item.anime, episode: episode, profileID: library.profile.id), library: library)
            } label: { ContinuationCard(item: item, decision: decision) }.buttonStyle(LoungePressStyle())
        } else {
            NavigationLink { DetailView(anime: item.anime) } label: {
                ContinuationCard(item: item, decision: decision)
            }.buttonStyle(LoungePressStyle())
        }
    }
}
