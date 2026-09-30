import XCTest
@testable import MusicCore

// SonglistService 是 @MainActor；这个类里既有测 SonglistStore（普通 actor）的用例，
// 也有测 SonglistService 的用例（#2），后者需要在同一个 actor 上下文里构造/调用它，
// 否则连 `SonglistService(root:)` 这个非 async 的初始化器都会被判成跨 actor、
// 要求加 await（F-11）。整个类标 @MainActor 之后，测 Store 的用例里那些
// `await store.xxx()` 仍然需要 await（Store 是另一个 actor，跨 actor调用）。
@MainActor
final class SonglistAddRemoveTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SonglistAddRemoveTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func songlistsDir() -> URL {
        root.appendingPathComponent("songlists", isDirectory: true)
    }

    private func track(_ name: String, path: String? = nil) -> Track {
        Track(url: URL(fileURLWithPath: path ?? "/Music/\(name).mp3"))
    }

    // MARK: - #1 空歌单依次加入

    func testAddToEmptySonglistAppendsInOrder() async throws {
        let store = SonglistStore(root: root)
        _ = await store.loadAll()
        let createOutcome = await store.commit(CreateSonglistOperation(name: "空歌单"))
        guard case .success(let created?) = createOutcome.result else {
            return XCTFail("准备数据失败")
        }

        let tracks = ["A02", "B05", "C07"].map { track($0) }
        let addOutcome = await store.commit(AddTracksOperation(id: created.id, tracks: tracks, knownName: created.name))
        guard case .success(let updated?) = addOutcome.result else {
            return XCTFail("加歌失败：\(addOutcome.result)")
        }

        XCTAssertEqual(updated.entries.map(\.title), ["A02", "B05", "C07"])
        let beforeCount = addOutcome.before?.entries.count ?? 0
        XCTAssertEqual(updated.entries.count - beforeCount, 3)
    }

    // MARK: - #2（Service 层）已有 A02、A03，再加 [A02, A03, A04]

    func testServiceAddReportsAddedAndSkippedCounts() async throws {
        let service = SonglistService(root: root)
        await service.loadAll()
        guard case .success(let created) = await service.create(name: "歌单") else {
            return XCTFail("准备数据失败")
        }
        guard case .success = await service.add(["A02", "A03"].map { track($0) }, to: created.id) else {
            return XCTFail("准备数据失败")
        }

        let result = await service.add(["A02", "A03", "A04"].map { track($0) }, to: created.id)
        guard case .success(let addResult) = result else {
            return XCTFail("加歌失败：\(result)")
        }

        XCTAssertEqual(addResult.added, 1)
        XCTAssertEqual(addResult.skipped, 2)
        XCTAssertEqual(service.entries(of: created.id)?.last?.title, "A04")
    }

    // MARK: - #3 全部已存在：不写盘

    func testAddAllExistingDoesNotWriteToDisk() async throws {
        let store = SonglistStore(root: root)
        _ = await store.loadAll()
        let createOutcome = await store.commit(CreateSonglistOperation(name: "歌单"))
        guard case .success(let created?) = createOutcome.result else {
            return XCTFail("准备数据失败")
        }
        _ = await store.commit(AddTracksOperation(id: created.id, tracks: [track("A02")], knownName: created.name))

        let fileURL = songlistsDir().appendingPathComponent("\(created.id.uuidString.lowercased()).json")
        let modifiedBefore = try FileManager.default.attributesOfItem(atPath: fileURL.path)[.modificationDate] as? Date

        let addOutcome = await store.commit(AddTracksOperation(id: created.id, tracks: [track("A02")], knownName: created.name))
        guard case .success(let updated?) = addOutcome.result else {
            return XCTFail("加歌失败：\(addOutcome.result)")
        }

        XCTAssertEqual(updated.entries.count, 1, "added == 0，内容不变")
        let modifiedAfter = try FileManager.default.attributesOfItem(atPath: fileURL.path)[.modificationDate] as? Date
        XCTAssertEqual(modifiedBefore, modifiedAfter, "全部已存在时不应写盘")
    }

    // MARK: - #4 输入里同一首出现两次（路径只差大小写）

    func testAddDedupesInputByIdentityIgnoringCase() async throws {
        let store = SonglistStore(root: root)
        _ = await store.loadAll()
        let createOutcome = await store.commit(CreateSonglistOperation(name: "歌单"))
        guard case .success(let created?) = createOutcome.result else {
            return XCTFail("准备数据失败")
        }

        let tracks = [track("A", path: "/Music/A02.mp3"), track("a", path: "/Music/a02.MP3")]
        let addOutcome = await store.commit(AddTracksOperation(id: created.id, tracks: tracks, knownName: created.name))
        guard case .success(let updated?) = addOutcome.result else {
            return XCTFail("加歌失败：\(addOutcome.result)")
        }

        XCTAssertEqual(updated.entries.count, 1, "只应加一次")
    }

    // MARK: - #5 非法名称调用 create(name:with:)

    func testCreateWithTracksInvalidNameWritesNothing() async throws {
        let store = SonglistStore(root: root)
        _ = await store.loadAll()

        let outcome = await store.commit(CreateWithTracksOperation(name: "   ", tracks: [track("A02")]))
        guard case .failure(.nameEmpty) = outcome.result else {
            return XCTFail("期望 nameEmpty，实际 \(outcome.result)")
        }

        let names = (try? FileManager.default.contentsOfDirectory(atPath: songlistsDir().path)) ?? []
        XCTAssertTrue(names.isEmpty, "名称不合法时不应写任何文件")
    }

    // MARK: - #6 目录只读时 add

    func testAddWhenDirectoryReadOnlyReturnsSaveFailed() async throws {
        let store = SonglistStore(root: root)
        _ = await store.loadAll()
        let createOutcome = await store.commit(CreateSonglistOperation(name: "歌单"))
        guard case .success(let created?) = createOutcome.result else {
            return XCTFail("准备数据失败")
        }

        chmod(songlistsDir().path, 0o500)
        defer { chmod(songlistsDir().path, 0o700) }

        let addOutcome = await store.commit(AddTracksOperation(id: created.id, tracks: [track("A02")], knownName: created.name))
        guard case .failure(.saveFailed(let reason)) = addOutcome.result else {
            return XCTFail("期望 saveFailed，实际 \(addOutcome.result)")
        }
        XCTAssertEqual(reason, "数据文件夹没有写入权限")

        chmod(songlistsDir().path, 0o700)
        let reloaded = await SonglistStore(root: root).loadAll()
        XCTAssertEqual(reloaded.songlists[created.id]?.entries.count, 0, "只读期间内存/磁盘都不应变化")
    }

    // MARK: - #7 两个 Store 实例分别加歌

    func testTwoStoreInstancesEachAddDifferentTrack() async throws {
        let storeA = SonglistStore(root: root)
        let storeB = SonglistStore(root: root)
        _ = await storeA.loadAll()
        _ = await storeB.loadAll()

        let createOutcome = await storeA.commit(CreateSonglistOperation(name: "共享歌单"))
        guard case .success(let created?) = createOutcome.result else {
            return XCTFail("准备数据失败")
        }
        _ = await storeB.loadAll()

        _ = await storeA.commit(AddTracksOperation(id: created.id, tracks: [track("C08")], knownName: created.name))
        _ = await storeB.commit(AddTracksOperation(id: created.id, tracks: [track("Q01")], knownName: created.name))

        let reloaded = await SonglistStore(root: root).loadAll()
        let titles = Set(reloaded.songlists[created.id]?.entries.map(\.title) ?? [])
        XCTAssertEqual(titles, ["C08", "Q01"], "两边加的都应该在")
    }

    // MARK: - #8 remove 一首已被另一个实例删掉的歌单

    func testRemoveTrackAlreadyRemovedByAnotherInstanceReturnsZeroWithoutWriting() async throws {
        let storeA = SonglistStore(root: root)
        let storeB = SonglistStore(root: root)
        _ = await storeA.loadAll()
        _ = await storeB.loadAll()

        let createOutcome = await storeA.commit(CreateSonglistOperation(name: "歌单"))
        guard case .success(let created?) = createOutcome.result else {
            return XCTFail("准备数据失败")
        }
        _ = await storeA.commit(AddTracksOperation(id: created.id, tracks: [track("B05")], knownName: created.name))
        _ = await storeB.loadAll() // B 同步到"歌单里有 B05"的状态

        let identityB05 = TrackIdentity(path: "/Music/B05.mp3")
        // A 先把 B05 从歌单里移除
        _ = await storeA.commit(RemoveTracksOperation(id: created.id, identities: [identityB05], knownName: created.name))

        let fileURL = songlistsDir().appendingPathComponent("\(created.id.uuidString.lowercased()).json")
        let modifiedBefore = try FileManager.default.attributesOfItem(atPath: fileURL.path)[.modificationDate] as? Date

        // B 现在也尝试移除 B05——歌单本身还在，只是这首已经不在里面了
        let removeOutcome = await storeB.commit(RemoveTracksOperation(id: created.id, identities: [identityB05], knownName: created.name))
        guard case .success(let updated?) = removeOutcome.result else {
            return XCTFail("期望成功（已经不存在的忽略，不报错），实际 \(removeOutcome.result)")
        }

        let beforeCount = removeOutcome.before?.entries.count ?? 0
        XCTAssertEqual(beforeCount - updated.entries.count, 0, "B05 已经不在了，这次应该返回 0")

        let modifiedAfter = try FileManager.default.attributesOfItem(atPath: fileURL.path)[.modificationDate] as? Date
        XCTAssertEqual(modifiedBefore, modifiedAfter, "没有实际变化时不应写盘")
    }

    // MARK: - #9 5000 首歌单再加 1 首的性能

    func testAddOneTrackToFiveThousandTrackSonglistPerformance() async throws {
        let store = SonglistStore(root: root)
        _ = await store.loadAll()

        let entries = (0..<5000).map { track("Seed\($0)", path: "/Music/seed-\($0).mp3") }
        struct SeedOperation: SonglistOperation {
            let songlist: Songlist
            var targetID: UUID? { songlist.id }
            func apply(to fresh: [UUID: Songlist], now: Date) throws -> Songlist? { songlist }
        }
        let seed = Songlist(
            id: UUID(), name: "大歌单", createdAt: Date(),
            entries: entries.map { SonglistEntry(path: $0.url.path, title: $0.title) }
        )
        let seedOutcome = await store.commit(SeedOperation(songlist: seed))
        guard case .success(let seeded?) = seedOutcome.result else {
            return XCTFail("准备大歌单失败")
        }

        // 预热
        _ = await store.commit(AddTracksOperation(id: seeded.id, tracks: [track("Warm", path: "/Music/warm.mp3")], knownName: seeded.name))

        var durations: [TimeInterval] = []
        for i in 0..<5 {
            let start = Date()
            _ = await store.commit(
                AddTracksOperation(id: seeded.id, tracks: [track("New\(i)", path: "/Music/new-\(i).mp3")], knownName: seeded.name)
            )
            durations.append(Date().timeIntervalSince(start))
        }

        let sorted = durations.sorted()
        let median = sorted[sorted.count / 2]
        XCTAssertLessThanOrEqual(median, 0.2, "5 次耗时：\(durations)")
    }

    // MARK: - #10 RefreshCacheOperation 只更新命中条目的缓存字段

    func testRefreshCacheOperationOnlyUpdatesMatchingEntries() async throws {
        let store = SonglistStore(root: root)
        _ = await store.loadAll()
        let createOutcome = await store.commit(CreateSonglistOperation(name: "歌单"))
        guard case .success(let created?) = createOutcome.result else {
            return XCTFail("准备数据失败")
        }
        let tracks = ["A02", "B05", "C07"].map { track($0) }
        _ = await store.commit(AddTracksOperation(id: created.id, tracks: tracks, knownName: created.name))

        let identityA = TrackIdentity(path: "/Music/A02.mp3")
        let identityC = TrackIdentity(path: "/Music/C07.mp3")
        let updates: [TrackIdentity: SonglistEntry] = [
            identityA: SonglistEntry(path: "/Music/A02.mp3", title: "A02 新标题", artist: "新歌手", duration: 200),
            identityC: SonglistEntry(path: "/Music/C07.mp3", title: "C07 新标题", duration: 300)
        ]
        let refreshOutcome = await store.commit(RefreshCacheOperation(id: created.id, updates: updates))
        guard case .success(let updated?) = refreshOutcome.result else {
            return XCTFail("刷新失败：\(refreshOutcome.result)")
        }

        XCTAssertEqual(updated.entries.map(\.title), ["A02 新标题", "B05", "C07 新标题"], "曲目顺序不变，只有命中的两条标题变了")
        XCTAssertEqual(updated.entries[0].artist, "新歌手")
        XCTAssertEqual(updated.entries[0].duration, 200)
        XCTAssertEqual(updated.entries[1].title, "B05", "没命中的条目不变")
    }
}
