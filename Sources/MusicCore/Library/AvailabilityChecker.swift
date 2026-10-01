import Foundation

/// 真正探测文件/卷是否可达的接口。可注入，测试用假实现模拟「存在」「不存在」
/// 「卷卡住」三种情况，不用真的碰文件系统。
public protocol FileProbe: Sendable {
    func fileExists(_ path: String) -> Bool
    func volumeReachable(_ root: String) -> Bool
}

public struct SystemFileProbe: FileProbe {
    public init() {}

    public func fileExists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }

    public func volumeReachable(_ root: String) -> Bool {
        FileManager.default.fileExists(atPath: root)
    }
}

public enum CheckPriority: Sendable {
    case high
    case low
}

/// 后台按需检查曲目可用性，结果写回 `AvailabilityStore`。
///
/// 按卷熔断（FR-021 ⑤）：外接卷/网络卷一旦探测为不可达，这个卷下的曲目全部判为
/// 不可用，不再逐个文件去试；结果缓存 10 秒后才重新探测，避免断线时每次检查都要
/// 等一轮超时。
public actor AvailabilityChecker {
    private let store: AvailabilityStore
    private let probe: FileProbe

    private var highQueue: [Track] = []
    private var lowQueue: [Track] = []
    /// 已经在某个队列里、还没处理到的 identity；用来去重，同一首歌不会排两次。
    private var queuedIdentities = Set<TrackIdentity>()
    private var workerTask: Task<Void, Never>?

    private var volumeCache: [String: (reachable: Bool, expiresAt: Date)] = [:]
    /// 正在探测、还没出结果的卷。同一个卷同时只有一次探测在跑；
    /// 探测卡着的时候，后来的请求不排队等它，直接按「不可达」处理。
    private var volumeProbing: Set<String> = []
    /// 每个卷根各自一条串行队列（F-14）；本机路径用 `"/"` 作为键。实例属性、
    /// 不是 static——一次卡住的探测只会拖累同一个卷/本机路径下的其它探测，
    /// 不会波及别的卷，更不会把本机启动盘上好好的文件也拖成「不可用」
    /// （FR-021 ①、TC-247）。
    private var probeQueues: [String: DispatchQueue] = [:]

    public init(store: AvailabilityStore, probe: FileProbe = SystemFileProbe()) {
        self.store = store
        self.probe = probe
    }

    /// 按 identity 去重后放入对应队列，立即返回。
    public func enqueue(_ tracks: [Track], priority: CheckPriority) {
        var added = false
        for track in tracks {
            guard queuedIdentities.insert(track.identity).inserted else { continue }
            switch priority {
            case .high: highQueue.append(track)
            case .low: lowQueue.append(track)
            }
            added = true
        }
        guard added else { return }
        startWorkerIfNeeded()
    }

    /// 离开页面时，把还没查到的 high 降级为 low，不丢弃、不打断正在检查的那个。
    public func demoteHigh() {
        guard !highQueue.isEmpty else { return }
        lowQueue.append(contentsOf: highQueue)
        highQueue.removeAll()
    }

    /// 点播时用，最多等 3 秒；卷已知不可达时立即返回 false。结果写回 store。
    public func checkNow(_ track: Track) async -> Bool {
        let result = await probeAvailability(track)
        await applyResult(result, for: track.identity)
        return result
    }

    // MARK: - 后台工作循环

    private func startWorkerIfNeeded() {
        guard workerTask == nil else { return }
        workerTask = Task { [weak self] in
            await self?.runWorker()
        }
    }

    private func runWorker() async {
        var availableBatch: [TrackIdentity] = []
        var unavailableBatch: [TrackIdentity] = []
        var lastFlush = Date()

        while true {
            let track: Track?
            if !highQueue.isEmpty {
                track = highQueue.removeFirst()
            } else if !lowQueue.isEmpty {
                track = lowQueue.removeFirst()
            } else {
                track = nil
            }
            guard let track else { break }
            queuedIdentities.remove(track.identity)

            let ok = await probeAvailability(track)
            if ok {
                availableBatch.append(track.identity)
            } else {
                unavailableBatch.append(track.identity)
            }

            if Date().timeIntervalSince(lastFlush) >= 0.1 {
                await flush(&availableBatch, &unavailableBatch)
                lastFlush = Date()
            }
        }

        await flush(&availableBatch, &unavailableBatch)
        workerTask = nil
    }

    private func flush(_ available: inout [TrackIdentity], _ unavailable: inout [TrackIdentity]) async {
        guard !available.isEmpty || !unavailable.isEmpty else { return }
        let availSnapshot = available
        let unavailSnapshot = unavailable
        await store.apply(available: availSnapshot, unavailable: unavailSnapshot)
        available.removeAll()
        unavailable.removeAll()
    }

    private func applyResult(_ ok: Bool, for identity: TrackIdentity) async {
        if ok {
            await store.apply(available: [identity], unavailable: [])
        } else {
            await store.apply(available: [], unavailable: [identity])
        }
    }

    // MARK: - 探测

    private func probeAvailability(_ track: Track) async -> Bool {
        let path = track.url.path
        let root = volumeRoot(for: path) ?? Self.localRoot
        if root != Self.localRoot {
            guard await isVolumeReachable(root) else { return false }
        }
        let queue = probeQueue(for: root)
        return await Self.probeWithTimeout(on: queue, seconds: 3, probe: probe) { $0.fileExists(path) } ?? false
    }

    /// 引擎报错时的快速复查（最多 1 秒）：文件确实不在了才标为不可用；
    /// 播放失败但文件还在（例如解码失败）不改变它原来的可用性。不查卷是否可达——
    /// 引擎已经打开失败，直接看这一个文件还在不在。
    public func checkAfterPlaybackError(_ track: Track) async {
        let path = track.url.path
        let root = volumeRoot(for: path) ?? Self.localRoot
        let queue = probeQueue(for: root)
        let exists = await Self.probeWithTimeout(on: queue, seconds: 1, probe: probe) { $0.fileExists(path) } ?? false
        guard !exists else { return }
        await applyResult(false, for: track.identity)
    }

    /// 本机路径（非 `/Volumes/...`）在 `probeQueues` 里的键。
    private static let localRoot = "/"

    /// 路径以 `/Volumes/<名称>/` 开头的，根是 `/Volumes/<名称>`；其余（本机启动盘）
    /// 返回 nil，调用方不探测，直接逐个文件检查。
    private func volumeRoot(for path: String) -> String? {
        guard path.hasPrefix("/Volumes/") else { return nil }
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        guard components.count >= 2 else { return nil }
        return "/" + components[0] + "/" + components[1]
    }

    /// 卷根对应的专用串行队列，没有就新建一个并记下来。
    private func probeQueue(for root: String) -> DispatchQueue {
        if let existing = probeQueues[root] { return existing }
        let queue = DispatchQueue(label: "com.macmusicplayer.availability-probe\(root)")
        probeQueues[root] = queue
        return queue
    }

    private func isVolumeReachable(_ root: String) async -> Bool {
        if let cached = volumeCache[root], cached.expiresAt > Date() {
            return cached.reachable
        }
        guard !volumeProbing.contains(root) else { return false }
        volumeProbing.insert(root)
        let queue = probeQueue(for: root)
        let result = await Self.probeWithTimeout(on: queue, seconds: 3, probe: probe) { $0.volumeReachable(root) } ?? false
        volumeProbing.remove(root)
        volumeCache[root] = (result, Date().addingTimeInterval(10))
        return result
    }

    /// 在指定队列上执行可能卡住的探测，外面用 `withCheckedContinuation` 和一个
    /// 定时器赛跑，谁先到谁 resume；`stat` 卡住时没办法取消，卡住的那次调用留在
    /// 后台自己结束，不重复派发（由调用方的 `volumeProbing`/去重队列保证）。
    ///
    /// **不能**用 `withTaskGroup` 实现这个赛跑：`withTaskGroup` 在闭包返回前会
    /// 隐式等待全部子任务完成，即使已经 `cancelAll()`——`Thread.sleep` 卡住的
    /// 探测不响应取消，会把整个函数拖到卡住的那次真正结束才返回，等于没有超时。
    ///
    /// **`queue` 必须是调用方按卷根取的专用队列**（F-14），不能是一个全局共用的
    /// 队列：一次卡住的探测会占住它，后面所有探测——哪怕是完全不相关的卷、完全
    /// 不卡的本机文件——都要排在它后面陪着空等，本机上好好的歌也会被拖到超时、
    /// 误判成不可用（FR-021 ①、TC-247）。按卷根分开队列后，卡住的只影响同一个
    /// 卷根，「同一个卷同时只探测一次」由 `volumeProbing` 逻辑层面去重，不依赖
    /// 队列本身的串行。
    private static func probeWithTimeout(
        on queue: DispatchQueue, seconds: TimeInterval, probe: FileProbe, _ work: @escaping @Sendable (FileProbe) -> Bool
    ) async -> Bool? {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool?, Never>) in
            let guard_ = ResumeOnce()

            queue.async {
                let result = work(probe)
                if guard_.tryResume() {
                    continuation.resume(returning: result)
                }
            }

            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
                if guard_.tryResume() {
                    continuation.resume(returning: nil)
                }
            }
        }
    }
}

/// 保证一个 continuation 只被 resume 一次：探测和超时定时器谁先到谁赢，
/// 另一边即使之后才完成，也只是发现自己没抢到，不会重复 resume。
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var resumed = false

    func tryResume() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !resumed else { return false }
        resumed = true
        return true
    }
}
