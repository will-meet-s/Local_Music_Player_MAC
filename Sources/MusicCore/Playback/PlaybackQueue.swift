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
    /// 当前曲目从列表里消失后停靠的位置（曲目下标，不是顺序表下标）。
    ///
    /// 存曲目下标而不是顺序表位置，是因为顺序表会随排序 / 洗牌重建。
    private var parkedIndex: Int?

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

    /// 清除当前选中项，下一次 `next` 从顺序表头部重新开始。
    public mutating func clearSelection() {
        current = nil
        position = 0
        parkedIndex = nil
    }

    /// 当前曲目从列表中消失（被删除或被搜索过滤）时，把队列停靠在它原来的序号上。
    ///
    /// 效果是「没有选中项，但下一次 `next` 会从 `index` 这个位置接着走」——
    /// 删掉第 300 首之后应该从第 300 位继续，而不是跳回列表开头。
    /// 停靠点**不**钳制到列表末尾。原位置超出新列表长度，语义就是「已经播过了结尾」，
    /// 该走结尾逻辑（顺序播放停止 / 循环回到开头），而不是硬拽到最后一首。
    public mutating func park(at index: Int) {
        current = nil
        position = 0
        parkedIndex = count > 0 ? max(0, index) : nil
    }

    /// 用户直接点选某首歌。
    public mutating func select(_ index: Int) {
        guard index >= 0 && index < count else { return }
        current = index
        position = order.firstIndex(of: index) ?? 0
        parkedIndex = nil
    }

    /// 预看下一首是谁，**不改变任何状态**。
    ///
    /// 无缝播放需要提前把下一首塞进播放队列缓冲，但那时当前曲还在播，
    /// 队列位置不能动 —— 所以不能用 `next(auto:)`。
    ///
    /// 有一处与 `next` 不一致：随机模式播到一轮末尾时返回 nil。
    /// 下一轮的随机顺序要到真正翻页时才洗出来，预看阶段无从得知，
    /// 代价是每轮有且仅有一次切歌拿不到无缝。
    public func peekNext(auto: Bool) -> Int? {
        guard count > 0 else { return nil }
        guard let c = current else { return parkedTarget }

        if auto && mode == .repeatOne { return c }

        if position + 1 < order.count {
            return order[position + 1]
        }

        switch mode {
        case .sequential: return nil
        case .shuffle: return nil
        case .repeatAll, .repeatOne: return order.first
        }
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

    /// 没有选中项时该从哪首开始。
    ///
    /// - 有停靠点且仍在列表内 → 就从它开始
    /// - 有停靠点但已超出列表长度（列表缩短了）→ 等同播到结尾：
    ///   顺序播放返回 nil（停止），循环 / 随机回到开头
    /// - 没有停靠点 → 顺序表首项
    private var parkedTarget: Int? {
        guard let parkedIndex else { return order.first }
        if order.contains(parkedIndex) { return parkedIndex }
        return mode == .sequential ? nil : order.first
    }

    private mutating func selectFirst() -> Int? {
        guard let target = parkedTarget else {
            parkedIndex = nil
            return nil
        }
        parkedIndex = nil
        position = order.firstIndex(of: target) ?? 0
        current = order[position]
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
