import Foundation

/// 性能打点（T-014 §2.4）：默认关闭，只有环境变量 `MACMUSICPLAYER_PERF=1` 时启用；
/// 关闭时 `begin`/`end` 直接返回，不产生文件。只记打点名和耗时，**不记路径、歌单名、
/// 曲目信息**（安全考量 §5）——业主执行完把 `perf.log` 交给测试工程师，不会带上
/// 任何真实的音乐库内容。
public enum PerfTrace {
    /// 只在进程启动时读一次环境变量，运行期间不会变化。
    private static let isEnabled: Bool = {
        ProcessInfo.processInfo.environment["MACMUSICPLAYER_PERF"] == "1"
    }()

    private static let lock = NSLock()
    private static var startTimes: [String: ContinuousClock.Instant] = [:]

    public static func begin(_ name: String) {
        guard isEnabled else { return }
        lock.lock()
        startTimes[name] = ContinuousClock.now
        lock.unlock()
    }

    public static func end(_ name: String) {
        guard isEnabled else { return }
        let now = ContinuousClock.now
        lock.lock()
        let start = startTimes.removeValue(forKey: name)
        lock.unlock()
        guard let start else { return }
        append(name: name, milliseconds: milliseconds(from: start, to: now))
    }

    private static func milliseconds(from start: ContinuousClock.Instant, to end: ContinuousClock.Instant) -> Double {
        let components = (end - start).components
        return Double(components.seconds) * 1000 + Double(components.attoseconds) / 1e15
    }

    /// 追加写到 `~/Library/Logs/MacMusicPlayer/perf.log`，一行一条：
    /// `{ISO 时间}\t{打点名}\t{毫秒}`。**不在数据文件夹里**，不影响 §4 数据位置的判定。
    private static func append(name: String, milliseconds: Double) {
        let line = "\(isoFormatter.string(from: Date()))\t\(name)\t\(String(format: "%.3f", milliseconds))\n"
        guard let data = line.data(using: .utf8) else { return }

        let fm = FileManager.default
        let directory = logFileURL.deletingLastPathComponent()
        if !fm.fileExists(atPath: directory.path) {
            try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        if !fm.fileExists(atPath: logFileURL.path) {
            fm.createFile(atPath: logFileURL.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: logFileURL) else { return }
        defer { try? handle.close() }
        handle.seekToEndOfFile()
        handle.write(data)
    }

    private static let logFileURL: URL = {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("MacMusicPlayer", isDirectory: true)
            .appendingPathComponent("perf.log", isDirectory: false)
    }()

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
