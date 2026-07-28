import Foundation
import SwiftUI
import AppKit

/// UI 的唯一数据源：串联扫描、元数据、歌词、播放队列与播放引擎。
///
/// 曲库有两份：`library` 是扫描出来的全量（文件顺序，不动），`tracks` 是经过
/// 搜索过滤与排序后**实际展示和播放**的列表。播放队列按 `tracks` 的下标工作，
/// 所以排序或搜索一变，队列必须跟着重建 —— 这件事统一在 `rebuildDisplayed()` 里做。
@MainActor
public final class PlayerViewModel: ObservableObject {

    // MARK: - 曲库

    /// 扫描得到的全量曲库，保持文件顺序。
    @Published public private(set) var library: [Track] = []
    /// 过滤 + 排序后的列表。UI 展示与播放队列都以它为准。
    @Published public private(set) var tracks: [Track] = []
    @Published public private(set) var folderURL: URL?
    @Published public private(set) var isScanning = false

    // MARK: - 搜索与排序

    @Published public var searchText: String = "" {
        didSet {
            guard oldValue != searchText else { return }
            rebuildDisplayed()
        }
    }

    @Published public var sortOrder: TrackSortOrder {
        didSet {
            guard oldValue != sortOrder else { return }
            Preferences.sortOrder = sortOrder
            rebuildDisplayed()
        }
    }

    @Published public var sortAscending: Bool {
        didSet {
            guard oldValue != sortAscending else { return }
            Preferences.sortAscending = sortAscending
            rebuildDisplayed()
        }
    }

    public var isFiltering: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - 播放状态

    /// 当前曲目在 `tracks` 里的下标。被搜索过滤掉时为 nil（歌照放，只是列表里没有它）。
    @Published public private(set) var currentIndex: Int?
    /// 正在播放的曲目本身。不受过滤影响，右侧「正在播放」区读这个。
    @Published public private(set) var playingTrack: Track?
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
            // 顺序变了，之前预判的「下一首」作废
            engine.invalidatePreload()
        }
    }

    /// 是否按 ReplayGain 标签做音量归一化。
    @Published public var replayGainEnabled: Bool {
        didSet {
            guard oldValue != replayGainEnabled else { return }
            Preferences.replayGainEnabled = replayGainEnabled
            // 增益是在创建播放条目时施加的，改了要重建预加载；
            // 当前这首要等下次切歌才生效
            engine.invalidatePreload()
        }
    }

    /// 是否把系统输出设备的采样率切到与当前文件一致。
    @Published public var sampleRateMatchingEnabled: Bool {
        didSet {
            guard oldValue != sampleRateMatchingEnabled else { return }
            Preferences.sampleRateMatchingEnabled = sampleRateMatchingEnabled
            engine.matchesOutputSampleRate = sampleRateMatchingEnabled
        }
    }

    @Published public var volume: Double {
        didSet {
            engine.volume = volume
            Preferences.volume = volume
        }
    }

    /// 右侧「正在播放」区的展示模式。
    @Published public var nowPlayingLayout: NowPlayingLayout {
        didSet {
            guard oldValue != nowPlayingLayout else { return }
            Preferences.nowPlayingLayout = nowPlayingLayout
        }
    }

    /// 磨砂背景的不透明度，下限见 `Preferences.minBackgroundOpacity`。
    @Published public var backgroundOpacity: Double {
        didSet {
            let clamped = Preferences.clampOpacity(backgroundOpacity)
            if clamped != backgroundOpacity {
                backgroundOpacity = clamped
                return
            }
            Preferences.backgroundOpacity = clamped
        }
    }

    @Published public var errorMessage: String?

    // MARK: - 内部

    private let engine = PlayerEngine()
    private var queue = PlaybackQueue()
    private var metadataTask: Task<Void, Never>?
    /// 连续播放失败次数。用来避免整目录都是坏文件时无限自动跳曲。
    private var consecutiveFailures = 0

    public var currentTrack: Track? { playingTrack }

    public init() {
        let mode = Preferences.playMode
        let vol = Preferences.volume
        self.playMode = mode
        self.volume = vol
        self.sortOrder = Preferences.sortOrder
        self.sortAscending = Preferences.sortAscending
        self.backgroundOpacity = Preferences.backgroundOpacity
        self.nowPlayingLayout = Preferences.nowPlayingLayout
        self.replayGainEnabled = Preferences.replayGainEnabled
        self.sampleRateMatchingEnabled = Preferences.sampleRateMatchingEnabled
        self.queue = PlaybackQueue(count: 0, mode: mode)

        engine.volume = vol
        engine.matchesOutputSampleRate = Preferences.sampleRateMatchingEnabled
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
        playingTrack = nil
        currentTime = 0
        duration = 0
        lyrics = []
        currentLyricIndex = nil
        isPlaying = false
        isScanning = true
        consecutiveFailures = 0
        // 换了曲库，旧关键词多半一条都匹配不上，留着只会看到空列表
        searchText = ""

        Task {
            let urls = await Task.detached(priority: .userInitiated) {
                LibraryScanner.scan(directory: folder)
            }.value

            self.library = urls.map(Track.init(url:))
            self.rebuildDisplayed()
            self.isScanning = false

            if self.library.isEmpty {
                self.errorMessage = "该文件夹下没有找到受支持的音频文件"
            }

            self.loadMetadataInBackground()
        }
    }

    /// 逐个补全元数据。
    ///
    /// 加载过程中只就地更新条目、不重排 —— 否则用户正在看的列表会随着元数据到位
    /// 不断跳动。全部加载完再统一重排一次。
    private func loadMetadataInBackground() {
        metadataTask = Task { [weak self] in
            guard let self else { return }
            let snapshot = self.library

            for (index, track) in snapshot.enumerated() {
                if Task.isCancelled { return }
                let loaded = await MetadataLoader.load(url: track.url)

                // 列表可能已被重新扫描，按 URL 校验后再写回
                guard self.library.indices.contains(index),
                      self.library[index].url == loaded.url else { continue }
                self.library[index] = loaded
                self.applyLoadedMetadataToDisplayed(loaded)
            }

            if Task.isCancelled { return }
            // 标题 / 歌手到位后，按这两个维度排序的结果才是对的
            if self.sortOrder != .fileOrder {
                self.rebuildDisplayed()
            }
        }
    }

    /// 把刚加载好的元数据同步到展示列表和「正在播放」，不改变顺序。
    private func applyLoadedMetadataToDisplayed(_ loaded: Track) {
        if let i = tracks.firstIndex(where: { $0.url == loaded.url }) {
            tracks[i] = loaded
        }

        guard playingTrack?.url == loaded.url else { return }
        playingTrack = loaded
        refreshLyrics(for: loaded)
        if duration == 0 { duration = loaded.duration }
    }

    // MARK: - 搜索与排序

    /// 重建展示列表并让播放队列跟上。
    ///
    /// 正在播放的曲目若仍在新列表里，就把队列位置对齐到它，播放不受影响；
    /// 若被过滤掉了，歌继续放，但列表中没有高亮项，此时按「下一首」会从列表头开始。
    private func rebuildDisplayed() {
        tracks = TrackFilter.apply(
            to: library,
            search: searchText,
            sort: sortOrder,
            ascending: sortAscending
        )

        queue.setCount(tracks.count)

        if let playingURL = playingTrack?.url,
           let index = tracks.firstIndex(where: { $0.url == playingURL }) {
            queue.select(index)
            currentIndex = index
        } else {
            queue.clearSelection()
            currentIndex = nil
        }

        // 列表变了，预判的「下一首」可能已经不对
        engine.invalidatePreload()
    }

    public func clearSearch() {
        searchText = ""
    }

    public func toggleSortDirection() {
        sortAscending.toggle()
    }

    // MARK: - 播放控制

    public func play(at index: Int) {
        guard tracks.indices.contains(index) else { return }
        queue.select(index)
        startCurrent()
    }

    public func togglePlayPause() {
        if playingTrack == nil {
            // 还没选歌时，播放键等同于从头开始
            if queue.next(auto: false) != nil {
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
        // 播放超过 3 秒时，「上一首」先回到本曲开头，符合常见播放器习惯
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

    public func cycleNowPlayingLayout() {
        nowPlayingLayout = nowPlayingLayout.next
    }

    // MARK: - 内部流转

    /// 手动切歌。自动推进由引擎的无缝队列负责，不走这里。
    private func advance(auto: Bool) {
        guard queue.next(auto: auto) != nil else {
            // 顺序播放到达列表末尾
            stop()
            return
        }
        startCurrent()
    }

    private func startCurrent() {
        guard let index = queue.current, tracks.indices.contains(index) else { return }
        let track = tracks[index]

        currentIndex = index
        playingTrack = track
        currentTime = 0
        duration = track.duration
        refreshLyrics(for: track)

        engine.load(playable(for: track), autoplay: true)
        isPlaying = engine.isPlaying
    }

    /// 引擎已无缝推进到下一首，这里只需把界面状态跟上。
    private func handleAutoAdvance(to url: URL) {
        // 推进播放队列。正常情况它给出的就是引擎已经切到的那首；
        // 若期间列表被排序/过滤改动过，就按 URL 重新对齐。
        let expected = queue.next(auto: true)

        if let expected, tracks.indices.contains(expected), tracks[expected].url == url {
            currentIndex = expected
        } else if let found = tracks.firstIndex(where: { $0.url == url }) {
            queue.select(found)
            currentIndex = found
        } else {
            // 这首已被搜索过滤掉，继续播但列表里不高亮
            currentIndex = nil
        }

        let track = currentIndex.map { tracks[$0] }
            ?? library.first { $0.url == url }
            ?? Track(url: url)

        playingTrack = track
        currentTime = 0
        duration = track.duration
        refreshLyrics(for: track)
        isPlaying = true
        consecutiveFailures = 0
    }

    /// 组装引擎需要的播放条目：URL + 归一化增益 + 采样率。
    private func playable(for track: Track) -> PlayableItem {
        let gain = replayGainEnabled ? (track.replayGain?.linearGain() ?? 1) : 1
        return PlayableItem(url: track.url, gain: gain, sampleRate: track.sampleRate)
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

        // 引擎会提前把下一首塞进队列缓冲以实现无缝切歌。
        // peekNext 不能有副作用 —— 此刻当前曲还在播，队列位置不能动。
        engine.provideNext = { [weak self] in
            guard let self,
                  let index = self.queue.peekNext(auto: true),
                  self.tracks.indices.contains(index) else { return nil }
            return self.playable(for: self.tracks[index])
        }

        engine.onAdvanced = { [weak self] url in
            self?.handleAutoAdvance(to: url)
        }

        engine.onQueueExhausted = { [weak self] in
            guard let self else { return }
            // 队列里没有下一首了。顺序播放到底就是停；随机模式一轮播完时
            // peekNext 拿不到新顺序，此处补一次真正的推进。
            if let next = self.queue.next(auto: true), self.tracks.indices.contains(next) {
                self.startCurrent()
            } else {
                self.stop()
            }
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
                self.playingTrack = nil
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
            if self.playingTrack?.duration == 0 {
                self.playingTrack?.duration = seconds
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
