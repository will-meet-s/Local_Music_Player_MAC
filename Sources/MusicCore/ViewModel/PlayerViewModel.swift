import Foundation
import SwiftUI
import AppKit

/// UI 的唯一数据源：串联扫描、元数据、歌词、播放队列与播放引擎。
@MainActor
public final class PlayerViewModel: ObservableObject {

    // MARK: - 曲库

    @Published public private(set) var tracks: [Track] = []
    @Published public private(set) var folderURL: URL?
    @Published public private(set) var isScanning = false

    // MARK: - 播放状态

    @Published public private(set) var currentIndex: Int?
    @Published public private(set) var isPlaying = false
    @Published public private(set) var currentTime: Double = 0
    @Published public private(set) var duration: Double = 0

    // MARK: - 歌词

    @Published public private(set) var lyrics: [LyricLine] = []
    @Published public private(set) var currentLyricIndex: Int?
    /// 歌词是否带时间戳。无时间戳时只静态展示，不高亮滚动。
    @Published public private(set) var lyricsAreSynced = false

    // MARK: - 用户偏好

    @Published public var playMode: PlayMode {
        didSet {
            queue.mode = playMode
            Preferences.playMode = playMode
        }
    }

    @Published public var volume: Double {
        didSet {
            engine.volume = volume
            Preferences.volume = volume
        }
    }

    @Published public var errorMessage: String?

    // MARK: - 内部

    private let engine = PlayerEngine()
    private var queue = PlaybackQueue()
    private var metadataTask: Task<Void, Never>?
    /// 连续播放失败次数。用来避免整目录都是坏文件时无限自动跳曲。
    private var consecutiveFailures = 0

    public var currentTrack: Track? {
        guard let i = currentIndex, tracks.indices.contains(i) else { return nil }
        return tracks[i]
    }

    public init() {
        let mode = Preferences.playMode
        let vol = Preferences.volume
        self.playMode = mode
        self.volume = vol
        self.queue = PlaybackQueue(count: 0, mode: mode)

        engine.volume = vol
        wireEngineCallbacks()
    }

    /// App 启动后调用：若上次的文件夹仍存在则自动重扫。
    public func restoreLastSession() {
        // 视图重建时 .task 会再次触发，已经有曲库就不要重扫
        guard folderURL == nil, let folder = Preferences.lastFolder else { return }
        scan(folder: folder)
    }

    // MARK: - 曲库扫描

    /// 弹出系统目录选择面板。
    public func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "选择"
        panel.message = "选择包含音乐文件的文件夹"
        panel.directoryURL = folderURL ?? FileManager.default.urls(for: .musicDirectory, in: .userDomainMask).first

        guard panel.runModal() == .OK, let url = panel.url else { return }
        scan(folder: url)
    }

    /// 扫描文件夹。先用文件名秒出列表，再后台补全元数据。
    public func scan(folder: URL) {
        metadataTask?.cancel()
        engine.unload()

        folderURL = folder
        Preferences.lastFolder = folder

        currentIndex = nil
        currentTime = 0
        duration = 0
        lyrics = []
        currentLyricIndex = nil
        isPlaying = false
        isScanning = true
        consecutiveFailures = 0

        Task {
            let urls = await Task.detached(priority: .userInitiated) {
                LibraryScanner.scan(directory: folder)
            }.value

            self.tracks = urls.map(Track.init(url:))
            self.queue.setCount(self.tracks.count)
            self.isScanning = false

            if self.tracks.isEmpty {
                self.errorMessage = "该文件夹下没有找到受支持的音频文件"
            }

            self.loadMetadataInBackground()
        }
    }

    /// 逐个补全元数据。就地更新，不改变列表顺序，因此不会打断用户操作。
    private func loadMetadataInBackground() {
        metadataTask = Task { [weak self] in
            guard let self else { return }
            let snapshot = self.tracks
            for (index, track) in snapshot.enumerated() {
                if Task.isCancelled { return }
                let loaded = await MetadataLoader.load(url: track.url)

                // 列表可能已被重新扫描，按 URL 校验后再写回。
                guard self.tracks.indices.contains(index),
                      self.tracks[index].url == loaded.url else { continue }
                self.tracks[index] = loaded

                // 正在播放的这首元数据到位后，补一次歌词与时长。
                if self.currentIndex == index {
                    self.refreshLyrics(for: loaded)
                    if self.duration == 0 { self.duration = loaded.duration }
                }
            }
        }
    }

    // MARK: - 播放控制

    public func play(at index: Int) {
        guard tracks.indices.contains(index) else { return }
        queue.select(index)
        startCurrent()
    }

    public func togglePlayPause() {
        if currentIndex == nil {
            // 还没选歌时，播放键等同于从头开始
            if let first = queue.next(auto: false) {
                queue.select(first)
                startCurrent()
            }
            return
        }
        engine.togglePlayPause()
        isPlaying = engine.isPlaying
    }

    public func stop() {
        engine.stop()
        isPlaying = false
        currentTime = 0
        currentLyricIndex = nil
    }

    public func nextTrack() {
        advance(auto: false)
    }

    public func previousTrack() {
        // 播放超过 3 秒时，「上一首」先回到本曲开头，符合常见播放器习惯。
        if currentTime > 3 {
            seek(to: 0)
            return
        }
        guard queue.previous() != nil else { return }
        startCurrent()
    }

    public func seek(to seconds: Double) {
        engine.seek(to: seconds)
    }

    public func cyclePlayMode() {
        playMode = playMode.next
    }

    // MARK: - 内部流转

    private func advance(auto: Bool) {
        guard let next = queue.next(auto: auto) else {
            // 顺序播放到达列表末尾
            stop()
            return
        }
        // 单曲循环自动重播时，直接从头播，不必重新加载文件
        if auto && playMode == .repeatOne && next == currentIndex {
            engine.seek(to: 0)
            engine.play()
            isPlaying = true
            return
        }
        startCurrent()
    }

    private func startCurrent() {
        guard let index = queue.current, tracks.indices.contains(index) else { return }
        let track = tracks[index]

        currentIndex = index
        currentTime = 0
        duration = track.duration
        refreshLyrics(for: track)

        engine.load(url: track.url, autoplay: true)
        isPlaying = engine.isPlaying
    }

    private func refreshLyrics(for track: Track) {
        let lines = LyricsProvider.lyrics(for: track)
        lyrics = lines
        lyricsAreSynced = lines.contains { $0.time >= 0 }
        currentLyricIndex = nil
    }

    private func wireEngineCallbacks() {
        engine.onProgress = { [weak self] seconds in
            guard let self else { return }
            self.currentTime = seconds
            self.updateLyricHighlight(at: seconds)
        }

        engine.onFinish = { [weak self] in
            self?.advance(auto: true)
        }

        engine.onError = { [weak self] message in
            guard let self else { return }
            self.errorMessage = message
            self.isPlaying = false

            // 坏文件不该卡住播放，自动跳过；但整个列表都放不出来时必须停下，
            // 否则会在队列里无限打转。
            self.consecutiveFailures += 1
            guard self.consecutiveFailures < max(1, self.tracks.count) else {
                self.errorMessage = "列表中的音频都无法播放，已停止"
                self.engine.unload()
                self.currentIndex = nil
                return
            }
            self.advance(auto: false)
        }

        engine.onDurationResolved = { [weak self] seconds in
            guard let self else { return }
            // 能拿到时长说明这首已经 readyToPlay，失败计数清零
            self.consecutiveFailures = 0
            self.duration = seconds
            if let i = self.currentIndex, self.tracks.indices.contains(i), self.tracks[i].duration == 0 {
                self.tracks[i].duration = seconds
            }
        }
    }

    /// 只在高亮行真正变化时写 `@Published`，避免每 0.1 秒触发一次全量重绘。
    private func updateLyricHighlight(at seconds: Double) {
        guard lyricsAreSynced, !lyrics.isEmpty else { return }
        let index = LRCParser.index(at: seconds, in: lyrics)
        if index != currentLyricIndex {
            currentLyricIndex = index
        }
    }
}
