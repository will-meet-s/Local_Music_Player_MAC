import Foundation

/// `nowplaying.json` 的完整内容（T-010 §3）。
public struct NowPlayingSnapshot: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var state: NowPlayingState
    public var source: NowPlayingSource
    /// 当前曲目（`playingTrack`）的路径；没有当前曲目时为 nil。
    public var currentPath: String?
    /// 独立状态下是完整列表；**跟随状态下恒为空数组**（不保存曲库镜像）。
    public var items: [SonglistEntry]
    public var savedAt: Date

    public init(
        state: NowPlayingState, source: NowPlayingSource, currentPath: String?,
        items: [SonglistEntry], savedAt: Date = Date()
    ) {
        self.schemaVersion = 1
        self.state = state
        self.source = source
        self.currentPath = currentPath
        self.items = items
        self.savedAt = savedAt
    }
}

/// 播放列表的恢复数据读写（T-010）。写法与 T-003 的 `SonglistStore` 相同：
/// 临时文件 + `fsync` + `rename` 原子替换，复用同一个 `writeAtomically`。
///
/// 不加锁、不做写前合并（FR-028 ④ 以最后退出的为准）：原子替换 + 退出时必写一次
/// 就够了，两个进程各自去抖保存，最后退出的最后写入。
public struct NowPlayingStore: Sendable {
    private let fileURL: URL

    public init(fileURL: URL = DataFolder.nowPlaying) {
        self.fileURL = fileURL
    }

    /// 文件不存在、读不出来、解码失败、`schemaVersion` 不对，都返回 nil，不抛错——
    /// 按需求 §4 可靠性，这份数据损坏时静默按初始状态启动，不提示。
    public func load() -> NowPlayingSnapshot? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        guard let snapshot = try? SonglistCoding.makeDecoder().decode(NowPlayingSnapshot.self, from: data) else {
            return nil
        }
        guard snapshot.schemaVersion == 1 else { return nil }
        return snapshot
    }

    /// 失败返回 errno 映射的原因（同 T-003 §2.4），成功返回 nil。
    public func save(_ snapshot: NowPlayingSnapshot) -> String? {
        // 确保 fileURL 所在目录存在——直接建 fileURL 的父目录，不用
        // DataFolder.ensureExists()：那个只认死 DataFolder.root，注入自定义
        // fileURL（测试用临时目录）时会去建错误的目录。已存在时 createDirectory
        // 不报错、也不改权限，等价于 T-003 的 ensureExists 语义。
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            // 目录不存在且创建失败（例如上级目录只读）；目录已存在但被设为只读的情况
            // 在下面写临时文件时通过 errno 精确映射。
            return "数据文件夹没有写入权限"
        }

        let data: Data
        do {
            data = try SonglistCoding.makeEncoder().encode(snapshot)
        } catch {
            return "写入失败（数据编码错误）"
        }

        let tempURL = fileURL.deletingLastPathComponent()
            .appendingPathComponent("\(fileURL.lastPathComponent).tmp-\(ProcessInfo.processInfo.processIdentifier)")

        do {
            try writeAtomically(data, tempURL: tempURL, finalURL: fileURL, beforeRename: nil)
            return nil
        } catch let error as POSIXIOError {
            return error.reason
        } catch {
            return "写入失败"
        }
    }
}
