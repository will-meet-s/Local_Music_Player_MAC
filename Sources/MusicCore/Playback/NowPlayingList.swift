import Foundation

/// 播放列表所处的两种状态（需求 §3.1）。
public enum NowPlayingState: String, Codable, Sendable {
    case followLibrary
    case independent
}

/// 播放列表当前内容的来源。
public enum NowPlayingSource: Equatable, Codable, Sendable {
    case library
    case songlist(name: String)
    case edited
}

/// 编辑类操作（T-008）的结果，供 ViewModel 决定要不要弹提示、要不要刷新预加载。
public struct EditResult: Equatable, Sendable {
    /// 新加入的首数。
    public var inserted = 0
    /// 已在列表里、被挪了位置的首数。
    public var relocated = 0
    /// 内容或顺序是否真的变了；false 时调用方什么都不做。
    public var changed = false
}

/// 「播放列表」（PL）：把播放用的列表从曲库当前显示的列表中拆出来。
///
/// 跟随状态下 `items` 是曲库显示列表的镜像，独立状态下由点播歌单或手动编辑产生，
/// 此时曲库的搜索、排序、刷新都不影响它。纯逻辑值类型，不依赖引擎和 UI，可以完整单测。
public struct NowPlayingList {
    public private(set) var items: [Track] = []
    public private(set) var state: NowPlayingState = .followLibrary
    public private(set) var source: NowPlayingSource = .library
    public var queue: PlaybackQueue

    /// `items` 里 identity 到下标的索引，随 `items` 整体更新一起重建，O(1) 查找。
    private var identityIndex: [TrackIdentity: Int] = [:]

    public init(mode: PlayMode) {
        self.queue = PlaybackQueue(count: 0, mode: mode)
    }

    /// `items` 里与 `identity` 相同的下标；没有返回 nil。
    public func index(of identity: TrackIdentity) -> Int? {
        identityIndex[identity]
    }

    // MARK: - T-001

    /// 跟随状态下由 `rebuildDisplayed` 调用；逻辑与基线 `rebuildDisplayed` 里对 queue 的处理逐行相同。
    public mutating func syncFromLibrary(_ displayed: [Track], playing: TrackIdentity?, previousIndex: Int?) {
        setItems(displayed)
        queue.setCount(items.count)

        if let playing, let index = identityIndex[playing] {
            queue.realign(index)
        } else if let previousIndex {
            queue.park(at: previousIndex)
        } else {
            queue.clearSelection()
        }
    }

    /// 在曲库点播：state = .followLibrary，source = .library，items = displayed，queue.select(index)。
    public mutating func playFromLibrary(_ displayed: [Track], at index: Int) {
        guard displayed.indices.contains(index) else { return }
        state = .followLibrary
        source = .library
        setItems(displayed)
        queue.setCount(items.count)
        queue.select(index)
    }

    /// 在 PL 页双击：只 select，状态和来源不变。
    public mutating func selectInList(_ index: Int) {
        guard index >= 0 && index < items.count else { return }
        queue.select(index)
    }

    /// 切换曲库文件夹（FR-024 ③，T-009 验收）：独立状态保留 items，queue.clearSelection()。
    public mutating func detachCurrent() {
        queue.clearSelection()
    }

    // MARK: - 内部

    private mutating func setItems(_ newItems: [Track]) {
        items = newItems
        // 大小写敏感的卷上 a.mp3 和 A.mp3 是同一个 identity（T-002 方案 §4），
        // 保留第一次出现的下标，不能用 uniqueKeysWithValues（重复键会崩溃）。
        identityIndex = Dictionary(items.enumerated().map { ($1.identity, $0) }, uniquingKeysWith: { first, _ in first })
    }
}
