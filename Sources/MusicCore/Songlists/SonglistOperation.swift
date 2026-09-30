import Foundation

/// 一次歌单改动。T-004、T-005、T-011 新增实现即可接入写入流程，不需要另写写盘代码。
public protocol SonglistOperation: Sendable {
    /// 新建时为 nil。
    var targetID: UUID? { get }

    /// 在「刚从磁盘同步过来的最新目录」上校验并应用。必须是纯函数。
    /// 返回新的歌单；删除返回 nil；校验不通过抛 `SonglistError`。
    func apply(to fresh: [UUID: Songlist], now: Date) throws -> Songlist?
}

/// 新建歌单。
public struct CreateSonglistOperation: SonglistOperation {
    public var targetID: UUID? { nil }

    private let newID: UUID
    private let rawName: String

    public init(id: UUID = UUID(), name: String) {
        self.newID = id
        self.rawName = name
    }

    public func apply(to fresh: [UUID: Songlist], now: Date) throws -> Songlist? {
        let existing = fresh.values.map { (id: $0.id, name: $0.name) }
        switch SonglistName.validate(rawName, existing: existing, excluding: nil) {
        case .failure(let error):
            throw error
        case .success(let trimmed):
            return Songlist(id: newID, name: trimmed, createdAt: now, revision: 0, entries: [])
        }
    }
}

/// 重命名歌单。
public struct RenameSonglistOperation: SonglistOperation {
    public let targetID: UUID?
    private let newName: String
    /// 调用方在发起操作时已知的名称，仅用于目标在同步时已不存在的错误提示。
    private let knownName: String

    public init(id: UUID, name: String, knownName: String) {
        self.targetID = id
        self.newName = name
        self.knownName = knownName
    }

    public func apply(to fresh: [UUID: Songlist], now: Date) throws -> Songlist? {
        guard let id = targetID, var target = fresh[id] else {
            throw SonglistError.notFound(name: knownName)
        }

        let existing = fresh.values.map { (id: $0.id, name: $0.name) }
        switch SonglistName.validate(newName, existing: existing, excluding: id) {
        case .failure(let error):
            throw error
        case .success(let trimmed):
            target.name = trimmed
            return target
        }
    }
}

/// 删除歌单。界面确认之后才应该构造这个操作。
public struct DeleteSonglistOperation: SonglistOperation {
    public let targetID: UUID?
    private let knownName: String

    public init(id: UUID, knownName: String) {
        self.targetID = id
        self.knownName = knownName
    }

    public func apply(to fresh: [UUID: Songlist], now: Date) throws -> Songlist? {
        guard let id = targetID, fresh[id] != nil else {
            throw SonglistError.notFound(name: knownName)
        }
        return nil
    }
}

// MARK: - T-004：往歌单里加歌、移除、新建并添加

/// 往已有歌单里加曲目（FR-015）。
public struct AddTracksOperation: SonglistOperation {
    public let targetID: UUID?
    private let tracks: [Track]
    private let knownName: String

    public init(id: UUID, tracks: [Track], knownName: String) {
        self.targetID = id
        self.tracks = tracks
        self.knownName = knownName
    }

    public func apply(to fresh: [UUID: Songlist], now: Date) throws -> Songlist? {
        guard let id = targetID, var target = fresh[id] else {
            throw SonglistError.notFound(name: knownName)
        }

        // ① 输入按 identity 去重，保留第一次出现的
        var seen = Set<TrackIdentity>()
        var deduped: [Track] = []
        for track in tracks where seen.insert(track.identity).inserted {
            deduped.append(track)
        }

        // ② 已有条目的 identity 集合，每条只算一次
        let existingIdentities = Set(target.entries.map { TrackIdentity(path: $0.path) })

        // ③ 其余按输入顺序追加到末尾，同时写入缓存字段
        let appended = deduped
            .filter { !existingIdentities.contains($0.identity) }
            .map(SonglistEntry.init(track:))

        // ④ 没有新增时原样返回目标歌单
        guard !appended.isEmpty else { return target }

        target.entries.append(contentsOf: appended)
        return target
    }
}

/// 新建歌单并直接写入曲目（FR-015，"播放列表存为歌单"等场景）。只写一次盘。
public struct CreateWithTracksOperation: SonglistOperation {
    public var targetID: UUID? { nil }

    private let newID: UUID
    private let rawName: String
    private let tracks: [Track]

    public init(id: UUID = UUID(), name: String, tracks: [Track]) {
        self.newID = id
        self.rawName = name
        self.tracks = tracks
    }

    public func apply(to fresh: [UUID: Songlist], now: Date) throws -> Songlist? {
        let existing = fresh.values.map { (id: $0.id, name: $0.name) }
        switch SonglistName.validate(rawName, existing: existing, excluding: nil) {
        case .failure(let error):
            throw error
        case .success(let trimmed):
            var seen = Set<TrackIdentity>()
            let entries = tracks
                .filter { seen.insert($0.identity).inserted }
                .map(SonglistEntry.init(track:))
            return Songlist(id: newID, name: trimmed, createdAt: now, revision: 0, entries: entries)
        }
    }
}

/// 从歌单里移除曲目（FR-016）。按 identity 判断，下标不可靠（FR-028 ②）。
public struct RemoveTracksOperation: SonglistOperation {
    public let targetID: UUID?
    private let identities: [TrackIdentity]
    private let knownName: String

    public init(id: UUID, identities: [TrackIdentity], knownName: String) {
        self.targetID = id
        self.identities = identities
        self.knownName = knownName
    }

    public func apply(to fresh: [UUID: Songlist], now: Date) throws -> Songlist? {
        guard let id = targetID, var target = fresh[id] else {
            throw SonglistError.notFound(name: knownName)
        }

        let toRemove = Set(identities)
        guard !toRemove.isEmpty else { return target }

        target.entries.removeAll { toRemove.contains(TrackIdentity(path: $0.path)) }
        return target
    }
}

/// F-7：只刷新命中条目的缓存字段（标题/歌手/专辑/时长），不改曲目和顺序。
/// 一个歌单一次只提交一次；调用方（`SonglistDetailView`）失败不提示，只是缓存没更新。
public struct RefreshCacheOperation: SonglistOperation {
    public let targetID: UUID?
    private let updates: [TrackIdentity: SonglistEntry]

    public init(id: UUID, updates: [TrackIdentity: SonglistEntry]) {
        self.targetID = id
        self.updates = updates
    }

    public func apply(to fresh: [UUID: Songlist], now: Date) throws -> Songlist? {
        guard let id = targetID, var target = fresh[id] else {
            throw SonglistError.notFound(name: "")
        }
        for index in target.entries.indices {
            let identity = TrackIdentity(path: target.entries[index].path)
            if let updated = updates[identity] {
                target.entries[index] = updated
            }
        }
        return target
    }
}

private extension SonglistEntry {
    init(track: Track) {
        self.init(path: track.url.path, title: track.title, artist: track.artist, album: track.album, duration: track.duration)
    }
}
