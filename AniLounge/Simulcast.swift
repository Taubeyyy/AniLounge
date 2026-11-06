import SwiftUI
import AniCore

/// This week's broadcasts in Japan (AniList), limited to series that exist on AniWorld.
@MainActor final class SimulcastStore: ObservableObject {
    static let shared = SimulcastStore()
    struct Slot: Identifiable, Hashable {
        var id: String { entry.id }
        let entry: AiringEntry
        let anime: Anime
    }
    @Published private(set) var slots: [Slot] = []
    @Published private(set) var loading = false
    @Published private(set) var error: String?
    private var loadedAt: Date?
    func load(force: Bool = false) async {
        if !force, let loadedAt, Date().timeIntervalSince(loadedAt) < 1800 { return }
        guard !loading else { return }
        loading = true; error = nil
        defer { loading = false }
        do {
            async let schedule = MetadataClient.shared.airingWeek()
            async let catalog = AniClient.shared.catalog()
            let (entries, series) = try await (schedule, catalog)
            let index = SimilarMatcher.index(series)
            var seen = Set<String>()
            slots = entries.compactMap { entry in
                guard let anime = SimilarMatcher.find(entry.titles, in: index), seen.insert(entry.id).inserted else { return nil }
                return Slot(entry: entry, anime: anime)
            }
            loadedAt = Date()
        } catch {
            if !Task.isCancelled { self.error = "Der Kalender konnte nicht geladen werden." }
        }
    }
    func slots(on day: Date) -> [Slot] { slots.filter { Calendar.current.isDate($0.entry.airingAt, inSameDayAs: day) } }
}

struct CalendarView: View {
    @ObservedObject private var store = SimulcastStore.shared
    @State private var day = Calendar.current.startOfDay(for: Date())
    private var days: [Date] {
        let today = Calendar.current.startOfDay(for: Date())
        return (-1...5).compactMap { Calendar.current.date(byAdding: .day, value: $0, to: today) }
    }
    var body: some View {
        LoungeScroll(title: "Simulcast-Kalender", largeTitle: true) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Neue Folgen in Japan, nur Serien, die es auf AniWorld gibt. Deutsche Fassungen folgen meist später.")
                    .font(.subheadline).foregroundColor(Theme.muted).padding(.horizontal, 20)
                ScrollViewReader { reader in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(days, id: \.self) { date in dayPill(date).id(date) }
                        }.padding(.horizontal, 20)
                    }.onAppear { reader.scrollTo(day, anchor: .center) }
                }
                if store.loading && store.slots.isEmpty {
                    VStack(spacing: 14) { ForEach(0..<5, id: \.self) { _ in EpisodeRowSkeleton() } }.padding(.horizontal, 20)
                } else if let error = store.error, store.slots.isEmpty {
                    ProblemView(message: error) { Task { await store.load(force: true) } }
                } else {
                    let items = store.slots(on: day)
                    if items.isEmpty {
                        Text("An diesem Tag läuft nichts, das es auf AniWorld gibt.").font(.subheadline).foregroundColor(Theme.muted)
                            .frame(maxWidth: .infinity).padding(.vertical, 40)
                    }
                    LazyVStack(spacing: 12) {
                        ForEach(items) { slot in
                            NavigationLink { DetailView(anime: slot.anime) } label: { SlotRow(slot: slot) }
                                .buttonStyle(LoungePressStyle()).foregroundColor(.white)
                                .transition(.opacity.combined(with: .offset(y: 10)))
                        }
                    }.padding(.horizontal, 20).animation(.easeOut(duration: 0.25), value: day)
                }
            }
        } leading: {
            BackButton()
        }
        .task { await store.load() }
        .refreshable { await store.load(force: true) }
    }
    private func dayPill(_ date: Date) -> some View {
        let active = Calendar.current.isDate(date, inSameDayAs: day)
        let count = store.slots(on: date).count
        return Button {
            UISelectionFeedbackGenerator().selectionChanged()
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { day = date }
        } label: {
            VStack(spacing: 3) {
                Text(Calendar.current.isDateInToday(date) ? "Heute" : date.formatted(.dateTime.weekday(.abbreviated)))
                    .font(.subheadline.bold())
                Text(count == 0 ? "–" : "\(count)").font(.caption2.monospacedDigit()).opacity(0.7)
            }
            .frame(minWidth: 54).padding(.vertical, 9).padding(.horizontal, 6)
            .background(active ? AnyShapeStyle(Color.white) : AnyShapeStyle(Theme.panelHigh))
            .foregroundColor(active ? .black : .white).clipShape(RoundedRectangle(cornerRadius: 14))
        }.buttonStyle(LoungePressStyle()).accessibilityAddTraits(active ? .isSelected : [])
    }
}
private struct SlotRow: View {
    let slot: SimulcastStore.Slot
    var body: some View {
        let aired = slot.entry.airingAt <= Date()
        HStack(spacing: 14) {
            Text(slot.entry.airingAt.formatted(date: .omitted, time: .shortened)).font(.subheadline.bold().monospacedDigit())
                .foregroundColor(aired ? Theme.muted : .white).frame(width: 52, alignment: .leading)
            AnimeArtwork(anime: slot.anime).frame(width: 52, height: 78).clipShape(RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 4) {
                Text(slot.anime.title).font(.subheadline.bold()).lineLimit(2).multilineTextAlignment(.leading)
                Text("Folge \(slot.entry.episode)").font(.caption).foregroundColor(Theme.muted)
                if aired {
                    Label("In Japan erschienen", systemImage: "checkmark.circle.fill").font(.caption2.bold()).foregroundColor(Theme.accentSoft)
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.caption.bold()).foregroundColor(Theme.muted)
        }.contentShape(Rectangle())
    }
}
/// "Heute in Japan" on the home screen, linking to the full calendar.
struct TodaySimulcastShelf: View {
    @ObservedObject private var store = SimulcastStore.shared
    var body: some View {
        let today = store.slots(on: Date())
        if !today.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    SectionHeader(title: "Heute in Japan", subtitle: "Simulcast")
                    NavigationLink { CalendarView() } label: {
                        Text("Kalender").font(.subheadline.bold()).foregroundColor(Theme.accentSoft).frame(minHeight: 44)
                    }.padding(.trailing, 20)
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 12) {
                        ForEach(today) { slot in
                            NavigationLink { DetailView(anime: slot.anime) } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    AnimeArtwork(anime: slot.anime).frame(width: 112, height: 168).clipShape(RoundedRectangle(cornerRadius: 8))
                                        .overlay(alignment: .topLeading) {
                                            Text(slot.entry.airingAt.formatted(date: .omitted, time: .shortened)).font(.caption2.bold().monospacedDigit())
                                                .padding(.horizontal, 6).padding(.vertical, 3).background(.ultraThinMaterial).clipShape(Capsule()).padding(6)
                                        }
                                    Text(slot.anime.title).font(.caption.weight(.semibold)).lineLimit(2)
                                    Text("Folge \(slot.entry.episode)").font(.caption2).foregroundColor(Theme.muted)
                                }.frame(width: 112).foregroundColor(.white)
                            }.buttonStyle(LoungePressStyle())
                        }
                    }.padding(.horizontal, 20)
                }
            }.transition(.opacity)
        }
    }
}
