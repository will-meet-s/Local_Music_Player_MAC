import XCTest
import Darwin
@testable import MusicCore

final class NowPlayingStoreTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NowPlayingStoreTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private var fileURL: URL {
        root.appendingPathComponent("nowplaying.json", isDirectory: false)
    }

    private func entry(_ name: String) -> SonglistEntry {
        SonglistEntry(path: "/Music/\(name).mp3", title: name, duration: 120)
    }

    // MARK: - #1 独立状态往返

    func testSaveAndLoadRoundTripsIndependentStateWithSonglistSource() {
        let store = NowPlayingStore(fileURL: fileURL)
        let items = (0..<6).map { entry("T\($0)") }
        let snapshot = NowPlayingSnapshot(
            state: .independent, source: .songlist(name: "通勤"), currentPath: items[2].path, items: items
        )

        XCTAssertNil(store.save(snapshot))
        guard let loaded = store.load() else { return XCTFail("应能读回") }

        XCTAssertEqual(loaded.state, .independent)
        XCTAssertEqual(loaded.source, .songlist(name: "通勤"))
        XCTAssertEqual(loaded.items, items, "顺序和内容都应该一致")
        XCTAssertEqual(loaded.currentPath, items[2].path)
    }

    // MARK: - #2 清空后 save

    func testEmptyIndependentListRoundTrips() {
        let store = NowPlayingStore(fileURL: fileURL)
        let snapshot = NowPlayingSnapshot(state: .independent, source: .edited, currentPath: nil, items: [])

        XCTAssertNil(store.save(snapshot))
        guard let loaded = store.load() else { return XCTFail("应能读回") }

        XCTAssertEqual(loaded.state, .independent)
        XCTAssertTrue(loaded.items.isEmpty)
        XCTAssertNil(loaded.currentPath)
    }

    // MARK: - #5 数据文件夹只读

    func testReadOnlyDirectoryReturnsFailureReasonEveryTime() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = NowPlayingStore(fileURL: fileURL)

        chmod(root.path, 0o500)
        defer { chmod(root.path, 0o700) }

        let snapshot = NowPlayingSnapshot(state: .independent, source: .library, currentPath: nil, items: [])
        for attempt in 1...3 {
            XCTAssertNotNil(store.save(snapshot), "第 \(attempt) 次应该也失败")
        }
    }

    // MARK: - #6 两个 Store 先后 save

    func testSecondStoreSaveOverwritesFirst() {
        let storeA = NowPlayingStore(fileURL: fileURL)
        let storeB = NowPlayingStore(fileURL: fileURL)

        let snapshotA = NowPlayingSnapshot(state: .independent, source: .edited, currentPath: nil, items: [entry("A")])
        let snapshotB = NowPlayingSnapshot(state: .independent, source: .edited, currentPath: nil, items: [entry("B")])

        XCTAssertNil(storeA.save(snapshotA))
        XCTAssertNil(storeB.save(snapshotB))

        guard let loaded = NowPlayingStore(fileURL: fileURL).load() else { return XCTFail("应能读回") }
        XCTAssertEqual(loaded.items, [entry("B")], "最后写入的应该是 B")
    }

    // MARK: - #7 损坏文件 / schemaVersion 不对

    func testLoadReturnsNilForRandomBytes() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data([0x00, 0xFF, 0x10, 0x22, 0x55]).write(to: fileURL)

        XCTAssertNil(NowPlayingStore(fileURL: fileURL).load(), "随机字节应该读取失败，不抛错")
    }

    func testLoadReturnsNilForWrongSchemaVersion() throws {
        let store = NowPlayingStore(fileURL: fileURL)
        let snapshot = NowPlayingSnapshot(state: .independent, source: .edited, currentPath: nil, items: [])
        XCTAssertNil(store.save(snapshot))

        var text = try String(contentsOf: fileURL, encoding: .utf8)
        text = text.replacingOccurrences(of: "\"schemaVersion\":1", with: "\"schemaVersion\":2")
        try text.write(to: fileURL, atomically: true, encoding: .utf8)

        XCTAssertNil(NowPlayingStore(fileURL: fileURL).load(), "schemaVersion 不对应该读取失败")
    }
}
