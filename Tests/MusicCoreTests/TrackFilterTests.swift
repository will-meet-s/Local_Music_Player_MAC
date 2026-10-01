import XCTest
@testable import MusicCore

final class TrackFilterTests: XCTestCase {

    private func track(
        path: String,
        title: String? = nil,
        artist: String? = nil,
        album: String? = nil
    ) -> Track {
        var t = Track(url: URL(fileURLWithPath: path))
        if let title { t.title = title }
        t.artist = artist
        t.album = album
        return t
    }

    // MARK: - 搜索

    func testEmptySearchReturnsEverything() {
        let tracks = [track(path: "/m/a.mp3"), track(path: "/m/b.mp3")]
        XCTAssertEqual(TrackFilter.filtered(tracks, search: "").count, 2)
        XCTAssertEqual(TrackFilter.filtered(tracks, search: "   ").count, 2)
    }

    func testSearchMatchesTitle() {
        let tracks = [
            track(path: "/m/1.mp3", title: "晴天"),
            track(path: "/m/2.mp3", title: "雨天")
        ]
        let hits = TrackFilter.filtered(tracks, search: "晴")
        XCTAssertEqual(hits.map(\.title), ["晴天"])
    }

    func testSearchMatchesArtistAndAlbum() {
        let tracks = [
            track(path: "/m/1.mp3", title: "A", artist: "周杰伦"),
            track(path: "/m/2.mp3", title: "B", album: "范特西"),
            track(path: "/m/3.mp3", title: "C")
        ]

        XCTAssertEqual(TrackFilter.filtered(tracks, search: "周杰伦").map(\.title), ["A"])
        XCTAssertEqual(TrackFilter.filtered(tracks, search: "范特西").map(\.title), ["B"])
    }

    func testSearchIsCaseInsensitive() {
        let tracks = [track(path: "/m/1.mp3", title: "Hello World")]
        XCTAssertEqual(TrackFilter.filtered(tracks, search: "hello").count, 1)
        XCTAssertEqual(TrackFilter.filtered(tracks, search: "WORLD").count, 1)
    }

    func testSearchIsDiacriticInsensitive() {
        let tracks = [track(path: "/m/1.mp3", title: "Café Bar")]
        XCTAssertEqual(TrackFilter.filtered(tracks, search: "cafe").count, 1)
    }

    func testSearchIsSubstringNotPrefix() {
        let tracks = [track(path: "/m/1.mp3", title: "夜曲")]
        XCTAssertEqual(TrackFilter.filtered(tracks, search: "曲").count, 1)
    }

    func testSearchKeywordIsTrimmed() {
        let tracks = [track(path: "/m/1.mp3", title: "晴天")]
        XCTAssertEqual(TrackFilter.filtered(tracks, search: "  晴天  ").count, 1)
    }

    func testNoMatchReturnsEmpty() {
        let tracks = [track(path: "/m/1.mp3", title: "晴天")]
        XCTAssertTrue(TrackFilter.filtered(tracks, search: "不存在").isEmpty)
    }

    // MARK: - 按文件顺序排序

    func testFileOrderUsesNaturalPathSort() {
        let tracks = [
            track(path: "/m/track10.mp3"),
            track(path: "/m/track2.mp3"),
            track(path: "/m/track1.mp3")
        ]
        let sorted = TrackFilter.sorted(tracks, by: .fileOrder, ascending: true)
        XCTAssertEqual(sorted.map { $0.url.lastPathComponent },
                       ["track1.mp3", "track2.mp3", "track10.mp3"])
    }

    func testFileOrderDescending() {
        let tracks = [
            track(path: "/m/a.mp3"),
            track(path: "/m/c.mp3"),
            track(path: "/m/b.mp3")
        ]
        let sorted = TrackFilter.sorted(tracks, by: .fileOrder, ascending: false)
        XCTAssertEqual(sorted.map { $0.url.lastPathComponent }, ["c.mp3", "b.mp3", "a.mp3"])
    }

    // MARK: - 按歌名排序

    func testTitleSortAscendingAndDescending() {
        let tracks = [
            track(path: "/m/1.mp3", title: "Banana"),
            track(path: "/m/2.mp3", title: "apple"),
            track(path: "/m/3.mp3", title: "Cherry")
        ]

        XCTAssertEqual(
            TrackFilter.sorted(tracks, by: .title, ascending: true).map(\.title),
            ["apple", "Banana", "Cherry"],
            "应按本地化规则排序，大小写不影响先后"
        )
        XCTAssertEqual(
            TrackFilter.sorted(tracks, by: .title, ascending: false).map(\.title),
            ["Cherry", "Banana", "apple"]
        )
    }

    func testTitleSortBreaksTiesByPathForStability() {
        let tracks = [
            track(path: "/m/z.mp3", title: "同名"),
            track(path: "/m/a.mp3", title: "同名")
        ]

        for ascending in [true, false] {
            let sorted = TrackFilter.sorted(tracks, by: .title, ascending: ascending)
            XCTAssertEqual(sorted.map { $0.url.lastPathComponent }, ["a.mp3", "z.mp3"],
                           "同名曲目应始终按路径定序，方向切换也不变")
        }
    }

    // MARK: - 按歌手排序

    func testArtistSort() {
        let tracks = [
            track(path: "/m/1.mp3", title: "A", artist: "Beyond"),
            track(path: "/m/2.mp3", title: "B", artist: "Air"),
            track(path: "/m/3.mp3", title: "C", artist: "Coldplay")
        ]

        XCTAssertEqual(
            TrackFilter.sorted(tracks, by: .artist, ascending: true).map { $0.artist },
            ["Air", "Beyond", "Coldplay"]
        )
        XCTAssertEqual(
            TrackFilter.sorted(tracks, by: .artist, ascending: false).map { $0.artist },
            ["Coldplay", "Beyond", "Air"]
        )
    }

    func testTracksWithoutArtistAlwaysSortLast() {
        let tracks = [
            track(path: "/m/1.mp3", title: "无歌手"),
            track(path: "/m/2.mp3", title: "有歌手", artist: "Air"),
            track(path: "/m/3.mp3", title: "空白歌手", artist: "   ")
        ]

        for ascending in [true, false] {
            let sorted = TrackFilter.sorted(tracks, by: .artist, ascending: ascending)

            XCTAssertEqual(sorted.first?.artist, "Air",
                           "有歌手的排在最前（ascending=\(ascending)）")

            let tail = sorted.dropFirst().map { $0.artist?.trimmingCharacters(in: .whitespaces) ?? "" }
            XCTAssertTrue(tail.allSatisfy(\.isEmpty),
                          "缺失歌手的两首应垫底（ascending=\(ascending)）")
        }
    }

    func testSameArtistSortsByTitle() {
        let tracks = [
            track(path: "/m/1.mp3", title: "Beta", artist: "Same Artist"),
            track(path: "/m/2.mp3", title: "Alpha", artist: "Same Artist")
        ]

        let sorted = TrackFilter.sorted(tracks, by: .artist, ascending: true)
        XCTAssertEqual(sorted.map(\.title), ["Alpha", "Beta"])
    }

    // MARK: - 组合

    func testApplyFiltersThenSorts() {
        // 标题用 ASCII —— 中文的排序结果取决于系统 locale 的拼音/笔画规则，
        // 断言具体顺序会让测试在不同机器上飘
        let tracks = [
            track(path: "/m/1.mp3", title: "Zulu", artist: "周杰伦"),
            track(path: "/m/2.mp3", title: "Alpha", artist: "周杰伦"),
            track(path: "/m/3.mp3", title: "Mike", artist: "Beyond")
        ]

        let result = TrackFilter.apply(to: tracks, search: "周杰伦", sort: .title, ascending: true)

        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result.map(\.title), ["Alpha", "Zulu"])
    }

    func testApplyOnEmptyLibrary() {
        XCTAssertTrue(TrackFilter.apply(to: [], search: "x", sort: .title, ascending: true).isEmpty)
    }
}

// MARK: - 歌单内搜索（T-012）
//
// T-012 直接复用 TrackFilter.filtered（只过滤、不排序），不改基线代码；这里按
// 方案 §7 的固定歌单「全」把验收场景过一遍，确认复用的规则和曲库搜索完全一致。

final class SonglistSearchFilterTests: XCTestCase {

    private func track(path: String, title: String, artist: String? = nil, album: String? = nil) -> Track {
        var t = Track(url: URL(fileURLWithPath: path))
        t.title = title
        t.artist = artist
        t.album = album
        return t
    }

    /// 歌单「全」= [C08, B05, A03, A02, P10, C07]。
    private var all: [Track] {
        [
            track(path: "/m/c08.mp3", title: "C08", artist: "Adele", album: "25"),
            track(path: "/m/b05.mp3", title: "B05", artist: "王菲"),
            track(path: "/m/a03.mp3", title: "A03"),
            track(path: "/m/a02.mp3", title: "A02"),
            track(path: "/m/p10.mp3", title: "Café"),
            track(path: "/m/c07.mp3", title: "C07", artist: "Adele", album: "25")
        ]
    }

    // #1
    func testSearchByTitlePrefixAndArtistAndAlbum() {
        XCTAssertEqual(TrackFilter.filtered(all, search: "A0").map(\.title), ["A03", "A02"])
        XCTAssertEqual(TrackFilter.filtered(all, search: "王菲").map(\.title), ["B05"])
        XCTAssertEqual(TrackFilter.filtered(all, search: "25").map(\.title), ["C08", "C07"], "按专辑名匹配，保持歌单里的原顺序")
    }

    // #2
    func testSearchByArtistIsCaseInsensitive() {
        XCTAssertEqual(TrackFilter.filtered(all, search: "adele").map(\.title), ["C08", "C07"])
        XCTAssertEqual(TrackFilter.filtered(all, search: "ADELE").map(\.title), ["C08", "C07"])
    }

    // #3
    func testSearchIsDiacriticInsensitiveForCafe() {
        XCTAssertEqual(TrackFilter.filtered(all, search: "cafe").map(\.title), ["Café"])
        XCTAssertEqual(TrackFilter.filtered(all, search: "CAFÉ").map(\.title), ["Café"])
    }

    // #4
    func testTwoSpacesReturnsEntireSonglistInOriginalOrder() {
        XCTAssertEqual(TrackFilter.filtered(all, search: "  ").map(\.title), ["C08", "B05", "A03", "A02", "Café", "C07"])
    }

    // #5
    func testSearchWithNoMatchesReturnsEmpty() {
        XCTAssertTrue(TrackFilter.filtered(all, search: "不存在xyz").isEmpty)
    }
}
