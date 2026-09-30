import Foundation

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

    /// 通用入口，上面三个都调用它。返回之前，内存目录和界面都没有变化；成功之后才提交。
    public func execute(_ op: SonglistOperation) async -> Result<Songlist?, SonglistError> {
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
        return outcome.result
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
