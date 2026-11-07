import SwiftUI
import AniCore

/// The watchlist as four lists with the look of a streaming app: what you are watching (a big
/// card, then rows), what is planned (posters), what is paused (two weeks without an episode)
/// and the trophy cabinet of finished series. Playback decides the list; the menu on every
/// card can override it.
struct SavedView: View {
    static let lists: [WatchStatus] = [.watching, .planned, .paused, .completed]
    @EnvironmentObject private var library: LibraryStore
    @AppStorage("watchlist.sort") private var sortByTitle = false
    @State private var selection: WatchStatus
    @State private var picked: Bool
    @State private var query = ""
    @State private var searching = false
    @State private var forward = true
    @FocusState private var searchFocused: Bool
    @Namespace private var chipMarker
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    init(initialFilter: WatchStatus? = nil) {
        _selection = State(initialValue: initialFilter ?? .watching)
        _picked = State(initialValue: initialFilter != nil)
    }

    var body: some View {
        let items = entries(in: selection)
        LoungeScroll(title: "Watchlist", largeTitle: true) {
            VStack(alignment: .leading, spacing: 14) {
                chips
                if searching {
                    searchField.padding(.horizontal, 20).transition(.move(edge: .top).combined(with: .opacity))
                }
                if !items.isEmpty { summary(items.count) }
                // Pages overlap while they change, so the outgoing one never pushes the new one down.
                ZStack(alignment: .top) {
                    page(items).id(selection).transition(pageTransition)
                }
                .frame(maxWidth: .infinity, alignment: .top)
                .contentShape(Rectangle())
                .simultaneousGesture(DragGesture(minimumDistance: 30).onEnded(swipe))
            }
            .padding(.bottom, 28)
            .animation(.easeInOut(duration: 0.22), value: searching)
            .animation(reduceMotion ? nil : .spring(response: 0.42, dampingFraction: 0.86), value: items.map(\.id))
        } leading: {
            EmptyView()
        } trailing: {
            HStack(spacing: 0) {
                Button(action: toggleSearch) { CircleIcon(systemName: searching ? "xmark" : "magnifyingglass") }
                    .buttonStyle(LoungePressStyle())
                    .accessibilityLabel(searching ? "Suche schließen" : "Watchlist durchsuchen")
                NavigationLink { FinishedView() } label: { CircleIcon(systemName: "plus") }
                    .buttonStyle(LoungePressStyle())
                    .accessibilityLabel("Bereits gesehene Anime eintragen")
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .onAppear(perform: pickFirstFilledList)
        .task(id: library.profile.id) { await SeriesCatalogStore.shared.refreshContinuations(library.active) }
    }

    // MARK: Lists
    private func entries(in status: WatchStatus) -> [WatchlistEntry] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let list = library.watchlist.filter {
            $0.status == status && (term.isEmpty || $0.anime.title.localizedStandardContains(term) || $0.anime.aliases.localizedStandardContains(term))
        }
        if sortByTitle { return list.sorted { $0.anime.title.localizedStandardCompare($1.anime.title) == .orderedAscending } }
        // Newest activity first; series never played keep the order they were added in.
        return list.enumerated().sorted { lhs, rhs in
            let left = lhs.element.lastActivity ?? .distantPast, right = rhs.element.lastActivity ?? .distantPast
            return left == right ? lhs.offset < rhs.offset : left > right
        }.map(\.element)
    }
    private func count(_ status: WatchStatus) -> Int { library.watchlist.reduce(0) { $0 + ($1.status == status ? 1 : 0) } }
    /// Opens on the first list with something in it, unless a list was asked for.
    private func pickFirstFilledList() {
        guard !picked else { return }
        picked = true
        if count(selection) == 0, let first = Self.lists.first(where: { count($0) > 0 }) { selection = first }
    }
    private func select(_ status: WatchStatus) {
        guard status != selection else { return }
        UISelectionFeedbackGenerator().selectionChanged()
        forward = (Self.lists.firstIndex(of: status) ?? 0) > (Self.lists.firstIndex(of: selection) ?? 0)
        picked = true
        withAnimation(reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.86)) { selection = status }
    }
    /// Swiping sideways over a list switches to the neighbouring one.
    private func swipe(_ value: DragGesture.Value) {
        let dx = value.translation.width, dy = value.translation.height
        guard abs(dx) > 70, abs(dx) > abs(dy) * 1.8, let index = Self.lists.firstIndex(of: selection) else { return }
        let next = index + (dx < 0 ? 1 : -1)
        guard Self.lists.indices.contains(next) else { return }
        select(Self.lists[next])
    }
    private var pageTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .asymmetric(insertion: .move(edge: forward ? .trailing : .leading).combined(with: .opacity), removal: .opacity)
    }

    // MARK: Chips, search, sort
    private var chips: some View {
        ScrollViewReader { reader in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Self.lists, id: \.self) { status in chip(status).id(status) }
                }
                .padding(.horizontal, 20).padding(.vertical, 2)
            }
            .onChange(of: selection) { value in
                withAnimation(.easeInOut(duration: 0.25)) { reader.scrollTo(value, anchor: .center) }
            }
        }
    }
    private func chip(_ status: WatchStatus) -> some View {
        let active = selection == status
        let total = count(status)
        return Button { select(status) } label: {
            HStack(spacing: 7) {
                Image(systemName: Self.symbol(status)).font(.system(size: 12, weight: .bold))
                    .foregroundStyle(status == .completed && !active ? AnyShapeStyle(TrophyStyle.goldFill) : AnyShapeStyle(active ? Color.black : Color.white))
                Text(status.label).font(.subheadline.weight(.semibold))
                Text("\(total)").font(.caption.weight(.bold)).monospacedDigit()
                    .foregroundColor(active ? .black.opacity(0.5) : .white.opacity(0.5))
            }
            .foregroundColor(active ? .black : .white)
            .padding(.horizontal, 14).frame(minHeight: 40)
            .background {
                if active { Capsule().fill(Color.white).matchedGeometryEffect(id: "chip", in: chipMarker) }
                else { Capsule().stroke(Color.white.opacity(0.2), lineWidth: 1) }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(LoungePressStyle())
        .accessibilityLabel("\(status.label), \(total)")
        .accessibilityAddTraits(active ? .isSelected : [])
    }
    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundColor(Theme.muted)
            TextField("In der Watchlist suchen", text: $query)
                .font(.subheadline).autocorrectionDisabled().textInputAutocapitalization(.never)
                .focused($searchFocused).submitLabel(.search).onSubmit { searchFocused = false }
            if !query.isEmpty {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill").frame(width: 40, height: 40) }
                    .foregroundColor(Theme.muted).accessibilityLabel("Suche löschen")
            }
        }
        .padding(.leading, 14).padding(.trailing, query.isEmpty ? 14 : 2).frame(minHeight: 46)
        .glassCard(cornerRadius: 14).foregroundColor(.white)
    }
    private func toggleSearch() {
        withAnimation(.easeInOut(duration: 0.22)) { searching.toggle() }
        if searching {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { searchFocused = true }
        } else { query = ""; searchFocused = false }
    }
    private func summary(_ total: Int) -> some View {
        HStack(spacing: 8) {
            Text(Self.caption(selection, count: total)).font(.footnote).foregroundColor(Theme.muted).lineLimit(1)
            Spacer(minLength: 8)
            Menu {
                Picker("Sortierung", selection: $sortByTitle) {
                    Text("Zuletzt aktiv").tag(false)
                    Text("Titel A–Z").tag(true)
                }
            } label: {
                HStack(spacing: 4) {
                    Text(sortByTitle ? "Titel A–Z" : "Zuletzt aktiv")
                    Image(systemName: "chevron.down").font(.caption2.weight(.bold))
                }
                .font(.footnote.weight(.semibold)).foregroundColor(.white.opacity(0.85)).frame(minHeight: 32)
            }
            .accessibilityLabel("Sortieren: \(sortByTitle ? "Titel A–Z" : "Zuletzt aktiv")")
        }
        .padding(.horizontal, 20)
    }

    // MARK: Pages
    @ViewBuilder private func page(_ items: [WatchlistEntry]) -> some View {
        if selection == .completed && query.isEmpty {
            TrophyCabinet(entries: items)
        } else if items.isEmpty {
            emptyState
        } else {
            switch selection {
            case .watching: WatchingList(entries: items)
            case .paused: RowList(entries: items)
            case .planned: PlannedGrid(entries: items)
            case .completed: TrophyCabinet(entries: items)
            }
        }
    }
    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: query.isEmpty ? Self.symbol(selection) : "magnifyingglass")
                .font(.system(size: 28, weight: .semibold)).foregroundColor(Theme.accentSoft)
                .frame(width: 72, height: 72).background(Circle().fill(Theme.accent.opacity(0.14)))
            Text(query.isEmpty ? Self.emptyTitle(selection) : "Keine Treffer").font(.headline)
            Text(query.isEmpty ? Self.emptyHint(selection) : "Versuche einen anderen Namen.")
                .font(.subheadline).foregroundColor(Theme.muted).fixedSize(horizontal: false, vertical: true)
        }
        .multilineTextAlignment(.center).frame(maxWidth: .infinity).padding(.horizontal, 36).padding(.vertical, 44)
    }

    static func symbol(_ status: WatchStatus) -> String {
        switch status {
        case .watching: return "play.fill"
        case .planned: return "bookmark.fill"
        case .paused: return "pause.fill"
        case .completed: return "trophy.fill"
        }
    }
    static func caption(_ status: WatchStatus, count: Int) -> String {
        switch status {
        case .watching: return "\(count) am Schauen"
        case .planned: return "\(count) gemerkt"
        case .paused: return "\(count) pausiert · 14 Tage ohne neue Folge"
        case .completed: return count == 1 ? "1 Trophäe" : "\(count) Trophäen"
        }
    }
    static func emptyTitle(_ status: WatchStatus) -> String {
        switch status {
        case .watching: return "Gerade schaust du nichts"
        case .planned: return "Noch nichts geplant"
        case .paused: return "Nichts pausiert"
        case .completed: return "Noch keine Trophäen"
        }
    }
    static func emptyHint(_ status: WatchStatus) -> String {
        switch status {
        case .watching: return "Starte eine Folge, dann erscheint der Anime hier von selbst."
        case .planned: return "Tippe bei einem Anime auf „Watchlist“, um ihn für später zu merken."
        case .paused: return "Anime, bei denen du zwei Wochen keine Folge geschaut hast, landen automatisch hier."
        case .completed: return "Schau einen Anime zu Ende und hol dir deine erste Trophäe."
        }
    }
}

// MARK: - Schaue ich, Pausiert
/// The newest series as a big card, the rest as rows.
private struct WatchingList: View {
    let entries: [WatchlistEntry]
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let first = entries.first {
                FeaturedWatchCard(entry: first).padding(.horizontal, 20).appearStagger(0)
            }
            if entries.count > 1 { RowList(entries: Array(entries.dropFirst()), offset: 1) }
        }
    }
}
private struct RowList: View {
    let entries: [WatchlistEntry]
    var offset = 0
    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 330), spacing: 12)], spacing: 10) {
            ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                WatchlistRow(entry: entry).appearStagger(index + offset)
            }
        }
        .padding(.horizontal, 20)
    }
}
private struct FeaturedWatchCard: View {
    let entry: WatchlistEntry
    @EnvironmentObject private var library: LibraryStore
    var body: some View {
        NavigationLink { DetailView(anime: entry.anime) } label: {
            ZStack(alignment: .bottomLeading) {
                Color.clear.aspectRatio(16 / 9, contentMode: .fit).overlay(WideArtwork(anime: entry.anime))
                LinearGradient(stops: [.init(color: .clear, location: 0.25), .init(color: .black.opacity(0.9), location: 1)],
                               startPoint: .top, endPoint: .bottom)
                VStack(alignment: .leading, spacing: 5) {
                    Text("ZULETZT GESCHAUT").font(.caption2.weight(.heavy)).tracking(1.2).foregroundColor(Theme.accentSoft)
                    Text(entry.anime.title).font(.title3.weight(.heavy)).tracking(-0.3).lineLimit(2).multilineTextAlignment(.leading)
                    Text(WatchlistText.progress(entry)).font(.footnote.weight(.medium)).foregroundColor(.white.opacity(0.8)).lineLimit(1)
                }
                .padding(.leading, 16).padding(.trailing, 84).padding(.bottom, 18)
                if let fraction = WatchlistText.openFraction(entry) {
                    ProgressBar(value: fraction, track: .white.opacity(0.22), height: 3)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.stroke))
        }
        .buttonStyle(LoungePressStyle()).foregroundColor(.white)
        .overlay(alignment: .bottomTrailing) { PlayButton(anime: entry.anime, size: 54).padding(.trailing, 14).padding(.bottom, 16) }
        .contextMenu { WatchlistMenu(entry: entry, library: library) }
    }
}
private struct WatchlistRow: View {
    let entry: WatchlistEntry
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.dynamicTypeSize) private var typeSize
    private var paused: Bool { entry.status == .paused }
    var body: some View {
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10)) : AnyLayout(HStackLayout(spacing: 12))
        HStack(spacing: 4) {
            NavigationLink { DetailView(anime: entry.anime) } label: {
                layout {
                    thumbnail
                    VStack(alignment: .leading, spacing: 4) {
                        Text(entry.anime.title).font(.subheadline.weight(.semibold)).multilineTextAlignment(.leading)
                            .lineLimit(typeSize.isAccessibilitySize ? nil : 2).fixedSize(horizontal: false, vertical: true)
                        Text(WatchlistText.progress(entry)).font(.caption).foregroundColor(Theme.muted).lineLimit(2)
                        if let when = WatchlistText.when(entry) {
                            Text(when).font(.caption2.weight(.semibold))
                                .foregroundColor(paused ? WatchlistText.pausedTint : Theme.muted.opacity(0.8))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.leading, 10).padding(.vertical, 10).contentShape(Rectangle())
            }
            .buttonStyle(LoungePressStyle()).foregroundColor(.white)
            VStack(spacing: 2) {
                PlayButton(anime: entry.anime, size: 38, prominent: false)
                Menu { WatchlistMenu(entry: entry, library: library) } label: {
                    Image(systemName: "ellipsis").font(.body.weight(.bold)).foregroundColor(Theme.muted)
                        .frame(width: 44, height: 40).contentShape(Rectangle())
                }
                .accessibilityLabel("Status und Aktionen für \(entry.anime.title)")
            }
            .padding(.trailing, 6)
        }
        .glassCard(cornerRadius: 16)
        .contextMenu { WatchlistMenu(entry: entry, library: library) }
    }
    private var thumbnail: some View {
        ZStack(alignment: .bottom) {
            Color.clear.aspectRatio(16 / 9, contentMode: .fit).overlay(WideArtwork(anime: entry.anime))
                .saturation(paused ? 0.15 : 1).brightness(paused ? -0.08 : 0)
            if paused {
                Image(systemName: "pause.fill").font(.system(size: 13, weight: .bold)).foregroundColor(.white)
                    .frame(width: 30, height: 30).background(.ultraThinMaterial, in: Circle())
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if let fraction = WatchlistText.openFraction(entry) {
                ProgressBar(value: fraction, track: .black.opacity(0.45), height: 3)
            }
        }
        .frame(width: typeSize.isAccessibilitySize ? nil : 136)
        .clipShape(RoundedRectangle(cornerRadius: Theme.tileRadius))
        .overlay(RoundedRectangle(cornerRadius: Theme.tileRadius).stroke(Theme.stroke))
    }
}

// MARK: - Geplant
private struct PlannedGrid: View {
    let entries: [WatchlistEntry]
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.dynamicTypeSize) private var typeSize
    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: typeSize.isAccessibilitySize ? 150 : 104), spacing: 12, alignment: .top)], spacing: 18) {
            ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                NavigationLink { DetailView(anime: entry.anime) } label: {
                    VStack(alignment: .leading, spacing: 7) {
                        Color.clear.aspectRatio(2 / 3, contentMode: .fit)
                            .overlay(AnimeArtwork(anime: entry.anime))
                            .clipShape(RoundedRectangle(cornerRadius: Theme.posterRadius))
                            .overlay(RoundedRectangle(cornerRadius: Theme.posterRadius).stroke(Theme.stroke))
                        Text(entry.anime.title).font(.caption.weight(.medium)).foregroundColor(.white.opacity(0.85))
                            .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .buttonStyle(LoungePressStyle())
                .contextMenu { WatchlistMenu(entry: entry, library: library) }
                .appearStagger(index)
            }
        }
        .padding(.horizontal, 20)
    }
}

// MARK: - Fertig
private struct TrophyCabinet: View {
    let entries: [WatchlistEntry]
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.dynamicTypeSize) private var typeSize
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            TrophyCabinetHeader(entries: entries, episodes: library.active.finishedEpisodes,
                                hours: Int(library.active.watchedSeconds / 3600))
                .padding(.horizontal, 20).appearStagger(0)
            if !entries.isEmpty {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: typeSize.isAccessibilitySize ? 150 : 104), spacing: 14, alignment: .top)], spacing: 22) {
                    ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                        NavigationLink { DetailView(anime: entry.anime) } label: { TrophyPoster(entry: entry) }
                            .buttonStyle(LoungePressStyle())
                            .contextMenu { WatchlistMenu(entry: entry, library: library) }
                            .appearStagger(index + 1)
                    }
                }
                .padding(.horizontal, 20)
            }
            NavigationLink { FinishedView() } label: {
                HStack(spacing: 12) {
                    Image(systemName: "plus").font(.body.weight(.bold)).frame(width: 36, height: 36)
                        .background(Circle().fill(Color.white.opacity(0.08)))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Woanders gesehen?").font(.subheadline.weight(.semibold))
                        Text("Trag fertige Anime per Namen ein").font(.caption).foregroundColor(Theme.muted)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundColor(Theme.muted)
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.white.opacity(0.16), style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
                .contentShape(Rectangle())
            }
            .buttonStyle(LoungePressStyle()).foregroundColor(.white).padding(.horizontal, 20)
        }
    }
}

// MARK: - Shared pieces
/// Status and actions for one series, behind a long press and the "…" button.
struct WatchlistMenu: View {
    let entry: WatchlistEntry
    let library: LibraryStore
    var body: some View {
        Button { Task { await QuickPlay.start(entry.anime, library: library) } } label: { Label("Abspielen", systemImage: "play.fill") }
        Section("Status") {
            ForEach(SavedView.lists, id: \.self) { choice in
                Button { library.setStatus(choice, for: entry.anime) } label: {
                    Label(choice.label, systemImage: entry.status == choice ? "checkmark" : choice.symbol)
                }
            }
            if entry.manual {
                Button { library.setStatus(nil, for: entry.anime) } label: { Label("Automatisch erkennen", systemImage: "wand.and.stars") }
            }
        }
        Button(role: .destructive) { library.removeFromList(entry.anime) } label: { Label("Aus Watchlist entfernen", systemImage: "bookmark.slash") }
    }
}

/// Round play button that starts the series right away, with a spinner while it resolves.
struct PlayButton: View {
    let anime: Anime
    var size: CGFloat = 44
    var prominent = true
    @EnvironmentObject private var library: LibraryStore
    @State private var starting = false
    var body: some View {
        Button {
            guard !starting else { return }
            starting = true
            Task { @MainActor in
                await QuickPlay.start(anime, library: library)
                starting = false
            }
        } label: {
            ZStack {
                if starting { ProgressView().tint(prominent ? .black : .white) }
                else { Image(systemName: "play.fill").font(.system(size: size * 0.36, weight: .bold)).offset(x: size * 0.03) }
            }
            .foregroundColor(prominent ? .black : .white)
            .frame(width: size, height: size)
            .background(Circle().fill(prominent ? AnyShapeStyle(Color.white) : AnyShapeStyle(.ultraThinMaterial)))
            .overlay(Circle().stroke(Color.white.opacity(prominent ? 0 : 0.18)))
            .shadow(color: .black.opacity(prominent ? 0.35 : 0), radius: 10, y: 4)
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(LoungePressStyle())
        .accessibilityLabel("\(anime.title) abspielen")
    }
}

/// Starts a series right away: the open episode, the next one, or episode 1.
@MainActor enum QuickPlay {
    static func start(_ anime: Anime, library: LibraryStore) async {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        let decision = try? await SeriesCatalogStore.shared.resolveStart(anime: anime, profile: library.active)
        if let episode = decision?.episode {
            PlaybackCenter.shared.open(PlaybackRequest(anime: anime, episode: episode, profileID: library.profile.id), library: library)
        } else if decision == .caughtUp {
            ToastCenter.shared.show("Alles gesehen. Neue Folgen erscheinen hier von selbst.", icon: "checkmark.circle.fill")
        } else {
            ToastCenter.shared.show("Folgen konnten nicht geladen werden", icon: "exclamationmark.triangle")
        }
    }
}

enum WatchlistText {
    static let pausedTint = Color(red: 1.0, green: 0.73, blue: 0.38)
    /// "Folge 5 · noch 12:30", "S2 · F3 gesehen · 15 von 24", or the length of an untouched series.
    static func progress(_ entry: WatchlistEntry) -> String {
        guard let latest = entry.latest else {
            if let total = entry.totalEpisodes { return "\(total) \(total == 1 ? "Folge" : "Folgen")" }
            return entry.status == .completed ? "Abgeschlossen" : "Noch nicht angefangen"
        }
        let name = episodeName(latest.episode)
        if latest.isFinished {
            if let total = entry.totalEpisodes, entry.seenEpisodes > 0 { return "\(name) gesehen · \(min(entry.seenEpisodes, total)) von \(total)" }
            return "\(name) gesehen"
        }
        if let duration = latest.duration, duration > 0 { return "\(name) · noch \(EpisodeProgress.format(max(0, duration - latest.seconds)))" }
        return "\(name) · bei \(latest.timeLabel)"
    }
    /// Share of the open episode, for the line on the artwork.
    static func openFraction(_ entry: WatchlistEntry) -> Double? {
        guard let latest = entry.latest, !latest.isFinished, let fraction = latest.fraction, fraction > 0 else { return nil }
        return fraction
    }
    static func when(_ entry: WatchlistEntry, now: Date = Date()) -> String? {
        guard let date = entry.lastActivity else { return nil }
        if now.timeIntervalSince(date) < 60 { return entry.status == .paused ? "Pausiert" : "Gerade geschaut" }
        let relative = relativeFormatter.localizedString(for: date, relativeTo: now)
        return entry.status == .paused ? "Pausiert · zuletzt \(relative)" : "Zuletzt \(relative)"
    }
    /// "Folge 5", from season 2 on "S2 · F5", films "Film 1".
    static func episodeName(_ episode: Episode) -> String {
        if episode.path.contains("/filme/") { return "Film \(episode.number)" }
        if let range = episode.path.range(of: "/staffel-"),
           let season = Int(episode.path[range.upperBound...].prefix { $0.isNumber }), season > 1 {
            return "S\(season) · F\(episode.number)"
        }
        return "Folge \(episode.number)"
    }
    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "de_DE")
        formatter.dateTimeStyle = .named
        formatter.unitsStyle = .full
        return formatter
    }()
}

/// Cards rise in one after another the first time a list shows them.
private struct AppearStagger: ViewModifier {
    let index: Int
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func body(content: Content) -> some View {
        content
            .opacity(shown || reduceMotion ? 1 : 0)
            .offset(y: shown || reduceMotion ? 0 : 14)
            .onAppear {
                guard !shown, !reduceMotion else { return }
                withAnimation(.spring(response: 0.45, dampingFraction: 0.86).delay(Double(min(index, 8)) * 0.04)) { shown = true }
            }
    }
}
extension View {
    func appearStagger(_ index: Int) -> some View { modifier(AppearStagger(index: index)) }
}
