import Foundation
import Darwin

/// 只管磁盘：加载全部、文件锁、同步变化、原子写、删除。不含业务规则。
///
/// 每次写入：进程内串行（actor 天然依次执行）→ 跨进程文件锁 `flock` →
/// 重新读取磁盘上变化过的文件 → 在最新数据上应用本次操作 → 写临时文件 + `fsync` →
/// `rename` 原子替换。先写盘成功，再由调用方更新界面。
public actor SonglistStore {

    /// 一次读取（`loadAll` / `refresh`）或一次改动（`commit`）之后的完整视图。
    public struct Snapshot: Sendable {
        public var songlists: [UUID: Songlist]
        public var failures: [LoadFailure]
    }

    /// `commit` 的结果：无论成功失败都带上最新的磁盘视图。
    public struct CommitOutcome: Sendable {
        public var snapshot: Snapshot
        /// 应用操作之前、写前同步后的 `fresh[targetID]`（T-004）。新建、或同步后才发现
        /// 目标不存在时为 nil。用来算 `added`/`skipped` 这类"和写前的最新数据比"的计数，
        /// 不能用界面上的旧数据算。
        public var before: Songlist?
        public var result: Result<Songlist?, SonglistError>
    }

    private struct FileStamp: Equatable {
        var modifiedAt: Date
        var size: Int
    }

    private let root: URL
    private let songlistsDir: URL
    private let lockFileURL: URL

    /// 当前已知的歌单内容，按文件名（不含路径）索引磁盘状态。
    private var songlistsByFile: [String: Songlist] = [:]
    private var stamps: [String: FileStamp] = [:]
    /// 读取失败的文件：程序从此不再读、不再写、不改名、不删除，原样留着。
    private var failures: [String: LoadFailure] = [:]

    /// 测试钩子：在 `rename` 之前调用，可以抛错模拟崩溃（TC 用于验证写入中断后的行为）。
    public var beforeRename: (@Sendable () throws -> Void)?

    /// 供测试从外部设置 `beforeRename`（跨 actor 隔离，需要 `await`）。
    public func setBeforeRename(_ hook: (@Sendable () throws -> Void)?) {
        beforeRename = hook
    }

    public init(root: URL) {
        self.root = root
        self.songlistsDir = root.appendingPathComponent("songlists", isDirectory: true)
        self.lockFileURL = root.appendingPathComponent(".lock", isDirectory: false)
    }

    private var currentSnapshot: Snapshot {
        let byID = Dictionary(uniqueKeysWithValues: songlistsByFile.values.map { ($0.id, $0) })
        return Snapshot(songlists: byID, failures: Array(failures.values))
    }

    // MARK: - 启动加载

    /// 加锁清理残留临时文件后，读取全部歌单。拿不到锁就只读、不删除临时文件。
    public func loadAll() async -> Snapshot {
        do {
            try DataFolder.ensureExists(root: root, songlistsDir: songlistsDir)
        } catch {
            // 上级目录只读等情况：目录视为空，之后的写入会得到 saveFailed
            return Snapshot(songlists: [:], failures: [])
        }

        switch await acquireLock(timeout: 2) {
        case .acquired(let fd):
            cleanupTemporaryFiles()
            flock(fd, LOCK_UN)
            close(fd)
        case .openFailed, .timedOut:
            break
        }

        syncFromDisk()
        return currentSnapshot
    }

    /// 只读同步一次磁盘，不加锁（FR-028 ③，打开歌单页时调用）。
    public func refresh() async -> Snapshot {
        syncFromDisk()
        return currentSnapshot
    }

    // MARK: - 写入

    /// 执行一次改动操作。预校验请在调用方持有的内存目录上先做一遍，
    /// 这里在锁内重新校验，因为磁盘状态可能已经变化。
    public func commit(_ op: SonglistOperation) async -> CommitOutcome {
        do {
            try DataFolder.ensureExists(root: root, songlistsDir: songlistsDir)
        } catch {
            // 目录不存在且创建失败（例如上级目录只读）；目录已存在但被设为只读的情况
            // 在下面写临时文件时通过 errno 精确映射，见 writeAtomically。
            return CommitOutcome(snapshot: currentSnapshot, before: nil, result: .failure(.saveFailed(reason: "数据文件夹没有写入权限")))
        }

        let lock = await acquireLock(timeout: 2)
        let fd: Int32
        switch lock {
        case .acquired(let acquiredFD):
            fd = acquiredFD
        case .openFailed(let errnoValue):
            let reason = POSIXIOError(errnoValue: errnoValue).reason
            return CommitOutcome(snapshot: currentSnapshot, before: nil, result: .failure(.saveFailed(reason: reason)))
        case .timedOut:
            return CommitOutcome(snapshot: currentSnapshot, before: nil, result: .failure(.saveFailed(reason: "歌单正在被另一个窗口保存，请稍后重试")))
        }
        defer {
            flock(fd, LOCK_UN)
            close(fd)
        }

        syncFromDisk()

        // 目标歌单的文件这时读取失败：不覆盖它（文件名由 UUID 决定，不依赖内容能否解析）
        if let targetID = op.targetID, failures[fileName(for: targetID)] != nil {
            return CommitOutcome(snapshot: currentSnapshot, before: nil, result: .failure(.saveFailed(reason: "歌单文件已损坏，已保留原文件")))
        }

        let fresh = currentSnapshot.songlists
        let before = op.targetID.flatMap { fresh[$0] }
        let applied: Songlist?
        do {
            applied = try op.apply(to: fresh, now: Date())
        } catch let error as SonglistError {
            return CommitOutcome(snapshot: currentSnapshot, before: before, result: .failure(error))
        } catch {
            return CommitOutcome(snapshot: currentSnapshot, before: before, result: .failure(.saveFailed(reason: "写入失败")))
        }

        if let applied {
            // T-004：应用后内容和写前同步后的最新数据完全一样（例如要加的歌全部已存在），
            // 不写盘，原样返回——文件修改时间不变（单测 3、8）。
            if applied == before {
                return CommitOutcome(snapshot: currentSnapshot, before: before, result: .success(applied))
            }

            // 新建 / 修改
            var toWrite = applied
            toWrite.revision += 1
            do {
                try write(toWrite)
            } catch let error as POSIXIOError {
                return CommitOutcome(snapshot: currentSnapshot, before: before, result: .failure(.saveFailed(reason: error.reason)))
            } catch {
                return CommitOutcome(snapshot: currentSnapshot, before: before, result: .failure(.saveFailed(reason: "写入失败")))
            }
            return CommitOutcome(snapshot: currentSnapshot, before: before, result: .success(toWrite))
        } else {
            // 删除
            guard let id = op.targetID else {
                return CommitOutcome(snapshot: currentSnapshot, before: before, result: .failure(.saveFailed(reason: "写入失败")))
            }
            do {
                try remove(fileName: fileName(for: id))
            } catch let error as POSIXIOError {
                return CommitOutcome(snapshot: currentSnapshot, before: before, result: .failure(.saveFailed(reason: error.reason)))
            } catch {
                return CommitOutcome(snapshot: currentSnapshot, before: before, result: .failure(.saveFailed(reason: "写入失败")))
            }
            return CommitOutcome(snapshot: currentSnapshot, before: before, result: .success(nil))
        }
    }

    /// 文件名由 UUID 决定（`<uuid>.json`），与内容能否解析无关。
    private func fileName(for id: UUID) -> String {
        "\(id.uuidString.lowercased()).json"
    }

    // MARK: - 磁盘同步

    /// 只重读 (修改时间, 大小) 变了的、新出现的、消失的文件。
    private func syncFromDisk() {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: songlistsDir.path) else { return }
        let jsonNames = Set(names.filter { $0.hasSuffix(".json") })

        // 消失的文件：从内存目录和失败列表里去掉
        for known in Set(songlistsByFile.keys).union(failures.keys) where !jsonNames.contains(known) {
            songlistsByFile.removeValue(forKey: known)
            stamps.removeValue(forKey: known)
            failures.removeValue(forKey: known)
        }

        for name in jsonNames.sorted() {
            let fileURL = songlistsDir.appendingPathComponent(name)
            guard let attrs = try? fm.attributesOfItem(atPath: fileURL.path),
                  let modifiedAt = attrs[.modificationDate] as? Date,
                  let size = attrs[.size] as? Int else {
                markFailed(name: name, reason: "读取失败")
                continue
            }
            let stamp = FileStamp(modifiedAt: modifiedAt, size: size)
            if stamps[name] == stamp, (songlistsByFile[name] != nil || failures[name] != nil) {
                continue // 没变化，跳过重读
            }

            stamps[name] = stamp
            do {
                let data = try Data(contentsOf: fileURL)
                let decoded = try SonglistCoding.makeDecoder().decode(Songlist.self, from: data)
                guard decoded.schemaVersion == 1 else {
                    markFailed(name: name, reason: "schemaVersion 不受支持")
                    continue
                }
                guard decoded.id.uuidString.lowercased() == (name as NSString).deletingPathExtension.lowercased() else {
                    markFailed(name: name, reason: "id 与文件名不一致")
                    continue
                }
                guard !decoded.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    markFailed(name: name, reason: "名称为空")
                    continue
                }
                songlistsByFile[name] = decoded
                failures.removeValue(forKey: name)
            } catch {
                markFailed(name: name, reason: "解码失败")
            }
        }
    }

    private func markFailed(name: String, reason: String) {
        songlistsByFile.removeValue(forKey: name)
        failures[name] = LoadFailure(fileName: name, reason: reason)
    }

    /// 拿到锁时删除 `songlists/` 下所有 `*.json.tmp-*` 残留（持锁时不可能有别的进程正在写）。
    private func cleanupTemporaryFiles() {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: songlistsDir.path) else { return }
        for name in names where name.contains(".json.tmp-") {
            try? fm.removeItem(at: songlistsDir.appendingPathComponent(name))
        }
    }

    // MARK: - 写入 / 删除的底层实现

    private func write(_ songlist: Songlist) throws {
        let fileName = "\(songlist.id.uuidString.lowercased()).json"
        let finalURL = songlistsDir.appendingPathComponent(fileName)
        let tempURL = songlistsDir.appendingPathComponent("\(fileName).tmp-\(ProcessInfo.processInfo.processIdentifier)")

        let data = try SonglistCoding.makeEncoder().encode(songlist)
        try writeAtomically(data, tempURL: tempURL, finalURL: finalURL, beforeRename: beforeRename)

        songlistsByFile[fileName] = songlist
        failures.removeValue(forKey: fileName)
        if let attrs = try? FileManager.default.attributesOfItem(atPath: finalURL.path),
           let modifiedAt = attrs[.modificationDate] as? Date,
           let size = attrs[.size] as? Int {
            stamps[fileName] = FileStamp(modifiedAt: modifiedAt, size: size)
        }
    }

    /// 只允许删除 `songlists/` 下、文件名匹配 UUID 命名规则的文件（§5 安全）。
    /// internal（非 private）是为了让测试用 `@testable import` 直接验证这条防护本身
    /// （F-5：公开 API 的 `targetID` 恒为合法 UUID，无法从外部触发越界路径）。
    func remove(fileName: String) throws {
        guard fileName.range(of: #"^[0-9a-f-]{36}\.json$"#, options: .regularExpression) != nil else {
            throw POSIXIOError(errnoValue: EINVAL)
        }
        let target = songlistsDir.appendingPathComponent(fileName)
        guard target.deletingLastPathComponent().standardizedFileURL == songlistsDir.standardizedFileURL else {
            throw POSIXIOError(errnoValue: EINVAL)
        }

        let result = target.path.withCString { unlink($0) }
        guard result == 0 else { throw POSIXIOError(errnoValue: errno) }

        songlistsByFile.removeValue(forKey: fileName)
        stamps.removeValue(forKey: fileName)
        failures.removeValue(forKey: fileName)
    }

    // MARK: - 跨进程锁

    private enum LockAcquireResult {
        case acquired(Int32)
        case openFailed(Int32)
        case timedOut
    }

    /// `flock` 每 50 ms 试一次，最多等 `timeout` 秒。`open` 本身失败（例如只读目录）直接返回。
    private func acquireLock(timeout: TimeInterval) async -> LockAcquireResult {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let fd = lockFileURL.path.withCString { open($0, O_RDONLY | O_CREAT, 0o600) }
            if fd < 0 {
                return .openFailed(errno)
            }
            if flock(fd, LOCK_EX | LOCK_NB) == 0 {
                return .acquired(fd)
            }
            close(fd)
            if Date() >= deadline {
                return .timedOut
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }
}

// MARK: - POSIX 错误映射

struct POSIXIOError: Error {
    let errnoValue: Int32

    /// errno 到用户可读文字的映射（§2.4）。
    var reason: String {
        switch errnoValue {
        case EACCES, EPERM, EROFS:
            return "数据文件夹没有写入权限"
        case ENOSPC, EDQUOT:
            return "磁盘空间不足"
        default:
            return "写入失败（错误码 \(errnoValue)）"
        }
    }
}

/// 写临时文件 + `fsync` + `rename` 原子替换（同一目录内）。
///
/// 不用 `Data.write(to:options:.atomic)`：它不 `fsync`，也不保证临时文件和目标在同一目录。
/// 不用 `FileManager.replaceItemAt`：只读目录里的行为和错误码不稳定，还会生成备份文件。
///
/// internal（非 private）：T-010 的 `NowPlayingStore` 复用同一套原子写实现（方案 §6）。
func writeAtomically(
    _ data: Data,
    tempURL: URL,
    finalURL: URL,
    beforeRename: (@Sendable () throws -> Void)?
) throws {
    let fd = tempURL.path.withCString { open($0, O_WRONLY | O_CREAT | O_TRUNC, 0o600) }
    guard fd >= 0 else { throw POSIXIOError(errnoValue: errno) }

    var writeErrno: Int32?
    data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
        guard let base = buffer.baseAddress, buffer.count > 0 else { return }
        var offset = 0
        while offset < buffer.count {
            let n = Darwin.write(fd, base.advanced(by: offset), buffer.count - offset)
            if n <= 0 {
                writeErrno = errno
                return
            }
            offset += n
        }
    }
    if let writeErrno {
        close(fd)
        try? FileManager.default.removeItem(at: tempURL)
        throw POSIXIOError(errnoValue: writeErrno)
    }

    guard fsync(fd) == 0 else {
        let failedErrno = errno
        close(fd)
        try? FileManager.default.removeItem(at: tempURL)
        throw POSIXIOError(errnoValue: failedErrno)
    }
    close(fd)

    do {
        try beforeRename?()
    } catch {
        try? FileManager.default.removeItem(at: tempURL)
        throw error
    }

    let renamed = tempURL.path.withCString { tmpPath in
        finalURL.path.withCString { finalPath in
            rename(tmpPath, finalPath)
        }
    }
    guard renamed == 0 else {
        let failedErrno = errno
        try? FileManager.default.removeItem(at: tempURL)
        throw POSIXIOError(errnoValue: failedErrno)
    }
}
