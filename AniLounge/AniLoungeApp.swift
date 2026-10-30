import SwiftUI
import AniCore

@main struct AniLoungeApp: App {
    @StateObject private var library = LibraryStore()
    var body: some Scene {
        WindowGroup {
            RootView().environmentObject(library).preferredColorScheme(.dark).tint(Theme.accent)
        }
    }
}
struct RootView: View {
    @EnvironmentObject private var library: LibraryStore
    @State private var selected = 0
    private let tabs = [("Entdecken", "sparkles"), ("Suche", "magnifyingglass"), ("Watchlist", "bookmark.fill"), ("Profil", "person.crop.circle.fill")]
    var body: some View {
        TabView(selection: $selected) {
            NavigationStack { HomeView() }.tag(0)
            NavigationStack { SearchView() }.tag(1)
            NavigationStack { SavedView() }.tag(2)
            NavigationStack { ProfileView() }.tag(3)
        }
        .toolbar(.hidden, for: .tabBar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack(spacing: 4) {
                ForEach(0..<tabs.count, id: \.self) { index in
                    Button { selected = index } label: {
                        VStack(spacing: 6) {
                            Image(systemName: tabs[index].1).font(.system(size: 20, weight: .semibold))
                            Text(tabs[index].0).font(.system(size: 10, weight: .semibold))
                        }.frame(maxWidth: .infinity).padding(.vertical, 12)
                            .foregroundColor(selected == index ? .white : .secondary)
                            .background(selected == index ? Theme.accent.opacity(0.25) : .clear)
                            .clipShape(RoundedRectangle(cornerRadius: 18))
                    }.buttonStyle(LoungePressStyle()).accessibilityAddTraits(selected == index ? .isSelected : [])
                }
            }.padding(7).background(.ultraThinMaterial).clipShape(RoundedRectangle(cornerRadius: 26))
                .overlay(RoundedRectangle(cornerRadius: 26).stroke(Theme.accent.opacity(0.2)))
                .padding(.horizontal, 18).padding(.vertical, 8).background(Theme.background.opacity(0.95))
        }
        .id(library.profile.id)
        .alert("Speichern nicht möglich", isPresented: Binding(get: { library.storageError != nil }, set: { if !$0 { library.storageError = nil } })) { Button("OK", role: .cancel) {} } message: { Text(library.storageError ?? "") }
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
            .overlay(RoundedRectangle(cornerRadius: 22).stroke(.white.opacity(0.07)))
    }
}
enum Theme {
    static let background = Color(red: 0.055, green: 0.035, blue: 0.09)
    static let panel = Color(red: 0.12, green: 0.075, blue: 0.18)
    static let accent = Color(red: 0.66, green: 0.38, blue: 0.96)
}
struct Artwork: View {
    let url: URL?
    @StateObject private var loader = CoverLoader()
    var body: some View {
        GeometryReader { geo in
            ZStack {
                LinearGradient(colors: [Theme.accent.opacity(0.25), Theme.panel], startPoint: .topLeading, endPoint: .bottomTrailing)
                if let image = loader.image {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    Image(systemName: "sparkles").font(.largeTitle).foregroundColor(Theme.accent.opacity(0.35))
                }
            }.frame(width: geo.size.width, height: geo.size.height).clipped()
        }.task(id: url) { await loader.load(url) }.accessibilityHidden(true)
    }
}
struct PosterCard: View {
    let anime: Anime
    var width: CGFloat = 132
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            AnimeArtwork(anime: anime).frame(width: width, height: width * 1.5)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(.white.opacity(0.07)))
            Text(anime.title).font(.caption.weight(.semibold)).lineLimit(2).frame(height: 34, alignment: .topLeading)
        }.frame(width: width).foregroundColor(.white)
    }
}
struct AnimeShelf: View {
    let title: String
    let items: [Anime]
    var body: some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                Text(title).font(.title3.bold()).padding(.horizontal, 20)
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 12) {
                        ForEach(items) { anime in
                            NavigationLink { DetailView(anime: anime) } label: { PosterCard(anime: anime) }.buttonStyle(.plain)
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

