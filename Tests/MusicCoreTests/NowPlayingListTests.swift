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
}
