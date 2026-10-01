import Foundation

/// 歌单里的一条曲目。只存打开和显示所需的信息，不存 identity 的 key
/// （T-002 §3 的约定：以后调整规范化规则不需要迁移数据）。
public struct SonglistEntry: Codable, Equatable, Sendable {
    /// `Track.url.path` 原样保存，用于打开和显示。
    public var path: String
    public var title: String
    public var artist: String?
    public var album: String?
    /// 秒，没有时为 0。
    public var duration: Double

    public init(path: String, title: String, artist: String? = nil, album: String? = nil, duration: Double = 0) {
        self.path = path
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
    }
}

/// 一个歌单的完整内容，对应 `songlists/<UUID>.json` 一个文件（§3.2，`schemaVersion` 1）。
public struct Songlist: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var id: UUID
    public var name: String
    public var createdAt: Date
    /// 每写一次 +1，用来排查。
    public var revision: Int
    public var entries: [SonglistEntry]

    public init(id: UUID, name: String, createdAt: Date, revision: Int = 0, entries: [SonglistEntry] = []) {
        self.schemaVersion = 1
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.revision = revision
        self.entries = entries
    }
}

/// 歌单列表页用的摘要，不含 `entries`。
public struct SonglistSummary: Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var count: Int
    public var createdAt: Date

    public init(id: UUID, name: String, count: Int, createdAt: Date) {
        self.id = id
        self.name = name
        self.count = count
        self.createdAt = createdAt
    }
}

/// 启动加载或同步时读取失败的文件，原文件不受影响、原样保留。
public struct LoadFailure: Identifiable, Equatable, Sendable {
    public var id: String { fileName }
    public var fileName: String
    public var reason: String

    public init(fileName: String, reason: String) {
        self.fileName = fileName
        self.reason = reason
    }
}

/// 歌单操作与磁盘 I/O 相关的错误（§2.4）。
public enum SonglistError: Error, Equatable, Sendable {
    case nameEmpty
    case nameTooLong
    case nameDuplicate(existing: String)
    case notFound(name: String)
    case saveFailed(reason: String)

    /// 展示给用户的提示文字。
    public var message: String {
        switch self {
        case .nameEmpty:
            return "歌单名称不能为空"
        case .nameTooLong:
            return "歌单名称不能超过 100 个字符"
        case .nameDuplicate(let existing):
            return "已有同名歌单「\(existing)」"
        case .notFound(let name):
            return "歌单「\(name)」已不存在"
        case .saveFailed(let reason):
            return "歌单保存失败：\(reason)。本次操作未生效"
        }
    }
}

/// `Songlist` 的编码格式：UTF-8、不缩进、不转义斜杠、日期为含毫秒的 ISO 8601（UTC）。
public enum SonglistCoding {
    static let dateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }()

    public static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(dateFormatter.string(from: date))
        }
        return encoder
    }

    public static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)
            guard let date = dateFormatter.date(from: string) else {
                throw DecodingError.dataCorruptedError(
                    in: container, debugDescription: "无法解析日期：\(string)"
                )
            }
            return date
        }
        return decoder
    }
}
