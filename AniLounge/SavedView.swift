import SwiftUI
import AniCore

struct SavedView: View {
    @EnvironmentObject private var library: LibraryStore
    @AppStorage("watchlist.sort") private var sortByTitle = false
    @State private var filter: WatchStatus?
    @State private var query = ""
    @FocusState private var searching: Bool
    init(initialFilter: WatchStatus? = nil) { _filter = State(initialValue: initialFilter) }

    private var items: [Anime] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var items = library.favorites.filter {
            (filter == nil || library.status(for: $0) == filter) &&
            (term.isEmpty || $0.title.localizedStandardContains(term) || $0.aliases.localizedStandardContains(term))
        }
        if sortByTitle { items.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending } }
        else {
            let dates = library.active.progress.values.reduce(into: [String: Date]()) { dates, progress in
                dates[progress.anime.id] = max(dates[progress.anime.id] ?? .distantPast, progress.updatedAt)
            }
            let order = Dictionary(uniqueKeysWithValues: library.favorites.enumerated().map { ($0.element.id, $0.offset) })
            items.sort {
                let lhs = dates[$0.id] ?? .distantPast, rhs = dates[$1.id] ?? .distantPast
                return lhs == rhs ? (order[$0.id] ?? 0) < (order[$1.id] ?? 0) : lhs > rhs
            }
        }
        return items
    }

    var body: some View {
        LoungeScroll(title: "Watchlist", largeTitle: true) {
            VStack(alignment: .leading, spacing: 18) {
                searchBar.padding(.horizontal, 20)
                filters
                if items.isEmpty { emptyState }
                else {
                    LazyVStack(spacing: 12) {
                        ForEach(items) { anime in
                            WatchlistRow(anime: anime, status: library.status(for: anime))
                        }
                    }.padding(.horizontal, 20)
                }
            }
        } leading: {
            EmptyView()
        } trailing: {
            NavigationLink { FinishedView() } label: { CircleIcon(systemName: "plus") }
                .accessibilityLabel("Bereits gesehene Anime eintragen")
        }
        .scrollDismissesKeyboard(.interactively)
        .task(id: library.profile.id) { await SeriesCatalogStore.shared.refreshContinuations(library.active) }
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundColor(Theme.muted)
                TextField("Deine Watchlist durchsuchen", text: $query)
                    .font(.subheadline).autocorrectionDisabled().textInputAutocapitalization(.never)
                    .focused($searching).submitLabel(.search).onSubmit { searching = false }
                    .accessibilityLabel("Watchlist durchsuchen")
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill").frame(width: 44, height: 44) }
                        .foregroundColor(Theme.muted).accessibilityLabel("Suche löschen")
                }
            }.padding(.leading, 14).padding(.trailing, query.isEmpty ? 12 : 0).frame(minHeight: 48).glassCard(cornerRadius: 14)
            Menu {
                Picker("Sortierung", selection: $sortByTitle) {
                    Text("Zuletzt aktiv").tag(false)
                    Text("Titel A–Z").tag(true)
                }
            } label: {
                Image(systemName: "arrow.up.arrow.down").font(.body.weight(.semibold))
                    .frame(width: 48, height: 48).glassCard(cornerRadius: 14)
            }.accessibilityLabel("Sortieren: \(sortByTitle ? "Titel A–Z" : "Zuletzt aktiv")")
        }.foregroundColor(.white)
    }

    private var filters: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach([nil, WatchStatus.watching, .completed, .planned, .paused], id: \.self) { status in
                    Button { filter = status } label: {
                        Text(status?.label ?? "Alle").font(.footnote.weight(.semibold))
                            .padding(.horizontal, 14).frame(minHeight: 44)
                            .background(filter == status ? Theme.accent : Theme.panel)
                            .foregroundColor(filter == status ? .white : Theme.muted).clipShape(Capsule())
                    }.buttonStyle(LoungePressStyle())
                        .accessibilityAddTraits(filter == status ? .isSelected : [])
                }
            }.padding(.horizontal, 20)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: query.isEmpty ? (filter?.symbol ?? "bookmark") : "magnifyingglass")
                .font(.system(size: 38, weight: .light)).foregroundColor(Theme.accentSoft)
            Text(query.isEmpty ? emptyTitle : "Keine Treffer").font(.title3.bold())
            Text(query.isEmpty ? emptyHint : "Versuche einen anderen Namen oder wähle „Alle“.")
                .font(.subheadline).foregroundColor(Theme.muted)
            if !query.isEmpty || filter != nil {
                Button("Alle Anime anzeigen") { query = ""; filter = nil }
                    .font(.subheadline.bold()).frame(minHeight: 44)
            }
        }.multilineTextAlignment(.center).frame(maxWidth: .infinity).padding(28).padding(.top, 28)
    }
    private var emptyTitle: String {
        switch filter {
        case .watching: return "Gerade nichts angefangen"
        case .completed: return "Noch keine fertigen Anime"
        case .planned: return "Noch nichts geplant"
        case .paused: return "Nichts auf Pause"
        case nil: return "Deine Anime finden hier Platz"
        }
    }
    private var emptyHint: String {
        switch filter {
        case .watching: return "Sobald du einen Anime schaust, erscheint er automatisch hier."
        case .completed: return "Gesehene Anime kannst du über + eintragen oder an einer Karte als „Fertig“ markieren."
        case .paused: return "Über das Menü an einer Karte kannst du einen Anime pausieren."
        default: return "Speichere einen Anime für später. Angefangene Titel werden automatisch ergänzt."
        }
    }
}

private struct WatchlistRow: View {
    let anime: Anime
    let status: WatchStatus
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.dynamicTypeSize) private var typeSize
    private var statusColor: Color {
        switch status {
        case .completed: return .mint
        case .watching: return Theme.accentSoft
        case .paused: return .orange
        case .planned: return Theme.muted
        }
    }
    var body: some View {
        HStack(alignment: .center, spacing: 0) {
            NavigationLink { DetailView(anime: anime) } label: {
                HStack(spacing: 14) {
                    AnimeArtwork(anime: anime).frame(width: 64, height: 96).clipShape(RoundedRectangle(cornerRadius: 10))
                    VStack(alignment: .leading, spacing: 10) {
                        Text(anime.title).font(.subheadline.weight(.semibold))
                            .lineLimit(typeSize.isAccessibilitySize ? nil : 3).fixedSize(horizontal: false, vertical: true)
                        Label(status.label, systemImage: status.symbol)
                            .font(.caption.weight(.semibold)).foregroundColor(statusColor)
                            .padding(.horizontal, 9).padding(.vertical, 5)
                            .background(statusColor.opacity(0.12)).clipShape(RoundedRectangle(cornerRadius: 8))
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.padding(.leading, 12).padding(.vertical, 12).contentShape(Rectangle())
            }.buttonStyle(LoungePressStyle()).foregroundColor(.white)
            Menu {
                Section("Status") {
                    ForEach(WatchStatus.allCases, id: \.self) { choice in
                        Button { library.setStatus(choice, for: anime) } label: {
                            Label(choice.label, systemImage: status == choice ? "checkmark" : choice.symbol)
                        }
                    }
                    Button { library.setStatus(nil, for: anime) } label: { Label("Automatisch", systemImage: "wand.and.stars") }
                }
                Button(role: .destructive) { library.removeFromList(anime) } label: { Label("Aus Watchlist entfernen", systemImage: "bookmark.slash") }
            } label: {
                Image(systemName: "ellipsis").font(.body.bold()).frame(width: 44, height: 48).contentShape(Rectangle())
            }.foregroundColor(Theme.muted).padding(.trailing, 4)
                .accessibilityLabel("Status und Aktionen für \(anime.title)")
        }.glassCard(cornerRadius: 18)
    }
}
