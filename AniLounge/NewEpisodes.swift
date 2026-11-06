import SwiftUI
import Combine
import AniCore

/// Remembers series that were fully watched. When such a series offers a next episode again,
/// AniWorld added one: it shows up under "Neue Folgen für dich".
@MainActor final class NewEpisodeTracker: ObservableObject {
    static let shared = NewEpisodeTracker()
    @Published private(set) var caughtUp: Set<String> = []
    private var profileID: UUID?
    private let defaults = UserDefaults.standard
    private func key(_ id: UUID) -> String { "series.caughtUp." + id.uuidString }
    func evaluate(profile: ProfileLibrary, catalogs: [String: SeriesCatalog]) {
        var set = Set(defaults.stringArray(forKey: key(profile.profile.id)) ?? [])
        for item in profile.continuationCandidates {
            switch SeriesPlaybackState.start(anime: item.anime, profile: profile, catalog: catalogs[item.anime.id]) {
            case .caughtUp: set.insert(item.anime.id)
            case .resume: set.remove(item.anime.id) // The viewer started the new episode.
            default: break
            }
        }
        defaults.set(Array(set), forKey: key(profile.profile.id))
        if set != caughtUp || profileID != profile.profile.id { caughtUp = set; profileID = profile.profile.id }
    }
    func isNew(_ anime: Anime, decision: SeriesPlaybackDecision) -> Bool {
        guard caughtUp.contains(anime.id), case .play = decision else { return false }
        return true
    }
}

private struct NewItem: Identifiable {
    let item: EpisodeProgress
    let decision: SeriesPlaybackDecision
    var id: String { item.id }
}
struct NewEpisodesShelf: View {
    @EnvironmentObject private var library: LibraryStore
    @ObservedObject private var catalogs = SeriesCatalogStore.shared
    @ObservedObject private var tracker = NewEpisodeTracker.shared
    var body: some View {
        let items: [NewItem] = library.active.continuationCandidates.compactMap { item in
            let decision = SeriesPlaybackState.start(anime: item.anime, profile: library.active, catalog: catalogs.catalogs[item.anime.id])
            return tracker.isNew(item.anime, decision: decision) ? NewItem(item: item, decision: decision) : nil
        }
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                SectionHeader(title: "Neue Folgen für dich", subtitle: "Serien, die du schon durch hattest")
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 12) {
                        ForEach(items) { entry in
                            let item = entry.item
                            let decision = entry.decision
                            if let episode = decision.episode {
                                Button {
                                    PlaybackCenter.shared.open(PlaybackRequest(anime: item.anime, episode: episode, profileID: library.profile.id), library: library)
                                } label: {
                                    ContinuationCard(item: item, decision: decision)
                                        .overlay(alignment: .topLeading) {
                                            Text("NEU").font(.caption2.weight(.black)).tracking(1).padding(.horizontal, 8).padding(.vertical, 4)
                                                .background(Theme.accentGradient).clipShape(Capsule()).padding(8)
                                        }
                                }.buttonStyle(LoungePressStyle())
                            }
                        }
                    }.padding(.horizontal, 20)
                }
            }.transition(.opacity.combined(with: .offset(y: 10)))
        }
    }
}
