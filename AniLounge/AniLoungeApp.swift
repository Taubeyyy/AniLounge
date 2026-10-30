import SwiftUI
import AniCore

@main struct AniLoungeApp: App {
    @StateObject private var library = LibraryStore()
    var body: some Scene {
        WindowGroup {
            RootView().environmentObject(library).preferredColorScheme(.dark).tint(.red)
        }
    }
}
struct RootView: View {
    var body: some View {
        TabView {
            NavigationStack { HomeView() }
                .tabItem { Label("Entdecken", systemImage: "house.fill") }
            NavigationStack { SearchView() }
                .tabItem { Label("Suche", systemImage: "magnifyingglass") }
            NavigationStack { SavedView() }
                .tabItem { Label("Meine Liste", systemImage: "bookmark.fill") }
        }
        .toolbarBackground(Color.black, for: .tabBar)
        .toolbarBackground(.visible, for: .tabBar)
    }
}
enum Theme {
    static let background = Color(red: 0.035, green: 0.04, blue: 0.055)
    static let panel = Color(red: 0.09, green: 0.095, blue: 0.115)
    static let accent = Color(red: 0.94, green: 0.13, blue: 0.21)
}
struct Artwork: View {
    let url: URL?
    var body: some View {
        GeometryReader { geo in
            AsyncImage(url: url) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFill()
                } else {
                    ZStack {
                        LinearGradient(colors: [Color(red: 0.2, green: 0.1, blue: 0.18), Theme.panel], startPoint: .topLeading, endPoint: .bottomTrailing)
                        Image(systemName: "sparkles.tv").font(.largeTitle).foregroundColor(.white.opacity(0.2))
                    }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height).clipped()
        }
        .accessibilityHidden(true)
    }
}
struct PosterCard: View {
    let anime: Anime
    var width: CGFloat = 132
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Artwork(url: anime.poster).frame(width: width, height: width * 1.5)
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
