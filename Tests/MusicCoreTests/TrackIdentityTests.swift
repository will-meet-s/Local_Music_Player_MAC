import XCTest
@testable import MusicCore

final class TrackIdentityTests: XCTestCase {

    func testIdenticalPathsAreEqual() {
        let a = TrackIdentity(path: "/Music/a.mp3")
        let b = TrackIdentity(path: "/Music/a.mp3")
        XCTAssertEqual(a, b)
    }

    func testDifferentCaseIsEqual() {
        let a = TrackIdentity(path: "/Music/A.MP3")
        let b = TrackIdentity(path: "/music/a.mp3")
        XCTAssertEqual(a, b)
    }

    func testDifferentCaseWithUnicodeIsEqual() {
        let a = TrackIdentity(path: "/Music/周杰伦/晴天.mp3")
        let b = TrackIdentity(path: "/MUSIC/周杰伦/晴天.MP3")
        XCTAssertEqual(a, b)
    }

    func testNFDAndNFCAreEqual() {
        // "Café" 的 NFD 形式：e + U+0301（组合重音符）
        let nfd = TrackIdentity(path: "/Music/Cafe\u{301}.mp3")
        let nfc = TrackIdentity(path: "/Music/Café.mp3")
        XCTAssertEqual(nfd, nfc)
    }

    func testDotAndDotDotSegmentsAreNormalized() {
        let a = TrackIdentity(path: "/Music/./x/../a.mp3")
        let b = TrackIdentity(path: "/Music/a.mp3")
        XCTAssertEqual(a, b)
    }

    func testDoubleSlashIsNormalized() {
        let a = TrackIdentity(path: "/Music//a.mp3")
        let b = TrackIdentity(path: "/Music/a.mp3")
        XCTAssertEqual(a, b)
    }

    func testDifferentFileNameIsNotEqual() {
        let a = TrackIdentity(path: "/Music/a.mp3")
        let b = TrackIdentity(path: "/Music/b.mp3")
        XCTAssertNotEqual(a, b)
    }

    func testDifferentDirectoryIsNotEqual() {
        let a = TrackIdentity(path: "/Music/a.mp3")
        let b = TrackIdentity(path: "/Other/a.mp3")
        XCTAssertNotEqual(a, b)
    }

    func testInitPathAndInitURLAreEquivalent() {
        let path = "/Music/a.mp3"
        let a = TrackIdentity(path: path)
        let b = TrackIdentity(url: URL(fileURLWithPath: path))
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.hashValue, b.hashValue)
    }

    func testTrackIdentityEqualButIdDiffersOnCaseOnlyPaths() {
        let a = Track(url: URL(fileURLWithPath: "/Music/A.mp3"))
        let b = Track(url: URL(fileURLWithPath: "/music/a.mp3"))
        XCTAssertEqual(a.identity, b.identity)
        XCTAssertNotEqual(a.id, b.id)
    }

    func testCaseOnlyDifferencesCollapseInASet() {
        let identities: Set<TrackIdentity> = [
            TrackIdentity(path: "/a/X.mp3"),
            TrackIdentity(path: "/a/x.mp3"),
            TrackIdentity(path: "/a/y.mp3")
        ]
        XCTAssertEqual(identities.count, 2)
    }

    func testCodableRoundTripPreservesEquality() throws {
        let original = TrackIdentity(path: "/Music/周杰伦/晴天.mp3")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(TrackIdentity.self, from: data)
        XCTAssertEqual(original, decoded)
    }

    func testConstructingTenThousandIdentitiesIsFast() {
        let start = Date()
        var set = Set<TrackIdentity>()
        for i in 0..<10_000 {
            set.insert(TrackIdentity(path: "/Music/track-\(i).mp3"))
        }
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertEqual(set.count, 10_000)
        XCTAssertLessThan(elapsed, 0.5)
    }
}
