import XCTest
@testable import MusicCore

final class LyricsProviderTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("LyricsProviderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testPrefersSidecarLRCFile() throws {
        let audio = root.appendingPathComponent("song.mp3")
        try Data("x".utf8).write(to: audio)
        try Data("[00:01.00]来自文件".utf8).write(to: root.appendingPathComponent("song.lrc"))

        var track = Track(url: audio)
        track.embeddedLyrics = "[00:02.00]来自内嵌"

        let lines = LyricsProvider.lyrics(for: track)

        XCTAssertEqual(lines.map(\.text), ["来自文件"])
    }

    func testFallsBackToEmbeddedLyrics() throws {
        let audio = root.appendingPathComponent("song.mp3")
        try Data("x".utf8).write(to: audio)

        var track = Track(url: audio)
        track.embeddedLyrics = "[00:02.00]来自内嵌"

        let lines = LyricsProvider.lyrics(for: track)

        XCTAssertEqual(lines.map(\.text), ["来自内嵌"])
        XCTAssertEqual(lines[0].time, 2.0, accuracy: 0.001)
    }

    func testUntimedEmbeddedLyricsBecomePlainLines() throws {
        let audio = root.appendingPathComponent("song.mp3")
        try Data("x".utf8).write(to: audio)

        var track = Track(url: audio)
        track.embeddedLyrics = "第一行\n第二行"

        let lines = LyricsProvider.lyrics(for: track)

        XCTAssertEqual(lines.map(\.text), ["第一行", "第二行"])
        // 时间为负表示无时间戳，UI 据此不做高亮滚动
        XCTAssertTrue(lines.allSatisfy { $0.time < 0 })
    }

    func testNoLyricsReturnsEmpty() throws {
        let audio = root.appendingPathComponent("song.mp3")
        try Data("x".utf8).write(to: audio)

        XCTAssertTrue(LyricsProvider.lyrics(for: Track(url: audio)).isEmpty)
    }

    func testDecodesGB18030LRCFile() throws {
        let audio = root.appendingPathComponent("song.mp3")
        try Data("x".utf8).write(to: audio)

        let gb18030 = String.Encoding(
            rawValue: CFStringConvertEncodingToNSStringEncoding(
                CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
            )
        )
        let content = "[00:01.00]中文歌词"
        let data = try XCTUnwrap(content.data(using: gb18030))
        try data.write(to: root.appendingPathComponent("song.lrc"))

        let lines = LyricsProvider.lyrics(for: Track(url: audio))

        XCTAssertEqual(lines.map(\.text), ["中文歌词"])
    }
}
