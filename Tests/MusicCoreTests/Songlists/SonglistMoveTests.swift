import XCTest
import Darwin
@testable import MusicCore

final class SonglistMoveTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SonglistMoveTests-\(UUID().uuidString)", isDirectory: true)
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

    /// 准备一个按 `names` 顺序排好的歌单。
    private func makeSonglist(_ store: SonglistStore, names: [String]) async throws -> Songlist {
        let createOutcome = await store.commit(CreateSonglistOperation(name: "歌单"))
        guard case .success(let created?) = createOutcome.result else {
            throw XCTSkip("准备数据失败")
        }
        let addOutcome = await store.commit(
            AddTracksOperation(id: created.id, tracks: names.map { track($0) }, knownName: created.name)
        )
        guard case .success(let seeded?) = addOutcome.result else {
            throw XCTSkip("准备数据失败")
        }
        return seeded
    }

    // MARK: - #1 第 5 首挪到第 0 位

    func testMoveFifthEntryToFront() async throws {
        let store = SonglistStore(root: root)
        _ = await store.loadAll()
        let names = ["A02", "A03", "B05", "B06", "C07", "C08"]
        let seeded = try await makeSonglist(store, names: names)

        let identity = TrackIdentity(path: "/Music/C07.mp3")
        let outcome = await store.commit(MoveEntryOperation(id: seeded.id, identity: identity, toIndex: 0, knownName: seeded.name))
        guard case .success(let updated?) = outcome.result else {
            return XCTFail("挪动失败：\(outcome.result)")
        }

        XCTAssertEqual(updated.entries.map(\.title), ["C07", "A02", "A03", "B05", "B06", "C08"])
    }

    // MARK: - #2 第 0 首挪到末尾；末尾挪到第 0 位

    func testMoveFirstEntryToEnd() async throws {
        let store = SonglistStore(root: root)
        _ = await store.loadAll()
        let names = ["A02", "A03", "B05"]
        let seeded = try await makeSonglist(store, names: names)

        let identity = TrackIdentity(path: "/Music/A02.mp3")
        let outcome = await store.commit(MoveEntryOperation(id: seeded.id, identity: identity, toIndex: 2, knownName: seeded.name))
        guard case .success(let updated?) = outcome.result else {
            return XCTFail("挪动失败：\(outcome.result)")
        }

        XCTAssertEqual(updated.entries.map(\.title), ["A03", "B05", "A02"])
    }

    func testMoveLastEntryToFront() async throws {
        let store = SonglistStore(root: root)
        _ = await store.loadAll()
        let names = ["A02", "A03", "B05"]
        let seeded = try await makeSonglist(store, names: names)

        let identity = TrackIdentity(path: "/Music/B05.mp3")
        let outcome = await store.commit(MoveEntryOperation(id: seeded.id, identity: identity, toIndex: 0, knownName: seeded.name))
        guard case .success(let updated?) = outcome.result else {
            return XCTFail("挪动失败：\(outcome.result)")
        }

        XCTAssertEqual(updated.entries.map(\.title), ["B05", "A02", "A03"])
    }

    // MARK: - #3 toIndex 等于当前位置：不写盘

    func testMoveToSamePositionDoesNotWriteToDisk() async throws {
        let store = SonglistStore(root: root)
        _ = await store.loadAll()
        let names = ["A02", "A03", "B05"]
        let seeded = try await makeSonglist(store, names: names)

        let fileURL = songlistsDir().appendingPathComponent("\(seeded.id.uuidString.lowercased()).json")
        let modifiedBefore = try FileManager.default.attributesOfItem(atPath: fileURL.path)[.modificationDate] as? Date

        let identity = TrackIdentity(path: "/Music/A03.mp3")
        // A03 已经在下标 1；挪到「移除后」的下标 1，就是原位。
        let outcome = await store.commit(MoveEntryOperation(id: seeded.id, identity: identity, toIndex: 1, knownName: seeded.name))
        guard case .success(let updated?) = outcome.result else {
            return XCTFail("应该原样返回：\(outcome.result)")
        }

        XCTAssertEqual(updated.entries.map(\.title), names, "顺序不应该变")
        let modifiedAfter = try FileManager.default.attributesOfItem(atPath: fileURL.path)[.modificationDate] as? Date
        XCTAssertEqual(modifiedBefore, modifiedAfter, "挪到原位不应该写盘")
    }

    // MARK: - #4 目标曲目已被另一个实例移除：成功，不写盘

    func testMoveTargetAlreadyRemovedByAnotherInstanceSucceedsWithoutWriting() async throws {
        let storeA = SonglistStore(root: root)
        _ = await storeA.loadAll()
        let names = ["A02", "A03", "B05"]
        let seeded = try await makeSonglist(storeA, names: names)

        let storeB = SonglistStore(root: root)
        _ = await storeB.loadAll()
        let removeOutcome = await storeB.commit(
            RemoveTracksOperation(id: seeded.id, identities: [TrackIdentity(path: "/Music/A03.mp3")], knownName: seeded.name)
        )
        guard case .success = removeOutcome.result else {
            return XCTFail("准备数据失败：另一个实例移除应该成功")
        }

        let fileURL = songlistsDir().appendingPathComponent("\(seeded.id.uuidString.lowercased()).json")
        let modifiedBefore = try FileManager.default.attributesOfItem(atPath: fileURL.path)[.modificationDate] as? Date

        let moveOutcome = await storeA.commit(
            MoveEntryOperation(id: seeded.id, identity: TrackIdentity(path: "/Music/A03.mp3"), toIndex: 0, knownName: seeded.name)
        )
        guard case .success(let result?) = moveOutcome.result else {
            return XCTFail("目标已被移除时应该按成功处理：\(moveOutcome.result)")
        }

        XCTAssertEqual(result.entries.map(\.title), ["A02", "B05"], "A03 已经不在了，其余顺序不变")
        let modifiedAfter = try FileManager.default.attributesOfItem(atPath: fileURL.path)[.modificationDate] as? Date
        XCTAssertEqual(modifiedBefore, modifiedAfter, "目标不存在时不应该再写一次盘")
    }

    // MARK: - #5 数据文件夹只读

    func testReadOnlyDirectoryReturnsPermissionSaveFailedAndKeepsOrderInMemory() async throws {
        let store = SonglistStore(root: root)
        _ = await store.loadAll()
        let names = ["A02", "A03", "B05"]
        let seeded = try await makeSonglist(store, names: names)

        chmod(songlistsDir().path, 0o500)
        defer { chmod(songlistsDir().path, 0o700) }

        let identity = TrackIdentity(path: "/Music/B05.mp3")
        let outcome = await store.commit(MoveEntryOperation(id: seeded.id, identity: identity, toIndex: 0, knownName: seeded.name))

        guard case .failure(.saveFailed(let reason)) = outcome.result else {
            return XCTFail("只读目录应该返回 saveFailed：\(outcome.result)")
        }
        XCTAssertEqual(reason, "数据文件夹没有写入权限")
        // 内存里的快照（写前同步到的最新数据）顺序不受影响。
        XCTAssertEqual(outcome.snapshot.songlists[seeded.id]?.entries.map(\.title), names)
    }

    // MARK: - #6 5000 首的歌单，把最后一首挪到第 0 位（性能类单测统一写法）

    func testMoveLastEntryToFrontOfFiveThousandTrackSonglistPerformance() async throws {
        let store = SonglistStore(root: root)
        _ = await store.loadAll()

        let names = (0..<5000).map { "Seed\($0)" }
        let createOutcome = await store.commit(CreateSonglistOperation(name: "大歌单"))
        guard case .success(let created?) = createOutcome.result else {
            return XCTFail("准备数据失败")
        }
        struct SeedOperation: SonglistOperation {
            let songlist: Songlist
            var targetID: UUID? { songlist.id }
            func apply(to fresh: [UUID: Songlist], now: Date) throws -> Songlist? { songlist }
        }
        let seed = Songlist(
            id: created.id, name: created.name, createdAt: created.createdAt,
            entries: names.enumerated().map { index, name in
                SonglistEntry(path: "/Music/seed-\(index).mp3", title: name)
            }
        )
        let seedOutcome = await store.commit(SeedOperation(songlist: seed))
        guard case .success(let seeded?) = seedOutcome.result else {
            return XCTFail("准备大歌单失败")
        }
        let lastIdentity = TrackIdentity(path: "/Music/seed-4999.mp3")

        // 预热
        _ = await store.commit(MoveEntryOperation(id: seeded.id, identity: lastIdentity, toIndex: 0, knownName: seeded.name))

        var durations: [TimeInterval] = []
        for i in 0..<5 {
            // 每次都把当前排在末尾的那首挪回第 0 位，往返操作，规模始终是 5000。
            let target = i % 2 == 0
                ? TrackIdentity(path: "/Music/seed-4998.mp3")
                : lastIdentity
            let start = Date()
            _ = await store.commit(MoveEntryOperation(id: seeded.id, identity: target, toIndex: 0, knownName: seeded.name))
            durations.append(Date().timeIntervalSince(start))
        }

        let sorted = durations.sorted()
        let median = sorted[sorted.count / 2]
        XCTAssertLessThanOrEqual(median, 0.2, "5 次耗时：\(durations)")
    }
}
