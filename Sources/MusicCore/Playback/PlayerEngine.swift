import Foundation
import AVFoundation

/// 一条待播条目：文件地址 + 已算好的音量归一化系数 + 采样率。
public struct PlayableItem: Equatable, Sendable {
    public let url: URL
    /// 线性增益系数，1 表示不做处理。
    public let gain: Float
    /// 音频采样率（Hz），未知为 nil。
    public let sampleRate: Double?

    public init(url: URL, gain: Float = 1, sampleRate: Double? = nil) {
        self.url = url
        self.gain = gain
        self.sampleRate = sampleRate
    }
}

/// `AVQueuePlayer` 封装，支持**无缝切歌**。
///
/// 无缝的关键：当前曲开始播放后立刻把下一首也塞进队列，让它提前缓冲。
/// `AVQueuePlayer` 播完自动推进到下一条，中间没有加载空档 —— 这是
/// `AVPlayer` + `replaceCurrentItem` 做不到的（每次换曲都要重新加载）。
///
/// 下一首是谁由外部通过 `provideNext` 回调决定，引擎不关心播放顺序逻辑。
/// 所有回调都在主线程触发。
@MainActor
public final class PlayerEngine {

    // MARK: - 回调

    /// 每 0.1 秒回调一次当前播放位置（秒）。
    public var onProgress: ((Double) -> Void)?
    /// 已无缝推进到下一首。参数是新曲目的 URL。
    public var onAdvanced: ((URL) -> Void)?
    /// 当前曲播完且队列里没有下一首。
    public var onQueueExhausted: (() -> Void)?
    /// 加载或播放失败，参数是给用户看的描述。
    public var onError: ((String) -> Void)?
    /// 曲目时长就绪（秒）。
    public var onDurationResolved: ((Double) -> Void)?
    /// 引擎需要预加载下一首时调用。返回 nil 表示没有下一首。
    ///
    /// **不得有副作用** —— 调用时当前曲还在播，播放队列的位置不能动。
    public var provideNext: (() -> PlayableItem?)?

    // MARK: - 状态

    private let player = AVQueuePlayer()
    private var timeObserver: Any?
    private var statusObservation: NSKeyValueObservation?
    private var currentItemObservation: NSKeyValueObservation?

    /// 是否已经为当前曲目预加载过下一首，避免重复插入。
    private var hasPreloaded = false

    public private(set) var currentURL: URL?
    public private(set) var isPlaying = false

    /// 开启后每次换曲会把系统输出设备切到与文件相同的采样率。
    public var matchesOutputSampleRate = false

    public var volume: Double {
        get { Double(player.volume) }
        set { player.volume = Float(max(0, min(1, newValue))) }
    }

    public init() {
        player.actionAtItemEnd = .advance
        addPeriodicObserver()
        observeCurrentItem()
    }

    deinit {
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
        }
        statusObservation?.invalidate()
        currentItemObservation?.invalidate()
    }

    // MARK: - 传输控制

    /// 从头加载并播放 `item`，清空原有队列。用户主动点歌、切歌时走这里。
    public func load(_ item: PlayableItem, autoplay: Bool = true) {
        player.removeAllItems()
        hasPreloaded = false
        currentURL = item.url

        applySampleRateIfNeeded(item)

        let playerItem = makeItem(for: item)
        player.insert(playerItem, after: nil)
        observeStatus(of: playerItem)

        onProgress?(0)

        if autoplay {
            play()
        } else {
            isPlaying = false
        }

        preloadNextIfNeeded()
    }

    public func play() {
        guard player.currentItem != nil else { return }
        player.play()
        isPlaying = true
    }

    public func pause() {
        player.pause()
        isPlaying = false
    }

    public func togglePlayPause() {
        isPlaying ? pause() : play()
    }

    /// 停止：暂停并回到曲目开头。
    public func stop() {
        player.pause()
        isPlaying = false
        seek(to: 0)
    }

    /// 卸载全部曲目。
    public func unload() {
        player.pause()
        player.removeAllItems()
        statusObservation?.invalidate()
        statusObservation = nil
        hasPreloaded = false
        isPlaying = false
        currentURL = nil
        onProgress?(0)
    }

    public func seek(to seconds: Double) {
        let target = CMTime(seconds: max(0, seconds), preferredTimescale: 600)
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
        onProgress?(max(0, seconds))
    }

    /// 丢弃已预加载的下一首并重新预加载。
    ///
    /// 播放顺序、搜索、排序一变，原先预判的「下一首」就作废了。
    public func invalidatePreload() {
        for item in player.items().dropFirst() {
            player.remove(item)
        }
        hasPreloaded = false
        preloadNextIfNeeded()
    }

    // MARK: - 预加载

    private func preloadNextIfNeeded() {
        guard !hasPreloaded, player.currentItem != nil else { return }
        hasPreloaded = true

        guard let next = provideNext?() else { return }

        let item = makeItem(for: next)
        // canInsert 为 false 说明队列不接受（例如同一个 item 已在队列里）
        guard player.canInsert(item, after: player.items().last) else { return }
        player.insert(item, after: player.items().last)
    }

    private func makeItem(for playable: PlayableItem) -> AVPlayerItem {
        let asset = AVURLAsset(url: playable.url)
        let item = AVPlayerItem(asset: asset)
        applyGain(playable.gain, to: item, asset: asset)
        return item
    }

    /// 用 `AVAudioMix` 施加归一化增益。
    ///
    /// 不用 `player.volume` 是因为它的取值上限是 1，无法为偏轻的曲目提升音量，
    /// 而且那是用户的音量旋钮，两者必须分开。`AVAudioMix` 的增益可以大于 1。
    private func applyGain(_ gain: Float, to item: AVPlayerItem, asset: AVURLAsset) {
        guard gain != 1 else { return }

        Task { @MainActor in
            guard let track = try? await asset.loadTracks(withMediaType: .audio).first else { return }

            let parameters = AVMutableAudioMixInputParameters(track: track)
            parameters.setVolume(gain, at: .zero)

            let mix = AVMutableAudioMix()
            mix.inputParameters = [parameters]
            item.audioMix = mix
        }
    }

    /// 把输出设备切到与文件一致的采样率。
    ///
    /// 注意这与无缝播放天然冲突：相邻两首采样率不同时，设备切换会带来一次
    /// 明显的停顿。所以只在用户显式开启时才做。
    private func applySampleRateIfNeeded(_ item: PlayableItem) {
        guard matchesOutputSampleRate, let rate = item.sampleRate else { return }
        AudioDeviceManager.matchSampleRate(rate)
    }

    // MARK: - 观察者

    private func addPeriodicObserver() {
        let interval = CMTime(seconds: 0.1, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self else { return }
            let seconds = time.seconds
            guard seconds.isFinite else { return }
            MainActor.assumeIsolated {
                self.onProgress?(max(0, seconds))
            }
        }
    }

    /// `currentItem` 变化即代表队列自动推进了 —— 无缝切歌的检测点。
    private func observeCurrentItem() {
        currentItemObservation = player.observe(\.currentItem, options: [.new]) { [weak self] player, _ in
            guard let self else { return }
            Task { @MainActor in
                self.handleCurrentItemChange(player.currentItem)
            }
        }
    }

    private func handleCurrentItemChange(_ item: AVPlayerItem?) {
        guard let item else {
            // 队列空了：最后一首播完
            guard currentURL != nil else { return }
            isPlaying = false
            onQueueExhausted?()
            return
        }

        guard let url = (item.asset as? AVURLAsset)?.url else { return }
        // load() 自己插入的第一条也会触发这里，那不算「推进」
        guard url != currentURL else { return }

        currentURL = url
        hasPreloaded = false
        observeStatus(of: item)
        onProgress?(0)
        onAdvanced?(url)
        preloadNextIfNeeded()
    }

    private func observeStatus(of item: AVPlayerItem) {
        statusObservation?.invalidate()
        statusObservation = item.observe(\.status, options: [.new, .initial]) { [weak self] observed, _ in
            guard let self else { return }
            Task { @MainActor in
                switch observed.status {
                case .failed:
                    let reason = observed.error?.localizedDescription ?? "未知错误"
                    self.isPlaying = false
                    self.onError?("无法播放该文件：\(reason)")
                case .readyToPlay:
                    let seconds = observed.duration.seconds
                    if seconds.isFinite && seconds > 0 {
                        self.onDurationResolved?(seconds)
                    }
                default:
                    break
                }
            }
        }
    }
}
