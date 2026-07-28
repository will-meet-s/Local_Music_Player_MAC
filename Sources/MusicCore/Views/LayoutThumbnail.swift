import SwiftUI

/// 浮在「正在播放」区右上角的小方块：画出当前布局的缩略示意图，点一下换下一种模式。
///
/// 做成独立的小控件而不是让整块区域响应点击 —— 后者会和歌词行的
/// 「点击跳播」抢手势，「只看歌词」模式下更是把切换完全挡死。
struct LayoutThumbnailButton: View {
    @EnvironmentObject private var vm: PlayerViewModel
    @State private var isHovering = false

    var body: some View {
        Button {
            vm.cycleNowPlayingLayout()
        } label: {
            LayoutGlyph(layout: vm.nowPlayingLayout)
                .frame(width: 30, height: 26)
                .padding(6)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7))
                .overlay {
                    RoundedRectangle(cornerRadius: 7)
                        .strokeBorder(Color.primary.opacity(isHovering ? 0.28 : 0.12))
                }
                .shadow(color: .black.opacity(0.18), radius: isHovering ? 5 : 2, y: 1)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help("当前：\(vm.nowPlayingLayout.displayName)，点击切换到「\(vm.nowPlayingLayout.next.displayName)」")
        .animation(.easeInOut(duration: 0.15), value: isHovering)
    }
}

/// 用色块画出三种布局的示意图。
private struct LayoutGlyph: View {
    let layout: NowPlayingLayout

    private var blockColor: Color { Color.primary.opacity(0.72) }
    private var lineColor: Color { Color.primary.opacity(0.42) }

    var body: some View {
        VStack(spacing: 3) {
            switch layout {
            case .artworkAndLyrics:
                RoundedRectangle(cornerRadius: 2)
                    .fill(blockColor)
                    .frame(width: 11, height: 11)
                lines(widths: [1.0, 0.72])

            case .artworkOnly:
                RoundedRectangle(cornerRadius: 3)
                    .fill(blockColor)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

            case .lyricsOnly:
                lines(widths: [1.0, 0.78, 0.9, 0.62])
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 用长短不一的胶囊模拟歌词行。
    private func lines(widths: [Double]) -> some View {
        VStack(spacing: 3) {
            ForEach(Array(widths.enumerated()), id: \.offset) { _, ratio in
                GeometryReader { geo in
                    Capsule()
                        .fill(lineColor)
                        .frame(width: geo.size.width * ratio, height: 2)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                }
                .frame(height: 2)
            }
        }
    }
}
