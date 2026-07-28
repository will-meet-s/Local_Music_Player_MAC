import Foundation

/// LRC 歌词格式解析器。
///
/// 支持：
/// - `[mm:ss]`、`[mm:ss.xx]`、`[mm:ss.xxx]`、`[mm:ss:xx]`（部分播放器用冒号分隔毫秒）
/// - 一行多个时间戳（`[00:12.00][01:30.00]同一句副歌`）
/// - 忽略 `[ti:]` `[ar:]` `[al:]` `[by:]` `[offset:]` 等元信息标签
/// - 输入乱序时按时间排序
public enum LRCParser {

    /// 解析 LRC 文本。空文本或无任何有效时间戳时返回空数组。
    public static func parse(_ content: String) -> [LyricLine] {
        var parsed: [(time: Double, text: String)] = []
        var offset: Double = 0

        for rawLine in content.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let line = String(rawLine)

            if let value = metadataOffset(in: line) {
                offset = value
                continue
            }

            let (stamps, text) = splitTimestamps(line)
            guard !stamps.isEmpty else { continue }

            let trimmed = text.trimmingCharacters(in: .whitespaces)
            for stamp in stamps {
                parsed.append((stamp, trimmed))
            }
        }

        // offset 为正表示歌词需要提前显示（LRC 规范），故从时间上减去。
        let shift = offset / 1000.0
        return parsed
            .map { (max(0, $0.time - shift), $0.text) }
            .sorted { $0.0 < $1.0 }
            .enumerated()
            .map { LyricLine(id: $0.offset, time: $0.element.0, text: $0.element.1) }
    }

    /// 从行首连续切出所有 `[...]` 时间戳，返回时间列表与剩余文本。
    ///
    /// 遇到第一个非时间戳的 `[...]`（例如 `[ti:标题]`）即停止，且该行被视为无时间戳。
    private static func splitTimestamps(_ line: String) -> ([Double], String) {
        var times: [Double] = []
        var rest = Substring(line)

        while true {
            let scan = rest.drop(while: { $0 == " " || $0 == "\t" })
            guard scan.first == "[",
                  let close = scan.firstIndex(of: "]") else { break }

            let inner = scan[scan.index(after: scan.startIndex)..<close]
            guard let time = parseTimestamp(String(inner)) else { break }

            times.append(time)
            rest = scan[scan.index(after: close)...]
        }

        return (times, String(rest))
    }

    /// 解析 `mm:ss`、`mm:ss.xx`、`mm:ss:xx` 形式的时间戳。非时间戳返回 nil。
    private static func parseTimestamp(_ s: String) -> Double? {
        // 必须以数字开头，用来把 `[00:12.34]` 与 `[ti:标题]` 区分开
        guard let first = s.first, first.isNumber else { return nil }

        let parts = s.split(whereSeparator: { $0 == ":" || $0 == "." })
        guard parts.count >= 2, parts.count <= 3 else { return nil }
        guard let minutes = Double(parts[0]), let seconds = Double(parts[1]) else { return nil }
        guard seconds < 60 else { return nil }

        var total = minutes * 60 + seconds
        if parts.count == 3 {
            guard let fracDigits = Int(parts[2]) else { return nil }
            // 两位是厘秒，三位是毫秒
            let divisor = pow(10.0, Double(parts[2].count))
            total += Double(fracDigits) / divisor
        }
        return total
    }

    /// 识别 `[offset:+/-N]` 标签，返回毫秒值。
    private static func metadataOffset(in line: String) -> Double? {
        let trimmed = line.trimmingCharacters(in: .whitespaces).lowercased()
        guard trimmed.hasPrefix("[offset:"), trimmed.hasSuffix("]") else { return nil }
        let start = trimmed.index(trimmed.startIndex, offsetBy: 8)
        let end = trimmed.index(before: trimmed.endIndex)
        let value = trimmed[start..<end].trimmingCharacters(in: .whitespaces)
        return Double(value)
    }

    /// 二分查找 `time` 时刻应高亮的行索引；早于第一行时返回 nil。
    public static func index(at time: Double, in lines: [LyricLine]) -> Int? {
        guard let first = lines.first, time >= first.time else { return nil }

        var low = 0
        var high = lines.count - 1
        var result = 0
        while low <= high {
            let mid = (low + high) / 2
            if lines[mid].time <= time {
                result = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return result
    }
}
