import Foundation
import SwiftUI
import AppKit
import Combine

/// UI 的唯一数据源：串联扫描、元数据、歌词、播放队列与播放引擎。
///
/// 曲库有两份：`library` 是扫描出来的全量（文件顺序，不动），`tracks` 是经过
/// 搜索过滤与排序后**实际展示**的列表。播放用的列表是 `nowPlaying`（`NowPlayingList`）：
/// 跟随状态下它是 `tracks` 的镜像，独立状态下由歌单点播或手动编辑产生，此时曲库的
/// 搜索、排序、刷新不再影响它（§3.1 两种状态）。
@MainActor
public final class PlayerViewModel: ObservableObject {

    // MARK: - 曲库

    /// 扫描得到的全量曲库，保持文件顺序。
    @Published public private(set) var library: [Track] = []
    /// `library` 里 identity 到下标的索引，随 `library` 整体重扫一起重建，O(1) 查找。
    /// 供 T-003 歌单详情页按路径把「曲库里已读好元数据的那份」显示出来（FR-012、FR-020）。
    @Published public private(set) var libraryIndex: [TrackIdentity: Int] = [:]
    /// 过滤 + 排序后的列表。曲库列表展示以它为准。
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

    // MARK: - 播放列表（PL）

    /// 播放用的列表：跟随曲库或独立编辑，见 `NowPlayingList`。
    @Published public private(set) var nowPlaying: NowPlayingList
    /// `nowPlaying` 的内容、状态、来源、当前曲目每变一次加 1。T-010 监听它保存。
    @Published public private(set) var nowPlayingRevision: Int = 0

    /// 当前曲目在 `nowPlaying.items` 里的下标，PL 页高亮用。
    public var nowPlayingIndex: Int? { nowPlaying.queue.current }

    /// 来源文字：曲库 / 歌单「{name}」（T-006）/ 已手动调整。
    public var nowPlayingSourceText: String {
        switch nowPlaying.source {
        case .library: return "曲库"
        case .songlist(let name): return "歌单「\(name)」"
        case .edited: return "已手动调整"
        }
    }

    /// PL 页顶部的一行说明文字。
    public var nowPlayingHeader: String {
        let count = nowPlaying.items.count
        guard count > 0 else { return "播放列表为空" }
        if let index = nowPlayingIndex, nowPlaying.items.indices.contains(index) {
            return "来源：\(nowPlayingSourceText) · 共 \(count) 首 · 当前第 \(index + 1) 首"
        }
        return "来源：\(nowPlayingSourceText) · 共 \(count) 首"
    }

    // MARK: - 播放状态

    /// 当前曲目在 `tracks` 里的下标。跟随状态下与 `nowPlayingIndex` 相同；
    /// 独立状态下按 `identity` 在 `tracks` 里重新找。曲库列表高亮用。
    @Published public private(set) var currentIndex: Int?
    /// 正在播放的曲目本身。不受过滤影响，右侧「正在播放」区读这个。
    @Published public private(set) var playingTrack: Track?
    /// 正在播的文件已不在曲库中（被删除或移走）。歌还能放完，但列表里没有它了。
    @Published public private(set) var playingTrackMissing = false
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
            nowPlaying.queue.mode = playMode
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
    /// 提示性文字（T-008），和 `errorMessage` 分开；设置后 3 秒自动置 nil。
    @Published public private(set) var notice: String?

    // MARK: - 可用性（T-007）

    /// 按 identity 集中存放的可用性；曲库列表、PL 页、歌单详情页都读它。
    public let availability = AvailabilityStore()

    // MARK: - 内部

    private let engine = PlayerEngine()
    private let availabilityChecker: AvailabilityChecker
    private var metadataTask: Task<Void, Never>?
    private var noticeTask: Task<Void, Never>?
    /// 连续播放失败次数。用来避免整目录都是坏文件时无限自动跳曲。
    private var consecutiveFailures = 0
    /// 每次编辑（T-008）+1，供 E-2 竞态判断预加载是否已作废（§4.5）。
    private var listVersion = 0
    /// `provideNext` 把下一首塞进引擎缓冲时记下当时的 `listVersion`。
    private var preloadedVersion = 0

    // MARK: - 重启恢复播放列表（T-010）

    private let nowPlayingStore = NowPlayingStore()
    private var cancellables = Set<AnyCancellable>()
    /// `restoreNowPlaying` 只执行一次，和 `restoreLastSession` 一样用 guard。
    private var nowPlayingRestored = false
    /// 保存失败只提示一次（本次运行），编辑照样生效，下一次变化照常重试（FR-027 ③）。
    private var saveFailureNotified = false

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
        self.nowPlaying = NowPlayingList(mode: mode)
        self.availabilityChecker = AvailabilityChecker(store: availability)

        engine.volume = vol
        engine.matchesOutputSampleRate = Preferences.sampleRateMatchingEnabled
        wireEngineCallbacks()
        wireNowPlayingPersistence()
    }

    /// App 启动后调用：若上次的文件夹仍存在则自动重扫。
    public func restoreLastSession() {
        // 视图重建时 .task 会再次触发，已经有曲库就不要重扫
        guard folderURL == nil, let folder = Preferences.lastFolder else { return }
        scan(folder: folder)
    }

    // MARK: - 重启恢复播放列表（T-010）

    private func wireNowPlayingPersistence() {
        $nowPlayingRevision
            .dropFirst()
            .debounce(for: .milliseconds(500), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                self?.saveNowPlayingInBackground()
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)
            .sink { [weak self] _ in
                self?.flushNowPlaying()
            }
            .store(in: &cancellables)
    }

    /// `ContentView.task` 里、`restoreLastSession()` 之前调用；只执行一次。
    public func restoreNowPlaying() async {
        guard !nowPlayingRestored else { return }
        nowPlayingRestored = true

        guard let snapshot = nowPlayingStore.load() else { return }

        switch snapshot.state {
        case .independent:
            let items = snapshot.items.map { entry -> Track in
                var track = Track(url: URL(fileURLWithPath: entry.path))
                track.title = entry.title
                track.artist = entry.artist
                track.album = entry.album
                track.duration = entry.duration
                return track
            }
            let current = snapshot.currentPath.flatMap { path in items.firstIndex(where: { $0.url.path == path }) }
            nowPlaying.restoreIndependent(items, current: current, source: snapshot.source)

            // 恢复「当前曲目」但不加载引擎：不自动播放、不恢复进度（方案 §4.2，Mac 差异）。
            if let current, items.indices.contains(current) {
                let track = items[current]
                playingTrack = track
                playingTrackMissing = false
                isPlaying = false
                currentTime = 0
                duration = track.duration
                refreshLyrics(for: track)
            }
            recomputeCurrentIndex()
            bumpRevision()
            await availabilityChecker.enqueue(items, priority: .high)

        case .followLibrary:
            if let currentPath = snapshot.currentPath {
                nowPlaying.pendingFollowCurrent = TrackIdentity(path: currentPath)
            }
        }
    }

    /// 每次 `nowPlayingRevision` 变化去抖 500 ms 后调用，在后台线程写盘——
    /// `store.save` 是阻塞的磁盘 I/O（含 `fsync`），不能占用主线程。
    private func saveNowPlayingInBackground() {
        let snapshot = nowPlaying.snapshot(currentTrack: playingTrack)
        let store = nowPlayingStore
        Task.detached(priority: .utility) { [weak self] in
            let reason = store.save(snapshot)
            guard let reason else { return }
            await MainActor.run {
                self?.handleNowPlayingSaveFailure(reason)
            }
        }
    }

    /// 退出（`willTerminate`）时调用：取消去抖，不管有没有变化都同步写一次
    /// （FR-028 ④）。必须同步——`willTerminate` 返回后进程就结束了。
    public func flushNowPlaying() {
        let snapshot = nowPlaying.snapshot(currentTrack: playingTrack)
        _ = nowPlayingStore.save(snapshot)
    }

    private func handleNowPlayingSaveFailure(_ reason: String) {
        guard !saveFailureNotified else { return }
        saveFailureNotified = true
        showNotice("播放列表未能保存，重启后可能无法恢复")
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

    /// 切换到新文件夹：停止播放、清空搜索、从零重建曲库。
    public func scan(folder: URL) {
        metadataTask?.cancel()
        engine.unload()

        folderURL = folder
        Preferences.lastFolder = folder

        playingTrack = nil
        playingTrackMissing = false
        currentTime = 0
        duration = 0
        lyrics = []
        currentLyricIndex = nil
        isPlaying = false
        consecutiveFailures = 0
        // 换了曲库，旧关键词多半一条都匹配不上，留着只会看到空列表
        searchText = ""

        // 立即清掉队列的选中项（与基线一致，不等异步扫描完成才清空高亮）。
        // 独立状态下 items 保留（FR-024 ③，T-009 验收）；跟随状态下 items
        // 由下面的 performScan → rebuildDisplayed → syncFromLibrary 换成新曲库。
        nowPlaying.detachCurrent()
        bumpRevision()
        recomputeCurrentIndex()

        performScan(folder: folder, reportEmpty: true)
    }

    /// 重新扫描当前文件夹，把新增 / 删除的文件同步进来。
    ///
    /// 与 `scan(folder:)` 的区别：**不打断播放**，也不动搜索词和排序。
    /// 已经读过元数据的文件会原样保留，不重复读盘。
    public func refreshLibrary() {
        guard let folder = folderURL, !isScanning else { return }
        metadataTask?.cancel()
        performScan(folder: folder, reportEmpty: false)
    }

    private func performScan(folder: URL, reportEmpty: Bool) {
        isScanning = true

        Task {
            let urls = await Task.detached(priority: .userInitiated) {
                LibraryScanner.scan(directory: folder)
            }.value

            // 复用已有条目，避免重扫时把整库的元数据全部重读一遍
            let known = Dictionary(self.library.map { ($0.url, $0) }, uniquingKeysWith: { first, _ in first })
            self.library = urls.map { known[$0] ?? Track(url: $0) }
            self.rebuildLibraryIndex()

            self.rebuildDisplayed()
            self.isScanning = false

            if self.library.isEmpty && reportEmpty {
                self.errorMessage = "该文件夹下没有找到受支持的音频文件"
            }

            // T-007/T-009（刷新曲库之后）：扫描到的曲目一律判为可用——扫描本身就证明
            // 文件存在；apply 必须排在 enqueue 前面，不然刚恢复的文件会先被旧结果盖住。
            // 独立状态下 PL 的 items 不是新曲库的一部分，额外用 high 优先级复查一遍
            // （例如卷刚恢复，之前判的不可用要更新）；跟随状态下 items 就是新曲库，
            // 已经在上面全量标可用了，不用再查一次。
            self.availability.apply(available: self.library.map(\.identity), unavailable: [])
            if self.nowPlaying.state == .independent {
                await self.availabilityChecker.enqueue(self.nowPlaying.items, priority: .high)
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
                // 重扫时大部分条目已经读过，跳过它们
                if track.metadataLoaded { continue }
                let loaded = await MetadataLoader.load(url: track.url)

                // 列表可能已被重新扫描，按 URL 校验后再写回
                guard self.library.indices.contains(index),
                      self.library[index].identity == loaded.identity else { continue }
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
        if let i = tracks.firstIndex(where: { $0.identity == loaded.identity }) {
            tracks[i] = loaded
        }

        guard playingTrack?.identity == loaded.identity else { return }
        playingTrack = loaded
        refreshLyrics(for: loaded)
        if duration == 0 { duration = loaded.duration }
    }

    // MARK: - 搜索与排序

    /// 重建展示列表并让播放列表跟上。
    ///
    /// 跟随状态：正在播放的曲目若仍在新列表里，就把队列位置对齐到它，播放不受影响；
    /// 若被过滤掉了，歌继续放，但列表中没有高亮项，此时按「下一首」会从列表头开始。
    /// 独立状态：只重建 `tracks`，PL 的内容和队列都不动。
    private func rebuildDisplayed() {
        // 先记住当前曲目在旧列表里的序号，它从新列表消失时要靠这个定位
        let previousIndex = currentIndex
        // T-010：调用 syncFromLibrary 之前先看有没有待定位的重启恢复目标——
        // 它会在这次调用里被消费掉（找到找不到都会清空），事后没法再判断「刚刚是不是消费了它」。
        let hadPendingFollowCurrent = nowPlaying.pendingFollowCurrent != nil

        tracks = TrackFilter.apply(
            to: library,
            search: searchText,
            sort: sortOrder,
            ascending: sortAscending
        )

        if nowPlaying.state == .followLibrary {
            nowPlaying.syncFromLibrary(tracks, playing: playingTrack?.identity, previousIndex: previousIndex)
            // 列表变了，预判的「下一首」可能已经不对
            engine.invalidatePreload()

            // T-010：这次 syncFromLibrary 刚好消费了重启恢复的定位目标——找到了就把
            // playingTrack 也设上，不加载引擎（方案 §4.2）；找不到（pendingFollowCurrent
            // 被清空但 queue.current 仍是 nil）就没有当前曲目，什么都不做。
            if hadPendingFollowCurrent, nowPlaying.pendingFollowCurrent == nil,
               let index = nowPlaying.queue.current, nowPlaying.items.indices.contains(index) {
                let track = nowPlaying.items[index]
                playingTrack = track
                playingTrackMissing = false
                isPlaying = false
                currentTime = 0
                duration = track.duration
                refreshLyrics(for: track)
            }
        }

        recomputeCurrentIndex()
        updatePlayingTrackMissing()
        bumpRevision()
    }

    private func rebuildLibraryIndex() {
        // 同上：identity 相同的重复项保留第一次出现的下标，不能用 uniqueKeysWithValues。
        libraryIndex = Dictionary(library.enumerated().map { ($1.identity, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// 按 `nowPlaying.state` 重新计算 `currentIndex`。
    private func recomputeCurrentIndex() {
        switch nowPlaying.state {
        case .followLibrary:
            // queue.current 指向的曲目可能已经不是 playingTrack 了（引擎切到的歌不在
            // items 里时，队列已经前进，但 playingTrack 还没跟上，见 handleAutoAdvance）。
            if let index = nowPlaying.queue.current,
               nowPlaying.items.indices.contains(index),
               nowPlaying.items[index].identity == playingTrack?.identity {
                currentIndex = index
            } else {
                currentIndex = nil
            }
        case .independent:
            if let identity = playingTrack?.identity {
                currentIndex = tracks.firstIndex(where: { $0.identity == identity })
            } else {
                currentIndex = nil
            }
        }
    }

    /// 正在播的曲目是否已经不在曲库中。
    ///
    /// 判据是**曲库**而不是展示列表 —— 被搜索过滤掉不等于文件没了，
    /// 只有重扫后曲库里都找不到，才说明文件真的被删除或移走了。
    private func updatePlayingTrackMissing() {
        guard let identity = playingTrack?.identity else {
            playingTrackMissing = false
            return
        }
        playingTrackMissing = !library.contains { $0.identity == identity }
    }

    public func clearSearch() {
        searchText = ""
    }

    public func toggleSortDirection() {
        sortAscending.toggle()
    }

    // MARK: - 播放控制

    /// 在曲库点播。不可用时（T-007）提示「找不到该文件」，当前播放和播放列表都不变。
    public func play(at index: Int) {
        guard tracks.indices.contains(index) else { return }
        let track = tracks[index]
        Task {
            guard await self.isPlayable(track) else {
                self.errorMessage = "找不到该文件：\(track.url.path)"
                return
            }
            // 等检查结果的这段时间列表可能变过，按原下标重新校验一次身份再落地。
            guard self.tracks.indices.contains(index), self.tracks[index].identity == track.identity else { return }
            self.nowPlaying.playFromLibrary(self.tracks, at: index)
            self.bumpRevision()
            self.startCurrent()
        }
    }

    /// 在播放列表页双击：只切换播放位置，状态和来源不变。不可用时同 `play(at:)`。
    public func playInNowPlaying(at index: Int) {
        guard nowPlaying.items.indices.contains(index) else { return }
        let track = nowPlaying.items[index]
        Task {
            guard await self.isPlayable(track) else {
                self.errorMessage = "找不到该文件：\(track.url.path)"
                return
            }
            guard self.nowPlaying.items.indices.contains(index),
                  self.nowPlaying.items[index].identity == track.identity else { return }
            self.nowPlaying.selectInList(index)
            self.bumpRevision()
            self.startCurrent()
        }
    }

    // MARK: - 播放歌单（T-006）

    /// 歌单详情页双击某一行。`displayed` 是详情页当前显示的曲目（T-004 的
    /// `displayedTracks`，T-012 之后是搜索结果），`name` 是当前歌单名。
    public func playSonglist(_ displayed: [Track], at index: Int, name: String) async {
        guard displayed.indices.contains(index) else { return }
        let track = displayed[index]
        guard await isPlayable(track) else {
            errorMessage = "找不到该文件：\(track.url.path)"
            return
        }
        nowPlaying.playFromSonglist(displayed, at: index, name: name)
        bumpRevision()
        startCurrent()
    }

    /// 歌单详情页顶部「播放全部」。从第 0 首开始；第 0 首不可用就往后找第一首可用的；
    /// 全部不可用时显示提示，播放列表不变。
    public func playSonglistAll(_ displayed: [Track], name: String) async {
        guard !displayed.isEmpty else { return }
        guard let index = await firstPlayable(in: displayed, from: 0) else {
            errorMessage = "列表中的音频都无法播放，已停止"
            return
        }
        nowPlaying.playFromSonglist(displayed, at: index, name: name)
        bumpRevision()
        startCurrent()
    }

    /// 点播时用：最多等 3 秒的实时检查（不看缓存的可用性结果，卷已知不可达时立即
    /// 返回 false）。结果写回 `availability`，供列表下次重绘时显示。
    public func isPlayable(_ track: Track) async -> Bool {
        await availabilityChecker.checkNow(track)
    }

    /// 从 `startIndex` 往后找第一首已知可用的（只看已有结果，不等待检查），
    /// 给「播放全部」用。
    public func firstPlayable(in tracks: [Track], from startIndex: Int) async -> Int? {
        guard startIndex >= 0, startIndex < tracks.count else { return nil }
        for index in startIndex..<tracks.count where availability.isAvailable(tracks[index].identity) {
            return index
        }
        return nil
    }

    /// 打开某个歌单/播放列表页、或程序启动时调用：这批曲目用 high 优先级检查（T-007 §2.3）。
    public func checkAvailabilityHigh(_ tracks: [Track]) {
        Task { await availabilityChecker.enqueue(tracks, priority: .high) }
    }

    /// 程序启动时对全部歌单的曲目用的低优先级检查（T-007 §2.3）。
    public func checkAvailabilityLow(_ tracks: [Track]) {
        Task { await availabilityChecker.enqueue(tracks, priority: .low) }
    }

    /// 离开歌单/播放列表页时调用：把还没查完的 high 降级为 low，不丢弃、不重新派发。
    public func demoteAvailabilityChecks() {
        Task { await availabilityChecker.demoteHigh() }
    }

    // MARK: - 播放列表编辑（T-008）

    /// 下一首播放（FR-004）。
    public func playNext(_ tracksToInsert: [Track]) {
        let result = nowPlaying.playNext(tracksToInsert, playing: playingTrack?.identity)
        finishEdit(result, notice: result.relocated > 0 ? "已调整到下一首" : nil)
    }

    /// 加到播放列表末尾（FR-005）。
    public func appendToNowPlaying(_ tracksToInsert: [Track]) {
        let result = nowPlaying.append(tracksToInsert, playing: playingTrack?.identity)
        let notice = result.relocated > 0 ? "有 \(result.relocated) 首已在播放列表中，已调整到末尾" : nil
        finishEdit(result, notice: notice)
    }

    /// 从播放列表移除（FR-006）。
    public func removeFromNowPlaying(at indices: IndexSet) {
        let result = nowPlaying.remove(at: indices)
        finishEdit(result, notice: nil)
    }

    /// 拖动排序（FR-007）。
    public func moveInNowPlaying(from: Int, to: Int) {
        let result = nowPlaying.move(from: from, to: to)
        finishEdit(result, notice: nil)
    }

    /// 清空播放列表（FR-008）。ViewModel 侧先停止播放、没有当前曲目，再清空列表。
    public func clearNowPlaying() {
        clearCurrentTrack()
        nowPlaying.clear()
        engine.invalidatePreload()
        listVersion += 1
        bumpRevision()
        recomputeCurrentIndex()
    }

    /// 每个编辑命令的收尾（changed == true 时）：让预判的下一首作废、推进版本号、
    /// 发布状态变化、按需弹提示。
    private func finishEdit(_ result: EditResult, notice noticeText: String?) {
        guard result.changed else { return }
        engine.invalidatePreload()
        listVersion += 1
        bumpRevision()
        recomputeCurrentIndex()
        if let noticeText {
            setNotice(noticeText)
        }
    }

    /// 供 `SonglistService`（T-004）等外部模块弹提示，和内部编辑命令共用同一套
    /// 3 秒自动消失的逻辑。
    public func showNotice(_ text: String) {
        setNotice(text)
    }

    private func setNotice(_ text: String) {
        noticeTask?.cancel()
        notice = text
        noticeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            self?.notice = nil
        }
    }

    /// 放完后「没有当前曲目」的收尾（Mac 特有，FR-006 ①③、§3.1）。
    /// 只在独立状态、且正在播的这首已经不在 `items` 里时调用；跟随状态下
    /// 当前曲目被搜索过滤掉时基线的行为是保留，不做这一步。
    private func clearCurrentTrack() {
        engine.unload()
        playingTrack = nil
        playingTrackMissing = false
        isPlaying = false
        currentTime = 0
        duration = 0
        lyrics = []
        currentLyricIndex = nil
        recomputeCurrentIndex()
    }

    public func togglePlayPause() {
        if playingTrack == nil {
            // 还没选歌时，播放键等同于从头开始
            if nowPlaying.queue.next(auto: false) != nil {
                startCurrent()
            }
            return
        }
        // T-010：重启恢复出来的当前曲目，引擎还没加载过（不自动播放、不恢复进度）；
        // 基线不会出现「有当前曲目但引擎没加载」这种状态，这个分支不影响基线行为。
        if engine.currentURL == nil {
            startCurrent()
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
        guard skippingUnavailable({ self.nowPlaying.queue.previous() }) != nil else { return }
        startCurrent()
        bumpRevision()
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
    ///
    /// T-007：拿到的曲目已知不可用时，继续同方向走，最多 `items.count` 步；
    /// 一直没有可用的，按顺序播放到达末尾一样停止（§4.2 的停止流程在 `onError`
    /// 连续失败达到整轮时也会触发，两处共用同一套「没有可用曲目」的收尾）。
    private func advance(auto: Bool) {
        guard skippingUnavailable({ self.nowPlaying.queue.next(auto: auto) }) != nil else {
            stop()
            collapseCurrentTrackIfOrphaned()
            return
        }
        startCurrent()
        bumpRevision()
    }

    /// `next`/`previous` 拿到的下标已知不可用时，反复调用同一个 `step()` 继续往
    /// 同方向走，最多 `items.count` 次，避免全部不可用时死循环；不修改 `items`
    /// （T-007 ①：不自动删除不可用曲目）。`step()` 连续两次给出同一个下标
    /// （单曲循环卡在同一首不可用的歌上、或顺序播放在边界上已经走不动）时提前
    /// 停手，视为「这个方向上找不到可用的」。
    private func skippingUnavailable(_ step: () -> Int?) -> Int? {
        var index = step()
        var steps = 0
        var seen = Set<Int>()
        while let i = index {
            guard nowPlaying.items.indices.contains(i) else { return nil }
            if availability.isAvailable(nowPlaying.items[i].identity) {
                return i
            }
            guard steps < nowPlaying.items.count, seen.insert(i).inserted else { return nil }
            steps += 1
            index = step()
        }
        return nil
    }

    /// 顺序播放到头要停止时，如果独立状态下正在播的这首已经不在 `items` 里
    /// （被移除后放完了），就没有当前曲目了（Mac 特有，FR-006 ①③、§3.1）。
    /// 跟随状态下不做这一步：那种情况是当前曲目被搜索过滤掉，基线的行为是保留。
    private func collapseCurrentTrackIfOrphaned() {
        guard nowPlaying.state == .independent,
              let identity = playingTrack?.identity,
              nowPlaying.index(of: identity) == nil else { return }
        clearCurrentTrack()
    }

    private func startCurrent() {
        guard let index = nowPlaying.queue.current, nowPlaying.items.indices.contains(index) else { return }
        let track = nowPlaying.items[index]

        playingTrack = track
        playingTrackMissing = false
        currentTime = 0
        duration = track.duration
        refreshLyrics(for: track)
        recomputeCurrentIndex()

        engine.load(playable(for: track), autoplay: true)
        isPlaying = engine.isPlaying
    }

    /// 引擎已无缝推进到下一首，这里只需把界面状态跟上。
    private func handleAutoAdvance(to url: URL) {
        let identity = TrackIdentity(url: url)
        let expected = nowPlaying.queue.next(auto: true)
        let expectedMatched = expected != nil
            && nowPlaying.items.indices.contains(expected!)
            && nowPlaying.items[expected!].identity == identity

        // E-2（§4.5）：先判断预加载是否已经被编辑作废，如果是，直接按队列原本预判的
        // 那首（items[expected]）重新加载——**不能**先按 identity 把队列对齐到引擎
        // 实际切到的这首再加载，那样加载的就是同一首（刚切过去的那首），会从头重播
        // 一遍，而编辑后本该紧接着放的那首反而被跳过了。
        if nowPlaying.state == .independent,
           preloadedVersion != listVersion,
           let expected, nowPlaying.items.indices.contains(expected),
           !expectedMatched {
            let track = nowPlaying.items[expected]
            #if DEBUG
            print("[NowPlaying] preload invalidated by edit")
            #endif
            engine.load(playable(for: track), autoplay: true)
            playingTrack = track
            currentTime = 0
            duration = track.duration
            refreshLyrics(for: track)
            isPlaying = true
            consecutiveFailures = 0
            recomputeCurrentIndex()
            updatePlayingTrackMissing()
            bumpRevision()
            return
        }

        // 正常情况：队列给出的就是引擎已经切到的那首；若期间列表被排序/过滤/编辑
        // 改动过，就按 identity 重新对齐（跟随状态完全走这条）。
        if !expectedMatched, let found = nowPlaying.index(of: identity) {
            nowPlaying.selectInList(found)
        }
        // 都找不到：这首已经不在 PL 里了，继续播但列表里不高亮

        // 只在 items[current] 确实是引擎切到的这首时才使用它；
        // 队列已经前进但这首不在 items 里（两个分支都没命中）时，不能想当然地
        // 用 items[current]（那是队列里另一首歌），必须按 identity 去 library 里找。
        let inList = nowPlaying.queue.current.flatMap { index -> Track? in
            guard nowPlaying.items.indices.contains(index), nowPlaying.items[index].identity == identity else {
                return nil
            }
            return nowPlaying.items[index]
        }
        let track = inList
            ?? library.first { $0.identity == identity }
            ?? Track(url: url)

        playingTrack = track
        currentTime = 0
        duration = track.duration
        refreshLyrics(for: track)
        isPlaying = true
        consecutiveFailures = 0
        recomputeCurrentIndex()
        updatePlayingTrackMissing()
        bumpRevision()
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

    private func bumpRevision() {
        nowPlayingRevision += 1
    }

    private func wireEngineCallbacks() {
        engine.onProgress = { [weak self] seconds in
            guard let self else { return }
            self.currentTime = seconds
            self.updateLyricHighlight(at: seconds)
        }

        // 引擎会提前把下一首塞进队列缓冲以实现无缝切歌。
        // peekNextWhere 不能有副作用 —— 此刻当前曲还在播，队列位置不能动。
        // T-007：跳过已知不可用的曲目，不然会预加载一首打不开的文件。
        engine.provideNext = { [weak self] in
            guard let self,
                  let index = self.nowPlaying.queue.peekNextWhere(
                      { self.nowPlaying.items.indices.contains($0)
                          && self.availability.isAvailable(self.nowPlaying.items[$0].identity) },
                      auto: true
                  ),
                  self.nowPlaying.items.indices.contains(index) else { return nil }
            self.preloadedVersion = self.listVersion
            return self.playable(for: self.nowPlaying.items[index])
        }

        engine.onAdvanced = { [weak self] url in
            self?.handleAutoAdvance(to: url)
        }

        engine.onQueueExhausted = { [weak self] in
            guard let self else { return }
            // 队列里没有下一首了。顺序播放到底就是停；随机模式一轮播完时
            // peekNext 拿不到新顺序，此处补一次真正的推进。
            if let next = self.nowPlaying.queue.next(auto: true), self.nowPlaying.items.indices.contains(next) {
                self.startCurrent()
                self.bumpRevision()
            } else {
                self.stop()
                self.collapseCurrentTrackIfOrphaned()
            }
        }

        engine.onError = { [weak self] message in
            guard let self else { return }
            self.errorMessage = message
            self.isPlaying = false

            // T-007：在基线逻辑之前，后台复查一下这首是不是文件真的不见了，
            // 不存在就标为不可用，供下次切歌/预加载跳过；不阻塞后面的自动跳过。
            if let failedTrack = self.playingTrack {
                Task { await self.availabilityChecker.checkAfterPlaybackError(failedTrack) }
            }

            // 坏文件不该卡住播放，自动跳过；但整个列表都放不出来时必须停下，
            // 否则会在队列里无限打转。
            self.consecutiveFailures += 1
            guard self.consecutiveFailures < max(1, self.nowPlaying.items.count) else {
                self.errorMessage = "列表中的音频都无法播放，已停止"
                self.engine.unload()
                self.playingTrack = nil
                self.recomputeCurrentIndex()
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
