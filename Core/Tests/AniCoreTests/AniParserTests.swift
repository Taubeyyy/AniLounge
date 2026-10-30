import XCTest
@testable import AniCore

final class AniParserTests: XCTestCase {
    func fixture() throws -> String {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "detail", withExtension: "html", subdirectory: "Fixtures"))
        return try String(contentsOf: url, encoding: .utf8)
    }
    func testDetailUsesFullDescriptionAndLazyCover() throws {
        let result = try AniParser.detail(fixture(), path: "/anime/stream/nebelreise")
        XCTAssertEqual(result.anime.title, "Nebelreise & Sterne")
        XCTAssertEqual(result.synopsis, "Die vollständige Beschreibung.")
        XCTAssertEqual(result.anime.poster?.absoluteString, "https://aniworld.to/public/img/cover/nebel.png")
        XCTAssertEqual(result.backdrop?.lastPathComponent, "nebel-wide.jpg")
        XCTAssertEqual(result.genres, ["Abenteuer", "Fantasy"])
    }
    func testSeasonsExcludeEpisodesDuplicatesAndOtherAnime() throws {
        let result = try AniParser.detail(fixture(), path: "/anime/stream/nebelreise/staffel-1")
        XCTAssertEqual(result.seasons.map(\.title), ["Filme", "Staffel 1", "Staffel 2"])
    }
    func testEpisodeTitlesAndLanguages() throws {
        let result = try AniParser.detail(fixture(), path: "/anime/stream/nebelreise")
        XCTAssertEqual(result.episodes.count, 2)
        XCTAssertEqual(result.episodes[0].number, "1")
        XCTAssertEqual(result.episodes[0].title, "Der Anfang")
        XCTAssertEqual(result.episodes[0].languages, ["Deutsch/German"])
        XCTAssertEqual(result.episodes[1].title, "Second Journey")
    }
    func testCatalogDeduplicatesGenresAndExcludesEpisodeLinks() throws {
        let html = """
        <a href="/anime/stream/nebelreise" data-alternative-title="Kiri">Nebelreise</a>
        <a href="/anime/stream/nebelreise">Nebelreise</a>
        <a href="/anime/stream/nebelreise/staffel-1/episode-1">Folge</a>
        <a href="https://evil.example/anime/stream/fake">Falsch</a>
        <a href="/anime/stream/abend">Abend</a>
        """
        let list = try AniParser.catalog(html)
        XCTAssertEqual(list.map(\.title), ["Abend", "Nebelreise"])
        XCTAssertEqual(list[1].aliases, "Kiri")
    }
    func testHomeTitlesIgnoreEpisodeDatesAndGenreLabels() throws {
        let html = """
        <div class="homeContentPromotionBox"><a href="/anime/stream/nebelreise"><h3>Nebelreise</h3><h4>Season 2</h4><img data-src="/hero.jpg"></a></div>
        <div class="carousel"><div class="coverListItem"><a href="/anime/stream/abend"><h3>Abend</h3><small>Fantasy</small><img data-src="/poster.jpg"></a></div></div>
        <div class="newEpisodeList"><a href="/anime/stream/nebelreise/staffel-2/episode-1"><strong>Nebelreise</strong><span>Datum · S02 E01</span></a></div>
        """
        let feed = try AniParser.home(html)
        XCTAssertEqual(feed.featured.first?.title, "Nebelreise")
        XCTAssertEqual(feed.popular.first?.title, "Abend")
        XCTAssertEqual(feed.recent.first?.title, "Nebelreise")
        XCTAssertNotNil(feed.recent.first?.poster)
    }
    func testChallengeAndChangedPagesProduceErrors() {
        XCTAssertThrowsError(try AniParser.catalog("<title>Just a moment...</title>"))
        XCTAssertThrowsError(try AniParser.detail("<h1>Unbekannt</h1>", path: "/anime/stream/nebelreise"))
        XCTAssertThrowsError(try AniParser.home("<p>Wartung</p>"))
    }
    func testLinksStayOnExpectedOrigin() {
        XCTAssertNil(AniURL.page("https://evil.example/anime/stream/test"))
        XCTAssertNil(AniURL.page("javascript:alert(1)"))
        XCTAssertNil(AniURL.page("//evil.example/test"))
        XCTAssertNil(AniURL.page("http://aniworld.to/test"))
        XCTAssertEqual(AniURL.animePath("/anime/stream/nebelreise/staffel-2/episode-1"), "/anime/stream/nebelreise")
        XCTAssertNil(AniURL.image("data:image/png;base64,abc"))
    }
    func testEmptySeasonIsValid() throws {
        let detail = try AniParser.detail("<div class='series-title'><h1>Neu</h1></div>", path: "/anime/stream/neu")
        XCTAssertTrue(detail.episodes.isEmpty)
    }
}
