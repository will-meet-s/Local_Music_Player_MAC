import Foundation
import AVFoundation

/// `AVPlayer` 的薄封装：加载、播放、暂停、停止、跳转、音量，并向外抛出进度 / 结束 / 错误回调。
///
/// 所有回调都在主线程触发。
@MainActor
public final class PlayerEngine {

    /// 每 0.1 秒回调一次当前播放位置（秒）。
    public var onProgress: ((Double) -> Void)?
    /// 当前曲目自然播放结束。
    public var onFinish: (() -> Void)?
    /// 加载或播放失败，参数是给用户看的描述。
    public var onError: ((String) -> Void)?
    /// 曲目时长就绪（秒）。文件元数据里没有时长时不会触发。
    public var onDurationResolved: ((Double) -> Void)?

    private let player = AVPlayer()
    private var timeObserver: Any?
    private var statusObservation: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?

    public private(set) var currentURL: URL?
    public private(set) var isPlaying = false

    public var volume: Double {
        get { Double(player.volume) }
        set { player.volume = Float(max(0, min(1, newValue))) }
    }

    public init() {
        player.actionAtItemEnd = .pause
        addPeriodicObserver()
    }

    deinit {
        // AVPlayer 的观察者必须显式移除，否则会泄漏并在对象销毁后继续回调。
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
        }
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        statusObservation?.invalidate()
    }

    // MARK: - 传输控制

    /// 加载并立即播放 `url`。
    public func load(url: URL, autoplay: Bool = true) {
        teardownItemObservers()

        currentURL = url
        let item = AVPlayerItem(url: url)
        player.replaceCurrentItem(with: item)
        observe(item: item)

        onProgress?(0)

        if autoplay {
            play()
        } else {
            isPlaying = false
        }
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

    /// 停止：暂停并回到曲目开头（区别于暂停，进度归零）。
    public func stop() {
        player.pause()
        isPlaying = false
        seek(to: 0)
    }

    /// 卸载当前曲目（列表清空、播放列表结束时用）。
    public func unload() {
        teardownItemObservers()
        player.pause()
        player.replaceCurrentItem(with: nil)
        isPlaying = false
        currentURL = nil
        onProgress?(0)
    }

    public func seek(to seconds: Double) {
        let target = CMTime(seconds: max(0, seconds), preferredTimescale: 600)
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
        onProgress?(max(0, seconds))
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

    private func observe(item: AVPlayerItem) {
        statusObservation = item.observe(\.status, options: [.new]) { [weak self] observed, _ in
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

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated {
                self.isPlaying = false
                self.onFinish?()
            }
        }
    }

    private func teardownItemObservers() {
        statusObservation?.invalidate()
        statusObservation = nil
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
    }
}
