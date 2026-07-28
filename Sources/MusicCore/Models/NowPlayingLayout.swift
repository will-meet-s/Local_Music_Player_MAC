import Foundation

/// 右侧「正在播放」区的展示模式。
public enum NowPlayingLayout: String, CaseIterable, Codable, Sendable {
    /// 封面 + 曲目信息 + 歌词（默认）。
    case artworkAndLyrics
    /// 只展示封面，尺寸随窗口放大。
    case artworkOnly
    /// 只展示歌词，占满整个区域。
    case lyricsOnly

    /// 循环切换到下一种模式。
    public var next: NowPlayingLayout {
        let all = NowPlayingLayout.allCases
        let i = all.firstIndex(of: self) ?? 0
        return all[(i + 1) % all.count]
    }

    public var displayName: String {
        switch self {
        case .artworkAndLyrics: return "封面 + 歌词"
        case .artworkOnly: return "只看封面"
        case .lyricsOnly: return "只看歌词"
        }
    }

    /// SF Symbols 名称。
    public var symbolName: String {
        switch self {
        case .artworkAndLyrics: return "square.split.1x2"
        case .artworkOnly: return "photo"
        case .lyricsOnly: return "text.alignleft"
        }
    }
}
