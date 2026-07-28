import XCTest
@testable import MusicCore

/// 用手工拼出的 FLAC 头验证解析器 —— 不需要真实音频文件，因此这些用例
/// 在任何机器上都能跑。
final class FlacMetadataTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("FlacMetadataTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - 构造 FLAC 字节

    private func uint32LE(_ value: UInt32) -> Data {
        Data([
            UInt8(value & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 24) & 0xFF)
        ])
    }

    private func uint32BE(_ value: UInt32) -> Data {
        Data([
            UInt8((value >> 24) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8(value & 0xFF)
        ])
    }

    /// 块头：1 字节（最高位=是否末块 | 低 7 位=类型）+ 3 字节大端长度
    private func blockHeader(type: UInt8, length: Int, isLast: Bool) -> Data {
        Data([
            (isLast ? 0x80 : 0x00) | type,
            UInt8((length >> 16) & 0xFF),
            UInt8((length >> 8) & 0xFF),
            UInt8(length & 0xFF)
        ])
    }

    private func vorbisCommentBody(_ fields: [String]) -> Data {
        var body = Data()
        let vendor = Data("test-vendor".utf8)
        body += uint32LE(UInt32(vendor.count))
        body += vendor
        body += uint32LE(UInt32(fields.count))
        for field in fields {
            let encoded = Data(field.utf8)
            body += uint32LE(UInt32(encoded.count))
            body += encoded
        }
        return body
    }

    private func pictureBody(mime: String, image: Data) -> Data {
        var body = Data()
        body += uint32BE(3)                                  // 图片类型：封面（正面）
        let mimeData = Data(mime.utf8)
        body += uint32BE(UInt32(mimeData.count))
        body += mimeData
        let desc = Data("cover".utf8)
        body += uint32BE(UInt32(desc.count))
        body += desc
        body += uint32BE(500)                                // 宽
        body += uint32BE(500)                                // 高
        body += uint32BE(24)                                 // 色深
        body += uint32BE(0)                                  // 索引色数
        body += uint32BE(UInt32(image.count))
        body += image
        return body
    }

    /// 组装一个最小可用的 FLAC 文件：fLaC + STREAMINFO(占位) + 若干块
    private func writeFlac(name: String = "song.flac", blocks: [(type: UInt8, body: Data)]) throws -> URL {
        var data = Data("fLaC".utf8)

        // STREAMINFO 必须存在且长度固定 34；内容对本解析器无意义，填 0 即可
        let streamInfo = Data(repeating: 0, count: 34)
        data += blockHeader(type: 0, length: streamInfo.count, isLast: blocks.isEmpty)
        data += streamInfo

        for (index, block) in blocks.enumerated() {
            let isLast = index == blocks.count - 1
            data += blockHeader(type: block.type, length: block.body.count, isLast: isLast)
            data += block.body
        }

        // 一点假的音频帧，确保解析器不会越界读到文件尾之外
        data += Data(repeating: 0xAA, count: 128)

        let url = root.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    // MARK: - 用例

    func testReadsBasicTags() throws {
        let body = vorbisCommentBody([
            "TITLE=晴天",
            "ARTIST=周杰伦",
            "ALBUM=叶惠美"
        ])
        let url = try writeFlac(blocks: [(4, body)])

        let tags = try XCTUnwrap(FlacMetadata.read(url: url))

        XCTAssertEqual(tags.title, "晴天")
        XCTAssertEqual(tags.artist, "周杰伦")
        XCTAssertEqual(tags.album, "叶惠美")
    }

    func testReadsLyricsField() throws {
        let body = vorbisCommentBody(["LYRICS=[00:01.00]第一行\n[00:05.00]第二行"])
        let url = try writeFlac(blocks: [(4, body)])

        let tags = try XCTUnwrap(FlacMetadata.read(url: url))

        XCTAssertEqual(tags.lyrics, "[00:01.00]第一行\n[00:05.00]第二行")
    }

    func testReadsUnsyncedLyricsField() throws {
        let body = vorbisCommentBody(["UNSYNCEDLYRICS=没有时间戳的歌词"])
        let url = try writeFlac(blocks: [(4, body)])

        XCTAssertEqual(try XCTUnwrap(FlacMetadata.read(url: url)).lyrics, "没有时间戳的歌词")
    }

    func testFieldNamesAreCaseInsensitive() throws {
        let body = vorbisCommentBody(["title=小写键", "Artist=混合大小写"])
        let url = try writeFlac(blocks: [(4, body)])

        let tags = try XCTUnwrap(FlacMetadata.read(url: url))

        XCTAssertEqual(tags.title, "小写键")
        XCTAssertEqual(tags.artist, "混合大小写")
    }

    func testFallsBackToAlbumArtist() throws {
        let body = vorbisCommentBody(["ALBUMARTIST=群星"])
        let url = try writeFlac(blocks: [(4, body)])

        XCTAssertEqual(try XCTUnwrap(FlacMetadata.read(url: url)).artist, "群星")
    }

    func testReadsEmbeddedPicture() throws {
        let image = Data(repeating: 0x42, count: 256)
        let url = try writeFlac(blocks: [
            (4, vorbisCommentBody(["TITLE=有封面"])),
            (6, pictureBody(mime: "image/jpeg", image: image))
        ])

        let tags = try XCTUnwrap(FlacMetadata.read(url: url))

        XCTAssertEqual(tags.artwork, image)
    }

    func testSkipsUnknownBlocksBeforeComments() throws {
        // PADDING(1) 和 SEEKTABLE(3) 夹在前面，解析器必须跳过它们
        let url = try writeFlac(blocks: [
            (1, Data(repeating: 0, count: 64)),
            (3, Data(repeating: 0, count: 90)),
            (4, vorbisCommentBody(["TITLE=在后面"]))
        ])

        XCTAssertEqual(try XCTUnwrap(FlacMetadata.read(url: url)).title, "在后面")
    }

    func testEmptyValuesAreIgnored() throws {
        let body = vorbisCommentBody(["TITLE=", "ARTIST=有值"])
        let url = try writeFlac(blocks: [(4, body)])

        let tags = try XCTUnwrap(FlacMetadata.read(url: url))

        XCTAssertNil(tags.title)
        XCTAssertEqual(tags.artist, "有值")
    }

    func testMalformedFieldWithoutSeparatorIsSkipped() throws {
        let body = vorbisCommentBody(["这条没有等号", "ALBUM=正常"])
        let url = try writeFlac(blocks: [(4, body)])

        XCTAssertEqual(try XCTUnwrap(FlacMetadata.read(url: url)).album, "正常")
    }

    func testNoTagBlockReturnsNil() throws {
        let url = try writeFlac(blocks: [])
        XCTAssertNil(FlacMetadata.read(url: url))
    }

    func testNonFlacFileReturnsNil() throws {
        let url = root.appendingPathComponent("fake.flac")
        try Data("这不是 FLAC 文件".utf8).write(to: url)

        XCTAssertNil(FlacMetadata.read(url: url))
    }

    func testMissingFileReturnsNil() {
        XCTAssertNil(FlacMetadata.read(url: root.appendingPathComponent("nope.flac")))
    }

    func testTruncatedCommentBlockDoesNotCrash() throws {
        // 声明有 999 个条目，实际一个都没有 —— 损坏文件不应让扫描崩掉
        var body = Data()
        body += uint32LE(0)      // vendor 长度
        body += uint32LE(999)    // 条目数（撒谎）
        let url = try writeFlac(blocks: [(4, body)])

        XCTAssertNil(FlacMetadata.read(url: url))
    }
}
