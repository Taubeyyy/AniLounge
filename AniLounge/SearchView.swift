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
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if let error { ProblemView(message: error) { Task { await load() } } }
                else if loading { ProgressView("Katalog wird geladen …").frame(maxWidth: .infinity).padding(40) }
                else {
                    Text("\(results.count) Anime\(query.isEmpty ? " im Katalog" : " gefunden")")
                        .font(.footnote).foregroundColor(.secondary).padding(.vertical, 16)
                    if results.isEmpty {
                        Text("Keine Treffer. Versuche einen anderen Titel oder den japanischen Namen.").foregroundColor(.secondary).padding(.vertical, 36)
                    }
                    ForEach(results) { anime in
                        NavigationLink { DetailView(anime: anime) } label: {
                            HStack(spacing: 14) {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 10).fill(Theme.panel)
                                    Text(String(anime.title.prefix(1))).font(.title2.weight(.black)).foregroundColor(Theme.accent)
                                }.frame(width: 48, height: 60)
                                Text(anime.title).font(.subheadline.weight(.semibold)).foregroundColor(.white).multilineTextAlignment(.leading)
                                Spacer(minLength: 6)
                                Image(systemName: "chevron.right").font(.caption).foregroundColor(.secondary)
                            }.padding(.vertical, 10)
                        }.buttonStyle(.plain)
                        Divider().overlay(.white.opacity(0.04))
                    }
                }
            }.padding(.horizontal, 20)
        }
        .background(Theme.background).navigationTitle("Suche")
        .searchable(text: $query, prompt: "Titel oder alternativer Name")
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
struct SavedView: View {
    @EnvironmentObject private var library: LibraryStore
    var body: some View {
        ScrollView {
            if library.favorites.isEmpty {
                VStack(spacing: 16) {
                    Image(systemName: "bookmark").font(.system(size: 44)).foregroundColor(Theme.accent)
                    Text("Platz für deine nächsten Lieblingsanime.").font(.title3.bold()).multilineTextAlignment(.center)
                    Text("Tippe bei einem Anime auf „Meine Liste“, um ihn hier zu speichern.").foregroundColor(.secondary).multilineTextAlignment(.center)
                }.padding(36).padding(.top, 80)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 16)], spacing: 22) {
                    ForEach(library.favorites) { anime in
                        NavigationLink { DetailView(anime: anime) } label: { PosterCard(anime: anime, width: 140) }
                            .buttonStyle(.plain)
                            .contextMenu { Button(role: .destructive) { library.toggle(anime) } label: { Label("Aus Liste entfernen", systemImage: "bookmark.slash") } }
                    }
                }.padding(20)
            }
        }.frame(maxWidth: .infinity).background(Theme.background).navigationTitle("Meine Liste")
    }
}
