import Foundation

/// 曲目可用性的集中存放（T-007）。`Track` 是值类型，同一首歌在曲库、歌单、播放列表里
/// 各有一份拷贝，可用性不能挂在 `Track` 上（检查一次只能更新其中一份），改成按
/// `TrackIdentity` 集中存放，三处都读同一份结果。
@MainActor
public final class AvailabilityStore: ObservableObject {
    /// 默认为空，也就是全部按可用显示（FR-021 ⑥）；只记不可用的，比记全量可用更省。
    @Published public private(set) var unavailable: Set<TrackIdentity> = []

    public init() {}

    public func isAvailable(_ id: TrackIdentity) -> Bool {
        !unavailable.contains(id)
    }

    /// 由 `AvailabilityChecker` 批量回写：每 100 ms 合并一次，只发布一次，
    /// 避免检查结果密集返回时（例如扫一个上万首的卷）让所有列表跟着连续重绘。
    public func apply(available: [TrackIdentity], unavailable newlyUnavailable: [TrackIdentity]) {
        guard !available.isEmpty || !newlyUnavailable.isEmpty else { return }
        var set = unavailable
        for id in available { set.remove(id) }
        for id in newlyUnavailable { set.insert(id) }
        guard set != unavailable else { return }
        unavailable = set
    }
}
