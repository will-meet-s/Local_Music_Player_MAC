import Foundation

/// 「同一首歌」的判定键（FR-026）：完整路径，不区分大小写。
/// 只做字符串规范化，不访问磁盘。
public struct TrackIdentity: Hashable, Codable, Sendable, CustomStringConvertible {
    /// 规范化后的键。只用于比较和持久化，不用于显示或打开文件。
    public let key: String

    public init(url: URL) {
        guard url.isFileURL else {
            self.key = url.absoluteString.lowercased()
            return
        }
        self.key = Self.normalize(path: url.standardizedFileURL.path)
    }

    /// 供 T-003 从持久化数据里的路径字符串重建。
    public init(path: String) {
        self.init(url: URL(fileURLWithPath: path))
    }

    public var description: String { key }

    private static func normalize(path: String) -> String {
        var result = path

        while result.contains("//") {
            result = result.replacingOccurrences(of: "//", with: "/")
        }

        if result.count > 1 && result.hasSuffix("/") {
            result.removeLast()
        }

        result = result.precomposedStringWithCanonicalMapping
        return result.lowercased()
    }
}
