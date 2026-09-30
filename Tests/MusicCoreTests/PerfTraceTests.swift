import XCTest
@testable import MusicCore

/// `PerfTrace` 只有环境变量 `MACMUSICPLAYER_PERF=1` 时才启用，`isEnabled` 又是进程
/// 生命周期内只读一次的 `static let`。`swift test` 这个进程本身没有设这个环境变量，
/// 所以这里只能测「关闭时」的行为（方案 §7 自测 #1、#4）；#2、#3（设了环境变量之后
/// 的行为）需要业主用 `MACMUSICPLAYER_PERF=1` 单独启动一次 App 手工验证，不在这个
/// 进程里测得出来。
final class PerfTraceTests: XCTestCase {

    private var logURL: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("MacMusicPlayer", isDirectory: true)
            .appendingPathComponent("perf.log", isDirectory: false)
    }

    // #1：不设环境变量运行，不生成 perf.log。
    func testDisabledStateDoesNotCreateLogFile() {
        PerfTrace.begin("songlist.open")
        PerfTrace.end("songlist.open")

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: logURL.path),
            "关闭状态下不应该创建 perf.log"
        )
    }

    // #4：开关关闭时 begin/end 各调 1 万次，≤ 5 ms，不创建文件。
    func testTenThousandBeginEndCallsWhenDisabledPerformance() {
        let start = Date()
        for i in 0..<10_000 {
            PerfTrace.begin("perf.test.\(i % 8)")
            PerfTrace.end("perf.test.\(i % 8)")
        }
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertLessThanOrEqual(elapsed, 0.005, "1 万次 begin/end 耗时 \(elapsed * 1000) ms")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: logURL.path),
            "关闭状态下不应该创建 perf.log"
        )
    }
}
