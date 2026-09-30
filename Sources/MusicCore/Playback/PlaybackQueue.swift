import Foundation

/// 列表发生结构性编辑（T-008）后，新加入曲目的插入策略。
public enum EditPlacement {
    case afterCurrent
    case atResume
    case atStart
    case randomInRemainder
    case keepNatural
}

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
    /// 当前曲目已被移除、还没放完时，放完后从顺序表的哪个位置接着走（顺序表下标）。
    /// 只由 `applyEdit` 设置；与 `parkedIndex` 互斥（同一时刻只有一个生效）。
    private var resumeAt: Int?

    public init(count: Int = 0, mode: PlayMode = .sequential) {
        self.count = count
        self.mode = mode
        rebuildOrder()
    }

    /// 正在放的歌已被移除、还没放完（`resumeAt`），或跟随状态下正在放的歌被搜索过滤掉
    /// 后停靠着（`parkedIndex`）时，续播点对应的 items 下标；越界时返回 `count`
    /// （表示「接在末尾」）；两者都没有时返回 nil。`applyEdit` 会把 `parkedIndex`
    /// 换算成真正的 `resumeAt`，这里只是给编辑操作的调用方一个统一的只读入口，
    /// 不改变内部状态。
    public var pendingResumeItemIndex: Int? {
        if let resumeAt {
            return resumeAt < order.count ? order[resumeAt] : count
        }
        if let parkedIndex {
            return parkedIndex < count ? parkedIndex : count
        }
        return nil
    }

    /// 曲目列表变化后调用。当前曲目若已越界则清空。
    public mutating func setCount(_ newCount: Int) {
        count = max(0, newCount)
        if let c = current, c >= count {
            current = nil
        }
        resumeAt = nil
        rebuildOrder()
    }

    /// 清除当前选中项，下一次 `next` 从顺序表头部重新开始。
    public mutating func clearSelection() {
        current = nil
        position = 0
        parkedIndex = nil
        resumeAt = nil
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
        resumeAt = nil
    }

    /// 用户直接点选某首歌。
    public mutating func select(_ index: Int) {
        guard index >= 0 && index < count else { return }
        current = index
        position = order.firstIndex(of: index) ?? 0
        parkedIndex = nil
        resumeAt = nil
    }

    /// 跟随状态下搜索、排序、刷新后重新对齐当前曲目。
    ///
    /// 与 `select` 相同，但不清除 `resumeAt`（跟随状态没有编辑操作，`resumeAt`
    /// 此刻恒为 nil，两者行为一致）。
    public mutating func realign(_ index: Int) {
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
        guard let c = current else {
            if resumeAt != nil { return peekResumeNext() }
            return parkedTarget
        }

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

    /// 与 `peekNext` 一样没有副作用，但按 `ok` 跳过不满足条件的候选项（T-007：
    /// 跳过已知不可用的曲目）。从当前位置模拟推进，最多 `count` 步，避免全部
    /// 都不满足时死循环；返回第一个满足 `ok` 的下标，找不到返回 nil。
    ///
    /// 随机模式走到一轮末尾时返回 nil，与 `peekNext` 的已知限制相同——下一轮的
    /// 随机顺序要到真正翻页时才洗出来，预看阶段无从得知。
    public func peekNextWhere(_ ok: (Int) -> Bool, auto: Bool) -> Int? {
        guard count > 0 else { return nil }
        let wraps = (mode == .repeatAll || mode == .repeatOne)

        guard let c = current else {
            if let r = resumeAt {
                return firstMatching(ok, startPosition: r, wrap: wraps)
            }
            guard let target = parkedTarget else { return nil }
            let startPos = order.firstIndex(of: target) ?? 0
            return firstMatching(ok, startPosition: startPos, wrap: wraps)
        }

        if auto && mode == .repeatOne {
            return ok(c) ? c : nil
        }

        return firstMatching(ok, startPosition: position + 1, wrap: wraps)
    }

    /// 从顺序表的某个位置开始（含），按「是否允许跨过表尾回到表头」找第一个满足
    /// `ok` 的下标；最多检查 `count` 次，不满足就往下一位置试，不修改任何状态。
    private func firstMatching(_ ok: (Int) -> Bool, startPosition: Int, wrap: Bool) -> Int? {
        guard !order.isEmpty else { return nil }
        var pos = startPosition
        var steps = 0
        while steps < count {
            if pos >= order.count {
                guard wrap else { return nil }
                pos = 0
            }
            if pos < order.count {
                let idx = order[pos]
                if ok(idx) { return idx }
            }
            pos += 1
            steps += 1
        }
        return nil
    }

    /// 下一首。
    /// - Parameter auto: true 表示当前曲目自然播完触发（单曲循环会重播当前曲）；
    ///                   false 表示用户点了「下一首」（单曲循环也前进）。
    /// - Returns: 下一首的索引；顺序播放到达末尾时返回 nil，表示应停止播放。
    public mutating func next(auto: Bool) -> Int? {
        guard count > 0 else { return nil }
        guard let c = current else {
            if resumeAt != nil { return resumeNext() }
            return selectFirst()
        }

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
        guard current != nil else {
            if resumeAt != nil { return resumePrevious() }
            return selectFirst()
        }

        if position - 1 >= 0 {
            position -= 1
        } else {
            if mode == .sequential { return current }
            position = order.count - 1
        }

        current = order[position]
        return current
    }

    // MARK: - T-008：结构性编辑

    /// 列表发生结构性编辑（插入、移除、挪动）后调用。
    ///
    /// - Parameters:
    ///   - map: 旧下标 → 新下标；nil 表示这首在编辑后被移除。长度等于编辑前的 `count`。
    ///   - newCount: 编辑后的曲目总数。
    ///   - added: 本次要放到 `placement` 位置的**全部**曲目的新下标，按插入顺序排列
    ///     （v2）：包括新加入的，也包括「已在列表里、被挪过来」的（例如对一首已在列表
    ///     里的歌选「下一首播放」）；`append` 调用方要自己排除当前曲目。随机模式下，
    ///     这里面列出的下标会先从重映射后的顺序表里摘掉，再按 `placement` 统一插入，
    ///     这样被挪过来的曲目才会真正跳到目标位置，而不是留在旧的洗牌相对位置上。
    ///   - placement: 新曲目的插入策略；`added` 为空时忽略。
    ///   - relocated: 被挪了位置、但不通过 `added`/`placement` 机制处理的新下标——
    ///     目前只有 `move()` 会用到（随机模式下，本轮已经放过的部分要重新算作没放过，
    ///     见方案 §2.3）；挪的是当前曲目时不受这条规则影响。`playNext`/`append`
    ///     传 `added` 就够了，这里传空集合。
    public mutating func applyEdit(
        map: [Int?],
        newCount: Int,
        added: [Int],
        placement: EditPlacement,
        relocated: Set<Int>
    ) {
        let wasRandom = (mode == .shuffle)
        let oldOrder = order
        let oldPosition = position
        let oldCurrent = current

        // 编辑前「没有当前曲目」时，把停靠点统一换算成 resumeAt（以旧顺序表位置计）。
        var effectiveOldResumeAt: Int?
        if oldCurrent == nil {
            if let r = resumeAt {
                effectiveOldResumeAt = r
            } else if let p = parkedIndex {
                effectiveOldResumeAt = wasRandom
                    ? (oldOrder.firstIndex(of: p) ?? oldOrder.count)
                    : min(p, oldOrder.count)
            }
        }

        // Step 1：构建新顺序表（还不含新曲目）。
        // 非随机：自然顺序，天然等于最终顺序表。
        // 随机：按 map 重映射旧顺序表，删掉被移除的，其余相对顺序不变。
        var newOrder: [Int] = wasRandom
            ? oldOrder.compactMap { map[$0] }
            : Array(0..<newCount)

        // Step 2：当前曲目
        var newCurrent: Int?
        var newPosition = 0
        var newResumeAt: Int?

        if let c = oldCurrent, let mappedC = map[c] {
            // 当前曲目还在：随机模式下它在顺序表里的位置不变
            // （newOrder 由 oldOrder 逐项重映射得到，相对位置天然保留）。
            newCurrent = mappedC
            newPosition = wasRandom ? (newOrder.firstIndex(of: mappedC) ?? 0) : mappedC
        } else if oldCurrent != nil {
            // 当前曲目被移除：resumeAt = 那一段之后第一首还留着的歌在新顺序表里的位置
            newResumeAt = Self.findSurvivorPosition(
                startingAt: oldPosition + 1, oldOrder: oldOrder, map: map, newOrder: newOrder, newCount: newCount
            )
        } else if let r = effectiveOldResumeAt {
            // 编辑前已经没有当前曲目，顺着旧的停靠点往后找
            newResumeAt = Self.findSurvivorPosition(
                startingAt: r, oldOrder: oldOrder, map: map, newOrder: newOrder, newCount: newCount
            )
        }
        // 三者都不成立（一直没有当前曲目，也没有任何停靠点）：newCurrent、newResumeAt 都保持 nil

        // Step 3：随机模式下，本轮已经放过、又被挪动过的曲目要重新算作没放过
        // （当前曲目自己不受这条规则影响）。
        if wasRandom, let curIdx = newCurrent {
            let curPos = newOrder.firstIndex(of: curIdx) ?? 0
            let alreadyPlayed = relocated.filter { idx in
                guard idx != curIdx, let posInNew = newOrder.firstIndex(of: idx) else { return false }
                return posInNew < curPos
            }
            if !alreadyPlayed.isEmpty {
                let toReinsert = Set(alreadyPlayed)
                newOrder.removeAll { toReinsert.contains($0) }
                let refreshedCurPos = newOrder.firstIndex(of: curIdx) ?? 0
                for idx in alreadyPlayed {
                    let low = refreshedCurPos + 1
                    let insertAt = low < newOrder.count ? Int.random(in: low...newOrder.count) : newOrder.count
                    newOrder.insert(idx, at: insertAt)
                }
                newPosition = newOrder.firstIndex(of: curIdx) ?? refreshedCurPos
            }
        }

        // Step 4：插入新曲目（v2：added 现在包含「新加入的」和「已在列表里、被挪过来的」
        // 两类——后者在 Step 1 的重映射里已经按旧的相对位置出现在 newOrder 里了，
        // 随机模式下要先把它们摘掉，才能统一在下面按 placement 重新插入，
        // 否则它们会留在旧位置，不会真的挪到 placement 指定的地方）。
        if wasRandom, !added.isEmpty {
            let addedSet = Set(added)
            newOrder.removeAll { addedSet.contains($0) }
            if let curIdx = newCurrent {
                newPosition = newOrder.firstIndex(of: curIdx) ?? newPosition
            }
        }

        if !added.isEmpty {
            switch placement {
            case .afterCurrent:
                // 非随机：新曲目已经在自然顺序里，不需要改 newOrder。
                if wasRandom, newCurrent != nil {
                    var insertAt = newPosition + 1
                    for idx in added {
                        let clamped = min(insertAt, newOrder.count)
                        newOrder.insert(idx, at: clamped)
                        insertAt = clamped + 1
                    }
                }

            case .atStart:
                // 非随机：新曲目天然在自然顺序开头，不需要改 newOrder。
                if wasRandom {
                    newOrder.insert(contentsOf: added, at: 0)
                }

            case .atResume:
                if wasRandom {
                    let insertAt = min(newResumeAt ?? newOrder.count, newOrder.count)
                    newOrder.insert(contentsOf: added, at: insertAt)
                    newResumeAt = insertAt
                } else {
                    // 非随机：新曲目已经物理插在正确位置（自然顺序 = items 下标）；
                    // resumeAt 不能沿用 Step 2 算出的「旧停靠点对应曲目的新下标」
                    // （那指向的是插入点之后的那首），必须直接指向第一首新曲目自己。
                    newResumeAt = added.first
                }

            case .randomInRemainder:
                // 非随机：新曲目已经物理追加在末尾，不需要改 newOrder。
                if wasRandom {
                    let lowerBound = (newCurrent.flatMap { newOrder.firstIndex(of: $0) } ?? -1) + 1
                    for idx in added {
                        let insertAt = lowerBound < newOrder.count ? Int.random(in: lowerBound...newOrder.count) : newOrder.count
                        newOrder.insert(idx, at: insertAt)
                    }
                }

            case .keepNatural:
                break // move 操作不新增曲目
            }

            // 随机模式下插入可能改变了当前曲目在顺序表里的位置（例如插在它前面），统一刷新一次。
            if wasRandom, let curIdx = newCurrent {
                newPosition = newOrder.firstIndex(of: curIdx) ?? newPosition
            }
        }

        order = newOrder
        current = newCurrent
        position = newPosition
        resumeAt = newResumeAt
        parkedIndex = nil
        count = newCount
    }

    /// 从旧顺序表的 `start` 位置起（含）往后找第一首在 `map` 里仍然存活的曲目，
    /// 返回它在新顺序表里的位置；找不到就返回 `newCount`（表示「接在末尾」）。
    private static func findSurvivorPosition(
        startingAt start: Int, oldOrder: [Int], map: [Int?], newOrder: [Int], newCount: Int
    ) -> Int {
        var q = max(0, start)
        while q < oldOrder.count {
            let oldItemIdx = oldOrder[q]
            if let newItemIdx = map[oldItemIdx], let posInNew = newOrder.firstIndex(of: newItemIdx) {
                return posInNew
            }
            q += 1
        }
        return newCount
    }

    // MARK: - resumeAt 的使用（只在 current == nil 且 resumeAt != nil 时生效）

    private func peekResumeNext() -> Int? {
        guard let r = resumeAt else { return nil }
        if r < order.count { return order[r] }
        switch mode {
        case .sequential: return nil
        case .repeatAll, .repeatOne: return order.first
        case .shuffle: return nil // 下一轮顺序要到真正推进时才洗出来，预看放弃
        }
    }

    private mutating func resumeNext() -> Int? {
        guard let r = resumeAt else { return nil }
        if r < order.count {
            position = r
            current = order[r]
            resumeAt = nil
            return current
        }
        resumeAt = nil
        switch mode {
        case .sequential:
            return nil
        case .repeatAll, .repeatOne:
            position = 0
            current = order.first
            return current
        case .shuffle:
            reshuffleKeepingNothing()
            position = 0
            current = order.first
            return current
        }
    }

    private mutating func resumePrevious() -> Int? {
        guard let r = resumeAt else { return nil }
        let targetPos = r - 1
        if targetPos >= 0 {
            position = targetPos
            current = order[targetPos]
            resumeAt = nil
            return current
        }
        resumeAt = nil
        switch mode {
        case .sequential:
            return nil
        case .repeatAll, .repeatOne, .shuffle:
            guard !order.isEmpty else { return nil }
            position = order.count - 1
            current = order[position]
            return current
        }
    }

    /// 没有选中项时该从哪首开始（`parkedIndex` 路径，供跟随状态使用）。
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
