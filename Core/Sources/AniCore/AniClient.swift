import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public actor AniClient {
    public static let shared = AniClient()
    private var cache: [String: (Date, String)] = [:]
    private let session: URLSession
    public init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 25
        config.timeoutIntervalForResource = 45
        config.httpMaximumConnectionsPerHost = 4
        session = URLSession(configuration: config)
    }
    private func page(_ path: String) async throws -> String {
        if let (date, html) = cache[path], Date().timeIntervalSince(date) < 300 { return html }
        guard let url = AniURL.page(path) else { throw AniError.invalidURL }
        var request = URLRequest(url: url)
        request.setValue("AniLounge/0.2 (personal iOS client)", forHTTPHeaderField: "User-Agent")
        request.setValue("de-DE,de;q=0.9,en;q=0.5", forHTTPHeaderField: "Accept-Language")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AniError.unexpectedPage }
        guard (200...299).contains(http.statusCode) else { throw AniError.http(http.statusCode) }
        guard let finalURL = http.url, AniURL.page(finalURL.absoluteString) != nil else { throw AniError.unexpectedPage }
        guard let html = String(data: data, encoding: .utf8) else { throw AniError.invalidEncoding }
        if cache.count > 80 { cache.removeAll() }
        cache[path] = (Date(), html)
        return html
    }
    public func home() async throws -> HomeFeed { try AniParser.home(await page("/")) }
    public func catalog() async throws -> [Anime] { try AniParser.catalog(await page("/animes")) }
    public func detail(path: String) async throws -> AnimeDetail { try AniParser.detail(await page(path), path: path) }
    public func hosts(path: String) async throws -> [StreamHost] { try AniParser.hosts(await page(path)) }
    public func clearCache() { cache.removeAll() }
}
