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
    func testSequelBridgesThroughSpecialsButPrefersSeries() throws {
        let bridge = Data("""
        {"data":{"Media":{"relations":{"edges":[
          {"relationType":"OTHER","node":{"id":133514,"type":"ANIME","format":"MUSIC"}},
          {"relationType":"SEQUEL","node":{"id":142876,"type":"ANIME","format":"SPECIAL"}}]}}}}
        """.utf8)
        XCTAssertEqual(try MetadataParser.sequel(fromAniList: bridge), 142876)
        let none = Data(#"{"data":{"Media":{"relations":{"edges":[{"relationType":"SEQUEL","node":{"id":9,"type":"ANIME","format":"MUSIC"}}]}}}}"#.utf8)
        XCTAssertNil(try MetadataParser.sequel(fromAniList: none))
    }
    func testAniZipKeepsMALEntryForSkipLookup() throws {
        let data = Data("""
        {"mappings":{"anilist_id":199221,"mal_id":62568},"episodes":{
          "1":{"episode":"1","seasonNumber":4,"episodeNumber":25,"title":{"en":"Future Engine"}},
          "S1":{"episode":"S1","seasonNumber":0,"episodeNumber":1}}}
        """.utf8)
        let season = MetadataParser.season(4, from: try MetadataParser.episodes(fromAniZip: data), allowAbsolute: false)
        XCTAssertEqual(season["25"]?.malID, 62568)
        XCTAssertEqual(season["25"]?.malEpisode, 1)
        let specials = MetadataParser.season(0, from: try MetadataParser.episodes(fromAniZip: data), allowAbsolute: false)
        XCTAssertNil(specials["1"]?.malID, "Specials have no MAL episode number")
    }
    func testAniSkipParsingAndLengthCheck() throws {
        let data = Data("""
        {"found":true,"results":[
          {"interval":{"startTime":22.9,"endTime":158.2},"skipType":"op","episodeLength":1439.9},
          {"interval":{"startTime":1268,"endTime":1392.5},"skipType":"ed","episodeLength":1419.9},
          {"interval":{"startTime":10,"endTime":12},"skipType":"recap"}]}
        """.utf8)
        let times = try XCTUnwrap(try MetadataParser.skipTimes(fromAniSkip: data))
        XCTAssertEqual(times.opening, 22.9...158.2)
        XCTAssertEqual(times.ending, 1268...1392.5)
        XCTAssertTrue(times.fits(duration: 1420))
        XCTAssertFalse(times.fits(duration: 1600), "A different cut must not skip at the wrong moment")
        XCTAssertNil(try MetadataParser.skipTimes(fromAniSkip: Data(#"{"found":false,"results":[]}"#.utf8)))
        let broken = Data(#"{"found":true,"results":[{"interval":{"startTime":100,"endTime":101},"skipType":"op"}]}"#.utf8)
        XCTAssertNil(try MetadataParser.skipTimes(fromAniSkip: broken))
    }
    func testNearlyFinishedEpisodesCountAsWatched() {
        XCTAssertTrue(EpisodeProgress.finished(seconds: 1344, duration: 1420), "22:24 of 23:40 is in the credits")
        XCTAssertFalse(EpisodeProgress.finished(seconds: 1100, duration: 1420))
        XCTAssertFalse(EpisodeProgress.finished(seconds: 80, duration: 85), "Clips are never auto-finished")
        XCTAssertFalse(EpisodeProgress.finished(seconds: 600, duration: nil))
    }
    func testLibraryResetsAndWatchTime() throws {
        var profile = ProfileLibrary()
        let anime = Anime(path: "/anime/stream/a", title: "A")
        let one = Episode(path: "/anime/stream/a/staffel-1/episode-1", number: "1", title: "Eins", languages: [])
        let two = Episode(path: "/anime/stream/a/staffel-1/episode-2", number: "2", title: "Zwei", languages: [])
        try profile.saveProgress(one, anime: anime, seconds: 1400, duration: 1440, completed: false)
        try profile.saveProgress(two, anime: anime, seconds: 600, duration: 1440, completed: false)
        XCTAssertEqual(profile.watchedSeconds, 1440 + 600, "Finished episodes count fully")
        XCTAssertEqual(profile.finishedEpisodes, 1)
        profile.toggleFavorite(anime)
        profile.clearHistory()
        XCTAssertTrue(profile.history.isEmpty)
        profile.resetProgress()
        XCTAssertTrue(profile.progress.isEmpty); XCTAssertTrue(profile.watched.isEmpty)
        XCTAssertEqual(profile.favorites.count, 1, "The watchlist survives a progress reset")
    }
}
