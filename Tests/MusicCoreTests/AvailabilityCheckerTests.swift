import XCTest
import Combine
@testable import MusicCore

/// `FileProbe` 假实现：模拟「存在」「不存在」「卷卡住」三种情况，不用真的碰文件系统。
/// 状态用 `NSLock` 保护——`volumeReachable` 会在 `AvailabilityChecker` 的专用探测
/// 队列上被调用，和测试主线程不是同一个线程。
final class FakeFileProbe: FileProbe, @unchecked Sendable {
    private let lock = NSLock()
    private var existingPaths: Set<String>
    private var reachableVolumes: Set<String>
    private var stuckVolumes: Set<String>

    init(existingPaths: Set<String> = [], reachableVolumes: Set<String> = [], stuckVolumes: Set<String> = []) {
        self.existingPaths = existingPaths
        self.reachableVolumes = reachableVolumes
        self.stuckVolumes = stuckVolumes
    }

    func fileExists(_ path: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return existingPaths.contains(path)
    }

    func volumeReachable(_ root: String) -> Bool {
        let stuck: Bool = {
            lock.lock(); defer { lock.unlock() }
            return stuckVolumes.contains(root)
        }()
        if stuck {
            // 模拟「探测卡住」：真睡到比 AvailabilityChecker 的 3 秒超时更久，
            // 让超时竞速的一方先赢；这次调用本身留在后台自己结束。
            Thread.sleep(forTimeInterval: 5)
        }
        lock.lock(); defer { lock.unlock() }
        return reachableVolumes.contains(root)
    }

    func setVolumeReachable(_ root: String, _ value: Bool) {
        lock.lock(); defer { lock.unlock() }
        if value { reachableVolumes.insert(root) } else { reachableVolumes.remove(root) }
    }
}

@MainActor
final class AvailabilityStoreTests: XCTestCase {
    private func track(_ name: String, path: String? = nil) -> Track {
        Track(url: URL(fileURLWithPath: path ?? "/Music/\(name).mp3"))
    }

    func testIsAvailableDefaultsToTrueForUnknownIdentity() {
        let store = AvailabilityStore()
        XCTAssertTrue(store.isAvailable(track("A").identity), "默认全部按可用显示（FR-021 ⑥）")
    }

    func testApplyMarksUnavailable() {
        let store = AvailabilityStore()
        let id = track("A").identity
        store.apply(available: [], unavailable: [id])
        XCTAssertFalse(store.isAvailable(id))
    }

    // #9：刷新曲库，某首原来不可用、现在扫描到了 → 变为可用
    func testApplyRestoresAvailabilityWhenRescanned() {
        let store = AvailabilityStore()
        let id = track("A").identity
        store.apply(available: [], unavailable: [id])
        XCTAssertFalse(store.isAvailable(id))

        store.apply(available: [id], unavailable: [])
        XCTAssertTrue(store.isAvailable(id), "重新扫描到之后应该恢复为可用")
    }
}

@MainActor
final class AvailabilityCheckerTests: XCTestCase {
    private func track(_ path: String) -> Track {
        Track(url: URL(fileURLWithPath: path))
    }

    // #6：checkNow 检查一首不存在的
    func testCheckNowReturnsFalseForMissingFileAndMarksUnavailable() async {
        let store = AvailabilityStore()
        let checker = AvailabilityChecker(store: store, probe: FakeFileProbe())
        let missing = track("/Music/Missing.mp3")

        let result = await checker.checkNow(missing)

        XCTAssertFalse(result)
        XCTAssertFalse(store.isAvailable(missing.identity))
    }

    func testCheckNowReturnsTrueForExistingFile() async {
        let store = AvailabilityStore()
        let probe = FakeFileProbe(existingPaths: ["/Music/A.mp3"])
        let checker = AvailabilityChecker(store: store, probe: probe)
        let existing = track("/Music/A.mp3")

        let result = await checker.checkNow(existing)

        XCTAssertTrue(result)
        XCTAssertTrue(store.isAvailable(existing.identity))
    }

    // #4：某个卷卡住，卷上 500 首；这期间 enqueue 不阻塞，约 3 秒后全部判为不可用
    func testStuckVolumeMarksAllItsTracksUnavailableWithinAFewSeconds() async throws {
        let store = AvailabilityStore()
        let probe = FakeFileProbe(stuckVolumes: ["/Volumes/StuckVol"])
        let checker = AvailabilityChecker(store: store, probe: probe)
        let tracks = (0..<500).map { track("/Volumes/StuckVol/T\($0).mp3") }

        let enqueueStart = Date()
        await checker.enqueue(tracks, priority: .high)
        let enqueueElapsed = Date().timeIntervalSince(enqueueStart)
        XCTAssertLessThan(enqueueElapsed, 0.5, "enqueue 应该立即返回，不等检查结果")

        try await Task.sleep(nanoseconds: 4_000_000_000)

        for t in tracks {
            XCTAssertFalse(store.isAvailable(t.identity), "\(t.url.path) 所在卷卡住，应该判为不可用")
        }
    }

    // F-14：一个卷卡住不该拖累本机文件——各卷根一条独立队列，互不阻塞。
    func testStuckVolumeDoesNotBlockLocalFileCheck() async throws {
        let store = AvailabilityStore()
        let probe = FakeFileProbe(existingPaths: ["/Music/A.mp3"], stuckVolumes: ["/Volumes/Stuck"])
        let checker = AvailabilityChecker(store: store, probe: probe)

        // 先让「卷卡住」的探测占住它自己的那条队列。
        Task { _ = await checker.checkNow(track("/Volumes/Stuck/X.mp3")) }
        try await Task.sleep(nanoseconds: 200_000_000)

        let localTrack = track("/Music/A.mp3")
        let start = Date()
        let result = await checker.checkNow(localTrack)
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertTrue(result, "本机文件存在，不应该被卡住的卷拖累判成不可用")
        XCTAssertLessThan(elapsed, 1, "本机文件的检查不该排在卡住的卷后面等")
    }

    // #5：10 秒后卷恢复，再检查 → 恢复为可用
    func testVolumeRecoversAfterCacheExpires() async throws {
        let store = AvailabilityStore()
        // F-15：卷恢复之后，文件本身也得在 existingPaths 里，不然就算卷可达判断
        // 完全正确，fileExists 这一步还是会返回 false，白测了卷缓存那部分。
        let probe = FakeFileProbe(existingPaths: ["/Volumes/Flaky/A.mp3"])
        let checker = AvailabilityChecker(store: store, probe: probe)
        let t = track("/Volumes/Flaky/A.mp3")

        let firstResult = await checker.checkNow(t)
        XCTAssertFalse(firstResult, "卷第一次探测就不可达")

        probe.setVolumeReachable("/Volumes/Flaky", true)
        let stillCached = await checker.checkNow(t)
        XCTAssertFalse(stillCached, "10 秒缓存没过期，不应该重新探测")

        try await Task.sleep(nanoseconds: 10_500_000_000)

        let afterExpiry = await checker.checkNow(t)
        XCTAssertTrue(afterExpiry, "缓存过期后重新探测，卷已恢复应该判为可用")
    }

    // #8：5000 首在 1 秒内全部检查完，`AvailabilityStore.apply` 调用次数不超过 11 次
    // （100 ms 合并一次）。用 `$unavailable` 的发布次数作代理，不改动 AvailabilityStore
    // 的公开接口。
    func testFiveThousandTracksBatchPublishCountBounded() async throws {
        let paths = (0..<5000).map { "/Music/T\($0).mp3" }
        let probe = FakeFileProbe(existingPaths: [])
        let store = AvailabilityStore()
        let checker = AvailabilityChecker(store: store, probe: probe)
        let tracks = paths.map { Track(url: URL(fileURLWithPath: $0)) }

        var publishCount = 0
        let cancellable = store.$unavailable.sink { _ in publishCount += 1 }

        await checker.enqueue(tracks, priority: .low)
        try await Task.sleep(nanoseconds: 1_500_000_000)

        cancellable.cancel()

        for t in tracks {
            XCTAssertFalse(store.isAvailable(t.identity))
        }
        // sink 订阅时会先同步收到一次当前值，扣掉这一次再比较。
        XCTAssertLessThanOrEqual(publishCount - 1, 11, "100 ms 合并批量写入，不应该逐首触发发布")
    }

    func testDemoteHighMovesUncheckedItemsToLowWithoutLosingThem() async throws {
        let store = AvailabilityStore()
        let probe = FakeFileProbe(existingPaths: ["/Music/A.mp3", "/Music/B.mp3"])
        let checker = AvailabilityChecker(store: store, probe: probe)
        let tracks = [track("/Music/A.mp3"), track("/Music/B.mp3")]

        await checker.enqueue(tracks, priority: .high)
        await checker.demoteHigh()

        try await Task.sleep(nanoseconds: 300_000_000)

        for t in tracks {
            XCTAssertTrue(store.isAvailable(t.identity), "降级为 low 之后应该照样被检查到，不会丢")
        }
    }
}
