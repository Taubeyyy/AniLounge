import SwiftUI
import AniCore

struct SearchView: View {
    @State private var catalog: [Anime] = []
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var query = ""
    @State private var error: String?
    @State private var loading = false
    @AppStorage("search.recent") private var recentStore = ""
    @FocusState private var focused: Bool
    @State private var surprise: Anime?
    @State private var genres: [Genre] = []
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
                        .submitLabel(.search).focused($focused).onSubmit { remember(query); focused = false }
                    if !query.isEmpty {
                        Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundColor(Theme.muted).frame(width: 44, height: 44).contentShape(Rectangle()) }.accessibilityLabel("Suche löschen")
                    }
                }.padding(.leading, 16).padding(.trailing, 4).frame(minHeight: 56).background(Theme.panelHigh).clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(focused ? Theme.accent.opacity(0.7) : .clear, lineWidth: 1.5))
                    .animation(.easeOut(duration: 0.15), value: focused)
                if query.isEmpty && !catalog.isEmpty {
                    Button {
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        surprise = catalog.randomElement()
                    } label: {
                        Label("Überrasch mich", systemImage: "dice.fill").font(.subheadline.bold()).frame(maxWidth: .infinity).frame(minHeight: 48)
                            .background(Theme.panel).clipShape(RoundedRectangle(cornerRadius: 12)).overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.stroke))
                    }.buttonStyle(LoungePressStyle()).foregroundColor(.white)
                }
                if query.isEmpty && !recent.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Zuletzt gesucht").font(.caption.bold()).foregroundColor(Theme.muted)
                            Spacer()
                            Button("Leeren") { withAnimation { recentStore = "" } }.font(.caption.bold()).foregroundColor(Theme.accentSoft).frame(minHeight: 44)
                        }
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(recent, id: \.self) { term in
                                    Button { query = term; focused = false } label: {
                                        Label(term, systemImage: "clock.arrow.circlepath").font(.footnote.weight(.semibold)).padding(.horizontal, 12).frame(minHeight: 44)
                                            .background(Theme.panel).clipShape(Capsule()).overlay(Capsule().stroke(Theme.stroke))
                                    }.buttonStyle(LoungePressStyle()).foregroundColor(.white)
                                }
                            }
                        }
                    }.padding(.top, 4)
                }
                if query.isEmpty && !genres.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Genres").font(.title3.weight(.bold)).padding(.top, 8)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
                            ForEach(genres) { genre in
                                NavigationLink { GenreView(genre: genre) } label: { GenreTile(genre: genre) }.buttonStyle(LoungePressStyle())
                            }
                        }
                    }.transition(.opacity)
                }
                if let error { ProblemView(message: error) { Task { await load() } } }
                else if loading {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: typeSize.isAccessibilitySize ? 150 : 104), spacing: 12)], spacing: 18) {
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
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: typeSize.isAccessibilitySize ? 150 : 104), spacing: 12, alignment: .top)], spacing: 18) {
                        ForEach(results) { anime in
                            NavigationLink { DetailView(anime: anime) } label: { GridPoster(anime: anime) }.buttonStyle(LoungePressStyle())
                                .simultaneousGesture(TapGesture().onEnded { if !query.isEmpty { remember(query) } })
                        }
                    }
                }
            }.padding(.horizontal, 20)
        }
        .autocorrectionDisabled()
        .navigationDestination(isPresented: Binding(get: { surprise != nil }, set: { if !$0 { surprise = nil } })) {
            if let surprise { DetailView(anime: surprise) }
        }
        .scrollDismissesKeyboard(.immediately)
        .task { if catalog.isEmpty { await load() } }
        .refreshable { await AniClient.shared.clearCache(); await load() }
    }
    private func load() async {
        guard !loading else { return }
        loading = true; error = nil
        defer { loading = false }
        do {
            let loaded = try await AniClient.shared.catalog()
            withAnimation(.easeOut(duration: 0.3)) { catalog = loaded }
            if let list = try? await AniClient.shared.genres() { withAnimation(.easeOut(duration: 0.3)) { genres = list } }
        }
        catch { if !Task.isCancelled { self.error = error.localizedDescription } }
    }
}
/// A colourful tile per genre; the colour is stable for each name.
private struct GenreTile: View {
    let genre: Genre
    private var hue: Double { Double(genre.name.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }) / 65_535 }
    var body: some View {
        ZStack(alignment: .bottomLeading) {
            LinearGradient(colors: [Color(hue: hue, saturation: 0.55, brightness: 0.5), Color(hue: hue, saturation: 0.7, brightness: 0.22)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            AnimeArtwork(anime: genre.anime[0]).frame(width: 54, height: 80).clipShape(RoundedRectangle(cornerRadius: 6))
                .rotationEffect(.degrees(14)).offset(x: 14, y: 10).shadow(radius: 6)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            VStack(alignment: .leading, spacing: 2) {
                Text(GenreView.title(genre.name)).font(.subheadline.weight(.bold)).lineLimit(2)
                Text("\(genre.anime.count) Anime").font(.caption2).opacity(0.75)
            }.padding(12)
        }
        .frame(height: 86).clipShape(RoundedRectangle(cornerRadius: 14)).foregroundColor(.white)
        .accessibilityElement(children: .combine)
    }
}
struct GenreView: View {
    let genre: Genre
    @Environment(\.dynamicTypeSize) private var typeSize
    /// AniWorld lists subtitle versions as genres; give them readable names.
    static func title(_ name: String) -> String {
        switch name {
        case "GerSub": return "Mit deutschen Untertiteln"
        case "EngSub": return "Mit englischen Untertiteln"
        default: return name
        }
    }
    var body: some View {
        LoungeScroll(title: Self.title(genre.name), largeTitle: true) {
            VStack(alignment: .leading, spacing: 12) {
                Text("\(genre.anime.count) Anime").font(.footnote.weight(.semibold)).foregroundColor(Theme.muted)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: typeSize.isAccessibilitySize ? 150 : 104), spacing: 12, alignment: .top)], spacing: 18) {
                    ForEach(genre.anime) { anime in
                        NavigationLink { DetailView(anime: anime) } label: { GridPoster(anime: anime) }.buttonStyle(LoungePressStyle())
                    }
                }
            }.padding(.horizontal, 20)
        } leading: {
            BackButton()
        }
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
            Text(anime.title).font(.caption.weight(.semibold)).lineLimit(3).fixedSize(horizontal: false, vertical: true).foregroundColor(.white)
        }
    }
}
struct SavedView: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    @EnvironmentObject private var library: LibraryStore
    @AppStorage("watchlist.sort") private var sortByTitle = false
    @State private var filter: WatchStatus?
    private var items: [Anime] {
        let all = sortByTitle ? library.favorites.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending } : library.favorites
        guard let filter else { return all }
        return all.filter { library.status(for: $0) == filter }
    }
    private func count(_ status: WatchStatus?) -> Int {
        guard let status else { return library.favorites.count }
        return library.favorites.filter { library.status(for: $0) == status }.count
    }
    private var statusFilter: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach([nil] + WatchStatus.allCases.map(Optional.some), id: \.self) { status in
                    let active = filter == status
                    Button {
                        UISelectionFeedbackGenerator().selectionChanged()
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { filter = status }
                    } label: {
                        HStack(spacing: 5) {
                            Text(status?.label ?? "Alle")
                            Text("\(count(status))").monospacedDigit().opacity(0.6)
                        }.font(.footnote.bold()).padding(.horizontal, 14).frame(minHeight: 40)
                            .background(active ? AnyShapeStyle(Theme.accentGradient) : AnyShapeStyle(Theme.panel))
                            .foregroundColor(.white).clipShape(Capsule())
                            .overlay(Capsule().stroke(active ? .clear : Theme.stroke))
                    }.buttonStyle(LoungePressStyle())
                }
            }.padding(.horizontal, 20)
        }
    }
    var body: some View {
        LoungeScroll(title: "Watchlist", largeTitle: true) {
            if !library.favorites.isEmpty {
                HStack(spacing: 8) {
                    ForEach([false, true], id: \.self) { byTitle in
                        Button { withAnimation(.easeInOut(duration: 0.2)) { sortByTitle = byTitle } } label: {
                            Text(byTitle ? "A–Z" : "Zuletzt hinzugefügt").font(.footnote.bold()).padding(.horizontal, 14).frame(minHeight: 44)
                                .background(sortByTitle == byTitle ? AnyShapeStyle(Color.white) : AnyShapeStyle(Theme.panelHigh))
                                .foregroundColor(sortByTitle == byTitle ? .black : .white).clipShape(Capsule())
                        }.buttonStyle(LoungePressStyle())
                    }
                    Spacer()
                    Text("\(library.favorites.count)").font(.footnote.bold().monospacedDigit()).foregroundColor(Theme.muted)
                }.padding(.horizontal, 20).padding(.bottom, 8)
                statusFilter.padding(.bottom, 12)
            }
            if library.favorites.isEmpty {
                VStack(spacing: 16) {
                    Image(systemName: "bookmark").font(.system(size: 44)).foregroundColor(Theme.accent)
                    Text("Platz für deine nächsten Lieblingsanime.").font(.title3.bold()).multilineTextAlignment(.center)
                    Text("Tippe bei einem Anime auf „Watchlist“, um ihn hier zu speichern.").foregroundColor(.secondary).multilineTextAlignment(.center)
                }.padding(36).padding(.top, 60).frame(maxWidth: .infinity)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: typeSize.isAccessibilitySize ? 150 : 104), spacing: 12, alignment: .top)], spacing: 18) {
                    ForEach(items) { anime in
                        NavigationLink { DetailView(anime: anime) } label: { GridPoster(anime: anime) }
                            .buttonStyle(LoungePressStyle())
                            .contextMenu {
                                ForEach(WatchStatus.allCases, id: \.self) { status in
                                    Button { library.setStatus(status, for: anime) } label: {
                                        Label(status.label, systemImage: library.status(for: anime) == status ? "checkmark" : status.symbol)
                                    }
                                }
                                Divider()
                                Button(role: .destructive) { library.toggleWatchlist(anime) } label: { Label("Aus Liste entfernen", systemImage: "bookmark.slash") }
                            }
                            .transition(.opacity.combined(with: .scale(scale: 0.95)))
                    }
                }.padding(.horizontal, 20).padding(.top, 6)
            }
        }
    }
}

