import Foundation

/// 一次批量加歌的结果（T-004）。
public struct AddResult: Equatable, Sendable {
    /// 新加入的首数。
    public var added: Int
    /// 因为已经在歌单里而跳过的首数（新建歌单时恒为 0）。
    public var skipped: Int
    public var songlistName: String

    /// 提示文字（T-004 §2.4）。「添加到歌单」菜单和 F-12 起 `ContentView` 的新建歌单
    /// 流程共用同一份措辞，不各写一份。
    public var noticeText: String {
        if skipped == 0 {
            return "已添加 \(added) 首到「\(songlistName)」"
        } else if added > 0 {
            return "已添加 \(added) 首到「\(songlistName)」，\(skipped) 首已存在"
        } else {
            return "\(skipped) 首已存在，「\(songlistName)」没有变化"
        }
    }
}

/// F-12/F-13：「新建歌单…」等待创建的曲目。`id` 是实例的固定字段，创建一次之后不再变——
/// 之前 `ContentView` 在 `.sheet(item:)` 的 `get` 里现取现造一个包装值，每次视图重绘都会
/// 生成新 `UUID()`；播放中 `currentTime` 高频发布导致 `ContentView` 频繁重绘，sheet 的
/// identity 跟着频繁变化，SwiftUI 把它当成「换了一个 sheet」处理，关了再弹，输入框里正在
/// 打的字每次都被清空（F-13）。改成调用方（菜单项）只创建一次、存进 `SonglistService`，
/// `id` 就固定了。`origin` 区分调用来源，这次只用 `.addToSonglist`；T-011 加 `.saveNowPlaying`。
public struct PendingCreate: Identifiable {
    public let id = UUID()
    public let tracks: [Track]
    public let origin: Origin

    public enum Origin: Equatable {
        case addToSonglist
        case saveNowPlaying
    }

    public init(tracks: [Track], origin: Origin) {
        self.tracks = tracks
        self.origin = origin
    }
}

/// 歌单的内存目录、发布给界面、调度写盘操作、生成提示文字。
///
/// 在 `MacMusicPlayerApp` 里用 `@StateObject` 创建一个，通过 `.environmentObject`
/// 注入主窗口和所有 `WindowGroup` 实例（和 `PlayerViewModel` 一样）。
@MainActor
public final class SonglistService: ObservableObject {

    @Published public private(set) var summaries: [SonglistSummary] = []
    @Published public private(set) var loadFailures: [LoadFailure] = []
    @Published public private(set) var isLoaded = false
    @Published public var errorMessage: String?
    /// F-12：「新建歌单…」待创建的曲目。挂在 `Menu`/`contextMenu` 内部视图上的
    /// `.sheet` 在菜单关闭时会被销毁、丢掉 `@State`，弹不出来；改成把待建曲目存
    /// 在这里，由 `ContentView` 挂唯一一个 `.sheet(item:)` 弹出。
    @Published public var pendingCreate: PendingCreate?

    private let store: SonglistStore
    /// 完整的歌单内容，供 `entries(of:)` 使用；界面只看 `summaries`。
    private var songlistsByID: [UUID: Songlist] = [:]
    private var loadTask: Task<SonglistStore.Snapshot, Never>?

    /// 只为读取 `library`（显示信息，§4.4）；不做播放相关的事，也不双向持有。
    public weak var playerViewModel: PlayerViewModel?

    public init(root: URL = DataFolder.root) {
        self.store = SonglistStore(root: root)
    }

    /// 内部保证只加载一次，多个窗口的 `.task` 重复触发时直接返回。
    public func loadAll() async {
        if isLoaded { return }
        if let loadTask {
            _ = await loadTask.value
            return
        }
        let task = Task { [store] in
            await store.loadAll()
        }
        loadTask = task
        let snapshot = await task.value
        apply(snapshot)
        isLoaded = true

        if !loadFailures.isEmpty {
            errorMessage = "有 \(loadFailures.count) 个歌单读取失败，原文件已保留在 "
                + "~/Library/Application Support/MacMusicPlayer/PlaylistData/songlists"
        }
    }

    /// 只读同步一次磁盘（不加锁），打开歌单页时调用（FR-028 ③）。
    public func refresh() async {
        let snapshot = await store.refresh()
        apply(snapshot)
    }

    public func entries(of id: UUID) -> [SonglistEntry]? {
        songlistsByID[id]?.entries
    }

    /// 按 `TrackIdentity(path:)` 在曲库索引里找：找到就用曲库里的那个 `Track`（保证和曲库
    /// 列表同一文件的信息完全一致，TC-036）；找不到（别的文件夹的歌）就用 entry 里缓存的
    /// 标题、歌手、专辑、时长构造一个。
    public func resolve(_ entry: SonglistEntry) -> Track {
        let identity = TrackIdentity(path: entry.path)
        if let vm = playerViewModel,
           let index = vm.libraryIndex[identity],
           vm.library.indices.contains(index) {
            return vm.library[index]
        }
        var track = Track(url: URL(fileURLWithPath: entry.path))
        track.title = entry.title
        track.artist = entry.artist
        track.album = entry.album
        track.duration = entry.duration
        return track
    }

    public func create(name: String) async -> Result<SonglistSummary, SonglistError> {
        let op = CreateSonglistOperation(name: name)
        switch await execute(op) {
        case .success(let songlist):
            guard let songlist else {
                return .failure(.saveFailed(reason: "写入失败"))
            }
            return .success(summary(for: songlist))
        case .failure(let error):
            return .failure(error)
        }
    }

    public func rename(_ id: UUID, to name: String) async -> Result<Void, SonglistError> {
        let knownName = songlistsByID[id]?.name ?? name
        let op = RenameSonglistOperation(id: id, name: name, knownName: knownName)
        switch await execute(op) {
        case .success:
            return .success(())
        case .failure(let error):
            return .failure(error)
        }
    }

    /// 调用前界面层必须已让用户确认。
    public func delete(_ id: UUID) async -> Result<Void, SonglistError> {
        let knownName = songlistsByID[id]?.name ?? ""
        let op = DeleteSonglistOperation(id: id, knownName: knownName)
        switch await execute(op) {
        case .success:
            return .success(())
        case .failure(let error):
            return .failure(error)
        }
    }

    /// 往已有歌单里加曲目（FR-015）。`tracks` 顺序由调用方用 `SelectionOrder` 排好。
    public func add(_ tracks: [Track], to id: UUID) async -> Result<AddResult, SonglistError> {
        let knownName = songlistsByID[id]?.name ?? ""
        let op = AddTracksOperation(id: id, tracks: tracks, knownName: knownName)
        let outcome = await commitAndApply(op)
        switch outcome.result {
        case .success(let songlist):
            guard let songlist else {
                return .failure(.saveFailed(reason: "写入失败"))
            }
            // added/skipped 都要按写前同步后的最新数据算，不能用界面上的旧数据。
            let beforeCount = outcome.before?.entries.count ?? 0
            let added = songlist.entries.count - beforeCount
            let dedupedInputCount = Self.dedupedCount(tracks)
            return .success(AddResult(added: added, skipped: dedupedInputCount - added, songlistName: songlist.name))
        case .failure(let error):
            return .failure(error)
        }
    }

    /// 新建歌单并直接写入曲目（FR-015；T-011「播放列表存为歌单」等场景）。
    public func create(name: String, with tracks: [Track]) async -> Result<AddResult, SonglistError> {
        let op = CreateWithTracksOperation(name: name, tracks: tracks)
        let outcome = await commitAndApply(op)
        switch outcome.result {
        case .success(let songlist):
            guard let songlist else {
                return .failure(.saveFailed(reason: "写入失败"))
            }
            return .success(AddResult(added: songlist.entries.count, skipped: 0, songlistName: songlist.name))
        case .failure(let error):
            return .failure(error)
        }
    }

    /// 从歌单里移除曲目（FR-016）。返回实际移除的首数。
    public func remove(_ identities: [TrackIdentity], from id: UUID) async -> Result<Int, SonglistError> {
        let knownName = songlistsByID[id]?.name ?? ""
        let op = RemoveTracksOperation(id: id, identities: identities, knownName: knownName)
        let outcome = await commitAndApply(op)
        switch outcome.result {
        case .success(let songlist):
            guard let songlist else {
                return .failure(.saveFailed(reason: "写入失败"))
            }
            let beforeCount = outcome.before?.entries.count ?? songlist.entries.count
            return .success(beforeCount - songlist.entries.count)
        case .failure(let error):
            return .failure(error)
        }
    }

    /// 通用入口，新建 / 重命名 / 删除都调用它。
    /// 返回之前，内存目录和界面都没有变化；成功之后才提交。
    public func execute(_ op: SonglistOperation) async -> Result<Songlist?, SonglistError> {
        await commitAndApply(op).result
    }

    /// F-7 专用：只在成功时更新内存 / 界面；失败时**不设置 `errorMessage`**（静默忽略，
    /// 只是缓存没更新，不影响已经显示的内容）。不能直接用 `execute`——那个失败时会弹
    /// `ErrorBanner`，而 F-7 的刷新是后台行为，用户没有对应的操作可以关联这条错误。
    public func refreshCacheSilently(_ op: RefreshCacheOperation) async {
        let outcome = await store.commit(op)
        if case .success = outcome.result {
            apply(outcome.snapshot)
        }
    }

    private func commitAndApply(_ op: SonglistOperation) async -> SonglistStore.CommitOutcome {
        let outcome = await store.commit(op)
        switch outcome.result {
        case .success:
            apply(outcome.snapshot)
            errorMessage = nil
        case .failure(let error):
            // 失败：内存和界面保持操作前的样子；只把最新的读取失败列表同步一下
            loadFailures = outcome.snapshot.failures
            errorMessage = error.message
        }
        return outcome
    }

    private static func dedupedCount(_ tracks: [Track]) -> Int {
        var seen = Set<TrackIdentity>()
        return tracks.filter { seen.insert($0.identity).inserted }.count
    }

    private func apply(_ snapshot: SonglistStore.Snapshot) {
        songlistsByID = snapshot.songlists
        summaries = snapshot.songlists.values
            .map { summary(for: $0) }
            .sorted { lhs, rhs in
                if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
                return lhs.id.uuidString < rhs.id.uuidString
            }
        loadFailures = snapshot.failures
    }

    private func summary(for songlist: Songlist) -> SonglistSummary {
        SonglistSummary(id: songlist.id, name: songlist.name, count: songlist.entries.count, createdAt: songlist.createdAt)
    }
}
