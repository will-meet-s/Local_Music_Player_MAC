import Foundation

/// 曲目列表的排序维度。
public enum TrackSortOrder: String, CaseIterable, Codable, Sendable {
    /// 文件路径自然序 —— 扫描出来的原始顺序，专辑目录结构在此顺序下最直观。
    case fileOrder
    case title
    case artist

    public var displayName: String {
        switch self {
        case .fileOrder: return "文件顺序"
        case .title: return "歌曲名"
        case .artist: return "歌手名"
        }
    }
}

/// 对曲目列表做搜索过滤 + 排序。
///
/// 纯函数，不碰任何状态，因此可完整单测。
public enum TrackFilter {

    /// 先按 `search` 过滤，再按 `sort` 排序。
    ///
    /// - Parameters:
    ///   - search: 空白字符串表示不过滤。匹配标题 / 歌手 / 专辑，忽略大小写与音调符号。
    ///   - ascending: 仅影响主排序键；歌手缺失的曲目始终排在最后。
    public static func apply(
        to tracks: [Track],
        search: String,
        sort: TrackSortOrder,
        ascending: Bool
    ) -> [Track] {
        sorted(filtered(tracks, search: search), by: sort, ascending: ascending)
    }

    // MARK: - 过滤

    public static func filtered(_ tracks: [Track], search: String) -> [Track] {
        let keyword = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { return tracks }

        return tracks.filter { track in
            matches(track.title, keyword)
                || matches(track.artist, keyword)
                || matches(track.album, keyword)
        }
    }

    private static func matches(_ text: String?, _ keyword: String) -> Bool {
        guard let text, !text.isEmpty else { return false }
        return text.range(of: keyword, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }

    // MARK: - 排序

    public static func sorted(
        _ tracks: [Track],
        by order: TrackSortOrder,
        ascending: Bool
    ) -> [Track] {
        switch order {
        case .fileOrder:
            return tracks.sorted { a, b in
                compare(a.url.path, b.url.path, ascending: ascending)
            }

        case .title:
            return tracks.sorted { a, b in
                let result = a.title.localizedStandardCompare(b.title)
                if result != .orderedSame {
                    return ascending ? result == .orderedAscending : result == .orderedDescending
                }
                // 同名歌曲按路径定序，保证结果稳定
                return a.url.path.localizedStandardCompare(b.url.path) == .orderedAscending
            }

        case .artist:
            return tracks.sorted { a, b in
                let left = a.artist?.trimmingCharacters(in: .whitespaces) ?? ""
                let right = b.artist?.trimmingCharacters(in: .whitespaces) ?? ""

                // 没有歌手信息的始终垫底，正序倒序都一样 —— 否则倒序时一堆
                // "未知歌手" 会顶到最前面，没有意义
                if left.isEmpty != right.isEmpty {
                    return right.isEmpty
                }

                let result = left.localizedStandardCompare(right)
                if result != .orderedSame {
                    return ascending ? result == .orderedAscending : result == .orderedDescending
                }
                // 同一歌手内部按歌名排，再按路径兜底
                let byTitle = a.title.localizedStandardCompare(b.title)
                if byTitle != .orderedSame {
                    return byTitle == .orderedAscending
                }
                return a.url.path.localizedStandardCompare(b.url.path) == .orderedAscending
            }
        }
    }

    private static func compare(_ a: String, _ b: String, ascending: Bool) -> Bool {
        let result = a.localizedStandardCompare(b)
        if result == .orderedSame { return false }
        return ascending ? result == .orderedAscending : result == .orderedDescending
    }
}
