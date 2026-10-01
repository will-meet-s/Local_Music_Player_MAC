import Foundation

/// 数据文件夹的路径常量和创建。本需求所有写盘都只能落在它下面。
///
/// App 没有沙盒，`applicationSupportDirectory` 解析为
/// `~/Library/Application Support`，这就是写进验收记录的路径。
public enum DataFolder {
    /// `~/Library/Application Support/MacMusicPlayer/PlaylistData`
    public static var root: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base
            .appendingPathComponent("MacMusicPlayer", isDirectory: true)
            .appendingPathComponent("PlaylistData", isDirectory: true)
    }

    public static var songlists: URL {
        root.appendingPathComponent("songlists", isDirectory: true)
    }

    public static var lockFile: URL {
        root.appendingPathComponent(".lock", isDirectory: false)
    }

    /// 播放列表的恢复数据（T-010 使用）。
    public static var nowPlaying: URL {
        root.appendingPathComponent("nowplaying.json", isDirectory: false)
    }

    /// 不存在就创建（含中间目录），权限 0700。已存在时不改权限（验收会把它设为只读）。
    public static func ensureExists(root: URL, songlistsDir: URL) throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: root.path) {
            try fm.createDirectory(
                at: root, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        if !fm.fileExists(atPath: songlistsDir.path) {
            try fm.createDirectory(
                at: songlistsDir, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
    }

    /// 便捷入口：作用于 `DataFolder.root` / `DataFolder.songlists`。
    public static func ensureExists() throws {
        try ensureExists(root: root, songlistsDir: songlists)
    }
}
