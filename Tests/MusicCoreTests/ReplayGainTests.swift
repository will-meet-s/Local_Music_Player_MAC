import XCTest
@testable import MusicCore

final class ReplayGainTests: XCTestCase {

    // MARK: - 解析

    func testParsesGainWithUnit() {
        XCTAssertEqual(ReplayGain.parseGain("-6.54 dB")!, -6.54, accuracy: 0.0001)
        XCTAssertEqual(ReplayGain.parseGain("+2.10dB")!, 2.10, accuracy: 0.0001)
        XCTAssertEqual(ReplayGain.parseGain("-3")!, -3, accuracy: 0.0001)
        XCTAssertEqual(ReplayGain.parseGain("  0.00 DB  ")!, 0, accuracy: 0.0001)
    }

    func testRejectsGarbageGain() {
        XCTAssertNil(ReplayGain.parseGain(""))
        XCTAssertNil(ReplayGain.parseGain("不是数字"))
        XCTAssertNil(ReplayGain.parseGain("dB"))
    }

    func testParsesPeak() {
        XCTAssertEqual(ReplayGain.parsePeak("0.988525")!, 0.988525, accuracy: 0.000001)
        XCTAssertEqual(ReplayGain.parsePeak(" 1.0 ")!, 1.0, accuracy: 0.0001)
    }

    func testRejectsOutOfRangePeak() {
        XCTAssertNil(ReplayGain.parsePeak("0"))
        XCTAssertNil(ReplayGain.parsePeak("-0.5"))
        XCTAssertNil(ReplayGain.parsePeak("99"))
        XCTAssertNil(ReplayGain.parsePeak("abc"))
    }

    func testKeyMatchingIsCaseInsensitive() {
        XCTAssertTrue(ReplayGain.isTrackGainKey("REPLAYGAIN_TRACK_GAIN"))
        XCTAssertTrue(ReplayGain.isTrackGainKey("replaygain_track_gain"))
        XCTAssertTrue(ReplayGain.isTrackPeakKey("ReplayGain_Track_Peak"))

        XCTAssertFalse(ReplayGain.isTrackGainKey("REPLAYGAIN_ALBUM_GAIN"))
        XCTAssertFalse(ReplayGain.isTrackGainKey("TITLE"))
    }

    // MARK: - 增益计算

    func testNoGainMeansUnchanged() {
        XCTAssertEqual(ReplayGain().linearGain(), 1, accuracy: 0.0001)
        XCTAssertEqual(ReplayGain(trackPeak: 0.9).linearGain(), 1, accuracy: 0.0001,
                       "只有峰值没有增益时不做任何处理")
    }

    func testZeroDBIsUnityGain() {
        XCTAssertEqual(ReplayGain(trackGainDB: 0).linearGain(), 1, accuracy: 0.0001)
    }

    func testNegativeGainAttenuates() {
        // -6.02 dB 约等于减半
        let factor = ReplayGain(trackGainDB: -6.0206).linearGain()
        XCTAssertEqual(factor, 0.5, accuracy: 0.001)
    }

    func testPositiveGainBoosts() {
        // +6.02 dB 约等于翻倍，峰值未知时不设限
        let factor = ReplayGain(trackGainDB: 6.0206).linearGain()
        XCTAssertEqual(factor, 2.0, accuracy: 0.001)
    }

    func testPeakPreventsClipping() {
        // 峰值 0.8 时最多只能放大到 1.25 倍，否则削波
        let gain = ReplayGain(trackGainDB: 12, trackPeak: 0.8)
        XCTAssertEqual(gain.linearGain(), 1.25, accuracy: 0.001)
    }

    func testPeakDoesNotInterfereWhenNoClipping() {
        // 衰减不可能削波，峰值不应改变结果
        let withPeak = ReplayGain(trackGainDB: -6.0206, trackPeak: 0.99).linearGain()
        XCTAssertEqual(withPeak, 0.5, accuracy: 0.001)
    }

    func testPreampIsApplied() {
        let base = ReplayGain(trackGainDB: 0).linearGain(preampDB: 6.0206)
        XCTAssertEqual(base, 2.0, accuracy: 0.001)
    }

    func testFactorIsClampedToSafeRange() {
        // 标签写错成极端值时不应炸耳朵，也不应彻底静音
        XCTAssertEqual(ReplayGain(trackGainDB: 60).linearGain(), ReplayGain.maxFactor, accuracy: 0.001)
        XCTAssertEqual(ReplayGain(trackGainDB: -60).linearGain(), ReplayGain.minFactor, accuracy: 0.001)
    }

    func testIsEmpty() {
        XCTAssertTrue(ReplayGain().isEmpty)
        XCTAssertFalse(ReplayGain(trackGainDB: -3).isEmpty)
        XCTAssertFalse(ReplayGain(trackPeak: 0.9).isEmpty)
    }
}
