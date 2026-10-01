import XCTest
@testable import MusicCore

final class LibraryLocatorTests: XCTestCase {

    private func track(_ name: String, path: String? = nil) -> Track {
        Track(url: URL(fileURLWithPath: path ?? "/Music/\(name).mp3"))
    }

    private func libraryIndex(_ tracks: [Track]) -> [TrackIdentity: Int] {
        Dictionary(tracks.enumerated().map { ($1.identity, $0) }, uniquingKeysWith: { first, _ in first })
    }

    // #1
    func testNoCurrentTrackReturnsNoTrack() {
        let displayed = (0..<3).map { track("T\($0)") }
        let result = LibraryLocator.locate(playing: nil, displayed: displayed, libraryIndex: libraryIndex(displayed))
        XCTAssertEqual(result, .noTrack)
    }

    // #2
    func testFindsCurrentTrackAtItsIndex() {
        let displayed = (0..<10).map { track("T\($0)") }
        let playing = displayed[3].identity
        let result = LibraryLocator.locate(playing: playing, displayed: displayed, libraryIndex: libraryIndex(displayed))
        XCTAssertEqual(result, .found(3))
    }

    // #3：降序（或任何其他排序）之后，displayed 的顺序变了，定位结果按新顺序来。
    func testFindsCurrentTrackAtIndexInReorderedDisplayedList() {
        let original = (0..<10).map { track("T\($0)") }
        let playing = original[3].identity
        let descending = Array(original.reversed())
        let result = LibraryLocator.locate(playing: playing, displayed: descending, libraryIndex: libraryIndex(original))
        XCTAssertEqual(result, .found(descending.firstIndex(where: { $0.identity == playing })!))
        XCTAssertEqual(result, .found(6), "倒序后原下标 3 应该落在下标 6")
    }

    // #4
    func testFilteredOutWhenNotInDisplayedButInLibrary() {
        let full = (0..<5).map { track("T\($0)") }
        let playing = full[2].identity
        let filtered = full.filter { $0.identity != playing }
        let result = LibraryLocator.locate(playing: playing, displayed: filtered, libraryIndex: libraryIndex(full))
        XCTAssertEqual(result, .filteredOut)
    }

    // #5
    func testNotInFolderWhenNotInLibraryIndexEither() {
        let displayed = (0..<3).map { track("T\($0)") }
        let elsewhere = TrackIdentity(path: "/Somewhere/Else.mp3")
        let result = LibraryLocator.locate(playing: elsewhere, displayed: displayed, libraryIndex: libraryIndex(displayed))
        XCTAssertEqual(result, .notInFolder)
    }

    // #6：只差路径大小写，仍然算同一首（T-002）。
    func testFindsTrackDifferingOnlyByPathCase() {
        let displayed = [track("A", path: "/Music/a.mp3"), track("B", path: "/Music/B.mp3")]
        let playing = TrackIdentity(path: "/MUSIC/a.MP3")
        let result = LibraryLocator.locate(playing: playing, displayed: displayed, libraryIndex: libraryIndex(displayed))
        XCTAssertEqual(result, .found(0))
    }

    // #7：扫描到一半，displayed 只有部分。
    func testPartiallyScannedLibraryFindsOrReportsNotInFolder() {
        let full = (0..<10).map { track("T\($0)") }
        let scannedSoFar = Array(full.prefix(5))

        let found = LibraryLocator.locate(
            playing: full[2].identity, displayed: scannedSoFar, libraryIndex: libraryIndex(scannedSoFar)
        )
        XCTAssertEqual(found, .found(2))

        let notYetScanned = LibraryLocator.locate(
            playing: full[8].identity, displayed: scannedSoFar, libraryIndex: libraryIndex(scannedSoFar)
        )
        XCTAssertEqual(notYetScanned, .notInFolder)
    }

    // #8：1 万首定位最后一首，中位数 ≤ 5 ms（性能类单测统一写法）。
    func testLocatingLastOfTenThousandTracksPerformance() {
        let displayed = (0..<10_000).map { track("T\($0)", path: "/Music/t-\($0).mp3") }
        let index = libraryIndex(displayed)
        let playing = displayed.last!.identity

        var durations: [TimeInterval] = []
        for _ in 0..<5 {
            let start = Date()
            let result = LibraryLocator.locate(playing: playing, displayed: displayed, libraryIndex: index)
            durations.append(Date().timeIntervalSince(start))
            XCTAssertEqual(result, .found(9999))
        }

        let sorted = durations.sorted()
        let median = sorted[sorted.count / 2]
        XCTAssertLessThanOrEqual(median, 0.005, "5 次耗时：\(durations)")
    }
}
