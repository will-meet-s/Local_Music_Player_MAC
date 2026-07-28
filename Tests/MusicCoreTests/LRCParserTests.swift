import XCTest
@testable import MusicCore

final class LRCParserTests: XCTestCase {

    func testParsesBasicTimestamps() {
        let lrc = """
        [00:12.34]第一行
        [01:05.00]第二行
        """
        let lines = LRCParser.parse(lrc)

        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines[0].time, 12.34, accuracy: 0.001)
        XCTAssertEqual(lines[0].text, "第一行")
        XCTAssertEqual(lines[1].time, 65.0, accuracy: 0.001)
        XCTAssertEqual(lines[1].text, "第二行")
    }

    func testParsesTimestampWithoutFraction() {
        let lines = LRCParser.parse("[02:03]文本")
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines[0].time, 123.0, accuracy: 0.001)
    }

    func testParsesMillisecondPrecision() {
        let lines = LRCParser.parse("[00:01.500]文本")
        XCTAssertEqual(lines[0].time, 1.5, accuracy: 0.001)
    }

    func testMultipleTimestampsOnOneLine() {
        let lines = LRCParser.parse("[00:10.00][01:10.00]副歌")

        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines.map(\.text), ["副歌", "副歌"])
        XCTAssertEqual(lines[0].time, 10.0, accuracy: 0.001)
        XCTAssertEqual(lines[1].time, 70.0, accuracy: 0.001)
    }

    func testIgnoresMetadataTags() {
        let lrc = """
        [ti:歌名]
        [ar:歌手]
        [al:专辑]
        [by:某人]
        [00:01.00]正文
        """
        let lines = LRCParser.parse(lrc)

        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines[0].text, "正文")
    }

    func testSortsOutOfOrderInput() {
        let lrc = """
        [00:30.00]后
        [00:10.00]前
        """
        let lines = LRCParser.parse(lrc)

        XCTAssertEqual(lines.map(\.text), ["前", "后"])
        // id 应按排序后的位置重新编号
        XCTAssertEqual(lines.map(\.id), [0, 1])
    }

    func testAppliesOffsetTag() {
        // offset 为正表示歌词提前显示，时间应被减小
        let lines = LRCParser.parse("[offset:+500]\n[00:10.00]文本")
        XCTAssertEqual(lines[0].time, 9.5, accuracy: 0.001)
    }

    func testOffsetNeverProducesNegativeTime() {
        let lines = LRCParser.parse("[offset:5000]\n[00:01.00]文本")
        XCTAssertEqual(lines[0].time, 0.0, accuracy: 0.001)
    }

    func testEmptyAndGarbageInput() {
        XCTAssertTrue(LRCParser.parse("").isEmpty)
        XCTAssertTrue(LRCParser.parse("这是一段没有时间戳的纯文本\n第二行").isEmpty)
        XCTAssertTrue(LRCParser.parse("[not-a-time]文本").isEmpty)
    }

    func testRejectsInvalidSeconds() {
        // 秒数 >= 60 不是合法时间戳
        XCTAssertTrue(LRCParser.parse("[00:99.00]文本").isEmpty)
    }

    func testKeepsEmptyLyricLines() {
        // 间奏留白行应该保留，否则滚动位置会错
        let lines = LRCParser.parse("[00:01.00]\n[00:05.00]有词")
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines[0].text, "")
    }

    // MARK: - index(at:in:)

    func testIndexLookup() {
        let lines = [
            LyricLine(id: 0, time: 0, text: "a"),
            LyricLine(id: 1, time: 10, text: "b"),
            LyricLine(id: 2, time: 20, text: "c")
        ]

        XCTAssertEqual(LRCParser.index(at: 0, in: lines), 0)
        XCTAssertEqual(LRCParser.index(at: 9.99, in: lines), 0)
        XCTAssertEqual(LRCParser.index(at: 10, in: lines), 1)
        XCTAssertEqual(LRCParser.index(at: 15, in: lines), 1)
        XCTAssertEqual(LRCParser.index(at: 1000, in: lines), 2)
    }

    func testIndexBeforeFirstLineIsNil() {
        let lines = [LyricLine(id: 0, time: 5, text: "a")]
        XCTAssertNil(LRCParser.index(at: 0, in: lines))
        XCTAssertNil(LRCParser.index(at: 4.9, in: lines))
    }

    func testIndexOnEmptyLyricsIsNil() {
        XCTAssertNil(LRCParser.index(at: 10, in: []))
    }
}
