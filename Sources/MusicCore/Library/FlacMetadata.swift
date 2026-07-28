import Foundation

/// FLAC 元数据读取器。
///
/// AVFoundation 能解码 FLAC 音频，但不解析它的 Vorbis Comment 标签块，
/// 所以标题 / 艺术家 / 专辑 / 歌词 / 封面全都拿不到。这里按 FLAC 规范
/// 自己走一遍文件头的元数据块。
///
/// 参考：https://xiph.org/flac/format.html
///
/// 只读文件开头的元数据区，不会把整个音频载入内存。
public enum FlacMetadata {

    public struct Tags: Equatable {
        public var title: String?
        public var artist: String?
        public var album: String?
        public var lyrics: String?
        public var artwork: Data?

        public init() {}

        public var isEmpty: Bool {
            title == nil && artist == nil && album == nil && lyrics == nil && artwork == nil
        }
    }

    private enum BlockType: UInt8 {
        case vorbisComment = 4
        case picture = 6
    }

    /// 单个元数据块的大小上限。封面图可能有几 MB，但超过这个值多半是文件损坏。
    private static let maxBlockSize = 32 * 1024 * 1024

    /// Vorbis Comment 里表示歌词的字段名（不同打标签软件用法不一）。
    private static let lyricsKeys = ["LYRICS", "UNSYNCEDLYRICS", "UNSYNCED LYRICS", "LYRIC"]

    // MARK: - 入口

    /// 读取 FLAC 文件的标签。不是 FLAC、读不动、或没有标签块时返回 nil。
    public static func read(url: URL) -> Tags? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        guard let magic = readBytes(handle, count: 4), magic == Data("fLaC".utf8) else {
            return nil
        }

        var tags = Tags()
        var isLast = false

        while !isLast {
            guard let header = readBytes(handle, count: 4), header.count == 4 else { break }

            let first = header[header.startIndex]
            isLast = (first & 0x80) != 0
            let rawType = first & 0x7F
            let length = Int(header[header.startIndex + 1]) << 16
                | Int(header[header.startIndex + 2]) << 8
                | Int(header[header.startIndex + 3])

            guard length >= 0, length <= maxBlockSize else { break }

            switch BlockType(rawValue: rawType) {
            case .vorbisComment:
                guard let body = readBytes(handle, count: length) else { return finish(tags) }
                applyVorbisComment(body, to: &tags)
            case .picture:
                guard let body = readBytes(handle, count: length) else { return finish(tags) }
                if tags.artwork == nil {
                    tags.artwork = parsePicture(body)
                }
            case nil:
                // STREAMINFO / PADDING / SEEKTABLE 等，跳过
                guard skip(handle, count: length) else { return finish(tags) }
            }
        }

        return finish(tags)
    }

    private static func finish(_ tags: Tags) -> Tags? {
        tags.isEmpty ? nil : tags
    }

    // MARK: - VORBIS_COMMENT 块

    /// 结构：vendor 长度(4, 小端) + vendor + 条目数(4, 小端) + N 个 [长度(4, 小端) + "KEY=value"]
    private static func applyVorbisComment(_ data: Data, to tags: inout Tags) {
        var cursor = data.startIndex

        guard let vendorLength = readUInt32LE(data, at: &cursor) else { return }
        guard advance(&cursor, by: Int(vendorLength), in: data) else { return }

        guard let count = readUInt32LE(data, at: &cursor) else { return }
        // 条目数来自文件，损坏时可能是个天文数字，用剩余字节数兜底
        let safeCount = min(Int(count), data.count / 4)

        for _ in 0..<safeCount {
            guard let fieldLength = readUInt32LE(data, at: &cursor) else { return }
            let end = cursor + Int(fieldLength)
            guard fieldLength <= UInt32(Int32.max), end <= data.endIndex else { return }

            let field = data[cursor..<end]
            cursor = end

            guard let text = String(data: field, encoding: .utf8),
                  let separator = text.firstIndex(of: "=") else { continue }

            let key = text[text.startIndex..<separator].uppercased()
            let value = String(text[text.index(after: separator)...])
            guard !value.isEmpty else { continue }

            switch key {
            case "TITLE" where tags.title == nil:
                tags.title = value
            case "ARTIST" where tags.artist == nil:
                tags.artist = value
            case "ALBUMARTIST" where tags.artist == nil:
                tags.artist = value
            case "ALBUM" where tags.album == nil:
                tags.album = value
            default:
                if tags.lyrics == nil, lyricsKeys.contains(key) {
                    tags.lyrics = value
                }
            }
        }
    }

    // MARK: - PICTURE 块

    /// 结构（全部大端）：类型(4) + MIME 长度(4) + MIME + 描述长度(4) + 描述
    ///                  + 宽(4) + 高(4) + 色深(4) + 索引色数(4) + 数据长度(4) + 数据
    private static func parsePicture(_ data: Data) -> Data? {
        var cursor = data.startIndex

        guard readUInt32BE(data, at: &cursor) != nil else { return nil }              // 图片类型

        guard let mimeLength = readUInt32BE(data, at: &cursor),
              advance(&cursor, by: Int(mimeLength), in: data) else { return nil }

        guard let descLength = readUInt32BE(data, at: &cursor),
              advance(&cursor, by: Int(descLength), in: data) else { return nil }

        // 宽、高、色深、索引色数
        for _ in 0..<4 {
            guard readUInt32BE(data, at: &cursor) != nil else { return nil }
        }

        guard let imageLength = readUInt32BE(data, at: &cursor) else { return nil }
        let end = cursor + Int(imageLength)
        guard imageLength > 0, end <= data.endIndex else { return nil }

        return Data(data[cursor..<end])
    }

    // MARK: - 字节读取

    private static func readBytes(_ handle: FileHandle, count: Int) -> Data? {
        guard count > 0 else { return Data() }
        guard let data = try? handle.read(upToCount: count), data.count == count else { return nil }
        return data
    }

    private static func skip(_ handle: FileHandle, count: Int) -> Bool {
        guard count > 0 else { return true }
        guard let current = try? handle.offset() else { return false }
        do {
            try handle.seek(toOffset: current + UInt64(count))
            return true
        } catch {
            return false
        }
    }

    private static func advance(_ cursor: inout Data.Index, by count: Int, in data: Data) -> Bool {
        guard count >= 0, cursor + count <= data.endIndex else { return false }
        cursor += count
        return true
    }

    private static func readUInt32LE(_ data: Data, at cursor: inout Data.Index) -> UInt32? {
        guard cursor + 4 <= data.endIndex else { return nil }
        let value = UInt32(data[cursor])
            | UInt32(data[cursor + 1]) << 8
            | UInt32(data[cursor + 2]) << 16
            | UInt32(data[cursor + 3]) << 24
        cursor += 4
        return value
    }

    private static func readUInt32BE(_ data: Data, at cursor: inout Data.Index) -> UInt32? {
        guard cursor + 4 <= data.endIndex else { return nil }
        let value = UInt32(data[cursor]) << 24
            | UInt32(data[cursor + 1]) << 16
            | UInt32(data[cursor + 2]) << 8
            | UInt32(data[cursor + 3])
        cursor += 4
        return value
    }
}
