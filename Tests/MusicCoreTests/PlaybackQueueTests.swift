import XCTest
@testable import MusicCore

final class PlaybackQueueTests: XCTestCase {

    // MARK: - 空队列

    func testEmptyQueueReturnsNil() {
        var q = PlaybackQueue(count: 0, mode: .repeatAll)
        XCTAssertNil(q.next(auto: false))
        XCTAssertNil(q.previous())
        XCTAssertNil(q.current)
    }

    // MARK: - 顺序播放

    func testSequentialAdvancesThenStopsAtEnd() {
        var q = PlaybackQueue(count: 3, mode: .sequential)
        q.select(0)

        XCTAssertEqual(q.next(auto: true), 1)
        XCTAssertEqual(q.next(auto: true), 2)
        // 末尾返回 nil，表示应停止播放
        XCTAssertNil(q.next(auto: true))
    }

    func testSequentialPreviousStopsAtFirst() {
        var q = PlaybackQueue(count: 3, mode: .sequential)
        q.select(0)
        XCTAssertEqual(q.previous(), 0)
    }

    func testFirstNextWithoutSelectionStartsAtZero() {
        var q = PlaybackQueue(count: 3, mode: .sequential)
        XCTAssertEqual(q.next(auto: false), 0)
    }

    // MARK: - 列表循环

    func testRepeatAllWrapsForward() {
        var q = PlaybackQueue(count: 3, mode: .repeatAll)
        q.select(2)
        XCTAssertEqual(q.next(auto: true), 0)
    }

    func testRepeatAllWrapsBackward() {
        var q = PlaybackQueue(count: 3, mode: .repeatAll)
        q.select(0)
        XCTAssertEqual(q.previous(), 2)
    }

    // MARK: - 单曲循环

    func testRepeatOneRepeatsOnAutoAdvance() {
        var q = PlaybackQueue(count: 3, mode: .repeatOne)
        q.select(1)
        XCTAssertEqual(q.next(auto: true), 1)
        XCTAssertEqual(q.next(auto: true), 1)
    }

    func testRepeatOneStillAdvancesOnManualNext() {
        var q = PlaybackQueue(count: 3, mode: .repeatOne)
        q.select(1)
        XCTAssertEqual(q.next(auto: false), 2)
    }

    func testRepeatOneManualNextWrapsAtEnd() {
        var q = PlaybackQueue(count: 3, mode: .repeatOne)
        q.select(2)
        XCTAssertEqual(q.next(auto: false), 0)
    }

    // MARK: - 随机播放

    func testShuffleCoversEveryTrackExactlyOncePerRound() {
        var q = PlaybackQueue(count: 6, mode: .shuffle)

        var visited: [Int] = []
        for _ in 0..<6 {
            guard let n = q.next(auto: false) else { break }
            visited.append(n)
        }

        XCTAssertEqual(visited.count, 6)
        XCTAssertEqual(Set(visited).count, 6, "一轮随机内不应重复")
        XCTAssertEqual(Set(visited), Set(0..<6))
    }

    func testShuffleKeepsCurrentTrackWhenModeChanges() {
        var q = PlaybackQueue(count: 10, mode: .sequential)
        q.select(7)

        q.mode = .shuffle

        // 切模式不该打断正在播放的歌
        XCTAssertEqual(q.current, 7)
        XCTAssertEqual(q.currentOrder.first, 7)
    }

    func testShufflePreviousRetracesPlayedOrder() {
        var q = PlaybackQueue(count: 5, mode: .shuffle)

        let a = q.next(auto: false)
        let b = q.next(auto: false)
        XCTAssertNotNil(a)
        XCTAssertNotNil(b)

        XCTAssertEqual(q.previous(), a, "上一首应沿实际播放顺序回退")
    }

    func testShuffleReshufflesAfterFullRound() {
        var q = PlaybackQueue(count: 4, mode: .shuffle)
        for _ in 0..<4 { _ = q.next(auto: false) }

        // 越过一轮边界后仍应给出合法索引，而不是 nil
        let wrapped = q.next(auto: false)
        XCTAssertNotNil(wrapped)
        XCTAssertTrue((0..<4).contains(wrapped!))
    }

    // MARK: - 列表变更

    func testSetCountClearsOutOfRangeCurrent() {
        var q = PlaybackQueue(count: 5, mode: .repeatAll)
        q.select(4)

        q.setCount(2)

        XCTAssertNil(q.current)
        XCTAssertEqual(q.count, 2)
        XCTAssertEqual(q.next(auto: false), 0)
    }

    func testSetCountKeepsInRangeCurrent() {
        var q = PlaybackQueue(count: 5, mode: .repeatAll)
        q.select(1)

        q.setCount(3)

        XCTAssertEqual(q.current, 1)
        XCTAssertEqual(q.next(auto: false), 2)
    }

    func testSelectOutOfRangeIsIgnored() {
        var q = PlaybackQueue(count: 3, mode: .sequential)
        q.select(99)
        XCTAssertNil(q.current)
    }

    // MARK: - peekNext（无缝播放的预加载依据）

    func testPeekDoesNotMutateState() {
        var q = PlaybackQueue(count: 5, mode: .repeatAll)
        q.select(2)

        _ = q.peekNext(auto: true)
        _ = q.peekNext(auto: true)
        _ = q.peekNext(auto: true)

        XCTAssertEqual(q.current, 2, "预看不能推进队列")
        XCTAssertEqual(q.next(auto: true), 3, "多次预看之后，真正推进仍应是 3")
    }

    func testPeekAgreesWithNextSequential() {
        var q = PlaybackQueue(count: 4, mode: .sequential)
        q.select(0)

        for _ in 0..<3 {
            let peeked = q.peekNext(auto: true)
            XCTAssertEqual(peeked, q.next(auto: true))
        }
        // 末尾两者都应给出 nil
        XCTAssertNil(q.peekNext(auto: true))
        XCTAssertNil(q.next(auto: true))
    }

    func testPeekAgreesWithNextRepeatAll() {
        var q = PlaybackQueue(count: 3, mode: .repeatAll)
        q.select(2)
        XCTAssertEqual(q.peekNext(auto: true), 0)
        XCTAssertEqual(q.next(auto: true), 0)
    }

    func testPeekRepeatsCurrentInRepeatOne() {
        var q = PlaybackQueue(count: 3, mode: .repeatOne)
        q.select(1)
        XCTAssertEqual(q.peekNext(auto: true), 1, "单曲循环预看到的就是自己，用于无缝循环")
        XCTAssertEqual(q.peekNext(auto: false), 2, "手动下一首仍然前进")
    }

    func testPeekReturnsNilAtShuffleRoundBoundary() {
        var q = PlaybackQueue(count: 3, mode: .shuffle)
        for _ in 0..<3 { _ = q.next(auto: false) }

        XCTAssertNil(q.peekNext(auto: true),
                     "下一轮的随机顺序尚未生成，预看应放弃而不是猜")
        XCTAssertNotNil(q.next(auto: true), "真正推进时会重新洗牌，仍要给出结果")
    }

    func testPeekWithoutSelectionReturnsFirst() {
        let q = PlaybackQueue(count: 3, mode: .sequential)
        XCTAssertEqual(q.peekNext(auto: true), 0)
    }

    func testPeekOnEmptyQueue() {
        let q = PlaybackQueue(count: 0, mode: .repeatAll)
        XCTAssertNil(q.peekNext(auto: true))
    }

    // MARK: - clearSelection

    func testClearSelectionResetsToListHead() {
        var q = PlaybackQueue(count: 5, mode: .repeatAll)
        q.select(3)

        q.clearSelection()

        XCTAssertNil(q.current)
        XCTAssertEqual(q.next(auto: false), 0, "清除后应从头开始")
    }

    // MARK: - park（当前曲目从列表消失）

    func testParkResumesFromSamePosition() {
        // 100 首里正在播第 80 首（下标 79），它被删了，还剩 99 首
        var q = PlaybackQueue(count: 100, mode: .sequential)
        q.select(79)

        q.setCount(99)
        q.park(at: 79)

        XCTAssertNil(q.current, "没有选中项")
        XCTAssertEqual(q.peekNext(auto: true), 79, "应从原来的序号继续，而不是跳回开头")
        XCTAssertEqual(q.next(auto: true), 79)
    }

    func testParkBeyondNewEndStopsInSequentialMode() {
        // 100 首里正在播第 80 首，删到只剩 50 首 —— 原位置已经超出列表末尾
        var q = PlaybackQueue(count: 100, mode: .sequential)
        q.select(79)

        q.setCount(50)
        q.park(at: 79)

        XCTAssertNil(q.peekNext(auto: true), "顺序播放：等同于播到了结尾，应停止")
        XCTAssertNil(q.next(auto: true))
    }

    func testParkBeyondNewEndWrapsInRepeatAll() {
        var q = PlaybackQueue(count: 100, mode: .repeatAll)
        q.select(79)

        q.setCount(50)
        q.park(at: 79)

        XCTAssertEqual(q.peekNext(auto: true), 0, "列表循环：等同播到结尾，回到第一首")
        XCTAssertEqual(q.next(auto: true), 0)
    }

    func testParkIsConsumedAfterUse() {
        var q = PlaybackQueue(count: 10, mode: .sequential)
        q.park(at: 4)

        XCTAssertEqual(q.next(auto: true), 4)
        XCTAssertEqual(q.next(auto: true), 5, "用过一次之后就回到正常推进")
    }

    func testSelectClearsPark() {
        var q = PlaybackQueue(count: 10, mode: .sequential)
        q.park(at: 7)

        q.select(2)

        XCTAssertEqual(q.current, 2)
        XCTAssertEqual(q.next(auto: true), 3, "点选之后停靠点应失效")
    }

    func testClearSelectionClearsPark() {
        var q = PlaybackQueue(count: 10, mode: .sequential)
        q.park(at: 7)

        q.clearSelection()

        XCTAssertEqual(q.next(auto: true), 0)
    }

    func testParkOnEmptyQueue() {
        var q = PlaybackQueue(count: 0, mode: .repeatAll)
        q.park(at: 3)

        XCTAssertNil(q.peekNext(auto: true))
        XCTAssertNil(q.next(auto: true))
    }

    func testParkAtNegativeIndexIsTreatedAsHead() {
        var q = PlaybackQueue(count: 5, mode: .sequential)
        q.park(at: -3)

        XCTAssertEqual(q.next(auto: true), 0)
    }

    // MARK: - 模式切换

    func testChangingModeToSameValueDoesNotResetPosition() {
        var q = PlaybackQueue(count: 5, mode: .repeatAll)
        q.select(3)
        q.mode = .repeatAll
        XCTAssertEqual(q.next(auto: false), 4)
    }

    // MARK: - realign（T-001：跟随状态下重新对齐当前曲目）

    func testRealignActsLikeSelect() {
        var q = PlaybackQueue(count: 5, mode: .sequential)
        q.realign(2)
        XCTAssertEqual(q.current, 2)
        XCTAssertEqual(q.next(auto: true), 3)
    }

    func testRealignOutOfRangeIsIgnored() {
        var q = PlaybackQueue(count: 3, mode: .sequential)
        q.realign(99)
        XCTAssertNil(q.current)
    }

    func testRealignClearsExistingPark() {
        var q = PlaybackQueue(count: 10, mode: .sequential)
        q.park(at: 7)

        q.realign(2)

        XCTAssertEqual(q.current, 2)
        XCTAssertEqual(q.next(auto: true), 3, "重新对齐后旧的停靠点应失效")
    }
}
