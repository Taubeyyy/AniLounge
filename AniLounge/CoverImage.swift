import SwiftUI
import AniCore

struct AnimeArtwork: View {
    let anime: Anime
    @State private var resolved: URL?
    var body: some View {
        Artwork(url: resolved ?? anime.poster)
            .task(id: anime.id) {
                resolved = await AniClient.shared.cover(for: anime)
            }
    }
}
@MainActor final class CoverLoader: ObservableObject {
    @Published var image: UIImage?
    private static let cache = NSCache<NSURL, UIImage>()
    func load(_ url: URL?) async {
        image = nil
        guard let url else { return }
        if let cached = Self.cache.object(forKey: url as NSURL) { image = cached; return }
        for attempt in 0..<2 {
            guard !Task.isCancelled else { return }
            var request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 15)
            request.setValue("https://aniworld.to/", forHTTPHeaderField: "Referer")
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard !Task.isCancelled else { return }
                if let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode), let loaded = UIImage(data: data) {
                    Self.cache.totalCostLimit = 40 * 1024 * 1024
                    Self.cache.setObject(loaded, forKey: url as NSURL, cost: Int(loaded.size.width * loaded.size.height * 4))
                    image = loaded; return
                }
            } catch { if Task.isCancelled { return } }
            if attempt == 0 { try? await Task.sleep(nanoseconds: 800_000_000) }
        }
    }
}
