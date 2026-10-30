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
                if let feed {
                    if let hero = feed.featured.first ?? feed.popular.first { HeroView(anime: hero) }
                    if let error { Text(error).font(.footnote).foregroundColor(.orange).padding(.horizontal, 20) }
                    if !library.history.isEmpty {
                        VStack(alignment: .leading, spacing: 14) {
                            Text("Zuletzt geöffnet").font(.title3.bold()).padding(.horizontal, 20)
                            ScrollView(.horizontal, showsIndicators: false) {
                                LazyHStack(spacing: 12) {
                                    ForEach(library.history) { entry in
                                        NavigationLink { DetailView(anime: entry.anime) } label: {
                                            VStack(alignment: .leading, spacing: 6) {
                                                Artwork(url: entry.anime.poster).frame(width: 190, height: 108).clipped().cornerRadius(8)
                                                Text(entry.anime.title).font(.subheadline.bold()).lineLimit(1)
                                                Text("Folge \(entry.episode.number) · erneut öffnen").font(.caption).foregroundColor(.secondary)
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
                    ProgressView("Dein Anime-Abend lädt …").frame(maxWidth: .infinity).padding(.top, 120)
                }
            }.padding(.bottom, 24)
        }
        .background(Theme.background).navigationBarTitleDisplayMode(.inline)
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
struct HeroView: View {
    let anime: Anime
    @EnvironmentObject private var library: LibraryStore
    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Artwork(url: anime.poster)
            LinearGradient(colors: [.clear, Theme.background.opacity(0.35), Theme.background], startPoint: .top, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 14) {
                Text("DEIN NÄCHSTER ANIME").font(.caption2.bold()).tracking(2.5).foregroundColor(.white.opacity(0.8))
                Text(anime.title).font(.system(size: 35, weight: .heavy, design: .rounded)).lineLimit(3).minimumScaleFactor(0.7)
                HStack(spacing: 12) {
                    NavigationLink { DetailView(anime: anime) } label: {
                        Label("Entdecken", systemImage: "play.fill").font(.subheadline.bold()).frame(maxWidth: .infinity).padding(.vertical, 14)
                            .background(.white).foregroundColor(.black).cornerRadius(8)
                    }
                    Button { library.toggle(anime) } label: {
                        Label(library.contains(anime) ? "Gemerkt" : "Meine Liste", systemImage: library.contains(anime) ? "checkmark" : "plus")
                            .font(.subheadline.bold()).frame(maxWidth: .infinity).padding(.vertical, 14)
                            .background(.white.opacity(0.16)).foregroundColor(.white).cornerRadius(8)
                    }
                }
            }.padding(22)
        }.frame(height: 450).clipped()
    }
}
struct InfoView: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                Section("AniLounge 0.1") {
                    Text("Dein persönlicher Anime-Browser für iPhone und iPad.")
                    Text("Katalog, Suche und Merkliste sind nativ. Videos öffnen sich über die Episodenseite im integrierten Browser.")
                }
                Section("Deine Daten") {
                    Text("Merkliste, zuletzt geöffnete Folgen und manuell gesetzte Gesehen-Markierungen bleiben auf diesem Gerät.")
                    Text("Keine automatische Erfassung von Wiedergabezeit oder Fortschritt. Webseiten und Videoanbieter verarbeiten ihre eigenen Verbindungsdaten.")
                }
                Section("Verbindung") {
                    Link("AniWorld öffnen", destination: AniURL.base)
                    Text("Inoffizieller Client, unabhängig von AniWorld und Netflix. Änderungen an der Website können die Datenanbindung beeinträchtigen.")
                }
            }.navigationTitle("Über AniLounge").toolbar { Button("Fertig") { dismiss() } }
        }
    }
}
