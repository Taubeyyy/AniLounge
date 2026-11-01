import XCTest
@testable import AniCore

final class MetadataTests: XCTestCase {
    func testDetailReadsIMDbLink() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "detail", withExtension: "html", subdirectory: "Fixtures"))
        let result = try AniParser.detail(try String(contentsOf: url, encoding: .utf8), path: "/anime/stream/nebelreise")
        XCTAssertEqual(result.imdb, "tt1234567")
    }
    func testIMDbValidation() {
        XCTAssertEqual(MetadataParser.validIMDb(" tt0388629 "), "tt0388629")
        XCTAssertNil(MetadataParser.validIMDb("tt"))
        XCTAssertNil(MetadataParser.validIMDb("tt12ab"))
        XCTAssertNil(MetadataParser.validIMDb("nm0388629"))
    }
    func testAniZipSeasonSelectionPrefersGermanTitles() throws {
        let data = Data("""
        {"mappings":{"anilist_id":16498},"episodes":{
          "1":{"seasonNumber":1,"episodeNumber":1,"absoluteEpisodeNumber":1,"title":{"de":"An dich","en":"To You"},"image":"https://img.example/1.jpg","runtime":24,"airDate":"2013-04-07"},
          "2":{"seasonNumber":2,"episodeNumber":1,"absoluteEpisodeNumber":26,"title":{"en":"Beast Titan"},"image":"http://insecure.example/2.jpg"},
          "S1":{"seasonNumber":null,"episodeNumber":null,"title":null}
        }}
        """.utf8)
        XCTAssertEqual(try MetadataParser.anilistID(fromAniZip: data), 16498)
        let episodes = try MetadataParser.episodes(fromAniZip: data)
        let first = MetadataParser.season(1, from: episodes, allowAbsolute: true)
        XCTAssertEqual(first["1"]?.title, "An dich")
        XCTAssertEqual(first["1"]?.image?.host, "img.example")
        XCTAssertEqual(first.count, 1)
        let second = MetadataParser.season(2, from: episodes, allowAbsolute: false)
        XCTAssertEqual(second["1"]?.title, "Beast Titan")
        XCTAssertNil(second["1"]?.image, "Only https images are used")
        XCTAssertTrue(MetadataParser.season(3, from: episodes, allowAbsolute: false).isEmpty)
    }
    func testAniListExtrasAndSequel() throws {
        let media = Data("""
        {"data":{"Media":{"id":154587,"bannerImage":"https://s4.anilist.co/banner.jpg","coverImage":{"extraLarge":"https://s4.anilist.co/cover.jpg","color":"#bbf1a1"},
        "averageScore":91,"status":"FINISHED","studios":{"nodes":[{"name":"MADHOUSE"}]},"trailer":{"site":"youtube","id":"tR8YH0G67Rk"},
        "nextAiringEpisode":{"episode":5,"airingAt":1700000000},
        "recommendations":{"nodes":[{"mediaRecommendation":{"title":{"romaji":"Mushishi","english":null},"synonyms":["Mushi-Shi"]}},{"mediaRecommendation":null}]}}}}
        """.utf8)
        let extras = try MetadataParser.extras(fromAniList: media)
        XCTAssertEqual(extras.anilistID, 154587)
        XCTAssertEqual(extras.score, 91)
        XCTAssertEqual(extras.studio, "MADHOUSE")
        XCTAssertEqual(extras.trailer?.absoluteString, "https://www.youtube.com/watch?v=tR8YH0G67Rk")
        XCTAssertEqual(extras.nextEpisode, 5)
        XCTAssertEqual(extras.recommendations, [["Mushishi", "Mushi-Shi"]])
        let relations = Data("""
        {"data":{"Media":{"relations":{"edges":[
          {"relationType":"ALTERNATIVE","node":{"id":1,"type":"ANIME","format":"MOVIE"}},
          {"relationType":"SEQUEL","node":{"id":2,"type":"MANGA","format":"MANGA"}},
          {"relationType":"SEQUEL","node":{"id":20958,"type":"ANIME","format":"TV"}}]}}}}
        """.utf8)
        XCTAssertEqual(try MetadataParser.sequel(fromAniList: relations), 20958)
    }
}
