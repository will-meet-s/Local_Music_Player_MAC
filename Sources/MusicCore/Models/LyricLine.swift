import Foundation

/// 一行带时间戳的歌词。
public struct LyricLine: Hashable, Identifiable {
    public let id: Int
    /// 该行开始时间，单位秒。
    public let time: Double
    public let text: String

    public init(id: Int, time: Double, text: String) {
        self.id = id
        self.time = time
        self.text = text
    }
}
