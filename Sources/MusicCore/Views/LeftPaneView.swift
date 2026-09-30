import SwiftUI

/// 左栏顶部分段的选项。「歌单」由 T-003 加入界面，这里先保留 case 以稳定契约。
public enum LeftPaneTab: String, Codable, Sendable {
    case library
    case songlists
    case nowPlaying
}

/// 左栏容器：顶部分段选择「曲库｜播放列表」，下面切换内容。
///
/// 切换分段不影响播放，右侧「正在播放」区不变（FR-001「打开播放列表不打断播放」）。
/// 页面没显示时不创建对应的 View（`switch` 分支），避免大列表在后台跟着刷新。
struct LeftPaneView: View {
    @EnvironmentObject private var vm: PlayerViewModel
    @SceneStorage("leftPaneTab") private var selectedTab: LeftPaneTab = .library

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $selectedTab) {
                Text("曲库").tag(LeftPaneTab.library)
                Text("播放列表").tag(LeftPaneTab.nowPlaying)
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
        case .nowPlaying:
            NowPlayingListView()
        case .songlists:
            // T-003 加入「歌单」分段前，这个 case 不会被 Picker 选中。
            EmptyView()
        }
    }
}
