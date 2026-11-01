import SwiftUI
import AniCore

struct SearchView: View {
    @State private var catalog: [Anime] = []
    @State private var query = ""
    @State private var error: String?
    @State private var loading = false
    private var results: [Anime] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return term.isEmpty ? catalog : catalog.filter { $0.title.localizedStandardContains(term) || $0.aliases.localizedStandardContains(term) }
    }
    var body: some View {
        LoungeScroll(title: "Suche", largeTitle: true) {
            LazyVStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Image(systemName: "magnifyingglass").foregroundColor(Theme.muted)
                    TextField("Deinen nächsten Anime finden", text: $query).textInputAutocapitalization(.never)
                    if !query.isEmpty { Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }.accessibilityLabel("Suche löschen") }
                }.padding(.horizontal, 14).padding(.vertical, 12).background(Theme.panelHigh).clipShape(RoundedRectangle(cornerRadius: 12))
                if let error { ProblemView(message: error) { Task { await load() } } }
                else if loading {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 12)], spacing: 18) {
                        ForEach(0..<12, id: \.self) { _ in RoundedRectangle(cornerRadius: 12).fill(Theme.panel).aspectRatio(2 / 3, contentMode: .fit).shimmer() }
                    }.padding(.top, 16)
                }
                else {
                    Text("\(results.count) Anime\(query.isEmpty ? " im Katalog" : " gefunden")")
                        .font(.footnote.weight(.semibold)).foregroundColor(Theme.muted).padding(.top, 6)
                    if results.isEmpty {
                        Text("Keine Treffer. Versuche einen anderen Titel oder den japanischen Namen.").foregroundColor(.secondary).padding(.vertical, 36)
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 12, alignment: .top)], spacing: 18) {
                        ForEach(results) { anime in
                            NavigationLink { DetailView(anime: anime) } label: { GridPoster(anime: anime) }.buttonStyle(LoungePressStyle())
                        }
                    }
                }
            }.padding(.horizontal, 20)
        }
        .autocorrectionDisabled()
        .task { if catalog.isEmpty { await load() } }
        .refreshable { await AniClient.shared.clearCache(); await load() }
    }
    private func load() async {
        guard !loading else { return }
        loading = true; error = nil
        defer { loading = false }
        do { catalog = try await AniClient.shared.catalog() }
        catch { if !Task.isCancelled { self.error = error.localizedDescription } }
    }
}
/// Poster that sizes itself to its grid column.
struct GridPoster: View {
    let anime: Anime
    @EnvironmentObject private var library: LibraryStore
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Color.clear.aspectRatio(2 / 3, contentMode: .fit)
                .overlay(AnimeArtwork(anime: anime))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.stroke))
                .overlay(alignment: .topTrailing) {
                    if library.contains(anime) {
                        Image(systemName: "bookmark.fill").font(.caption2.bold()).padding(5).background(Theme.accent).clipShape(Circle()).padding(5)
                    }
                }
            Text(anime.title).font(.caption.weight(.semibold)).lineLimit(2).frame(height: 32, alignment: .topLeading).foregroundColor(.white)
        }
    }
}
struct SavedView: View {
    @EnvironmentObject private var library: LibraryStore
    var body: some View {
        LoungeScroll(title: "Watchlist", largeTitle: true) {
            if library.favorites.isEmpty {
                VStack(spacing: 16) {
                    Image(systemName: "bookmark").font(.system(size: 44)).foregroundColor(Theme.accent)
                    Text("Platz für deine nächsten Lieblingsanime.").font(.title3.bold()).multilineTextAlignment(.center)
                    Text("Tippe bei einem Anime auf „Watchlist“, um ihn hier zu speichern.").foregroundColor(.secondary).multilineTextAlignment(.center)
                }.padding(36).padding(.top, 60).frame(maxWidth: .infinity)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 12, alignment: .top)], spacing: 18) {
                    ForEach(library.favorites) { anime in
                        NavigationLink { DetailView(anime: anime) } label: { GridPoster(anime: anime) }
                            .buttonStyle(LoungePressStyle())
                            .contextMenu { Button(role: .destructive) { library.toggle(anime) } label: { Label("Aus Liste entfernen", systemImage: "bookmark.slash") } }
                    }
                }.padding(.horizontal, 20).padding(.top, 6)
            }
        }
    }
}

