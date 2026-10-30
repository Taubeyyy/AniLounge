import Foundation
import SwiftSoup

public enum AniParser {
    private static func document(_ html: String) throws -> Document {
        let doc = try SwiftSoup.parse(html)
        let title = try doc.title().lowercased()
        if title.contains("just a moment") || title.contains("access denied") {
            throw AniError.unexpectedPage
        }
        return doc
    }
    private static func image(_ element: Element) throws -> URL? {
        guard let img = try element.select("img").first() else { return nil }
        let lazy = try img.attr("data-src")
        return AniURL.image(lazy.isEmpty ? try img.attr("src") : lazy)
    }
    private static func cards(_ doc: Element, selector: String, rootOnly: Bool = false) throws -> [Anime] {
        var result: [Anime] = []
        var seen = Set<String>()
        for anchor in try doc.select(selector) {
            let href = try anchor.attr("href")
            guard let path = AniURL.animePath(href) else { continue }
            if rootOnly, AniURL.page(href)?.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) != String(path.dropFirst()) { continue }
            let heading = try anchor.select("h3, strong").first()?.text() ?? ""
            let title = heading.isEmpty ? try anchor.text() : heading
            guard !title.isEmpty else { continue }
            if !seen.insert(path).inserted {
                if let index = result.firstIndex(where: { $0.path == path }), result[index].poster == nil {
                    result[index].poster = try image(anchor)
                }
                continue
            }
            result.append(Anime(path: path, title: title, poster: try image(anchor), aliases: try anchor.attr("data-alternative-title")))
        }
        return result
    }
    public static func hosts(_ html: String) throws -> [StreamHost] {
        let doc = try document(html)
        var languages: [String: String] = [:]
        for image in try doc.select(".changeLanguageBox img[data-lang-key]") {
            languages[try image.attr("data-lang-key")] = try image.attr("title")
        }
        var seen = Set<String>()
        var hosts: [StreamHost] = []
        for row in try doc.select(".hosterSiteVideo li[data-link-target]") {
            guard let url = AniURL.page(try row.attr("data-link-target")),
                  url.path.hasPrefix("/redirect/"), seen.insert(url.absoluteString).inserted else { continue }
            let name = try row.select("h4").text()
            guard !name.isEmpty else { continue }
            let key = try row.attr("data-lang-key")
            hosts.append(StreamHost(name: name, language: languages[key] ?? "Sprache \(key)", url: url))
        }
        guard !hosts.isEmpty else { throw AniError.missingContent }
        return hosts
    }
    public static func catalog(_ html: String) throws -> [Anime] {
        let doc = try document(html)
        let result = try cards(doc, selector: "a[href*='/anime/stream/']", rootOnly: true)
        guard !result.isEmpty else { throw AniError.missingContent }
        return result.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
    public static func home(_ html: String) throws -> HomeFeed {
        let doc = try document(html)
        let featured = try cards(doc, selector: ".homeContentPromotionBox a[href]")
        let popular = try cards(doc.select(".carousel").first() ?? doc, selector: ".coverListItem a[href]")
        let all = try cards(doc, selector: "a[href*='/anime/stream/']")
        guard !all.isEmpty else { throw AniError.missingContent }
        // Only artwork-backed cards belong in the large hero.
        let visual = all.filter { $0.poster != nil }
        var recent = try cards(doc, selector: ".newEpisodeList a[href], .newEpisodeListContainer a[href]")
        let artwork = Dictionary(visual.map { ($0.id, $0.poster) }, uniquingKeysWith: { first, _ in first })
        for i in recent.indices { recent[i].poster = artwork[recent[i].id] ?? nil }
        return HomeFeed(featured: featured.isEmpty ? Array(visual.prefix(8)) : featured,
                        popular: popular.isEmpty ? visual : popular,
                        recent: recent.isEmpty ? all : recent)
    }
    public static func detail(_ html: String, path: String) throws -> AnimeDetail {
        let doc = try document(html)
        guard let root = AniURL.animePath(path) else { throw AniError.invalidURL }
        let title = try doc.select(".series-title h1").text()
        guard !title.isEmpty else { throw AniError.missingContent }
        let poster = try doc.select(".seriesCoverBox").first().flatMap { try image($0) }
        let summary = try doc.select(".seri_des").first()
        let full = try summary?.attr("data-full-description") ?? ""
        let synopsis = full.isEmpty ? (try summary?.text() ?? "") : full
        let genres = try doc.select(".genres a").array().map { try $0.text() }
        let year = try doc.select("[itemprop=startDate]").text()
        var seasons: [Season] = []
        var seen = Set<String>()
        for a in try doc.select("a[href]") {
            guard let url = AniURL.page(try a.attr("href")) else { continue }
            let suffix = String(url.path.dropFirst(root.count))
            guard url.path.hasPrefix(root + "/"), !suffix.dropFirst().contains("/"),
                  suffix.hasPrefix("/staffel-") || suffix == "/filme", seen.insert(url.path).inserted else { continue }
            seasons.append(Season(path: url.path, title: suffix == "/filme" ? "Filme" : "Staffel \(suffix.replacingOccurrences(of: "/staffel-", with: ""))"))
        }
        var episodes: [Episode] = []
        seen.removeAll()
        for row in try doc.select("tr[data-episode-id]") {
            guard let anchor = try row.select("a[href]").first(),
                  let url = AniURL.page(try anchor.attr("href")),
                  url.path.hasPrefix(root + "/"), seen.insert(url.path).inserted else { continue }
            let number = try row.select("meta[itemprop=episodeNumber]").attr("content")
            let de = try row.select(".seasonEpisodeTitle strong").text()
            let en = try row.select(".seasonEpisodeTitle span").text()
            let languages = try row.select("img.flag").array().map { try $0.attr("title") }
            episodes.append(Episode(path: url.path, number: number,
                                    title: de.isEmpty ? (en.isEmpty ? "Folge \(number)" : en) : de,
                                    languages: languages))
        }
        let style = try doc.select(".backdrop").attr("style")
        var backdrop: URL?
        if let start = style.range(of: "url("), let end = style[start.upperBound...].firstIndex(of: ")") {
            let raw = String(style[start.upperBound..<end]).trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
            backdrop = AniURL.image(raw)
        }
        return AnimeDetail(anime: Anime(path: root, title: title, poster: poster), synopsis: synopsis,
                           genres: genres, year: year, seasons: seasons, episodes: episodes, backdrop: backdrop)
    }
}

