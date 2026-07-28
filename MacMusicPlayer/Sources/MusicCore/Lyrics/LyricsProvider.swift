import Foundation

/// 为曲目查找歌词。
///
/// 优先级：同目录同名 `.lrc` 文件 → 音频内嵌歌词 → 无。
public enum LyricsProvider {

    public static func lyrics(for track: Track) -> [LyricLine] {
        if let text = readLRCFile(for: track.url) {
            let lines = LRCParser.parse(text)
            if !lines.isEmpty { return lines }
        }

        if let embedded = track.embeddedLyrics {
            let lines = LRCParser.parse(embedded)
            if !lines.isEmpty { return lines }
            // 内嵌歌词常常是没有时间戳的纯文本，此时整体作为一行显示。
            let plain = embedded.trimmingCharacters(in: .whitespacesAndNewlines)
            if !plain.isEmpty {
                return plain
                    .split(whereSeparator: { $0 == "\n" || $0 == "\r" })
                    .enumerated()
                    .map { LyricLine(id: $0.offset, time: -1, text: String($0.element)) }
            }
        }

        return []
    }

    /// 读取同名 `.lrc`（大小写两种后缀都试）。UTF-8 失败时退 GB18030。
    static func readLRCFile(for audioURL: URL) -> String? {
        let base = audioURL.deletingPathExtension()
        for ext in ["lrc", "LRC"] {
            let url = base.appendingPathExtension(ext)
            guard let data = try? Data(contentsOf: url) else { continue }
            if let s = decode(data) { return s }
        }
        return nil
    }

    static func decode(_ data: Data) -> String? {
        if let s = String(data: data, encoding: .utf8) { return s }

        // 中文歌词文件常见 GB18030 / GBK 编码
        let gb18030 = String.Encoding(
            rawValue: CFStringConvertEncodingToNSStringEncoding(
                CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
            )
        )
        if let s = String(data: data, encoding: gb18030) { return s }

        return String(data: data, encoding: .isoLatin1)
    }
}
