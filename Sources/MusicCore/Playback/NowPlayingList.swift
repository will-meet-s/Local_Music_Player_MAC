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

    /// 跟随状态下，扫描完成后的第一次同步要定位的曲目（T-010，重启恢复用）。
    /// 用完即清：不管找没找到，`syncFromLibrary` 里 `playing == nil` 的那次尝试
    /// 之后都会把它清空，不会一直占着、影响之后的搜索/排序/刷新。
    public var pendingFollowCurrent: TrackIdentity?

    public init(mode: PlayMode) {
        self.queue = PlaybackQueue(count: 0, mode: mode)
    }

    /// `items` 里与 `identity` 相同的下标；没有返回 nil。
    public func index(of identity: TrackIdentity) -> Int? {
        identityIndex[identity]
    }

    // MARK: - T-001

    /// 跟随状态下由 `rebuildDisplayed` 调用；逻辑与基线 `rebuildDisplayed` 里对 queue 的处理逐行相同。
    ///
    /// T-010：`playing == nil` 且 `pendingFollowCurrent` 有值时（重启恢复后的第一次
    /// 同步），优先用它定位，找到就 `select`；这个分支只在 `playing` 为 nil 时生效，
    /// `playing` 非空但没找到（被搜索过滤掉）时仍然走原来的 `previousIndex` 逻辑。
    public mutating func syncFromLibrary(_ displayed: [Track], playing: TrackIdentity?, previousIndex: Int?) {
        setItems(displayed)
        queue.setCount(items.count)

        if let playing, let index = identityIndex[playing] {
            queue.realign(index)
        } else if playing == nil, let pending = pendingFollowCurrent {
            if let index = identityIndex[pending] {
                queue.select(index)
            } else {
                queue.clearSelection()
            }
            pendingFollowCurrent = nil
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

    /// 在歌单里点播（T-006）。`snapshot` 是详情页当前显示的曲目——Swift 数组是值
    /// 类型，传过去就是一份独立拷贝，之后歌单的任何改动都碰不到这份播放列表。
    /// `name` 是点播那一刻的歌单名快照，之后不再更新（FR-001、FR-025）。
    public mutating func playFromSonglist(_ snapshot: [Track], at index: Int, name: String) {
        guard snapshot.indices.contains(index) else { return }
        state = .independent
        source = .songlist(name: name)
        setItems(snapshot)
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

    // MARK: - T-010：重启恢复播放列表

    /// 生成用于持久化的快照。`currentTrack` 是调用方（`PlayerViewModel`）的
    /// `playingTrack`——按 §3.1，Mac 上的「当前曲目」就是它，不是 `queue.current`
    /// 反查出来的曲目。跟随状态下 `items` 固定为空，不保存曲库镜像（方案 §3）。
    public func snapshot(currentTrack: Track?) -> NowPlayingSnapshot {
        let persistedItems: [SonglistEntry] = state == .independent
            ? items.map {
                SonglistEntry(path: $0.url.path, title: $0.title, artist: $0.artist, album: $0.album, duration: $0.duration)
            }
            : []
        return NowPlayingSnapshot(
            state: state, source: source, currentPath: currentTrack?.url.path, items: persistedItems
        )
    }

    /// 恢复独立状态（T-010）：`state = .independent`，`source` 按快照；`current`
    /// 有值时 `queue.select`，不触发播放——调用方负责设置 `playingTrack`，
    /// 不调用 `engine.load`（不自动播放、不恢复进度，方案 §4.2）。
    public mutating func restoreIndependent(_ items: [Track], current: Int?, source: NowPlayingSource) {
        state = .independent
        self.source = source
        setItems(items)
        queue.setCount(self.items.count)
        if let current {
            queue.select(current)
        } else {
            queue.clearSelection()
        }
    }

    // MARK: - T-008：编辑操作

    /// 下一首播放（FR-004）。`tracks` 是用户选中的、要插入的曲目，
    /// `playing` 是当前正在播放曲目的 identity（用于去掉①和排除④）。
    public mutating func playNext(_ tracks: [Track], playing: TrackIdentity?) -> EditResult {
        var toInsertIdentities = Set<TrackIdentity>()
        var toInsert: [Track] = []
        for track in tracks {
            guard track.identity != playing, toInsertIdentities.insert(track.identity).inserted else { continue }
            toInsert.append(track)
        }
        guard !toInsert.isEmpty else { return EditResult() }

        let cur = queue.current
        var anchor: Int
        if let cur {
            anchor = cur + 1
        } else if let resumeIndex = queue.pendingResumeItemIndex {
            anchor = resumeIndex
        } else {
            anchor = 0
        }

        // 单次遍历 items，把要挪走的摘出来，同时数出 anchor 之前被摘走了几个用来修正
        // anchor；调用方可能传入大批量曲目（多选），禁止嵌套 firstIndex(where: identity==)
        // 造成 O(输入 × items) 的退化（方案 §4 性能类要求）。
        var remaining: [Track] = []
        remaining.reserveCapacity(items.count)
        var relocatedIdentities = Set<TrackIdentity>()
        var removedBeforeAnchor = 0
        for (index, track) in items.enumerated() {
            if toInsertIdentities.contains(track.identity) {
                relocatedIdentities.insert(track.identity)
                if index < anchor { removedBeforeAnchor += 1 }
            } else {
                remaining.append(track)
            }
        }
        anchor = min(max(anchor - removedBeforeAnchor, 0), remaining.count)

        var newItems = remaining
        newItems.insert(contentsOf: toInsert, at: anchor)

        let placement: EditPlacement = cur != nil ? .afterCurrent : (queue.pendingResumeItemIndex != nil ? .atResume : .atStart)
        // v2：queue 的 added 要包含 toInsert 全部（新加入的 + 被挪过来的）；playNext
        // 的 toInsert 在上面的去重循环里已经排除了正在播放的那首，不需要再排除。
        return commitEdit(
            newItems, addedTracks: toInsert,
            insertedCount: toInsert.count - relocatedIdentities.count, relocatedCount: relocatedIdentities.count,
            placement: placement
        )
    }

    /// 加到末尾（FR-005）。正在播放的那首即使在输入里也不去掉：它被挪到末尾，播放不中断。
    public mutating func append(_ tracks: [Track], playing: TrackIdentity?) -> EditResult {
        var toInsertIdentities = Set<TrackIdentity>()
        var toInsert: [Track] = []
        for track in tracks {
            guard toInsertIdentities.insert(track.identity).inserted else { continue }
            toInsert.append(track)
        }
        guard !toInsert.isEmpty else { return EditResult() }

        var remaining: [Track] = []
        remaining.reserveCapacity(items.count)
        var relocatedIdentities = Set<TrackIdentity>()
        for track in items {
            if toInsertIdentities.contains(track.identity) {
                relocatedIdentities.insert(track.identity)
            } else {
                remaining.append(track)
            }
        }

        var newItems = remaining
        newItems.append(contentsOf: toInsert)

        // v2：queue 的 added 要排除当前曲目——它即使在输入里也不去掉（①），但它已经
        // 在顺序表里占着位置，不能再当作「要插入的」处理，否则随机模式下顺序表会出现
        // 重复下标。EditResult 的计数仍然按 toInsert 全量算，和当前曲目是否在其中无关。
        let addedTracks = toInsert.filter { $0.identity != playing }
        return commitEdit(
            newItems, addedTracks: addedTracks,
            insertedCount: toInsert.count - relocatedIdentities.count, relocatedCount: relocatedIdentities.count,
            placement: .randomInRemainder
        )
    }

    /// 从播放列表移除（FR-006）。下标可以重复、可以越界，越界的忽略。
    public mutating func remove(at indices: IndexSet) -> EditResult {
        let validIndices = indices.filter { items.indices.contains($0) }
        guard !validIndices.isEmpty else { return EditResult() }

        let oldItems = items
        var newItems = items
        for index in validIndices.sorted(by: >) {
            newItems.remove(at: index)
        }

        setItems(newItems)
        let map = oldItems.map { identityIndex[$0.identity] }
        queue.applyEdit(map: map, newCount: newItems.count, added: [], placement: .keepNatural, relocated: [])
        markEdited()

        return EditResult(inserted: 0, relocated: 0, changed: true)
    }

    /// 拖动排序（FR-007）。`to` 是移除 `from` 之后、新列表里的位置。
    public mutating func move(from: Int, to: Int) -> EditResult {
        guard from >= 0, from < items.count, to >= 0, to < items.count, from != to else {
            return EditResult()
        }

        let oldItems = items
        var newItems = items
        let moved = newItems.remove(at: from)
        newItems.insert(moved, at: to)

        setItems(newItems)
        let map = oldItems.map { identityIndex[$0.identity] }
        let relocated: Set<Int> = identityIndex[moved.identity].map { Set([$0]) } ?? []
        queue.applyEdit(map: map, newCount: newItems.count, added: [], placement: .keepNatural, relocated: relocated)
        markEdited()

        return EditResult(inserted: 0, relocated: 1, changed: true)
    }

    /// 清空（FR-008）。已为空时照样执行，不报错（TC-138）。
    public mutating func clear() {
        setItems([])
        queue.setCount(0)
        markEdited()
    }

    // MARK: - 内部

    private mutating func setItems(_ newItems: [Track]) {
        items = newItems
        // 大小写敏感的卷上 a.mp3 和 A.mp3 是同一个 identity（T-002 方案 §4），
        // 保留第一次出现的下标，不能用 uniqueKeysWithValues（重复键会崩溃）。
        var index: [TrackIdentity: Int] = [:]
        index.reserveCapacity(newItems.count)
        for (offset, track) in newItems.enumerated() where index[track.identity] == nil {
            index[track.identity] = offset
        }
        identityIndex = index
    }

    /// `playNext`/`append` 共用的收尾：算出 `map`，提交新 `items`，推进队列，
    /// 转入独立状态，返回编辑结果。复用 `setItems` 刚建好的 `identityIndex` 查
    /// `addedTracks` 对应的新下标，不再单独为 `newItems` 重建一份索引或整体扫描
    /// 一遍判断谁是新的——1 万首规模下这对性能类单测有意义。
    ///
    /// - Parameters:
    ///   - addedTracks: 要传给 `queue.applyEdit` 的 `added`（v2 语义：本次放到 placement
    ///     位置的全部曲目，新加入的 + 被挪过来的；调用方已经按各自的规则排除了不该算
    ///     进去的曲目，例如 `append` 排除当前曲目）。
    ///   - insertedCount / relocatedCount: `EditResult` 用，和 `addedTracks` 是否排除
    ///     当前曲目无关，按输入去重后的全量计算。
    private mutating func commitEdit(
        _ newItems: [Track], addedTracks: [Track], insertedCount: Int, relocatedCount: Int, placement: EditPlacement
    ) -> EditResult {
        let oldItems = items

        setItems(newItems)

        let map = oldItems.map { identityIndex[$0.identity] }
        let added = addedTracks.compactMap { identityIndex[$0.identity] }

        // playNext/append 的「被挪过来」已经通过 added + placement 处理（会被挪到
        // placement 指定的位置），不再走 relocated 那条「随机插回剩余部分」的规则——
        // 那条规则现在只服务于 move()。
        queue.applyEdit(map: map, newCount: newItems.count, added: added, placement: placement, relocated: [])
        markEdited()

        return EditResult(inserted: insertedCount, relocated: relocatedCount, changed: true)
    }

    private mutating func markEdited() {
        state = .independent
        source = .edited
    }
}
