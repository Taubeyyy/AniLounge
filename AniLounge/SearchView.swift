import SwiftUI
import AniCore

struct SearchView: View {
    @State private var catalog: [Anime] = []
    @State private var query = ""
    @State private var error: String?
    @State private var loading = false
    @AppStorage("search.recent") private var recentStore = ""
    @FocusState private var focused: Bool
    private var recent: [String] { recentStore.split(separator: "\n").map(String.init) }
    private func remember(_ term: String) {
        let clean = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.count >= 2 else { return }
        recentStore = ([clean] + recent.filter { $0.caseInsensitiveCompare(clean) != .orderedSame }).prefix(8).joined(separator: "\n")
    }
    private var results: [Anime] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return term.isEmpty ? catalog : catalog.filter { $0.title.localizedStandardContains(term) || $0.aliases.localizedStandardContains(term) }
    }
    var body: some View {
        LoungeScroll(title: "Suche", largeTitle: true) {
            LazyVStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Image(systemName: "magnifyingglass").foregroundColor(Theme.muted)
                    TextField("Titel, auch japanisch", text: $query).textInputAutocapitalization(.never)
                        .submitLabel(.search).focused($focused).onSubmit { remember(query) }
                    if !query.isEmpty {
                        Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundColor(Theme.muted) }.accessibilityLabel("Suche löschen")
                    }
                }.padding(.horizontal, 14).padding(.vertical, 12).background(Theme.panelHigh).clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(focused ? Theme.accent.opacity(0.7) : .clear, lineWidth: 1.5))
                    .animation(.easeOut(duration: 0.15), value: focused)
                if query.isEmpty && !recent.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Zuletzt gesucht").font(.caption.bold()).foregroundColor(Theme.muted)
                            Spacer()
                            Button("Leeren") { withAnimation { recentStore = "" } }.font(.caption.bold()).foregroundColor(Theme.accentSoft)
                        }
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(recent, id: \.self) { term in
                                    Button { query = term } label: {
                                        Label(term, systemImage: "clock.arrow.circlepath").font(.footnote.weight(.semibold)).padding(.horizontal, 12).padding(.vertical, 8)
                                            .background(Theme.panel).clipShape(Capsule()).overlay(Capsule().stroke(Theme.stroke))
                                    }.buttonStyle(LoungePressStyle()).foregroundColor(.white)
                                }
                            }
                        }
                    }.padding(.top, 4)
                }
                if let error { ProblemView(message: error) { Task { await load() } } }
                else if loading {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 12)], spacing: 18) {
                        ForEach(0..<12, id: \.self) { _ in RoundedRectangle(cornerRadius: 12).fill(Theme.panel).aspectRatio(2 / 3, contentMode: .fit).shimmer() }
                    }.padding(.top, 16)
                }
                else {
                    Text(query.isEmpty ? "Alle \(results.count) Anime" : "\(results.count) Treffer")
                        .font(.footnote.weight(.semibold)).foregroundColor(Theme.muted).padding(.top, 6)
                    if results.isEmpty {
                        VStack(spacing: 10) {
                            Image(systemName: "magnifyingglass").font(.system(size: 34)).foregroundColor(Theme.muted)
                            Text("Keine Treffer für „\(query)“").font(.headline)
                            Text("Versuch einen anderen Titel oder den japanischen Namen.").font(.subheadline).foregroundColor(Theme.muted)
                        }.frame(maxWidth: .infinity).padding(.vertical, 40)
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 12, alignment: .top)], spacing: 18) {
                        ForEach(results) { anime in
                            NavigationLink { DetailView(anime: anime) } label: { GridPoster(anime: anime) }.buttonStyle(LoungePressStyle())
                                .simultaneousGesture(TapGesture().onEnded { if !query.isEmpty { remember(query) } })
                        }
                    }
                }
            }.padding(.horizontal, 20)
        }
        .autocorrectionDisabled()
        .scrollDismissesKeyboard(.immediately)
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
    @AppStorage("watchlist.sort") private var sortByTitle = false
    private var items: [Anime] {
        sortByTitle ? library.favorites.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending } : library.favorites
    }
    var body: some View {
        LoungeScroll(title: "Watchlist", largeTitle: true) {
            if !library.favorites.isEmpty {
                HStack(spacing: 8) {
                    ForEach([false, true], id: \.self) { byTitle in
                        Button { withAnimation(.easeInOut(duration: 0.2)) { sortByTitle = byTitle } } label: {
                            Text(byTitle ? "A–Z" : "Zuletzt hinzugefügt").font(.footnote.bold()).padding(.horizontal, 14).padding(.vertical, 8)
                                .background(sortByTitle == byTitle ? AnyShapeStyle(Color.white) : AnyShapeStyle(Theme.panelHigh))
                                .foregroundColor(sortByTitle == byTitle ? .black : .white).clipShape(Capsule())
                        }.buttonStyle(LoungePressStyle())
                    }
                    Spacer()
                    Text("\(library.favorites.count)").font(.footnote.bold().monospacedDigit()).foregroundColor(Theme.muted)
                }.padding(.horizontal, 20).padding(.bottom, 12)
            }
            if library.favorites.isEmpty {
                VStack(spacing: 16) {
                    Image(systemName: "bookmark").font(.system(size: 44)).foregroundColor(Theme.accent)
                    Text("Platz für deine nächsten Lieblingsanime.").font(.title3.bold()).multilineTextAlignment(.center)
                    Text("Tippe bei einem Anime auf „Watchlist“, um ihn hier zu speichern.").foregroundColor(.secondary).multilineTextAlignment(.center)
                }.padding(36).padding(.top, 60).frame(maxWidth: .infinity)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 12, alignment: .top)], spacing: 18) {
                    ForEach(items) { anime in
                        NavigationLink { DetailView(anime: anime) } label: { GridPoster(anime: anime) }
                            .buttonStyle(LoungePressStyle())
                            .contextMenu { Button(role: .destructive) { library.toggleWatchlist(anime) } label: { Label("Aus Liste entfernen", systemImage: "bookmark.slash") } }
                    }
                }.padding(.horizontal, 20).padding(.top, 6)
            }
        }
    }
}

