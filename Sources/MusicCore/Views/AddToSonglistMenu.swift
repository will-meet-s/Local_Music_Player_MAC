import SwiftUI

/// 「添加到歌单」菜单：曲库列表、播放列表、歌单详情页、正在播放区四个入口共用（T-004）。
///
/// `tracks` 是懒取的闭包，菜单打开、用户真正选中一项时才求值，这样多选状态不会用旧的。
/// 默认以文字「添加到歌单」作为触发项（用在其他右键菜单里）；正在播放区需要一个
/// 图标按钮触发，用另一个 init 传自定义 `label`。
struct AddToSonglistMenu<Label: View>: View {
    let tracks: () -> [Track]
    /// 歌单详情页调用时传自己的 id，菜单里不再显示"添加到本歌单"。
    let excluding: UUID?
    let label: () -> Label

    @EnvironmentObject private var songlists: SonglistService

    init(tracks: @escaping () -> [Track], excluding: UUID?) where Label == Text {
        self.tracks = tracks
        self.excluding = excluding
        self.label = { Text("添加到歌单") }
    }

    init(tracks: @escaping () -> [Track], excluding: UUID?, @ViewBuilder label: @escaping () -> Label) {
        self.tracks = tracks
        self.excluding = excluding
        self.label = label
    }

    var body: some View {
        Menu {
            // 每次打开菜单都直接读 summaries，不缓存成 @State，这样新建、删除、
            // 改名之后菜单内容不会是旧的。
            ForEach(songlists.summaries.filter { $0.id != excluding }) { summary in
                Button(summary.name) {
                    Task { await addTracks(to: summary.id) }
                }
            }
            Divider()
            Button("新建歌单…") {
                // F-12：菜单项自己不弹 sheet——挂在这里的 .sheet 会在菜单关闭时被销毁，
                // @State 跟着丢失，弹不出来。改成把待建曲目交给 ContentView 唯一的 sheet。
                // F-13：这里只创建一次 PendingCreate，id 就固定了，不会在 sheet 打开期间变化。
                songlists.pendingCreate = PendingCreate(tracks: tracks(), origin: .addToSonglist)
            }
        } label: {
            label()
        }
    }

    private func addTracks(to id: UUID) async {
        let result = await songlists.add(tracks(), to: id)
        // 失败时 errorMessage 已经在 SonglistService 里设置，ContentView 的 ErrorBanner 会显示。
        if case .success(let addResult) = result {
            songlists.playerViewModel?.showNotice(addResult.noticeText)
        }
    }
}
