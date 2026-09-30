import XCTest
@testable import MusicCore

final class NowPlayingListTests: XCTestCase {

    private func track(_ name: String) -> Track {
        Track(url: URL(fileURLWithPath: "/Music/\(name).mp3"))
    }

    // MARK: - 初始状态

    func testInitialStateFollowsLibraryWithEmptyItems() {
        let list = NowPlayingList(mode: .sequential)
        XCTAssertEqual(list.state, .followLibrary)
        XCTAssertEqual(list.source, .library)
        XCTAssertTrue(list.items.isEmpty)
        XCTAssertEqual(list.queue.count, 0)
    }

    // MARK: - playFromLibrary（在曲库点播）

    func testPlayFromLibrarySelectsGivenIndex() {
        var list = NowPlayingList(mode: .sequential)
        let displayed = [track("A"), track("B"), track("C")]

        list.playFromLibrary(displayed, at: 1)

        XCTAssertEqual(list.state, .followLibrary)
        XCTAssertEqual(list.source, .library)
        XCTAssertEqual(list.items.map(\.identity), displayed.map(\.identity))
        XCTAssertEqual(list.queue.current, 1)
    }

    func testPlayFromLibraryOutOfRangeIsIgnored() {
        var list = NowPlayingList(mode: .sequential)
        let displayed = [track("A"), track("B")]

        list.playFromLibrary(displayed, at: 5)

        XCTAssertTrue(list.items.isEmpty, "越界时不应生效，同基线 play(at:)")
        XCTAssertNil(list.queue.current)
    }

    // MARK: - selectInList（PL 页双击）

    func testSelectInListDoesNotChangeStateOrSource() {
        var list = NowPlayingList(mode: .sequential)
        list.playFromLibrary([track("A"), track("B")], at: 0)

        list.selectInList(1)

        XCTAssertEqual(list.state, .followLibrary)
        XCTAssertEqual(list.source, .library)
        XCTAssertEqual(list.queue.current, 1)
    }

    func testSelectInListOutOfRangeIsIgnored() {
        var list = NowPlayingList(mode: .sequential)
        list.playFromLibrary([track("A"), track("B")], at: 0)

        list.selectInList(99)

        XCTAssertEqual(list.queue.current, 0, "越界时保持原选中项不变")
    }

    // MARK: - index(of:)：O(1) 身份查找

    func testIndexOfReturnsMatchingIdentity() {
        var list = NowPlayingList(mode: .sequential)
        let displayed = [track("A"), track("B"), track("C")]
        list.playFromLibrary(displayed, at: 0)

        XCTAssertEqual(list.index(of: displayed[2].identity), 2)
        XCTAssertNil(list.index(of: TrackIdentity(path: "/Music/Z.mp3")))
    }

    // MARK: - syncFromLibrary（跟随状态下搜索、排序、刷新）

    func testSyncFromLibraryRealignsWhenCurrentStillPresent() {
        var list = NowPlayingList(mode: .sequential)
        let all = [track("A"), track("B"), track("C")]
        list.playFromLibrary(all, at: 1) // 当前 B

        // 排序后 B 挪到了下标 0
        let resorted = [track("B"), track("A"), track("C")]
        list.syncFromLibrary(resorted, playing: track("B").identity, previousIndex: 1)

        XCTAssertEqual(list.queue.current, 0, "应对齐到 B 的新下标")
        XCTAssertEqual(list.queue.next(auto: true), 1, "对齐后队列位置也应正确前进")
    }

    func testSyncFromLibraryParksWhenCurrentFilteredOut() {
        var list = NowPlayingList(mode: .sequential)
        let all = [track("A"), track("B"), track("C")]
        list.playFromLibrary(all, at: 1) // 当前 B

        // 搜索后 B 被过滤掉，只剩 A、C
        let filtered = [track("A"), track("C")]
        list.syncFromLibrary(filtered, playing: track("B").identity, previousIndex: 1)

        XCTAssertNil(list.queue.current, "被过滤掉后没有选中项")
        XCTAssertEqual(list.queue.peekNext(auto: true), 1, "应从原序号继续，而不是跳回开头")
    }

    func testSyncFromLibraryClearsSelectionWhenNoCurrentTrack() {
        var list = NowPlayingList(mode: .sequential)
        let displayed = [track("A"), track("B")]

        list.syncFromLibrary(displayed, playing: nil, previousIndex: nil)

        XCTAssertNil(list.queue.current)
        XCTAssertEqual(list.items.map(\.identity), displayed.map(\.identity))
    }

    // MARK: - detachCurrent（切换曲库文件夹，独立状态保留 items）

    func testDetachCurrentKeepsItemsButClearsSelection() {
        var list = NowPlayingList(mode: .sequential)
        list.playFromLibrary([track("A"), track("B")], at: 1)

        list.detachCurrent()

        XCTAssertEqual(list.items.count, 2, "items 应保留")
        XCTAssertNil(list.queue.current)
    }

    // MARK: - F-2：identity 相同（大小写敏感卷上的重复文件）不应崩溃

    func testDuplicateIdentityDoesNotCrashAndIndexReturnsFirstOccurrence() {
        var list = NowPlayingList(mode: .sequential)
        let caseOnlyDuplicate = [
            Track(url: URL(fileURLWithPath: "/Music/X.mp3")),
            Track(url: URL(fileURLWithPath: "/Music/x.mp3")),
            track("Y")
        ]

        // 不崩溃是这条用例的第一重断言
        list.syncFromLibrary(caseOnlyDuplicate, playing: nil, previousIndex: nil)

        XCTAssertEqual(list.index(of: caseOnlyDuplicate[0].identity), 0, "应返回第一次出现的下标")
    }

    // MARK: - T-008 #4：playNext 把已在列表里的曲目挪到当前曲目之后

    func testPlayNextRelocatesExistingTracksRightAfterCurrent() {
        var list = NowPlayingList(mode: .sequential)
        let ten = (0..<10).map { track("T\($0)") }
        list.playFromLibrary(ten, at: 2) // 当前 T2

        let result = list.playNext([ten[7], ten[8]], playing: ten[2].identity)

        XCTAssertEqual(result.relocated, 2)
        XCTAssertEqual(result.inserted, 0)
        XCTAssertTrue(result.changed)
        XCTAssertEqual(list.items.count, 10)
        let names = list.items.map(\.title)
        XCTAssertEqual(names, ["T0", "T1", "T2", "T7", "T8", "T3", "T4", "T5", "T6", "T9"])
        XCTAssertEqual(list.queue.current, 2, "当前曲目下标不变")
    }

    // MARK: - T-008 #5：连续两次 playNext，后一次排在前一次前面

    func testConsecutivePlayNextInsertsNewerOneFirst() {
        var list = NowPlayingList(mode: .sequential)
        let ten = (0..<10).map { track("T\($0)") }
        list.playFromLibrary(ten, at: 2) // 当前 T2

        _ = list.playNext([ten[7]], playing: ten[2].identity)
        _ = list.playNext([ten[8]], playing: ten[2].identity)

        let afterCurrent = Array(list.items[3...4]).map(\.title)
        XCTAssertEqual(afterCurrent, ["T8", "T7"], "第二次插入的应排在第一次插入的前面")
    }

    // MARK: - T-008 #6：playNext 输入是当前曲目本身

    func testPlayNextWithOnlyCurrentTrackDoesNothing() {
        var list = NowPlayingList(mode: .sequential)
        let three = (0..<3).map { track("T\($0)") }
        list.playFromLibrary(three, at: 1)

        let result = list.playNext([three[1]], playing: three[1].identity)

        XCTAssertFalse(result.changed)
    }

    // MARK: - T-008 #7：空列表时 playNext

    func testPlayNextOnEmptyListThenNextStartsAtZero() {
        var list = NowPlayingList(mode: .sequential)
        let newTrack = track("C07")

        let result = list.playNext([newTrack], playing: nil)

        XCTAssertTrue(result.changed)
        XCTAssertEqual(list.items.map(\.identity), [newTrack.identity])
        XCTAssertNil(list.queue.current)
        XCTAssertEqual(list.queue.next(auto: false), 0)
    }

    // MARK: - T-008 #8：顺序放完后 playNext 插在停着的那首后面（Mac 口径 FR-004 ⑤）

    func testPlayNextAfterSequentialFinishInsertsAfterParkedCurrent() {
        var list = NowPlayingList(mode: .sequential)
        let ten = (0..<10).map { track("T\($0)") }
        list.playFromLibrary(ten, at: 0)
        for _ in 0..<9 { _ = list.queue.next(auto: true) } // 推进到最后一首（下标 9）
        XCTAssertNil(list.queue.next(auto: true), "顺序播放到头应返回 nil")
        XCTAssertEqual(list.queue.current, 9, "基线：放完后仍保留当前曲目")

        // A03（原下标 3）移到最后一首后面
        let result = list.playNext([ten[3]], playing: ten[9].identity)

        XCTAssertTrue(result.changed)
        XCTAssertEqual(list.queue.current, 8, "原最后一首整体前移一位后的新下标")
        XCTAssertEqual(list.items[9].identity, ten[3].identity)
        XCTAssertEqual(list.queue.next(auto: false), 9, "手动下一首应前进到刚插入的这首")
    }

    // MARK: - T-008 #9：顺序放完后 append 不影响当前曲目

    func testAppendAfterSequentialFinishKeepsCurrentTrack() {
        var list = NowPlayingList(mode: .sequential)
        let ten = (0..<10).map { track("T\($0)") }
        list.playFromLibrary(ten, at: 0)
        for _ in 0..<9 { _ = list.queue.next(auto: true) }
        XCTAssertNil(list.queue.next(auto: true))
        let lastIdentity = ten[9].identity

        let newTrack = track("C07")
        let result = list.append([newTrack], playing: lastIdentity)

        XCTAssertTrue(result.changed)
        XCTAssertEqual(list.items.last?.identity, newTrack.identity)
        XCTAssertEqual(list.items[list.queue.current!].identity, lastIdentity, "当前曲目不变")
    }

    // MARK: - T-008 #10：单曲循环下 playNext

    func testPlayNextInRepeatOneMode() {
        var list = NowPlayingList(mode: .repeatOne)
        let three = (0..<3).map { track("T\($0)") }
        list.playFromLibrary(three, at: 1) // 当前 T1

        let newTrack = track("X")
        _ = list.playNext([newTrack], playing: three[1].identity)

        XCTAssertEqual(list.queue.current, 1, "自动切歌（重播）不应改变 current")
        XCTAssertEqual(list.queue.next(auto: true), 1, "单曲循环自动推进重播当前曲")
        XCTAssertEqual(list.queue.next(auto: false), 2, "手动下一首前进到插入的那首")
        XCTAssertEqual(list.items[2].identity, newTrack.identity)
    }

    // MARK: - T-008 #11：随机模式下 playNext 插入的新曲目紧接着播，且不在本轮重复

    func testShufflePlayNextInsertsNewTrackRightAfterCurrentWithoutRepeats() {
        var list = NowPlayingList(mode: .shuffle)
        let original = (0..<3).map { track("Original\($0)") }
        list.playFromLibrary(original, at: 0)

        _ = list.queue.next(auto: true) // 播完第 1 首
        _ = list.queue.next(auto: true) // 播完第 2 首，当前第 3 首

        // 用顺序表直接算「已经放过的」，而不是之后再调用 next() 去数——调用次数一旦
        // 数错就会跨进下一轮（随机重新洗牌），那一轮完全可能又抽到同一首，是不必要的
        // 脆弱点（T-008 #14 就因为这样在 CI 上偶发失败过一次，这里改成结构性检查）。
        let playedBeforeEdit: Set<TrackIdentity> = {
            guard let idx = list.queue.current, let pos = list.queue.currentOrder.firstIndex(of: idx) else { return [] }
            return Set(list.queue.currentOrder.prefix(pos).map { list.items[$0].identity })
        }()
        let currentIdentity = list.queue.current.map { list.items[$0].identity }
        let newTrack = track("NewW")

        let result = list.playNext([newTrack], playing: currentIdentity)
        XCTAssertTrue(result.changed)
        XCTAssertEqual(result.inserted, 1)

        guard let curItemsIdx = list.queue.current,
              let curPos = list.queue.currentOrder.firstIndex(of: curItemsIdx) else {
            return XCTFail("应有当前曲目")
        }
        let order = list.queue.currentOrder
        guard let newTrackItemsIdx = list.items.firstIndex(where: { $0.identity == newTrack.identity }) else {
            return XCTFail("应能找到新插入的曲目")
        }
        XCTAssertEqual(order[curPos + 1], newTrackItemsIdx, "新曲目应该紧跟在当前曲目后面")

        // 本轮剩余部分（当前之后）不应再出现已经放过的曲目
        for idx in order[(curPos + 1)...] {
            XCTAssertFalse(playedBeforeEdit.contains(list.items[idx].identity), "已经放过的曲目不应在本轮剩余部分再出现")
        }
    }

    // MARK: - T-008 #12/#13：顺序播放下 move 当前曲目

    func testMoveCurrentTrackToFrontInSequentialMode() {
        var list = NowPlayingList(mode: .sequential)
        let three = (0..<3).map { track("T\($0)") }
        list.playFromLibrary(three, at: 2) // 当前最后一首

        let result = list.move(from: 2, to: 0)
        XCTAssertTrue(result.changed)
        XCTAssertEqual(list.items[0].identity, three[2].identity)
        XCTAssertEqual(list.queue.current, 0, "挪到第 0 位后 current 应跟到新位置")
        XCTAssertEqual(list.queue.next(auto: true), 1, "应返回原第 0 位那首（现在第 1 位）")
    }

    func testMoveCurrentTrackToEndThenSequentialStopsThenRepeatAllWrapsToHead() {
        var listSeq = NowPlayingList(mode: .sequential)
        let three = (0..<3).map { track("T\($0)") }
        listSeq.playFromLibrary(three, at: 0) // 当前第 0 首

        _ = listSeq.move(from: 0, to: 2) // 挪到末尾
        XCTAssertEqual(listSeq.queue.current, 2)
        XCTAssertNil(listSeq.queue.next(auto: true), "顺序播放：挪到末尾后下一首即到头")

        var listRepeat = NowPlayingList(mode: .repeatAll)
        listRepeat.playFromLibrary(three, at: 0)
        _ = listRepeat.move(from: 0, to: 2)
        XCTAssertEqual(listRepeat.queue.next(auto: true), 0, "列表循环：挪到末尾后下一首回到第 0 首")
    }

    // MARK: - T-008 #14：随机模式下 move 一首已经放过的曲目，本轮会再出现一次

    func testShuffleMoveOfAlreadyPlayedTrackReappearsOnceThisRound() {
        var list = NowPlayingList(mode: .shuffle)
        let all = (0..<5).map { track("M\($0)") }
        list.playFromLibrary(all, at: 0)

        _ = list.queue.next(auto: true) // 播完第 1 首
        guard let playedIdx = list.queue.current else { return XCTFail("应有当前曲目") }
        let playedIdentity = list.items[playedIdx].identity
        _ = list.queue.next(auto: true) // 播完第 2 首，当前第 3 首

        guard let fromIndex = list.items.firstIndex(where: { $0.identity == playedIdentity }) else {
            return XCTFail("应能找到已播放的那首")
        }
        let result = list.move(from: fromIndex, to: list.items.count - 1)
        XCTAssertTrue(result.changed)

        // 直接看顺序表「当前之后」的部分有没有恰好一次这首——而不是调用 next() 数
        // 出对应次数：调用次数一旦数错就会跨进下一轮（随机重新洗牌），那一轮完全
        // 可能又抽到同一首，是不必要的脆弱点（这条用例在 CI 上因此偶发失败过一次）。
        guard let curItemsIdx = list.queue.current,
              let curPos = list.queue.currentOrder.firstIndex(of: curItemsIdx) else {
            return XCTFail("应有当前曲目")
        }
        let remainder = list.queue.currentOrder[(curPos + 1)...]
        let occurrences = remainder.filter { list.items[$0].identity == playedIdentity }.count
        XCTAssertEqual(occurrences, 1, "被挪动的已播放曲目本轮应恰好再出现一次")
    }

    // MARK: - T-008 #15/#16：remove 当前曲目及其邻居

    func testRemoveCurrentTrackResumesAtNextSurvivor() {
        var list = NowPlayingList(mode: .sequential)
        let ten = (0..<10).map { track("T\($0)") }
        list.playFromLibrary(ten, at: 2)

        let result = list.remove(at: IndexSet([2]))

        XCTAssertTrue(result.changed)
        XCTAssertNil(list.queue.current)
        XCTAssertEqual(list.queue.next(auto: true), 2, "原第 4 首（T3）现在下标 2")
    }

    func testRemoveCurrentAndNextResumesAtFirstSurvivorAfter() {
        var list = NowPlayingList(mode: .sequential)
        let ten = (0..<10).map { track("T\($0)") }
        list.playFromLibrary(ten, at: 2)

        _ = list.remove(at: IndexSet([2, 3]))

        XCTAssertNil(list.queue.current)
        XCTAssertEqual(list.items[list.queue.next(auto: true)!].identity, ten[4].identity)
    }

    func testRemoveLastTrackWhileCurrentStopsSequentialWrapsRepeatAllResuffleShuffle() {
        var listSeq = NowPlayingList(mode: .sequential)
        let three = (0..<3).map { track("T\($0)") }
        listSeq.playFromLibrary(three, at: 2)
        _ = listSeq.remove(at: IndexSet([2]))
        XCTAssertNil(listSeq.queue.next(auto: true), "顺序播放：最后一首被移除应停止")

        var listRepeat = NowPlayingList(mode: .repeatAll)
        listRepeat.playFromLibrary(three, at: 2)
        _ = listRepeat.remove(at: IndexSet([2]))
        XCTAssertEqual(listRepeat.queue.next(auto: true), 0, "列表循环：回到第一首")

        var listShuffle = NowPlayingList(mode: .shuffle)
        listShuffle.playFromLibrary(three, at: 2)
        _ = listShuffle.remove(at: IndexSet([2]))
        XCTAssertNotNil(listShuffle.queue.next(auto: true), "随机模式：重新洗牌后应给出新一轮第一首")
    }

    func testRemoveAllTracksReturnsNilOnNext() {
        var list = NowPlayingList(mode: .sequential)
        let three = (0..<3).map { track("T\($0)") }
        list.playFromLibrary(three, at: 1)

        _ = list.remove(at: IndexSet(0..<3))

        XCTAssertTrue(list.items.isEmpty)
        XCTAssertNil(list.queue.next(auto: true))
    }

    // MARK: - T-008 #17：remove 当前曲目后 playNext 走 atResume，再手动前进到原续播点

    func testRemoveCurrentThenPlayNextThenAdvanceTwiceGoesToInsertedThenSurvivor() {
        var list = NowPlayingList(mode: .sequential)
        let abcd = ["A", "B", "C", "D"].map { track($0) }
        list.playFromLibrary(abcd, at: 1) // 当前 B

        _ = list.remove(at: IndexSet([1]))
        XCTAssertNil(list.queue.current)

        let x = track("X")
        _ = list.playNext([x], playing: nil)

        XCTAssertEqual(list.items[list.queue.next(auto: true)!].identity, x.identity, "先 X")
        XCTAssertEqual(list.items[list.queue.next(auto: true)!].identity, abcd[2].identity, "再 C")
    }

    // MARK: - T-008 #18：remove 当前曲目后 move 另一首，续播点仍指向正确的存活曲目

    func testRemoveCurrentThenMoveAnotherTrackStillResumesCorrectly() {
        var list = NowPlayingList(mode: .sequential)
        let abcd = ["A", "B", "C", "D"].map { track($0) }
        list.playFromLibrary(abcd, at: 1) // 当前 B

        _ = list.remove(at: IndexSet([1])) // 剩 A C D，续播点指向 C
        guard let dIndex = list.items.firstIndex(where: { $0.identity == abcd[3].identity }) else {
            return XCTFail("应能找到 D")
        }
        _ = list.move(from: dIndex, to: 0) // D 挪到最前面

        XCTAssertEqual(list.items[list.queue.next(auto: true)!].identity, abcd[2].identity, "应返回 C")
    }

    // MARK: - T-008 #19：当前曲目是最后一首且被移除，playNext 后续播点正确

    func testRemoveLastCurrentTrackThenPlayNextResumesAtInserted() {
        var list = NowPlayingList(mode: .sequential)
        let three = (0..<3).map { track("T\($0)") }
        list.playFromLibrary(three, at: 2) // 当前最后一首

        _ = list.remove(at: IndexSet([2]))
        XCTAssertEqual(list.queue.pendingResumeItemIndex, list.items.count, "插入前应等于 count")

        let x = track("X")
        _ = list.playNext([x], playing: nil)

        XCTAssertEqual(list.items[list.queue.next(auto: true)!].identity, x.identity)
    }

    // MARK: - T-008 #20：跟随状态下当前曲目被过滤掉后 playNext，转为独立并插在停靠位置

    func testPlayNextAfterParkedInFollowModeTransitionsToIndependent() {
        var list = NowPlayingList(mode: .sequential)
        let ten = (0..<10).map { track("T\($0)") }
        list.syncFromLibrary(ten, playing: nil, previousIndex: nil)
        list.queue.select(5)
        // 模拟「当前曲目被搜索过滤掉」：跟随状态下重新 syncFromLibrary，不含当前曲目
        var filtered = ten
        let filteredOutIdentity = ten[5].identity
        filtered.remove(at: 5)
        list.syncFromLibrary(filtered, playing: filteredOutIdentity, previousIndex: 5)
        XCTAssertNil(list.queue.current)
        XCTAssertEqual(list.state, .followLibrary)

        let x = track("X")
        let result = list.playNext([x], playing: nil)

        XCTAssertTrue(result.changed)
        XCTAssertEqual(list.state, .independent)
        XCTAssertEqual(list.items[5].identity, x.identity, "应插在原停靠位置")
        XCTAssertEqual(list.items[list.queue.next(auto: true)!].identity, x.identity)
    }

    // MARK: - T-008 #21：跟随状态、还没点播时 append

    func testAppendBeforeAnyPlaybackStartsFromFirstTrack() {
        var list = NowPlayingList(mode: .sequential)
        let ten = (0..<10).map { track("T\($0)") }
        list.syncFromLibrary(ten, playing: nil, previousIndex: nil)
        XCTAssertNil(list.queue.current)

        let x = track("X")
        _ = list.append([x], playing: nil)

        XCTAssertEqual(list.queue.next(auto: false), 0, "应返回原第一首")
    }

    // MARK: - T-008 #22：clear 两次都成功

    func testClearTwiceBothSucceed() {
        var list = NowPlayingList(mode: .sequential)
        let three = (0..<3).map { track("T\($0)") }
        list.playFromLibrary(three, at: 0)

        list.clear()
        XCTAssertTrue(list.items.isEmpty)
        XCTAssertEqual(list.state, .independent)
        XCTAssertEqual(list.source, .edited)

        list.clear() // 再来一次不应报错或崩溃
        XCTAssertTrue(list.items.isEmpty)
    }

    // MARK: - T-008 #24：1 万首列表上 playNext/remove/move 的性能

    func testEditPerformanceOnTenThousandTracks() {
        var list = NowPlayingList(mode: .sequential)
        let many = (0..<10_000).map { track("P\($0)") }
        list.playFromLibrary(many, at: 0)

        // 预热
        _ = list.playNext([many[9000]], playing: many[0].identity)

        var durations: [TimeInterval] = []
        for i in 0..<5 {
            let start = Date()
            _ = list.playNext([many[8000 + i]], playing: many[0].identity)
            _ = list.remove(at: IndexSet([100 + i]))
            _ = list.move(from: 200 + i, to: 300 + i)
            durations.append(Date().timeIntervalSince(start))
        }

        let sorted = durations.sorted()
        let median = sorted[sorted.count / 2]
        // v2：CI 的 swift test 是 debug 构建，阈值从 50ms 放宽到 100ms；
        // 1 万首时如果退化成 O(n²)，耗时会到秒级，100ms 仍然能发现。
        XCTAssertLessThanOrEqual(median, 0.1, "5 次耗时：\(durations)")
    }

    // MARK: - T-008 #25（v2，F-8）：随机模式下 playNext 一首已在列表里的曲目，应紧接着播

    func testShufflePlayNextOfAlreadyPresentTrackPlaysNext() {
        var list = NowPlayingList(mode: .shuffle)
        let all = (0..<5).map { track("S\($0)") }
        list.playFromLibrary(all, at: 0)

        _ = list.queue.next(auto: true) // 播完第 1 首
        _ = list.queue.next(auto: true) // 播完第 2 首，当前第 3 首（对应设计里的 Z）

        let currentIdentity = list.queue.current.map { list.items[$0].identity }
        guard let curItemsIdx = list.queue.current,
              let curPos = list.queue.currentOrder.firstIndex(of: curItemsIdx) else {
            return XCTFail("应有当前曲目")
        }
        // 选一个不是当前曲目所在的位置（5 首里必然存在）；之前按"顺序表最后一位"挑，
        // 当前曲目恰好落在最后一位时会选中它自己，playNext 会把它当成"就是正在播放的
        // 那首"而直接过滤掉（changed == false），导致断言偶发失败——这里改成结构性地
        // 找任意一个不等于 curPos 的位置，不依赖随机结果落在哪。
        let order = list.queue.currentOrder
        guard let candidatePos = order.indices.first(where: { $0 != curPos }) else {
            return XCTFail("应该不止一首曲目")
        }
        let x = list.items[order[candidatePos]]

        let result = list.playNext([x], playing: currentIdentity)
        XCTAssertTrue(result.changed)
        XCTAssertEqual(result.relocated, 1, "X 本来就在列表里，应计入 relocated")

        // 直接检查顺序表结构：X 应该紧跟在当前曲目后面——不调用 next() 去验证，
        // 避免任何跨轮次的可能（即便这里按 afterCurrent 的插入逻辑分析不会有风险，
        // 结构性断言仍然更直接、更不依赖对边界条件的额外推理）。
        guard let newCurItemsIdx = list.queue.current,
              let newCurPos = list.queue.currentOrder.firstIndex(of: newCurItemsIdx) else {
            return XCTFail("应有当前曲目")
        }
        let newOrder = list.queue.currentOrder
        guard let xItemsIdx = list.items.firstIndex(where: { $0.identity == x.identity }) else {
            return XCTFail("应能找到 X")
        }
        XCTAssertEqual(newOrder[newCurPos + 1], xItemsIdx, "X 应该紧跟在当前曲目后面")
    }

    // MARK: - T-008 #26（v2，F-8）：非随机 atResume 下，被挪过来的曲目不能被跳过

    func testRemoveCurrentThenPlayNextOfExistingTrackIsNotSkipped() {
        var list = NowPlayingList(mode: .sequential)
        let abcd = ["A", "B", "C", "D"].map { track($0) }
        list.playFromLibrary(abcd, at: 1) // 当前 B

        _ = list.remove(at: IndexSet([1])) // 剩 A C D，续播点指向 C
        XCTAssertNil(list.queue.current)

        // D 已经在列表里，playNext([D]) 应该把它挪到续播点，而不是被当成「非新曲目」
        // 整个丢在原地（F-8 之前的 bug：resumeAt 仍指向 C，D 被跳过）
        let result = list.playNext([abcd[3]], playing: nil)
        XCTAssertTrue(result.changed)
        XCTAssertEqual(result.relocated, 1)
        XCTAssertEqual(list.items.map(\.identity), [abcd[0], abcd[3], abcd[2]].map(\.identity), "应变成 [A, D, C]")

        XCTAssertEqual(list.items[list.queue.next(auto: true)!].identity, abcd[3].identity, "先 D")
        XCTAssertEqual(list.items[list.queue.next(auto: true)!].identity, abcd[2].identity, "再 C")
    }

    // MARK: - T-008 #27（v2）：随机模式下 append([当前曲目, W])，当前曲目位置不变、播放不中断

    func testShuffleAppendIncludingCurrentTrackKeepsItsRoundPosition() {
        var list = NowPlayingList(mode: .shuffle)
        let three = (0..<3).map { track("A\($0)") }
        list.playFromLibrary(three, at: 0)

        guard let curIdx = list.queue.current else { return XCTFail("应有当前曲目") }
        let currentIdentity = list.items[curIdx].identity
        let currentPositionBefore = list.queue.currentOrder.firstIndex(of: curIdx)

        // W 在前、当前曲目在后，这样「挪到末尾」可以直接断言 items.last。
        let w = track("W")
        let result = list.append([w, list.items[curIdx]], playing: currentIdentity)
        XCTAssertTrue(result.changed)
        XCTAssertEqual(result.relocated, 1, "当前曲目本来就在列表里，应计入 relocated")
        XCTAssertEqual(result.inserted, 1, "只有 W 是真正新增的")

        XCTAssertEqual(list.items.last?.identity, currentIdentity, "当前曲目应挪到末尾")
        XCTAssertEqual(list.queue.current, list.index(of: currentIdentity), "播放不中断，current 跟到新下标")

        guard let newCurIdx = list.queue.current,
              let currentPositionAfter = list.queue.currentOrder.firstIndex(of: newCurIdx) else {
            return XCTFail("应有当前曲目")
        }
        XCTAssertEqual(currentPositionAfter, currentPositionBefore, "它在顺序表里的位置不变")

        // W 应该在本轮剩余部分里（不会立即打断播放）
        XCTAssertTrue(list.queue.currentOrder.contains(list.items.firstIndex(where: { $0.identity == w.identity })!))
    }
}

final class SelectionOrderTests: XCTestCase {

    // MARK: - T-008 #23

    func testByListOrderIgnoresSelectionOrderAndFollowsListOrder() {
        let list = [
            Track(url: URL(fileURLWithPath: "/Music/B05.mp3")),
            Track(url: URL(fileURLWithPath: "/Music/C08.mp3")),
            Track(url: URL(fileURLWithPath: "/Music/B06.mp3"))
        ]
        // 先选 C08 再选 B05：点选顺序与结果无关
        let selection: Set<URL> = [list[1].id, list[0].id]

        let ordered = SelectionOrder.byListOrder(selection, in: list)

        XCTAssertEqual(ordered.map(\.title), ["B05", "C08"])
    }
}
