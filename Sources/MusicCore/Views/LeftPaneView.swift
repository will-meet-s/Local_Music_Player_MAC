import SwiftUI

/// 左栏顶部分段的选项。T-019：播放列表面板改成独立开关（FR-030 ①），
/// 不再是这里的一个分段，这里只剩「曲库」「歌单」两项。
public enum LeftPaneTab: String, Codable, Sendable {
    case library
    case songlists
}

/// 左栏容器：顶部分段选择「曲库｜歌单」，下面切换内容。
///
/// 切换分段不影响播放，右侧「正在播放」区不变（FR-001「打开播放列表不打断播放」）。
/// 页面没显示时不创建对应的 View（`switch` 分支），避免大列表在后台跟着刷新。
struct LeftPaneView: View {
    @EnvironmentObject private var vm: PlayerViewModel
    // T-019：原来存过 "nowPlaying" 的值解码失败时自动回落到默认的 .library，
    // 不需要迁移代码。
    @SceneStorage("leftPaneTab") private var selectedTab: LeftPaneTab = .library

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $selectedTab) {
                Text("曲库").tag(LeftPaneTab.library)
                Text("歌单").tag(LeftPaneTab.songlists)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .padding(.bottom, 6)

            Divider()

            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var content: some View {
        switch selectedTab {
        case .library:
            TrackListView()
        case .songlists:
            SonglistListView()
        }
    }
}
