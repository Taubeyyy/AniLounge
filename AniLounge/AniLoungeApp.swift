import SwiftUI
import Combine
import AniCore

@main struct AniLoungeApp: App {
    @UIApplicationDelegateAdaptor(DownloadAppDelegate.self) private var appDelegate
    @StateObject private var library = LibraryStore()
    var body: some Scene {
        WindowGroup {
            RootView().environmentObject(library).preferredColorScheme(.dark).tint(Theme.accent).task {
                DownloadStore.shared.start()
                Task.detached(priority: .background) { ArtworkCache.shared.trim() }
            }
        }
    }
}
struct RootView: View {
    @EnvironmentObject private var library: LibraryStore
    @ObservedObject private var playback = PlaybackCenter.shared
    @ObservedObject private var quickActions = QuickActions.shared
    @ObservedObject private var catalogs = SeriesCatalogStore.shared
    @State private var selected = 0
    @State private var showingCalendar = false
    private let tabs = [("Start", "house.fill"), ("Suche", "magnifyingglass"), ("Watchlist", "bookmark.fill"), ("Downloads", "arrow.down.circle.fill"), ("Profil", "person.crop.circle.fill")]
    var body: some View {
        TabView(selection: $selected) {
            NavigationStack { HomeView() }.tag(0)
            NavigationStack { SearchView() }.tag(1)
            NavigationStack { SavedView() }.tag(2)
            NavigationStack { DownloadsView() }.tag(3)
            NavigationStack { ProfileView() }.tag(4)
        }
        .toolbar(.hidden, for: .tabBar)
        .safeAreaInset(edge: .bottom, spacing: 0) { LoungeTabBar(tabs: tabs, selected: $selected) }
        .id(library.profile.id)
        .overlay(alignment: .top) { ToastHost() }
        // Every episode opens here, and so does a restored Picture in Picture window.
        .fullScreenCover(item: $playback.presented) { PlaybackView(model: $0) }
        .confirmationDialog("Gespeicherte Sprachfassung", isPresented: Binding(
            get: { playback.pendingOffline != nil }, set: { if !$0 { playback.pendingOffline = nil } }),
            titleVisibility: .visible, presenting: playback.pendingOffline) { prompt in
                Button("Diese Fassung offline ansehen") { playback.confirmOffline(prompt) }
                Button("Online-Quelle wählen") { playback.chooseOnline(prompt) }
                Button("Abbrechen", role: .cancel) { playback.pendingOffline = nil }
            } message: { prompt in
                Text("Die gespeicherte Fassung (\(prompt.option.language ?? "Sprache unbekannt")) entspricht nicht deiner bevorzugten Sprache. Möchtest du sie trotzdem ansehen?")
            }
        .onReceive(quickActions.$pending.compactMap { $0 }) { handle($0) }
        .sheet(isPresented: $showingCalendar) { NavigationStack { CalendarView() }.preferredColorScheme(.dark) }
        .alert("Speichern nicht möglich", isPresented: Binding(get: { library.storageError != nil }, set: { if !$0 { library.storageError = nil } })) { Button("OK", role: .cancel) {} } message: { Text(library.storageError ?? "") }
    }
}
extension RootView {
    /// Home screen quick action: continue the newest series, open the calendar or search.
    func handle(_ action: String) {
        quickActions.pending = nil
        switch action {
        case QuickActions.continueType:
            for item in library.active.continuationCandidates {
                if let episode = SeriesPlaybackState.start(anime: item.anime, profile: library.active, catalog: catalogs.catalogs[item.anime.id]).episode {
                    PlaybackCenter.shared.open(PlaybackRequest(anime: item.anime, episode: episode, profileID: library.profile.id), library: library)
                    return
                }
            }
            selected = 0
        case QuickActions.calendarType: showingCalendar = true
        case QuickActions.searchType: selected = 1
        default: break
        }
    }
}
struct LoungeTabBar: View {
    let tabs: [(String, String)]
    @Binding var selected: Int
    @Namespace private var pill
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<tabs.count, id: \.self) { index in
                Button {
                    guard selected != index else { return }
                    UISelectionFeedbackGenerator().selectionChanged()
                    withAnimation(reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.82)) { selected = index }
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: tabs[index].1).font(.system(size: 19, weight: .semibold))
                            .scaleEffect(selected == index && !reduceMotion ? 1.12 : 1)
                            .animation(.spring(response: 0.3, dampingFraction: 0.5), value: selected)
                        Text(tabs[index].0).font(.caption2.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.8)
                    }.frame(maxWidth: .infinity).padding(.vertical, 10)
                        .foregroundColor(selected == index ? .white : Theme.muted)
                        .background {
                            if selected == index {
                                RoundedRectangle(cornerRadius: 18).fill(Theme.accent.opacity(0.28))
                                    .overlay(RoundedRectangle(cornerRadius: 18).stroke(Theme.accent.opacity(0.45), lineWidth: 0.5))
                                    .matchedGeometryEffect(id: "pill", in: pill)
                            }
                        }
                }.buttonStyle(LoungePressStyle()).accessibilityAddTraits(selected == index ? .isSelected : [])
            }
        }.padding(6).background(.ultraThinMaterial).clipShape(RoundedRectangle(cornerRadius: 24))
            .overlay(RoundedRectangle(cornerRadius: 24).stroke(Theme.stroke))
            .shadow(color: .black.opacity(0.45), radius: 20, y: 8)
            .padding(.horizontal, 16).padding(.top, 6).padding(.bottom, 4)
            .background(LinearGradient(colors: [Theme.background.opacity(0), Theme.background], startPoint: .top, endPoint: .center).ignoresSafeArea())
    }
}
struct LoungePressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.75 : 1)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: configuration.isPressed)
    }
}
extension View {
    func loungeCard() -> some View {
        self.background(LinearGradient(colors: [Theme.panel, Theme.panel.opacity(0.65)], startPoint: .topLeading, endPoint: .bottomTrailing))
            .clipShape(RoundedRectangle(cornerRadius: 22))
            .overlay(RoundedRectangle(cornerRadius: 22).stroke(Theme.stroke))
    }
    func shimmer(_ active: Bool = true) -> some View { modifier(Shimmer(active: active)) }
}
struct Shimmer: ViewModifier {
    let active: Bool
    @State private var phase: CGFloat = -1
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func body(content: Content) -> some View {
        content.overlay {
            if active && !reduceMotion {
                GeometryReader { geo in
                    LinearGradient(colors: [.clear, .white.opacity(0.09), .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: geo.size.width * 0.6).offset(x: phase * geo.size.width * 1.6)
                }.clipped().allowsHitTesting(false)
                    .onAppear { withAnimation(.linear(duration: 1.3).repeatForever(autoreverses: false)) { phase = 1 } }
            }
        }
    }
}
struct SectionHeader: View {
    let title: String
    var subtitle: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.title3.weight(.bold))
            if let subtitle { Text(subtitle).font(.caption).foregroundColor(Theme.muted) }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 20).accessibilityAddTraits(.isHeader)
    }
}
struct PosterSkeleton: View {
    var width: CGFloat = 132
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            RoundedRectangle(cornerRadius: 12).fill(Theme.panel).frame(width: width, height: width * 1.5)
            RoundedRectangle(cornerRadius: 4).fill(Theme.panel).frame(width: width * 0.8, height: 12)
        }.shimmer()
    }
}
struct HomeSkeleton: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            Rectangle().fill(Theme.panel).frame(height: 450).shimmer()
            ForEach(0..<2, id: \.self) { _ in
                VStack(alignment: .leading, spacing: 14) {
                    RoundedRectangle(cornerRadius: 4).fill(Theme.panel).frame(width: 160, height: 18).padding(.horizontal, 20)
                    HStack(spacing: 12) { ForEach(0..<4, id: \.self) { _ in PosterSkeleton() } }.padding(.horizontal, 20)
                }
            }
        }.accessibilityLabel("Lädt")
    }
}
enum Theme {
    static let background = Color(red: 0.045, green: 0.04, blue: 0.065)
    static let panel = Color(red: 0.105, green: 0.09, blue: 0.14)
    static let panelHigh = Color(red: 0.155, green: 0.13, blue: 0.205)
    static let accent = Color(red: 0.66, green: 0.38, blue: 0.96)
    static let accentSoft = Color(red: 0.80, green: 0.64, blue: 1.0)
    static let muted = Color.white.opacity(0.70)
    static let stroke = Color.white.opacity(0.08)
    static let accentGradient = LinearGradient(colors: [Color(red: 0.74, green: 0.42, blue: 1.0), Color(red: 0.52, green: 0.30, blue: 0.92)], startPoint: .topLeading, endPoint: .bottomTrailing)
}
struct Artwork: View {
    let url: URL?
    @StateObject private var loader = CoverLoader()
    var body: some View {
        GeometryReader { geo in
            ZStack {
                LinearGradient(colors: [Theme.accent.opacity(0.25), Theme.panel], startPoint: .topLeading, endPoint: .bottomTrailing)
                // Pictures already in memory draw on the first frame, without a placeholder flash.
                if let image = url.flatMap(ArtworkCache.shared.memoryImage) ?? loader.image {
                    Image(uiImage: image).resizable().scaledToFill().transition(.opacity)
                } else if url == nil {
                    Image(systemName: "photo").font(.title3).foregroundColor(.white.opacity(0.18))
                } else {
                    Color.clear.shimmer()
                }
            }.frame(width: geo.size.width, height: geo.size.height).clipped()
                .animation(.easeOut(duration: 0.3), value: loader.image != nil)
        }.task(id: url) { await loader.load(url) }.accessibilityHidden(true)
    }
}
struct PosterCard: View {
    let anime: Anime
    var width: CGFloat = 132
    @EnvironmentObject private var library: LibraryStore
    private var saved: Bool { library.contains(anime) }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            AnimeArtwork(anime: anime).frame(width: width, height: width * 1.5)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.stroke))
                .overlay(alignment: .topTrailing) {
                    if saved {
                        Image(systemName: "bookmark.fill").font(.caption2.bold()).padding(6)
                            .background(Theme.accent).clipShape(Circle()).padding(6).accessibilityLabel("In der Watchlist")
                    }
                }
                .contextMenu {
                    Button { library.toggleWatchlist(anime) } label: {
                        Label(saved ? "Von der Watchlist entfernen" : "Zur Watchlist", systemImage: saved ? "bookmark.slash" : "bookmark")
                    }
                    if let url = AniURL.page(anime.path) { ShareLink(item: url) { Label("Teilen", systemImage: "square.and.arrow.up") } }
                }
            Text(anime.title).font(.caption.weight(.semibold)).lineLimit(3).fixedSize(horizontal: false, vertical: true)
        }.frame(width: width).foregroundColor(.white)
    }
}
struct AnimeShelf: View {
    let title: String
    let items: [Anime]
    var body: some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                SectionHeader(title: title)
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 12) {
                        ForEach(items) { anime in
                            NavigationLink { DetailView(anime: anime) } label: { PosterCard(anime: anime) }.buttonStyle(LoungePressStyle())
                        }
                    }.padding(.horizontal, 20)
                }
                // Posters further along the row are fetched before the viewer swipes to them.
                .task(id: items.count) { ArtworkCache.shared.prefetch(Array(items.compactMap(\.poster).prefix(20))) }
            }
        }
    }
}
/// Netflix-style ranking row: large outlined numerals tucked behind the posters.
struct TopTenShelf: View {
    let title: String
    let items: [Anime]
    var body: some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                SectionHeader(title: title)
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .bottom, spacing: 6) {
                        ForEach(Array(items.prefix(10).enumerated()), id: \.element.id) { index, anime in
                            NavigationLink { DetailView(anime: anime) } label: {
                                HStack(alignment: .bottom, spacing: -22) {
                                    Text("\(index + 1)")
                                        .font(.system(size: 104, weight: .black, design: .rounded)).monospacedDigit()
                                        .foregroundStyle(LinearGradient(colors: [.white.opacity(0.85), .white.opacity(0.15)], startPoint: .top, endPoint: .bottom))
                                        .shadow(color: .black.opacity(0.6), radius: 1, x: 2, y: 0)
                                        .frame(minWidth: 52, alignment: .trailing).offset(y: 14)
                                        .accessibilityHidden(true)
                                    AnimeArtwork(anime: anime).frame(width: 104, height: 156)
                                        .clipShape(RoundedRectangle(cornerRadius: 8))
                                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.stroke))
                                        .shadow(color: .black.opacity(0.5), radius: 8, x: -4)
                                }
                            }.buttonStyle(LoungePressStyle()).accessibilityLabel("Platz \(index + 1): \(anime.title)")
                        }
                    }.padding(.horizontal, 20)
                }
            }
        }
    }
}
struct ProblemView: View {
    let message: String
    let retry: () -> Void
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "wifi.exclamationmark").font(.largeTitle).foregroundColor(.secondary)
            Text(message).multilineTextAlignment(.center).foregroundColor(.secondary)
            Button("Erneut versuchen", action: retry).buttonStyle(.borderedProminent).tint(Theme.accent)
            Link("AniWorld im Browser öffnen", destination: AniURL.base).font(.footnote)
        }.padding(28).frame(maxWidth: .infinity)
    }
}

