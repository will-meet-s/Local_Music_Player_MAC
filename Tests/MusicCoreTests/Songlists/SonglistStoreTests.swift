import XCTest
import Darwin
@testable import MusicCore

final class SonglistStoreTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SonglistStoreTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func songlistsDir() -> URL {
        root.appendingPathComponent("songlists", isDirectory: true)
    }

    // MARK: - #1 新建、改名、删除之后用新实例重新加载

    func testCreateRenameDeletePersistAcrossNewStoreInstance() async throws {
        let store1 = SonglistStore(root: root)
        _ = await store1.loadAll()

        let createOutcome = await store1.commit(CreateSonglistOperation(name: "通勤"))
        guard case .success(let created?) = createOutcome.result else {
            return XCTFail("新建失败：\(createOutcome.result)")
        }

        let renameOutcome = await store1.commit(RenameSonglistOperation(id: created.id, name: "上班路上", knownName: created.name))
        guard case .success = renameOutcome.result else {
            return XCTFail("改名失败：\(renameOutcome.result)")
        }

        let secondID = UUID()
        _ = await store1.commit(CreateSonglistOperation(id: secondID, name: "工作"))
        let deleteOutcome = await store1.commit(DeleteSonglistOperation(id: secondID, knownName: "工作"))
        guard case .success = deleteOutcome.result else {
            return XCTFail("删除失败：\(deleteOutcome.result)")
        }

        // 用全新实例重新加载，验证数据落盘且与内存一致
        let store2 = SonglistStore(root: root)
        let snapshot = await store2.loadAll()

        XCTAssertEqual(snapshot.songlists.count, 1)
        XCTAssertEqual(snapshot.songlists[created.id]?.name, "上班路上")
        XCTAssertNil(snapshot.songlists[secondID])
        XCTAssertTrue(snapshot.failures.isEmpty)
    }

    // MARK: - #3 特殊字符名称端到端：直接调 Store，不经输入框

    func testSpecialCharacterNamesRoundTrip() async throws {
        let store = SonglistStore(root: root)
        _ = await store.loadAll()

        // 临时目录是多个测试共享的，只关心这次操作有没有在 root 的上级新增条目，
        // 不假设上级目录本身是空的。
        let parentOfRoot = root.deletingLastPathComponent()
        let parentContentsBefore = Set((try? FileManager.default.contentsOfDirectory(atPath: parentOfRoot.path)) ?? [])

        let names = [
            "🎵通勤🚇", "周杰倫・𠮷野家", "../../x", "a/b", "a:b", ".", "..", "~",
            "<>\"|?*", "第一行\n第二行"
        ]

        for name in names {
            let outcome = await store.commit(CreateSonglistOperation(name: name))
            guard case .success(let created?) = outcome.result else {
                return XCTFail("创建失败：\(name) -> \(outcome.result)")
            }
            XCTAssertEqual(created.name, name.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        let reloaded = await SonglistStore(root: root).loadAll()
        XCTAssertEqual(reloaded.songlists.count, names.count)
        XCTAssertTrue(reloaded.failures.isEmpty)

        // songlists/ 里只有 UUID 命名的文件
        let fileNames = try FileManager.default.contentsOfDirectory(atPath: songlistsDir().path)
        for fileName in fileNames {
            XCTAssertNotNil(fileName.range(of: #"^[0-9a-f-]{36}\.json$"#, options: .regularExpression), fileName)
        }
        // root 的上级目录没有新增条目（写入全部落在 DataFolder 下面）
        let parentContentsAfter = Set((try? FileManager.default.contentsOfDirectory(atPath: parentOfRoot.path)) ?? [])
        XCTAssertEqual(parentContentsAfter.subtracting(parentContentsBefore), [])
    }

    // MARK: - #4 损坏文件进入 loadFailures，不影响其他歌单

    func testCorruptedFilesGoToLoadFailuresWithoutAffectingOthers() async throws {
        let store = SonglistStore(root: root)
        _ = await store.loadAll()
        let goodOutcome = await store.commit(CreateSonglistOperation(name: "好的歌单"))
        guard case .success(let good?) = goodOutcome.result else {
            return XCTFail("准备数据失败")
        }

        let fm = FileManager.default
        try fm.createDirectory(at: songlistsDir(), withIntermediateDirectories: true)

        try Data([0xFF, 0x00, 0x11, 0x22]).write(to: songlistsDir().appendingPathComponent("\(UUID().uuidString.lowercased()).json"))

        let truncatedID = UUID()
        let validData = try SonglistCoding.makeEncoder().encode(
            Songlist(id: truncatedID, name: "will be truncated", createdAt: Date())
        )
        let truncated = validData.prefix(validData.count / 2)
        try Data(truncated).write(to: songlistsDir().appendingPathComponent("\(truncatedID.uuidString.lowercased()).json"))

        try Data().write(to: songlistsDir().appendingPathComponent("\(UUID().uuidString.lowercased()).json"))

        let wrongVersionID = UUID()
        var wrongVersion = Songlist(id: wrongVersionID, name: "v2", createdAt: Date())
        wrongVersion.schemaVersion = 2
        try SonglistCoding.makeEncoder().encode(wrongVersion)
            .write(to: songlistsDir().appendingPathComponent("\(wrongVersionID.uuidString.lowercased()).json"))

        let mismatchedID = UUID()
        let mismatchedContent = Songlist(id: UUID(), name: "id 不一致", createdAt: Date())
        try SonglistCoding.makeEncoder().encode(mismatchedContent)
            .write(to: songlistsDir().appendingPathComponent("\(mismatchedID.uuidString.lowercased()).json"))

        let snapshot = await SonglistStore(root: root).loadAll()

        XCTAssertEqual(snapshot.songlists.count, 1)
        XCTAssertEqual(snapshot.songlists[good.id]?.name, "好的歌单")
        XCTAssertEqual(snapshot.failures.count, 5, "5 个坏文件都应进入 loadFailures")
    }

    // MARK: - #5 损坏文件之后再操作，损坏的文件不变

    func testOperationsAfterCorruptionLeaveCorruptedFilesUntouched() async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: songlistsDir(), withIntermediateDirectories: true)
        let badFile = songlistsDir().appendingPathComponent("\(UUID().uuidString.lowercased()).json")
        try Data([0x00, 0x01]).write(to: badFile)
        let originalAttrs = try fm.attributesOfItem(atPath: badFile.path)
        let originalModified = originalAttrs[.modificationDate] as? Date
        let originalSize = originalAttrs[.size] as? Int

        let store = SonglistStore(root: root)
        _ = await store.loadAll()

        _ = await store.commit(CreateSonglistOperation(name: "新歌单"))
        let existingOutcome = await store.loadAll()
        if let anID = existingOutcome.songlists.keys.first {
            _ = await store.commit(RenameSonglistOperation(id: anID, name: "改名了", knownName: "新歌单"))
        }

        let afterAttrs = try fm.attributesOfItem(atPath: badFile.path)
        XCTAssertEqual(afterAttrs[.modificationDate] as? Date, originalModified)
        XCTAssertEqual(afterAttrs[.size] as? Int, originalSize)
        XCTAssertTrue(fm.fileExists(atPath: badFile.path), "损坏文件应原样保留，不被删除")
    }

    // MARK: - #6 beforeRename 抛错：原文件不变，残留临时文件下次加载时被清理

    func testBeforeRenameFailureLeavesOriginalUnchangedAndCleansUpTempFile() async throws {
        let store = SonglistStore(root: root)
        _ = await store.loadAll()

        let createOutcome = await store.commit(CreateSonglistOperation(name: "原始名称"))
        guard case .success(let created?) = createOutcome.result else {
            return XCTFail("准备数据失败")
        }

        struct SimulatedCrash: Error {}
        await store.setBeforeRename { throw SimulatedCrash() }

        let renameOutcome = await store.commit(RenameSonglistOperation(id: created.id, name: "改坏了", knownName: created.name))
        guard case .failure(let error) = renameOutcome.result else {
            return XCTFail("期望失败")
        }
        if case .saveFailed = error {} else {
            XCTFail("期望 saveFailed，实际 \(error)")
        }

        await store.setBeforeRename(nil)

        // 原文件内容不变
        let reloaded = await SonglistStore(root: root).loadAll()
        XCTAssertEqual(reloaded.songlists[created.id]?.name, "原始名称")

        // 残留的 .tmp- 文件在下一次加锁加载时被清理
        let leftoverBeforeCleanup = try FileManager.default.contentsOfDirectory(atPath: songlistsDir().path)
            .filter { $0.contains(".tmp-") }
        XCTAssertTrue(leftoverBeforeCleanup.isEmpty, "writeAtomically 失败路径应自行清理临时文件")
    }

    // MARK: - #7 数据文件夹只读

    func testReadOnlyDirectoryReturnsPermissionSaveFailed() async throws {
        let store = SonglistStore(root: root)
        _ = await store.loadAll()

        let createOutcome = await store.commit(CreateSonglistOperation(name: "占位"))
        guard case .success(let placeholder?) = createOutcome.result else {
            return XCTFail("准备数据失败")
        }

        chmod(songlistsDir().path, 0o500)
        defer { chmod(songlistsDir().path, 0o700) }

        let createResult = await store.commit(CreateSonglistOperation(name: "只读期间新建"))
        assertPermissionSaveFailed(createResult.result)

        let renameResult = await store.commit(RenameSonglistOperation(id: placeholder.id, name: "只读期间改名", knownName: placeholder.name))
        assertPermissionSaveFailed(renameResult.result)

        let deleteResult = await store.commit(DeleteSonglistOperation(id: placeholder.id, knownName: placeholder.name))
        assertPermissionSaveFailed(deleteResult.result)

        chmod(songlistsDir().path, 0o700)
        let reloaded = await SonglistStore(root: root).loadAll()
        XCTAssertEqual(reloaded.songlists.count, 1)
        XCTAssertEqual(reloaded.songlists[placeholder.id]?.name, "占位", "只读期间内存和磁盘都不应变化")
    }

    private func assertPermissionSaveFailed(_ result: Result<Songlist?, SonglistError>, file: StaticString = #filePath, line: UInt = #line) {
        guard case .failure(.saveFailed(let reason)) = result else {
            return XCTFail("期望 saveFailed，实际 \(result)", file: file, line: line)
        }
        XCTAssertEqual(reason, "数据文件夹没有写入权限", file: file, line: line)
    }

    // MARK: - #8 两个 Store 实例模拟两个进程

    func testTwoStoreInstancesSimulatingTwoProcesses() async throws {
        let storeA = SonglistStore(root: root)
        let storeB = SonglistStore(root: root)
        _ = await storeA.loadAll()
        _ = await storeB.loadAll()

        let createOutcome = await storeA.commit(CreateSonglistOperation(name: "共享歌单"))
        guard case .success(let shared?) = createOutcome.result else {
            return XCTFail("准备数据失败")
        }
        _ = await storeB.loadAll()

        _ = await storeA.commit(RenameSonglistOperation(id: shared.id, name: "A 改的", knownName: shared.name))
        let renameB = await storeB.commit(RenameSonglistOperation(id: shared.id, name: "B 改的", knownName: shared.name))
        guard case .success = renameB.result else {
            return XCTFail("B 改名应成功（后执行的为准）")
        }

        _ = await storeA.commit(CreateSonglistOperation(name: "A 新建"))
        _ = await storeB.commit(CreateSonglistOperation(name: "B 新建"))

        let reloaded = await SonglistStore(root: root).loadAll()
        XCTAssertEqual(reloaded.songlists[shared.id]?.name, "B 改的", "后执行的一方为准")
        XCTAssertEqual(reloaded.songlists.count, 3, "共享歌单 + A 新建 + B 新建")
    }

    // MARK: - #9 等锁超时

    func testWaitingForLockTimesOutAfterAboutTwoSeconds() async throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let lockPath = root.appendingPathComponent(".lock").path
        let fd = lockPath.withCString { open($0, O_RDONLY | O_CREAT, 0o600) }
        XCTAssertGreaterThanOrEqual(fd, 0)
        XCTAssertEqual(flock(fd, LOCK_EX), 0, "测试线程先拿住锁")

        let holdTask = Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            flock(fd, LOCK_UN)
            close(fd)
        }

        let store = SonglistStore(root: root)
        let start = Date()
        let outcome = await store.commit(CreateSonglistOperation(name: "等锁"))
        let elapsed = Date().timeIntervalSince(start)

        guard case .failure(.saveFailed(let reason)) = outcome.result else {
            return XCTFail("期望超时 saveFailed，实际 \(outcome.result)")
        }
        XCTAssertEqual(reason, "歌单正在被另一个窗口保存，请稍后重试")
        XCTAssertGreaterThanOrEqual(elapsed, 1.8)
        XCTAssertLessThan(elapsed, 2.9)

        _ = await holdTask.value
    }

    // MARK: - #11 5000 首歌单改名性能（预热 1 次、计时 5 次、断言中位数）

    func testRenameFiveThousandTrackSonglistPerformance() async throws {
        let store = SonglistStore(root: root)
        _ = await store.loadAll()

        let entries = (0..<5000).map { i in
            SonglistEntry(path: "/Music/track-\(i).mp3", title: "Track \(i)", artist: "Artist", album: "Album", duration: 180)
        }
        // 直接构造一个大歌单写入，跳过逐首添加（那是 T-004 的操作）
        struct SeedOperation: SonglistOperation {
            let songlist: Songlist
            var targetID: UUID? { songlist.id }
            func apply(to fresh: [UUID: Songlist], now: Date) throws -> Songlist? { songlist }
        }
        let seed = Songlist(id: UUID(), name: "大歌单", createdAt: Date(), entries: entries)
        let seedOutcome = await store.commit(SeedOperation(songlist: seed))
        guard case .success(let seeded?) = seedOutcome.result else {
            return XCTFail("准备大歌单失败")
        }

        // 预热
        _ = await store.commit(RenameSonglistOperation(id: seeded.id, name: "预热", knownName: seeded.name))

        var durations: [TimeInterval] = []
        var previousName = "预热"
        for i in 0..<5 {
            let newName = "改名 \(i)"
            let start = Date()
            let outcome = await store.commit(RenameSonglistOperation(id: seeded.id, name: newName, knownName: previousName))
            durations.append(Date().timeIntervalSince(start))
            guard case .success = outcome.result else { return XCTFail("改名失败") }
            previousName = newName
        }

        let sorted = durations.sorted()
        let median = sorted[sorted.count / 2]
        XCTAssertLessThanOrEqual(median, 0.2, "5 次耗时：\(durations)")
    }

    // MARK: - #12 删除整个数据文件夹后 loadAll，再新建

    func testLoadAllAfterRootDeletedThenCreateAgain() async throws {
        let store = SonglistStore(root: root)
        _ = await store.loadAll()
        _ = await store.commit(CreateSonglistOperation(name: "会被删掉"))

        try FileManager.default.removeItem(at: root)

        let snapshot = await store.loadAll()
        XCTAssertTrue(snapshot.songlists.isEmpty)

        let createOutcome = await store.commit(CreateSonglistOperation(name: "重建之后"))
        guard case .success(let created?) = createOutcome.result else {
            return XCTFail("目录被删后应能重建并新建成功")
        }
        XCTAssertEqual(created.name, "重建之后")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.path))
    }
}
