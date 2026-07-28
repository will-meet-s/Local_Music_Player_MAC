import XCTest
@testable import MusicCore

final class LibraryScannerTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("MusicScannerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeFile(_ relativePath: String) throws {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("x".utf8).write(to: url)
    }

    func testFiltersBySupportedExtension() throws {
        try makeFile("a.mp3")
        try makeFile("b.flac")
        try makeFile("c.txt")
        try makeFile("d.jpg")
        try makeFile("e.lrc")

        let names = LibraryScanner.scan(directory: root).map(\.lastPathComponent)

        XCTAssertEqual(Set(names), ["a.mp3", "b.flac"])
    }

    func testExtensionMatchIsCaseInsensitive() throws {
        try makeFile("A.MP3")
        try makeFile("B.M4a")

        let names = LibraryScanner.scan(directory: root).map(\.lastPathComponent)

        XCTAssertEqual(Set(names), ["A.MP3", "B.M4a"])
    }

    func testRecursesIntoSubdirectories() throws {
        try makeFile("top.mp3")
        try makeFile("album/one.mp3")
        try makeFile("album/disc2/two.mp3")

        let names = LibraryScanner.scan(directory: root).map(\.lastPathComponent)

        XCTAssertEqual(Set(names), ["top.mp3", "one.mp3", "two.mp3"])
    }

    func testSkipsHiddenFiles() throws {
        try makeFile("visible.mp3")
        try makeFile(".hidden.mp3")

        let names = LibraryScanner.scan(directory: root).map(\.lastPathComponent)

        XCTAssertEqual(names, ["visible.mp3"])
    }

    func testEmptyDirectoryReturnsEmpty() {
        XCTAssertTrue(LibraryScanner.scan(directory: root).isEmpty)
    }

    func testMissingDirectoryReturnsEmptyRatherThanThrowing() {
        let missing = root.appendingPathComponent("does-not-exist", isDirectory: true)
        XCTAssertTrue(LibraryScanner.scan(directory: missing).isEmpty)
    }

    func testNaturalSortOrder() {
        let urls = [
            URL(fileURLWithPath: "/m/track10.mp3"),
            URL(fileURLWithPath: "/m/track2.mp3"),
            URL(fileURLWithPath: "/m/track1.mp3")
        ]

        let sorted = LibraryScanner.sorted(urls).map(\.lastPathComponent)

        XCTAssertEqual(sorted, ["track1.mp3", "track2.mp3", "track10.mp3"])
    }
}
