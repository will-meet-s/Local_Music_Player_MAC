import Foundation

/// 根据播放模式计算「下一首 / 上一首」的索引。
///
/// 只关心索引，不持有曲目数据，因此可以脱离音频完全单测。
/// 内部维护一张播放顺序表 `order`（元素是曲目索引）与当前位置 `position`：
/// 非随机模式下 `order` 就是自然序，随机模式下是一次性洗好的顺序，
/// 这样「上一首」能沿着实际播放过的顺序回退，且一轮内不重复。
public struct PlaybackQueue {

    public private(set) var count: Int
    public private(set) var current: Int?

    public var mode: PlayMode {
        didSet {
            guard mode != oldValue else { return }
            rebuildOrder()
        }
    }

    private var order: [Int] = []
    private var position: Int = 0

    public init(count: Int = 0, mode: PlayMode = .sequential) {
        self.count = count
        self.mode = mode
        rebuildOrder()
    }

    /// 曲目列表变化后调用。当前曲目若已越界则清空。
    public mutating func setCount(_ newCount: Int) {
        count = max(0, newCount)
        if let c = current, c >= count {
            current = nil
        }
        rebuildOrder()
    }

    /// 用户直接点选某首歌。
    public mutating func select(_ index: Int) {
        guard index >= 0 && index < count else { return }
        current = index
        position = order.firstIndex(of: index) ?? 0
    }

    /// 下一首。
    /// - Parameter auto: true 表示当前曲目自然播完触发（单曲循环会重播当前曲）；
    ///                   false 表示用户点了「下一首」（单曲循环也前进）。
    /// - Returns: 下一首的索引；顺序播放到达末尾时返回 nil，表示应停止播放。
    public mutating func next(auto: Bool) -> Int? {
        guard count > 0 else { return nil }
        guard let c = current else { return selectFirst() }

        if auto && mode == .repeatOne { return c }

        if position + 1 < order.count {
            position += 1
        } else {
            if mode == .sequential { return nil }
            if mode == .shuffle { reshuffleKeepingNothing() }
            position = 0
        }

        current = order[position]
        return current
    }

    /// 上一首。顺序播放停在第一首，其余模式环绕到末尾。
    public mutating func previous() -> Int? {
        guard count > 0 else { return nil }
        guard current != nil else { return selectFirst() }

        if position - 1 >= 0 {
            position -= 1
        } else {
            if mode == .sequential { return current }
            position = order.count - 1
        }

        current = order[position]
        return current
    }

    private mutating func selectFirst() -> Int? {
        guard !order.isEmpty else { return nil }
        position = 0
        current = order[0]
        return current
    }

    private mutating func rebuildOrder() {
        guard count > 0 else {
            order = []
            position = 0
            return
        }

        switch mode {
        case .shuffle:
            var shuffled = Array(0..<count).shuffled()
            // 把当前曲目挪到表首，这样切入随机模式不会打断正在播放的歌。
            if let c = current, let idx = shuffled.firstIndex(of: c) {
                shuffled.swapAt(0, idx)
            }
            order = shuffled
        default:
            order = Array(0..<count)
        }

        position = current.flatMap { order.firstIndex(of: $0) } ?? 0
    }

    /// 一轮随机播完后重新洗牌，开始新的一轮。
    private mutating func reshuffleKeepingNothing() {
        order = Array(0..<count).shuffled()
    }

    // MARK: - 供测试观察内部顺序

    var currentOrder: [Int] { order }
}
