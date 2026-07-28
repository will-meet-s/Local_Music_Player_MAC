import Foundation

/// 轻量偏好持久化：上次打开的文件夹、播放模式、音量。
public enum Preferences {

    private enum Key {
        static let lastFolderPath = "lastFolderPath"
        static let playMode = "playMode"
        static let volume = "volume"
        static let sortOrder = "sortOrder"
        static let sortAscending = "sortAscending"
        static let backgroundOpacity = "backgroundOpacity"
    }

    /// 背景不透明度下限。再低文字就浮在桌面上没法看了。
    public static let minBackgroundOpacity: Double = 0.2

    private static var defaults: UserDefaults { .standard }

    public static var lastFolder: URL? {
        get {
            guard let path = defaults.string(forKey: Key.lastFolderPath), !path.isEmpty else { return nil }
            let url = URL(fileURLWithPath: path, isDirectory: true)
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
                return nil
            }
            return url
        }
        set {
            defaults.set(newValue?.path, forKey: Key.lastFolderPath)
        }
    }

    public static var playMode: PlayMode {
        get {
            guard let raw = defaults.string(forKey: Key.playMode) else { return .sequential }
            return PlayMode(rawValue: raw) ?? .sequential
        }
        set { defaults.set(newValue.rawValue, forKey: Key.playMode) }
    }

    public static var sortOrder: TrackSortOrder {
        get {
            guard let raw = defaults.string(forKey: Key.sortOrder) else { return .fileOrder }
            return TrackSortOrder(rawValue: raw) ?? .fileOrder
        }
        set { defaults.set(newValue.rawValue, forKey: Key.sortOrder) }
    }

    public static var sortAscending: Bool {
        get {
            guard defaults.object(forKey: Key.sortAscending) != nil else { return true }
            return defaults.bool(forKey: Key.sortAscending)
        }
        set { defaults.set(newValue, forKey: Key.sortAscending) }
    }

    public static var backgroundOpacity: Double {
        get {
            guard defaults.object(forKey: Key.backgroundOpacity) != nil else { return 1 }
            return clampOpacity(defaults.double(forKey: Key.backgroundOpacity))
        }
        set { defaults.set(clampOpacity(newValue), forKey: Key.backgroundOpacity) }
    }

    static func clampOpacity(_ value: Double) -> Double {
        min(1, max(minBackgroundOpacity, value))
    }

    public static var volume: Double {
        get {
            guard defaults.object(forKey: Key.volume) != nil else { return 0.8 }
            return min(1, max(0, defaults.double(forKey: Key.volume)))
        }
        set { defaults.set(min(1, max(0, newValue)), forKey: Key.volume) }
    }
}
