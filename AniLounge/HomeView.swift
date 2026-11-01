import SwiftUI
import AniCore

struct HomeView: View {
    @EnvironmentObject private var library: LibraryStore
    @State private var feed: HomeFeed?
    @State private var error: String?
    @State private var loading = false
    @State private var showingInfo = false
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 28) {
                ContinueWatchingShelf()
                if let feed {
                    HeroCarousel(items: Array((feed.featured.isEmpty ? feed.popular : feed.featured).prefix(6)))
                    if let error { Text(error).font(.footnote).foregroundColor(.orange).padding(.horizontal, 20) }
                    if !library.history.isEmpty {
                        VStack(alignment: .leading, spacing: 14) {
                            SectionHeader(title: "Zuletzt geöffnet")
                            ScrollView(.horizontal, showsIndicators: false) {
                                LazyHStack(spacing: 12) {
                                    ForEach(library.history) { entry in
                                        NavigationLink { DetailView(anime: entry.anime, resumeEpisode: entry.episode) } label: {
                                            VStack(alignment: .leading, spacing: 6) {
                                                AnimeArtwork(anime: entry.anime).frame(width: 190, height: 108).clipShape(RoundedRectangle(cornerRadius: 12))
                                                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.stroke))
                                                Text(entry.anime.title).font(.subheadline.bold()).lineLimit(1)
                                                Text("Folge \(entry.episode.number)").font(.caption).foregroundColor(Theme.muted)
                                            }.frame(width: 190).foregroundColor(.white)
                                        }.buttonStyle(.plain)
                                    }
                                }.padding(.horizontal, 20)
                            }
                        }
                    }
                    AnimeShelf(title: "Beliebt auf AniWorld", items: feed.popular)
                    AnimeShelf(title: "Auf der Startseite", items: feed.featured)
                    AnimeShelf(title: "Anime mit neuen Folgen", items: Array(feed.recent.prefix(30)))
                    Text("Deine Anime. Dein Abend.").font(.footnote).foregroundColor(.secondary).frame(maxWidth: .infinity).padding(.vertical, 16)
                } else if let error {
                    ProblemView(message: error) { Task { await load() } }.padding(.top, 80)
                } else {
                    HomeSkeleton()
                }
            }.padding(.bottom, 24)
        }
        .background(Theme.background.ignoresSafeArea()).navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                HStack(spacing: 2) {
                    Text("ANI").foregroundColor(Theme.accent)
                    Text("LOUNGE").foregroundColor(.white)
                }.font(.system(size: 23, weight: .black, design: .rounded)).tracking(-0.8)
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button { showingInfo = true } label: { Image(systemName: "info.circle").foregroundColor(.white) }.accessibilityLabel("Über AniLounge")
            }
        }
        .task { if feed == nil { await load() } }
        .refreshable { await AniClient.shared.clearCache(); await load() }
        .sheet(isPresented: $showingInfo) { InfoView() }
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        if !items.isEmpty {
            VStack(spacing: 10) {
                TabView(selection: $page) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, anime in HeroView(anime: anime).tag(index) }
                }.tabViewStyle(.page(indexDisplayMode: .never)).frame(height: 480)
                HStack(spacing: 6) {
                    ForEach(items.indices, id: \.self) { index in
                        Capsule().fill(index == page ? Theme.accent : .white.opacity(0.25)).frame(width: index == page ? 20 : 6, height: 6)
                    }
                }.animation(.spring(response: 0.3), value: page).accessibilityHidden(true)
            }
            // Gentle auto-advance like streaming apps; a manual swipe restarts the timer.
            .task(id: page) {
                guard !reduceMotion, items.count > 1 else { return }
                try? await Task.sleep(nanoseconds: 7_000_000_000)
                guard !Task.isCancelled else { return }
                withAnimation(.easeInOut(duration: 0.5)) { page = (page + 1) % items.count }
            }
        }
    }
}
struct HeroView: View {
    let anime: Anime
    @EnvironmentObject private var library: LibraryStore
    var body: some View {
        ZStack(alignment: .bottomLeading) {
            AnimeArtwork(anime: anime)
            LinearGradient(colors: [Theme.background.opacity(0.55), .clear, Theme.background.opacity(0.4), Theme.background], startPoint: .top, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 14) {
                Text("HIGHLIGHT").font(.caption2.bold()).tracking(2.5).padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Theme.accent.opacity(0.85)).clipShape(Capsule())
                Text(anime.title).font(.system(size: 35, weight: .heavy, design: .rounded)).lineLimit(3).minimumScaleFactor(0.7)
                HStack(spacing: 12) {
                    NavigationLink { DetailView(anime: anime) } label: {
                        Label("Ansehen", systemImage: "play.fill").font(.subheadline.bold()).frame(maxWidth: .infinity).padding(.vertical, 14)
                            .background(Color.white).foregroundColor(.black).clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    Button { UIImpactFeedbackGenerator(style: .light).impactOccurred(); library.toggle(anime) } label: {
                        Label(library.contains(anime) ? "Gemerkt" : "Watchlist", systemImage: library.contains(anime) ? "checkmark" : "plus")
                            .font(.subheadline.bold()).frame(maxWidth: .infinity).padding(.vertical, 14)
                            .background(.ultraThinMaterial).foregroundColor(.white).clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                }
            }.padding(.horizontal, 20).padding(.bottom, 18)
        }.frame(height: 480).clipped()
    }
}
struct InfoView: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                Section("AniLounge 0.6") {
                    Text("Dein persönlicher Anime-Browser für iPhone und iPad.")
                    Text("Katalog, Suche, Watchlist und Anbieterauswahl sind nativ. Erkannte MP4-/HLS-Links laufen im iOS-Player mit Bild-in-Bild; der Webplayer bleibt als Alternative verfügbar.")
                }
                Section("Deine Daten") {
                    Text("Profile, Watchlists und Wiedergabepositionen bleiben auf diesem Gerät. Es gibt keine Anmeldung oder Synchronisierung zwischen iPhone und iPad.")
                    Text("Der iOS-Player und unterstützte HTML5-Videos speichern den Fortschritt automatisch. Webseiten und Videoanbieter verarbeiten ihre eigenen Verbindungsdaten.")
                }
                Section("Verbindung") {
                    Link("AniWorld öffnen", destination: AniURL.base)
                    Text("Inoffizieller Client, unabhängig von AniWorld und Netflix. Änderungen an der Website können die Datenanbindung beeinträchtigen.")
                }
            }.navigationTitle("Über AniLounge").toolbar { Button("Fertig") { dismiss() } }
        }
    }
}

struct ContinueWatchingShelf: View {
    @EnvironmentObject private var library: LibraryStore
    @State private var playback: PlaybackRequest?
    var body: some View {
        if !library.continueWatching.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                SectionHeader(title: "Weiterschauen", subtitle: "Für \(library.profile.name)")
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 14) {
                        ForEach(library.continueWatching) { item in
                            Button {
                                library.opened(item.episode, anime: item.anime)
                                playback = PlaybackRequest(anime: item.anime, episode: item.episode, profileID: library.profile.id)
                            } label: {
                                VStack(alignment: .leading, spacing: 8) {
                                    ZStack(alignment: .bottom) {
                                        AnimeArtwork(anime: item.anime).frame(width: 230, height: 130)
                                        LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .center, endPoint: .bottom)
                                        Image(systemName: "play.fill").font(.title3).frame(width: 46, height: 46)
                                            .background(.ultraThinMaterial).clipShape(Circle()).overlay(Circle().stroke(.white.opacity(0.3)))
                                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                                        HStack {
                                            Text("F\(item.episode.number)").font(.caption.bold())
                                            Spacer()
                                            Text(item.timeLabel).font(.caption2.monospacedDigit()).foregroundColor(.white.opacity(0.8))
                                        }.padding(.horizontal, 10).padding(.bottom, 10)
                                        GeometryReader { geo in
                                            ZStack(alignment: .leading) {
                                                Rectangle().fill(.white.opacity(0.25))
                                                Rectangle().fill(Theme.accent).frame(width: geo.size.width * CGFloat(item.fraction ?? 0))
                                            }
                                        }.frame(height: 4).frame(maxHeight: .infinity, alignment: .bottom)
                                    }.frame(width: 230, height: 130).clipShape(RoundedRectangle(cornerRadius: 12))
                                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.stroke))
                                    Text(item.anime.title).font(.subheadline.bold()).lineLimit(1)
                                }.frame(width: 230)
                            }.buttonStyle(.plain).foregroundColor(.white)
                        }
                    }.padding(.horizontal, 20)
                }
            }.padding(.top, 16)
                .fullScreenCover(item: $playback) { PlaybackView(request: $0, library: library) }
        }
    }
}

