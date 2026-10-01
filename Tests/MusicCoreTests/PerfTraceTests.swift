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

    // #4（v2，F-25）：开关关闭时 begin/end 各调 1 万次，中位数 ≤ 20 ms，不创建文件。
    // v1 在计时循环里拼接打点名，测到的主要是字符串插值的开销而不是 PerfTrace 本身，
    // 而且只测 1 次，在共享 CI 机器上会波动；改成打点名事先建好、预热 1 次、计时 5 次
    // 取中位数（沿用本单性能类单测的统一写法）。
    func testTenThousandBeginEndCallsWhenDisabledPerformance() {
        let names = (0..<8).map { "perf.test.\($0)" }

        func runOnce() -> TimeInterval {
            let start = Date()
            for i in 0..<10_000 {
                PerfTrace.begin(names[i % 8])
                PerfTrace.end(names[i % 8])
            }
            return Date().timeIntervalSince(start)
        }

        // 预热
        _ = runOnce()

        var durations: [TimeInterval] = []
        for _ in 0..<5 {
            durations.append(runOnce())
        }

        let sorted = durations.sorted()
        let median = sorted[sorted.count / 2]
        // 关闭状态下只是读一下 static let 然后直接返回；如果误写了文件，1 万次
        // 至少要几百毫秒，20 ms 仍然能发现这个问题（方案 v2 §7 #4）。
        XCTAssertLessThanOrEqual(median, 0.02, "5 次耗时：\(durations)")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: logURL.path),
            "关闭状态下不应该创建 perf.log"
        )
    }
}
