import XCTest
@testable import MusicCore

/// T-019：左栏分段只剩「曲库」「歌单」两项，`nowPlaying` 改成了独立开关。
final class LeftPaneTabTests: XCTestCase {

    func testOnlyLibraryAndSonglistsAreValidCases() {
        XCTAssertNotNil(LeftPaneTab(rawValue: "library"))
        XCTAssertNotNil(LeftPaneTab(rawValue: "songlists"))
    }

    // 旧版本存过的 "nowPlaying" 不再是合法取值；@SceneStorage 构造失败时会
    // 自动回落到声明的默认值（.library），不需要额外的迁移代码。
    func testLegacyNowPlayingRawValueFailsToConstruct() {
        XCTAssertNil(LeftPaneTab(rawValue: "nowPlaying"))
    }
}
