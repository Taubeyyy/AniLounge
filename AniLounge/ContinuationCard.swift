import SwiftUI
import AniCore

struct ContinuationCard: View {
    let item: EpisodeProgress
    let decision: SeriesPlaybackDecision
    private var progress: EpisodeProgress? {
        if case .resume(let value) = decision { return value }
        return nil
    }
    private var label: String {
        switch decision {
        case .resume(let value):
            if let duration = value.duration {
                return "Folge \(value.episode.number) · noch \(EpisodeProgress.format(max(0, duration - value.seconds)))"
            }
            return "Folge \(value.episode.number) · bei \(value.timeLabel)"
        case .play(let episode): return "Als Nächstes · Folge \(episode.number)"
        default: return "Weitere Folgen prüfen"
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ZStack(alignment: .bottom) {
                WideArtwork(anime: item.anime)
                LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .center, endPoint: .bottom)
                Image(systemName: decision.episode == nil ? "list.bullet" : "play.fill")
                    .frame(width: 42, height: 42).background(.ultraThinMaterial).clipShape(Circle())
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if let fraction = progress?.fraction {
                    ProgressBar(value: fraction, track: .white.opacity(0.25), height: 3)
                }
            }.frame(width: 230, height: 129).clipShape(RoundedRectangle(cornerRadius: Theme.tileRadius))
            Text(item.anime.title).font(.subheadline.bold()).lineLimit(2)
            Text(label).font(.caption.monospacedDigit()).foregroundColor(Theme.muted)
        }.frame(width: 230).foregroundColor(.white)
    }
}
