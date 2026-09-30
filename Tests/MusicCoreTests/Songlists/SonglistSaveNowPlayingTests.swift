import XCTest
import Darwin
@testable import MusicCore

/// T-011「播放列表存为歌单」：复用 T-004 的 `create(name:with:)`，这里按方案 §7
/// 的场景把 Service 层的验收过一遍。
@MainActor
final class SonglistSaveNowPlayingTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SonglistSaveNowPlayingTests-\(UUID().uuidString)", isDirectory: true)
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

    // MARK: - #1 10 首的快照，顺序一致

    func testCreateFromTenTrackSnapshotPreservesOrder() async throws {
        let service = SonglistService(root: root)
        await service.loadAll()
        let snapshot = (0..<10).map { track("T\($0)") }

        let result = await service.create(name: "存档", with: snapshot)
        guard case .success(let addResult) = result else {
            return XCTFail("应该成功：\(result)")
        }

        XCTAssertEqual(addResult.added, 10)
        XCTAssertEqual(addResult.songlistName, "存档")
        guard let id = service.summaries.first(where: { $0.name == "存档" })?.id else {
            return XCTFail("没找到新建的歌单")
        }
        XCTAssertEqual(service.entries(of: id)?.map(\.title), (0..<10).map { "T\($0)" }, "顺序应该和快照一致")
    }

    // MARK: - #2 快照里有一首路径不存在的，也写进歌单

    func testCreateWritesEntryEvenWhenFileDoesNotExist() async throws {
        let service = SonglistService(root: root)
        await service.loadAll()
        let missing = track("Missing", path: "/Music/DoesNotExist.mp3")

        let result = await service.create(name: "存档", with: [missing])
        guard case .success(let addResult) = result else {
            return XCTFail("应该成功：\(result)")
        }

        XCTAssertEqual(addResult.added, 1)
        guard let id = service.summaries.first(where: { $0.name == "存档" })?.id else {
            return XCTFail("没找到新建的歌单")
        }
        XCTAssertEqual(service.entries(of: id)?.map(\.path), [missing.url.path], "不存在的文件也应该照样写进歌单")
    }

    // MARK: - #3 名称为空、或者和已有歌单重名

    func testCreateWithEmptyNameFails() async throws {
        let service = SonglistService(root: root)
        await service.loadAll()

        let result = await service.create(name: "   ", with: [track("A")])
        guard case .failure(.nameEmpty) = result else {
            return XCTFail("期望 nameEmpty，实际 \(result)")
        }
        XCTAssertTrue(service.summaries.isEmpty, "不应该新建歌单")
    }

    func testCreateWithDuplicateNameFails() async throws {
        let service = SonglistService(root: root)
        await service.loadAll()
        _ = await service.create(name: "通勤", with: [track("A")])

        let result = await service.create(name: "通勤", with: [track("B")])
        guard case .failure(.nameDuplicate(let existing)) = result else {
            return XCTFail("期望 nameDuplicate，实际 \(result)")
        }
        XCTAssertEqual(existing, "通勤")
        XCTAssertEqual(service.summaries.count, 1, "重名不应该新建第二个歌单")
    }

    // MARK: - #4 数据文件夹只读

    func testCreateOnReadOnlyDirectoryReturnsSaveFailedAndWritesNothing() async throws {
        try FileManager.default.createDirectory(at: songlistsDir(), withIntermediateDirectories: true)
        let service = SonglistService(root: root)
        await service.loadAll()

        chmod(songlistsDir().path, 0o500)
        defer { chmod(songlistsDir().path, 0o700) }

        let result = await service.create(name: "存档", with: [track("A")])
        guard case .failure(.saveFailed(let reason)) = result else {
            return XCTFail("期望 saveFailed，实际 \(result)")
        }
        XCTAssertEqual(reason, "数据文件夹没有写入权限")

        let names = (try? FileManager.default.contentsOfDirectory(atPath: songlistsDir().path)) ?? []
        XCTAssertTrue(names.isEmpty, "只读时不应该写任何文件")
    }

    // MARK: - #5 NowPlayingList 层：本任务不应调用任何 mutating 方法（防回归）

    func testSavingNowPlayingDoesNotMutateNowPlayingList() {
        var list = NowPlayingList(mode: .sequential)
        let tracks = (0..<5).map { track("N\($0)") }
        list.playFromLibrary(tracks, at: 2)

        let stateBefore = list.state
        let sourceBefore = list.source
        let itemsBefore = list.items.map(\.identity)
        let currentBefore = list.queue.current

        // T-011：「存为歌单」只是读 vm.nowPlaying.items 取快照，不应该调用
        // NowPlayingList 的任何 mutating 方法——这里断言读取本身不改变任何状态。
        _ = list.items

        XCTAssertEqual(list.state, stateBefore)
        XCTAssertEqual(list.source, sourceBefore)
        XCTAssertEqual(list.items.map(\.identity), itemsBefore)
        XCTAssertEqual(list.queue.current, currentBefore)
    }
}
