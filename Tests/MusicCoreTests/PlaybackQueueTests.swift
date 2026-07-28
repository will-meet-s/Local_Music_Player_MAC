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

    // MARK: - 模式切换

    func testChangingModeToSameValueDoesNotResetPosition() {
        var q = PlaybackQueue(count: 5, mode: .repeatAll)
        q.select(3)
        q.mode = .repeatAll
        XCTAssertEqual(q.next(auto: false), 4)
    }
}
