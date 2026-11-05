import SwiftUI
import AniCore

struct HomeView: View {
    @EnvironmentObject private var library: LibraryStore
    @State private var feed: HomeFeed?
    @State private var error: String?
    @State private var loading = false
    var body: some View {
        LoungeScroll(title: "", underBar: true, threshold: 420) {
            LazyVStack(alignment: .leading, spacing: 30) {
                if let feed {
                    HeroCarousel(items: Array((feed.featured.isEmpty ? feed.popular : feed.featured).prefix(6)))
                    ContinueWatchingShelf()
                    if let error { Text(error).font(.footnote).foregroundColor(.orange).padding(.horizontal, 20) }
                    RecentShelf()
                    AnimeShelf(title: "Beliebt auf AniWorld", items: feed.popular)
                    AnimeShelf(title: "Neue Folgen", items: Array(feed.recent.prefix(30)))
                    AnimeShelf(title: "Auf der Startseite", items: feed.featured)
                } else if let error {
                    ProblemView(message: error) { Task { await load() } }.padding(.top, 140)
                } else {
                    HomeSkeleton()
                }
            }
        } leading: {
            LoungeLogo()
        }
        .task { if feed == nil { await load() } }
        .refreshable { await AniClient.shared.clearCache(); await load() }
    }
    private func load() async {
        guard !loading else { return }
        loading = true; error = nil
        defer { loading = false }
        do { feed = try await AniClient.shared.home() }
        catch { if !Task.isCancelled { self.error = error.localizedDescription } }
    }
}
struct HeroCarousel: View {
    let items: [Anime]
    @State private var page = 0
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
            .frame(height: 540)
            // Gentle auto-advance like streaming apps; a manual swipe restarts the timer.
            .task(id: page) {
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
    var body: some View {
        ZStack(alignment: .bottom) {
            WideArtwork(anime: anime)
            LinearGradient(stops: [.init(color: .black.opacity(0.45), location: 0), .init(color: .clear, location: 0.25),
                                   .init(color: Theme.background.opacity(0.35), location: 0.55), .init(color: Theme.background, location: 0.95)],
                           startPoint: .top, endPoint: .bottom)
            VStack(spacing: 16) {
                Text(anime.title).font(.system(size: 30, weight: .heavy, design: .rounded)).multilineTextAlignment(.center)
                    .lineLimit(2).minimumScaleFactor(0.75).shadow(color: .black.opacity(0.5), radius: 10)
                HStack(spacing: 12) {
                    NavigationLink { DetailView(anime: anime) } label: {
                        Label("Ansehen", systemImage: "play.fill").font(.subheadline.bold()).frame(maxWidth: .infinity).padding(.vertical, 13)
                            .background(Color.white).foregroundColor(.black).clipShape(RoundedRectangle(cornerRadius: 10))
                    }.buttonStyle(LoungePressStyle())
                    Button { library.toggleWatchlist(anime) } label: {
                        Label("Watchlist", systemImage: library.contains(anime) ? "checkmark" : "plus")
                            .font(.subheadline.bold()).frame(maxWidth: .infinity).padding(.vertical, 13)
                            .background(.ultraThinMaterial).foregroundColor(.white).clipShape(RoundedRectangle(cornerRadius: 10))
                    }.buttonStyle(LoungePressStyle())
                }
            }.padding(.horizontal, 24).padding(.bottom, 30)
        }.clipped()
    }
}
struct InfoView: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                Section("AniLounge 0.8") {
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
                                    WideArtwork(anime: entry.anime).frame(width: 200, height: 112).clipShape(RoundedRectangle(cornerRadius: 10))
                                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.stroke))
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
    var body: some View {
        if !library.continueWatching.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                SectionHeader(title: "Weiterschauen", subtitle: "Für \(library.profile.name)")
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 12) {
                        ForEach(library.continueWatching) { item in
                            Button {
                                library.opened(item.episode, anime: item.anime)
                                PlaybackCenter.shared.open(PlaybackRequest(anime: item.anime, episode: item.episode, profileID: library.profile.id), library: library)
                            } label: {
                                VStack(alignment: .leading, spacing: 7) {
                                    ZStack(alignment: .bottom) {
                                        WideArtwork(anime: item.anime)
                                        LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .center, endPoint: .bottom)
                                        Image(systemName: "play.fill").font(.body).frame(width: 42, height: 42)
                                            .background(.ultraThinMaterial).clipShape(Circle()).overlay(Circle().stroke(.white.opacity(0.3)))
                                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                                        GeometryReader { geo in
                                            ZStack(alignment: .leading) {
                                                Rectangle().fill(.white.opacity(0.25))
                                                Rectangle().fill(Theme.accent).frame(width: geo.size.width * CGFloat(item.fraction ?? 0))
                                            }
                                        }.frame(height: 3).frame(maxHeight: .infinity, alignment: .bottom)
                                    }.frame(width: 230, height: 129).clipShape(RoundedRectangle(cornerRadius: 10))
                                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.stroke))
                                    Text(item.anime.title).font(.subheadline.bold()).lineLimit(1)
                                    Text("Folge \(item.episode.number) · noch \(EpisodeProgress.format(max(0, (item.duration ?? item.seconds) - item.seconds)))")
                                        .font(.caption.monospacedDigit()).foregroundColor(Theme.muted)
                                }.frame(width: 230)
                            }.buttonStyle(LoungePressStyle()).foregroundColor(.white)
                        }
                    }.padding(.horizontal, 20)
                }
            }
        }
    }
}
