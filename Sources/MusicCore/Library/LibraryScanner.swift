import Foundation

/// 递归扫描目录，收集受支持的音频文件。
public enum LibraryScanner {

    /// AVFoundation 在 macOS 上原生支持的常见格式。
    public static let supportedExtensions: Set<String> = [
        "mp3", "m4a", "aac", "flac", "wav", "aiff", "aif", "alac", "m4b", "caf"
    ]

    /// 递归扫描 `directory`，返回按路径自然序排序的音频文件 URL。
    ///
    /// 跳过隐藏文件与包（`.app` 等）。目录不可读时返回空数组，不抛错。
    public static func scan(directory: URL) -> [URL] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey]

        guard let enumerator = fm.enumerator(
            at: directory,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { _, _ in true }   // 单个子目录不可读时继续
        ) else {
            return []
        }

        var results: [URL] = []
        for case let url as URL in enumerator {
            guard supportedExtensions.contains(url.pathExtension.lowercased()) else { continue }
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard values?.isRegularFile == true else { continue }
            results.append(url)
        }

        return sorted(results)
    }

    /// 按完整路径做自然序排序（"track2" 排在 "track10" 前面）。
    static func sorted(_ urls: [URL]) -> [URL] {
        urls.sorted { a, b in
            a.path.localizedStandardCompare(b.path) == .orderedAscending
        }
    }
}
