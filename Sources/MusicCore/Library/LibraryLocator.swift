import Foundation

/// 「定位当前播放的歌曲」的结果（T-016）。
public enum LocateResult: Equatable {
    /// 在 `displayed`（当前排序/搜索下）的下标。
    case found(Int)
    /// 在曲库里，但被搜索过滤掉了。
    case filteredOut
    /// 不在当前曲库文件夹（别的文件夹的歌单曲目、文件已被删除后刷新过、扫描还没扫到它）。
    case notInFolder
    /// 没有当前曲目。
    case noTrack
}

/// 纯函数：判断当前播放的歌曲在曲库列表里的位置，不碰任何状态，可完整单测。
public enum LibraryLocator {
    /// 比较一律用 `identity`，不用 `Track.id`（URL）——独立状态下 `playingTrack`
    /// 可能来自歌单或重启恢复数据，路径大小写可能和曲库不同（T-002）。
    public static func locate(
        playing: TrackIdentity?, displayed: [Track], libraryIndex: [TrackIdentity: Int]
    ) -> LocateResult {
        guard let playing else { return .noTrack }

        if let index = displayed.firstIndex(where: { $0.identity == playing }) {
            return .found(index)
        }

        if libraryIndex[playing] != nil {
            return .filteredOut
        }

        return .notInFolder
    }
}
