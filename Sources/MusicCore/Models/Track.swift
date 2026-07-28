import Foundation

/// 一首本地音乐曲目。
///
/// 创建时只需要文件 URL，标题降级为文件名；元数据由 `MetadataLoader` 异步补全。
public struct Track: Identifiable, Hashable {
    public var id: URL { url }

    public let url: URL
    public var title: String
    public var artist: String?
    public var album: String?
    /// 秒。未知时为 0。
    public var duration: Double
    public var artworkData: Data?
    /// 音频文件内嵌的歌词文本（未解析）。
    public var embeddedLyrics: String?
    /// 音量归一化信息。文件没打标签时为 nil。
    public var replayGain: ReplayGain?
    /// 音频采样率（Hz）。用于把输出设备切到同一采样率，避免系统重采样。
    public var sampleRate: Double?
    /// 元数据是否已异步加载完成。
    public var metadataLoaded: Bool

    public init(url: URL) {
        self.url = url
        self.title = url.deletingPathExtension().lastPathComponent
        self.artist = nil
        self.album = nil
        self.duration = 0
        self.artworkData = nil
        self.embeddedLyrics = nil
        self.replayGain = nil
        self.sampleRate = nil
        self.metadataLoaded = false
    }

    /// 副标题：「艺术家 — 专辑」，缺失部分自动省略。
    public var subtitle: String {
        [artist, album].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " — ")
    }
}
