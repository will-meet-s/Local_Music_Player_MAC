import SwiftUI

/// 播放列表抽屉（T-019 v2）：盖在「正在播放」区右侧的浮层，不参与布局，
/// 不挤占任何一栏的宽度（FR-030 ④）。
struct NowPlayingDrawer: View {
    let onClose: () -> Void
    @EnvironmentObject private var vm: PlayerViewModel

    var body: some View {
        GeometryReader { geo in
            NowPlayingListView(onClose: onClose)
                .frame(width: min(320, geo.size.width))
                .background(
                    // 底层：模糊窗口内下面的内容（保证 20% 不透明度时文字仍然清楚可读）；
                    // 上层：跟随不透明度滑块的窗口后磨砂，和窗口其余部分同一种材质
                    // （方案 §4.4）。
                    ZStack {
                        VisualEffectView(material: .sidebar, blendingMode: .withinWindow, opacity: 1)
                        VisualEffectView(material: .sidebar, blendingMode: .behindWindow, opacity: vm.backgroundOpacity)
                    }
                )
                .shadow(color: .black.opacity(0.18), radius: 8, x: -2, y: 0)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
        }
    }
}
