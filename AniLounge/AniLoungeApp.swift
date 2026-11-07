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
    @State private var showingProfileSummary = false
    @State private var openProfileAfterDismiss = false
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var launching = true
    private let tabs: [LoungeTab] = [
        LoungeTab(title: "Start", icon: "house", selectedIcon: "house.fill"),
        LoungeTab(title: "Suche", icon: "magnifyingglass", selectedIcon: "magnifyingglass"),
        LoungeTab(title: "Watchlist", icon: "bookmark", selectedIcon: "bookmark.fill"),
        LoungeTab(title: "Downloads", icon: "arrow.down.circle", selectedIcon: "arrow.down.circle.fill"),
        LoungeTab(title: "Profil", icon: "person.crop.circle", selectedIcon: "person.crop.circle.fill")
    ]
    var body: some View {
        TabView(selection: $selected) {
            NavigationStack { HomeView(onOpenProfileSummary: { showingProfileSummary = true }) }.tag(0)
            NavigationStack { SearchView() }.tag(1)
            NavigationStack { SavedView() }.tag(2)
            NavigationStack { DownloadsView() }.tag(3)
            NavigationStack { ProfileView() }.tag(4)
        }
        .toolbar(.hidden, for: .tabBar)
        .safeAreaInset(edge: .bottom, spacing: 0) { LoungeTabBar(tabs: tabs, selected: $selected) }
        .id(library.profile.id)
        .overlay(alignment: .top) { ToastHost() }
        .overlay { if launching { LaunchOverlay { launching = false }.transition(.opacity).zIndex(10) } }
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
        .sheet(isPresented: $showingProfileSummary, onDismiss: {
            // Finish dismissing before changing tabs, so Start keeps its navigation state.
            if openProfileAfterDismiss { selected = 4 }
            openProfileAfterDismiss = false
        }) {
            ProfileSummaryView {
                openProfileAfterDismiss = true
                showingProfileSummary = false
            }
            .presentationDetents(typeSize.isAccessibilitySize ? [.large] : [.height(440), .large])
            .presentationDragIndicator(.visible)
            .preferredColorScheme(.dark)
        }
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
struct LoungeTab {
    let title: String
    let icon: String
    let selectedIcon: String
}
/// Full-width translucent bar like the big streaming apps: outline symbols, the selected tab
/// filled and white, a short accent line gliding to it.
struct LoungeTabBar: View {
    let tabs: [LoungeTab]
    @Binding var selected: Int
    @Namespace private var marker
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        HStack(spacing: 0) {
            ForEach(0..<tabs.count, id: \.self) { index in
                let active = selected == index
                Button {
                    guard !active else { return }
                    UISelectionFeedbackGenerator().selectionChanged()
                    withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.86)) { selected = index }
                } label: {
                    VStack(spacing: 5) {
                        ZStack {
                            if active {
                                Capsule().fill(Theme.accent).frame(width: 20, height: 3)
                                    .matchedGeometryEffect(id: "marker", in: marker)
                            }
                        }.frame(height: 3)
                        Image(systemName: active ? tabs[index].selectedIcon : tabs[index].icon)
                            .font(.system(size: 20, weight: active ? .semibold : .regular)).frame(height: 24)
                        Text(tabs[index].title).font(.system(size: 10, weight: active ? .semibold : .medium))
                            .lineLimit(1).minimumScaleFactor(0.8)
                    }
                    .frame(maxWidth: .infinity).padding(.bottom, 4)
                    .foregroundColor(active ? .white : .white.opacity(0.5))
                    .contentShape(Rectangle())
                }
                .buttonStyle(LoungePressStyle())
                .accessibilityLabel(tabs[index].title)
                .accessibilityAddTraits(active ? .isSelected : [])
            }
        }
        .padding(.horizontal, 6)
        .background {
            ZStack(alignment: .top) {
                Rectangle().fill(.ultraThinMaterial)
                Theme.background.opacity(0.72)
                Rectangle().fill(Color.white.opacity(0.08)).frame(height: 0.5)
            }.ignoresSafeArea(edges: .bottom)
        }
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
    /// A light glass surface: blurred background, faint tint and a thin highlight edge.
    func glassCard(cornerRadius: CGFloat = 16) -> some View {
        self.background(.ultraThinMaterial)
            .background(Theme.panel.opacity(0.45))
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius)
                .stroke(LinearGradient(colors: [.white.opacity(0.18), .white.opacity(0.04)], startPoint: .top, endPoint: .bottom), lineWidth: 1))
    }
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
            Text(title).font(.title3.weight(.heavy)).tracking(-0.3)
            if let subtitle { Text(subtitle).font(.caption).foregroundColor(Theme.muted) }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 20).accessibilityAddTraits(.isHeader)
    }
}
struct PosterSkeleton: View {
    var width: CGFloat = 112
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            RoundedRectangle(cornerRadius: Theme.posterRadius).fill(Theme.panel).frame(width: width, height: width * 1.5)
            RoundedRectangle(cornerRadius: 4).fill(Theme.panel).frame(width: width * 0.8, height: 12)
        }.shimmer()
    }
}
struct HomeSkeleton: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            RoundedRectangle(cornerRadius: 20).fill(Theme.panel).frame(height: 360).padding(.horizontal, 20).shimmer()
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
    // Neutral near-black like Netflix and Crunchyroll: the artwork brings the colour.
    static let background = Color(red: 0.035, green: 0.035, blue: 0.045)
    static let panel = Color(red: 0.095, green: 0.095, blue: 0.115)
    static let panelHigh = Color(red: 0.15, green: 0.15, blue: 0.18)
    /// Corner radii: small on artwork (cinematic), larger on controls and sheets.
    static let posterRadius: CGFloat = 6
    static let tileRadius: CGFloat = 8
    static let accent = Color(red: 0.66, green: 0.38, blue: 0.96)
    static let accentSoft = Color(red: 0.80, green: 0.64, blue: 1.0)
    static let muted = Color.white.opacity(0.70)
    static let stroke = Color.white.opacity(0.08)
    static let accentGradient = LinearGradient(colors: [Color(red: 0.74, green: 0.42, blue: 1.0), Color(red: 0.52, green: 0.30, blue: 0.92)], startPoint: .topLeading, endPoint: .bottomTrailing)
}
struct Artwork: View {
    let url: URL?
    @StateObject private var loader = CoverLoader()
    @Environment(\.displayScale) private var displayScale
    var body: some View {
        GeometryReader { geo in
            ZStack {
                LinearGradient(colors: [Theme.panelHigh, Theme.panel], startPoint: .topLeading, endPoint: .bottomTrailing)
                // Pictures already in memory draw on the first frame, without a placeholder flash.
                if let image = url.flatMap({ ArtworkCache.shared.memoryImage($0) }) ?? loader.image(for: url) {
                    Image(uiImage: image).resizable().scaledToFill()
                } else if url == nil {
                    Image(systemName: "photo").font(.title3).foregroundColor(.white.opacity(0.18))
                } else {
                    Color.clear.shimmer()
                }
            }.frame(width: geo.size.width, height: geo.size.height).clipped()
            .task(id: url) { await loader.load(url, filling: pixels(geo.size)) }
        }.accessibilityHidden(true)
    }
    private func pixels(_ size: CGSize) -> CGSize { CGSize(width: size.width * displayScale, height: size.height * displayScale) }
}
struct PosterCard: View {
    let anime: Anime
    var width: CGFloat = 112
    @EnvironmentObject private var library: LibraryStore
    private var saved: Bool { library.contains(anime) }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            AnimeArtwork(anime: anime).frame(width: width, height: width * 1.5)
                .clipShape(RoundedRectangle(cornerRadius: Theme.posterRadius))
                .overlay(RoundedRectangle(cornerRadius: Theme.posterRadius).stroke(Theme.stroke))
                .overlay(alignment: .topTrailing) {
                    if saved {
                        Image(systemName: "bookmark.fill").font(.system(size: 9, weight: .bold)).padding(5)
                            .background(Theme.accent).clipShape(Circle()).padding(5).accessibilityLabel("In der Watchlist")
                    }
                }
                .contextMenu {
                    Button { library.toggleWatchlist(anime) } label: {
                        Label(saved ? "Von der Watchlist entfernen" : "Zur Watchlist", systemImage: saved ? "bookmark.slash" : "bookmark")
                    }
                    if let url = AniURL.page(anime.path) { ShareLink(item: url) { Label("Teilen", systemImage: "square.and.arrow.up") } }
                }
            Text(anime.title).font(.caption.weight(.medium)).foregroundColor(.white.opacity(0.82))
                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
        }.frame(width: width).foregroundColor(.white)
    }
}
struct AnimeShelf: View {
    let title: String
    let items: [Anime]
    var body: some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: title)
                    .overlay(alignment: .trailing) {
                        if items.count > 6 {
                            NavigationLink { ShelfGridView(title: title, items: items) } label: {
                                HStack(spacing: 3) { Text("Alle"); Image(systemName: "chevron.right").font(.caption.weight(.bold)) }
                                    .font(.subheadline.weight(.semibold)).foregroundColor(Theme.muted).frame(minHeight: 44)
                            }.padding(.trailing, 20).accessibilityLabel("Alle aus \(title)")
                        }
                    }
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 8) {
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
                                        .font(.system(size: 104, weight: .black)).monospacedDigit().tracking(-4)
                                        .foregroundStyle(LinearGradient(colors: [.white.opacity(0.85), .white.opacity(0.15)], startPoint: .top, endPoint: .bottom))
                                        .shadow(color: .black.opacity(0.6), radius: 1, x: 2, y: 0)
                                        .frame(minWidth: 52, alignment: .trailing).offset(y: 14)
                                        .accessibilityHidden(true)
                                    AnimeArtwork(anime: anime).frame(width: 104, height: 156)
                                        .clipShape(RoundedRectangle(cornerRadius: Theme.posterRadius))
                                        .overlay(RoundedRectangle(cornerRadius: Theme.posterRadius).stroke(Theme.stroke))
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
/// A whole shelf as a grid, opened from its "Alle" link.
struct ShelfGridView: View {
    let title: String
    let items: [Anime]
    var body: some View {
        LoungeScroll(title: title, largeTitle: true) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 10, alignment: .top)], spacing: 16) {
                ForEach(items) { anime in
                    NavigationLink { DetailView(anime: anime) } label: { PosterCard(anime: anime, width: 104) }
                        .buttonStyle(LoungePressStyle())
                }
            }.padding(.horizontal, 20)
        } leading: {
            BackButton()
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

