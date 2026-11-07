import SwiftUI
import AniCore

/// Colours of the four trophy tiers. Unknown length (finished elsewhere, catalog not loaded
/// yet) uses gold without naming a tier.
struct TrophyStyle {
    let tier: TrophyTier?
    var colors: [Color] {
        switch tier ?? .gold {
        case .bronze: return [Color(red: 0.95, green: 0.68, blue: 0.46), Color(red: 0.62, green: 0.36, blue: 0.19)]
        case .silver: return [Color(red: 0.95, green: 0.96, blue: 0.99), Color(red: 0.58, green: 0.62, blue: 0.70)]
        case .gold: return [Color(red: 1.0, green: 0.88, blue: 0.46), Color(red: 0.86, green: 0.57, blue: 0.11)]
        case .platinum: return [Color(red: 0.90, green: 0.97, blue: 1.0), Color(red: 0.60, green: 0.68, blue: 0.98)]
        }
    }
    var fill: LinearGradient { LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing) }
    var edge: LinearGradient { LinearGradient(colors: [colors[0].opacity(0.95), colors[1].opacity(0.3)], startPoint: .top, endPoint: .bottom) }
    var softEdge: LinearGradient { LinearGradient(colors: [colors[0].opacity(0.5), colors[1].opacity(0.12)], startPoint: .top, endPoint: .bottom) }
    var glow: Color { colors[1] }
    var light: Color { colors[0] }
    static let goldFill = TrophyStyle(tier: .gold).fill
    /// "Gold · 64 Folgen", or just "Fertig" while the length is unknown.
    static func caption(_ entry: WatchlistEntry) -> String {
        guard let tier = entry.trophy, let episodes = entry.trophyEpisodes else { return "Fertig" }
        return "\(tier.label) · \(episodes) \(episodes == 1 ? "Folge" : "Folgen")"
    }
}

/// Small round medal for posters and counts.
struct TrophyBadge: View {
    let tier: TrophyTier?
    var size: CGFloat = 28
    var body: some View {
        let style = TrophyStyle(tier: tier)
        Image(systemName: "trophy.fill")
            .font(.system(size: size * 0.46, weight: .bold))
            .foregroundColor(.black.opacity(0.7))
            .frame(width: size, height: size)
            .background(Circle().fill(style.fill))
            .overlay(Circle().stroke(Color.white.opacity(0.6), lineWidth: max(1, size / 30)).blendMode(.overlay))
            .shadow(color: style.glow.opacity(0.55), radius: size * 0.22)
            .accessibilityLabel(tier.map { "Trophäe \($0.label)" } ?? "Trophäe")
    }
}

/// The large trophy of the cabinet: metallic gradient, a warm glow and a light sweep now and
/// then (still with "Bewegung reduzieren").
struct TrophyEmblem: View {
    let tier: TrophyTier?
    var size: CGFloat = 64
    var animated = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var sweep = false
    var body: some View {
        let style = TrophyStyle(tier: tier)
        let symbol = Image(systemName: "trophy.fill").font(.system(size: size * 0.6, weight: .bold))
        ZStack {
            Circle().fill(RadialGradient(colors: [style.glow.opacity(0.5), .clear], center: .center, startRadius: 1, endRadius: size * 0.7))
                .frame(width: size * 1.4, height: size * 1.4)
            symbol.foregroundStyle(style.fill)
                .overlay {
                    if animated && !reduceMotion {
                        GeometryReader { geo in
                            LinearGradient(colors: [.clear, .white.opacity(0.85), .clear], startPoint: .leading, endPoint: .trailing)
                                .frame(width: geo.size.width * 0.35)
                                .rotationEffect(.degrees(18))
                                .offset(x: sweep ? geo.size.width * 2.2 : -geo.size.width * 1.2)
                        }
                        .mask { symbol }
                        .allowsHitTesting(false)
                    }
                }
                .shadow(color: style.glow.opacity(0.65), radius: size * 0.18)
        }
        .frame(width: size, height: size)
        .onAppear {
            guard animated && !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 3.2).delay(0.5).repeatForever(autoreverses: false)) { sweep = true }
        }
        .accessibilityHidden(true)
    }
}

/// Poster of a finished series: tier-coloured edge, medal on the corner, tier and length below.
struct TrophyPoster: View {
    let entry: WatchlistEntry
    var body: some View {
        let style = TrophyStyle(tier: entry.trophy)
        VStack(alignment: .leading, spacing: 6) {
            Color.clear.aspectRatio(2 / 3, contentMode: .fit)
                .overlay(AnimeArtwork(anime: entry.anime))
                .clipShape(RoundedRectangle(cornerRadius: Theme.posterRadius))
                .overlay(RoundedRectangle(cornerRadius: Theme.posterRadius).stroke(style.edge, lineWidth: 1.5))
                .overlay(alignment: .bottomTrailing) { TrophyBadge(tier: entry.trophy, size: 30).offset(x: 5, y: 8) }
            Text(entry.anime.title).font(.caption.weight(.semibold)).foregroundColor(.white)
                .lineLimit(2).fixedSize(horizontal: false, vertical: true).padding(.top, 4)
            Text(TrophyStyle.caption(entry)).font(.caption2.weight(.semibold)).foregroundColor(style.light.opacity(0.9))
        }
        .accessibilityElement(children: .combine)
    }
}

/// Head of the "Fertig" list: the cabinet with counts per tier and the overall numbers.
struct TrophyCabinetHeader: View {
    let entries: [WatchlistEntry]
    let episodes: Int
    /// "12 Std. Sehzeit"; nil before anything was watched in the app.
    let watchTime: String?
    private var totals: String {
        let count = "Insgesamt \(episodes) \(episodes == 1 ? "Folge" : "Folgen")"
        guard let watchTime else { return count }
        return count + " · " + watchTime
    }
    var body: some View {
        let tiers = Dictionary(grouping: entries.compactMap(\.trophy), by: { $0 }).mapValues(\.count)
        let best = tiers.keys.max()
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 16) {
                TrophyEmblem(tier: best ?? .gold, size: 66)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Trophäenschrank").font(.title3.weight(.heavy)).tracking(-0.3)
                    Text(entries.isEmpty ? "Schau einen Anime zu Ende und hol dir deine erste Trophäe."
                         : "\(entries.count) Anime abgeschlossen")
                        .font(.footnote).foregroundColor(Theme.muted).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 8) {
                ForEach(TrophyTier.allCases.reversed(), id: \.self) { tier in
                    let count = tiers[tier] ?? 0
                    HStack(spacing: 6) {
                        TrophyBadge(tier: tier, size: 20)
                        Text("\(count)").font(.footnote.weight(.bold)).monospacedDigit()
                    }
                    .padding(.leading, 5).padding(.trailing, 10).frame(minHeight: 30)
                    .background(Color.white.opacity(0.06)).clipShape(Capsule())
                    .opacity(count == 0 ? 0.45 : 1)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(tier.label): \(count)")
                }
                Spacer(minLength: 0)
            }
            if episodes > 0 {
                Text(totals)
                    .font(.caption.weight(.semibold)).foregroundColor(Theme.muted)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            ZStack(alignment: .topLeading) {
                Theme.panel
                RadialGradient(colors: [TrophyStyle(tier: best ?? .gold).glow.opacity(0.28), .clear],
                               center: UnitPoint(x: 0.12, y: 0.2), startRadius: 4, endRadius: 260)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(TrophyStyle(tier: best ?? .gold).softEdge, lineWidth: 1))
        .foregroundColor(.white)
    }
}

/// Announces trophies one after another, a few seconds each, with a success haptic.
@MainActor final class TrophyCenter: ObservableObject {
    static let shared = TrophyCenter()
    struct Unlock: Identifiable, Equatable {
        let id = UUID()
        let anime: Anime
        let tier: TrophyTier?
        let episodes: Int?
    }
    @Published private(set) var current: Unlock?
    private(set) var queue: [Unlock] = []
    func unlock(_ entry: WatchlistEntry) {
        guard current?.anime.id != entry.id, !queue.contains(where: { $0.anime.id == entry.id }) else { return }
        queue.append(Unlock(anime: entry.anime, tier: entry.trophy, episodes: entry.trophyEpisodes))
        showNext()
    }
    func dismiss() {
        withAnimation(.easeIn(duration: 0.25)) { current = nil }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 400_000_000)
            showNext()
        }
    }
    private func showNext() {
        guard current == nil, !queue.isEmpty else { return }
        let next = queue.removeFirst()
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) { current = next }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 4_500_000_000)
            guard current?.id == next.id else { return }
            dismiss()
        }
    }
}

struct TrophyBannerHost: View {
    @ObservedObject private var center = TrophyCenter.shared
    var body: some View {
        ZStack {
            if let unlock = center.current {
                TrophyBanner(unlock: unlock)
                    .padding(.horizontal, 16).padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .id(unlock.id)
                    .onTapGesture { center.dismiss() }
            }
        }
    }
}

/// "Trophäe freigeschaltet": the medal pops in front of slowly turning light.
struct TrophyBanner: View {
    let unlock: TrophyCenter.Unlock
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var popped = false
    var body: some View {
        let style = TrophyStyle(tier: unlock.tier)
        HStack(spacing: 14) {
            ZStack {
                if !reduceMotion {
                    AngularGradient(colors: [style.glow.opacity(0), style.light.opacity(0.6), style.glow.opacity(0),
                                             style.light.opacity(0.6), style.glow.opacity(0)], center: .center)
                        .clipShape(Circle()).blur(radius: 3)
                        .rotationEffect(.degrees(popped ? 180 : 0))
                        .animation(.linear(duration: 6).repeatForever(autoreverses: false), value: popped)
                }
                TrophyBadge(tier: unlock.tier, size: 44)
                    .scaleEffect(popped || reduceMotion ? 1 : 0.3)
                    .rotationEffect(.degrees(popped || reduceMotion ? 0 : -30))
            }
            .frame(width: 60, height: 60)
            VStack(alignment: .leading, spacing: 2) {
                Text("TROPHÄE FREIGESCHALTET").font(.caption2.weight(.heavy)).tracking(1.1).foregroundColor(style.light)
                Text(unlock.anime.title).font(.subheadline.weight(.bold)).lineLimit(1)
                Text(detail).font(.caption).foregroundColor(Theme.muted)
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, 10).padding(.trailing, 16).padding(.vertical, 10)
        .frame(maxWidth: 440)
        .background(.ultraThinMaterial)
        .background(Color.black.opacity(0.55))
        .clipShape(RoundedRectangle(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22).stroke(style.edge, lineWidth: 1))
        .shadow(color: .black.opacity(0.45), radius: 20, y: 8)
        .foregroundColor(.white)
        .onAppear { withAnimation(.spring(response: 0.45, dampingFraction: 0.55).delay(0.15)) { popped = true } }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isStaticText)
    }
    private var detail: String {
        let tier = unlock.tier?.label ?? "Abgeschlossen"
        guard let episodes = unlock.episodes else { return tier }
        return "\(tier) · \(episodes) \(episodes == 1 ? "Folge" : "Folgen")"
    }
}
