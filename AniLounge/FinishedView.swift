import SwiftUI
import AniCore

/// Every series marked "Fertig", including ones watched elsewhere: type a name, tap +.
struct FinishedView: View {
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var catalog: [Anime] = []
    @State private var query = ""
    @State private var loadError: String?
    @FocusState private var focused: Bool
    private var finished: [Anime] {
        library.favorites.filter { library.status(for: $0) == .completed }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
    private var matches: [Anime] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard term.count >= 2 else { return [] }
        return Array(catalog.filter { $0.title.localizedStandardContains(term) || $0.aliases.localizedStandardContains(term) }.prefix(8))
    }
    var body: some View {
        LoungeScroll(title: "Fertig geschaut", largeTitle: true) {
            VStack(alignment: .leading, spacing: 16) {
                addField
                if !matches.isEmpty {
                    VStack(spacing: 0) {
                        ForEach(matches) { anime in suggestion(anime) }
                    }.glassCard().transition(.opacity.combined(with: .offset(y: -6)))
                } else if let loadError, !query.isEmpty {
                    Text(loadError).font(.footnote).foregroundColor(.orange)
                }
                HStack {
                    Text(finished.isEmpty ? "Noch nichts eingetragen" : "\(finished.count) Anime").font(.footnote.weight(.semibold)).foregroundColor(Theme.muted)
                    Spacer()
                }.padding(.top, 4)
                if finished.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "checkmark.seal").font(.system(size: 40, weight: .light)).foregroundColor(Theme.accentSoft)
                        Text("Trag oben Anime ein, die du schon gesehen hast, auch woanders.")
                            .font(.subheadline).foregroundColor(Theme.muted).multilineTextAlignment(.center)
                    }.frame(maxWidth: .infinity).padding(.vertical, 40)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: typeSize.isAccessibilitySize ? 150 : 104), spacing: 12, alignment: .top)], spacing: 18) {
                        ForEach(finished) { anime in
                            NavigationLink { DetailView(anime: anime) } label: {
                                if let entry = library.entry(for: anime) { TrophyPoster(entry: entry) } else { GridPoster(anime: anime) }
                            }
                                .buttonStyle(LoungePressStyle())
                                .contextMenu {
                                    Button { library.setStatus(.watching, for: anime) } label: { Label("Doch noch nicht fertig", systemImage: "play.circle") }
                                    Button(role: .destructive) { library.removeFromList(anime) } label: {
                                        Label("Aus der Liste entfernen", systemImage: "trash")
                                    }
                                }
                                .transition(.opacity.combined(with: .scale(scale: 0.9)))
                        }
                    }
                }
            }.padding(.horizontal, 20)
            .animation(.easeInOut(duration: 0.2), value: matches.map(\.id))
            .animation(.spring(response: 0.35, dampingFraction: 0.85), value: finished.map(\.id))
        } leading: {
            BackButton()
        }
        .scrollDismissesKeyboard(.immediately)
        .task {
            guard catalog.isEmpty else { return }
            do { catalog = try await AniClient.shared.catalog() }
            catch { loadError = "Der Katalog konnte nicht geladen werden." }
        }
    }
    private var addField: some View {
        HStack(spacing: 12) {
            Image(systemName: "plus.magnifyingglass").foregroundColor(Theme.muted)
            TextField("Anime hinzufügen, z. B. Frieren", text: $query)
                .textInputAutocapitalization(.never).autocorrectionDisabled().focused($focused).submitLabel(.done)
                .onSubmit { if let first = matches.first { add(first) } }
            if !query.isEmpty {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundColor(Theme.muted).frame(width: 40, height: 40) }
                    .accessibilityLabel("Eingabe löschen")
            }
        }
        .padding(.leading, 16).padding(.trailing, 4).frame(minHeight: 54).glassCard(cornerRadius: 14)
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(focused ? Theme.accent.opacity(0.7) : .clear, lineWidth: 1.5))
    }
    private func suggestion(_ anime: Anime) -> some View {
        let done = library.status(for: anime) == .completed && library.contains(anime)
        return Button { if !done { add(anime) } } label: {
            HStack(spacing: 12) {
                AnimeArtwork(anime: anime).frame(width: 36, height: 54).clipShape(RoundedRectangle(cornerRadius: 5))
                Text(anime.title).font(.subheadline.weight(.semibold)).lineLimit(2).multilineTextAlignment(.leading)
                Spacer(minLength: 8)
                Image(systemName: done ? "checkmark.circle.fill" : "plus.circle.fill").font(.title3)
                    .foregroundColor(done ? Theme.muted : Theme.accentSoft)
            }.padding(.horizontal, 12).padding(.vertical, 8).contentShape(Rectangle())
        }.buttonStyle(LoungePressStyle()).foregroundColor(.white)
            .accessibilityLabel(done ? "\(anime.title), schon fertig" : "\(anime.title) als fertig eintragen")
    }
    /// Marks the series as finished; keeps the field open for the next name.
    private func add(_ anime: Anime) {
        library.setStatus(.completed, for: anime)
        query = ""
        focused = true
    }
}
