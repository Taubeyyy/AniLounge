import SwiftUI
import Charts
import AniCore

/// "Weil du … geschaut hast": AniList recommendations for the latest series, limited to
/// what exists on AniWorld and not already on the list or started.
struct BecauseYouWatchedShelf: View {
    @EnvironmentObject private var library: LibraryStore
    @State private var basis: Anime?
    @State private var items: [Anime] = []
    var body: some View {
        Group {
            if let basis, !items.isEmpty {
                AnimeShelf(title: "Weil du \(basis.title) geschaut hast", items: items).transition(.opacity)
            }
        }
        .task(id: library.history.first?.anime.id) { await load() }
    }
    private func load() async {
        guard let anime = library.history.first?.anime else { items = []; return }
        guard let detail = try? await AniClient.shared.detail(path: anime.path), let imdb = detail.imdb,
              let extras = try? await MetadataClient.shared.extras(imdb: imdb), !extras.recommendations.isEmpty,
              let catalog = try? await AniClient.shared.catalog(), !Task.isCancelled else { return }
        let known = Set(library.favorites.map(\.id)).union(library.history.map(\.anime.id))
        let matched = SimilarMatcher.match(extras.recommendations, in: catalog).filter { $0.id != anime.id && !known.contains($0.id) }
        withAnimation(.easeOut(duration: 0.35)) { basis = anime; items = Array(matched.prefix(12)) }
    }
}

/// Episodes started or finished per day over the last week.
struct WeekActivity: View {
    let profile: ProfileLibrary
    private struct Day: Identifiable {
        let date: Date
        let count: Int
        var id: Date { date }
    }
    private var days: [Day] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        return (0..<7).reversed().compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else { return nil }
            let count = profile.progress.values.filter { calendar.isDate($0.updatedAt, inSameDayAs: day) }.count
            return Day(date: day, count: count)
        }
    }
    var body: some View {
        let data = days
        let total = data.reduce(0) { $0 + $1.count }
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Diese Woche").font(.headline)
                Spacer()
                Text(total == 1 ? "1 Folge" : "\(total) Folgen").font(.subheadline.weight(.semibold)).foregroundColor(Theme.muted)
            }
            Chart(data) { day in
                BarMark(x: .value("Tag", day.date, unit: .day), y: .value("Folgen", day.count))
                    .foregroundStyle(Calendar.current.isDateInToday(day.date) ? AnyShapeStyle(Theme.accentGradient) : AnyShapeStyle(Theme.accent.opacity(0.45)))
                    .cornerRadius(5)
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .day)) { _ in AxisValueLabel(format: .dateTime.weekday(.narrow)).foregroundStyle(Theme.muted) }
            }
            .chartYAxis(.hidden)
            .frame(height: 110)
            .accessibilityLabel("Folgen pro Tag in den letzten sieben Tagen, insgesamt \(total)")
        }
        .padding(16).glassCard()
    }
}
