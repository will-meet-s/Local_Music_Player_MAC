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
