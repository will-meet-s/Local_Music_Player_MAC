import Foundation

/// 播放顺序模式。
public enum PlayMode: String, CaseIterable, Codable, Sendable {
    /// 顺序播放：播到列表末尾自动停止。
    case sequential
    /// 列表循环：播到末尾回到开头。
    case repeatAll
    /// 单曲循环：自动切歌时重播当前曲；手动下一首仍前进。
    case repeatOne
    /// 随机播放：一轮内不重复。
    case shuffle

    /// 循环切换到下一个模式。
    public var next: PlayMode {
        let all = PlayMode.allCases
        let i = all.firstIndex(of: self) ?? 0
        return all[(i + 1) % all.count]
    }

    public var displayName: String {
        switch self {
        case .sequential: return "顺序播放"
        case .repeatAll: return "列表循环"
        case .repeatOne: return "单曲循环"
        case .shuffle: return "随机播放"
        }
    }

    /// SF Symbols 名称。
    public var symbolName: String {
        switch self {
        case .sequential: return "arrow.right"
        case .repeatAll: return "repeat"
        case .repeatOne: return "repeat.1"
        case .shuffle: return "shuffle"
        }
    }
}
