import SwiftUI

/// 播放列表（PL）页。T-001 阶段先保持单选和双击播放；
/// 多选、右键菜单、拖动排序、删除键、「清空」按钮由 T-008 加入。
struct NowPlayingListView: View {
    @EnvironmentObject private var vm: PlayerViewModel
    @State private var selection: URL?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // 背景与曲库列表相同：磨砂 + 隐藏 List 自带的不透明背景
        .background(VisualEffectView(material: .sidebar, opacity: vm.backgroundOpacity))
    }

    private var header: some View {
        HStack {
            Text(vm.nowPlayingHeader)
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var content: some View {
        if vm.nowPlaying.items.isEmpty {
            emptyState
        } else {
            ScrollViewReader { proxy in
                List(selection: $selection) {
                    ForEach(Array(vm.nowPlaying.items.enumerated()), id: \.element.id) { index, track in
                        TrackRow(track: track, isCurrent: index == vm.nowPlayingIndex, isPlaying: vm.isPlaying)
                            .tag(track.id)
                            .contentShape(Rectangle())
                            .onTapGesture(count: 2) {
                                vm.playInNowPlaying(at: index)
                            }
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
                .onAppear { scrollToCurrent(proxy) }
            }
        }
    }

    /// 新的行还没完成布局就 scrollTo 会没反应，所以放到下一个 runloop。
    private func scrollToCurrent(_ proxy: ScrollViewProxy) {
        guard let index = vm.nowPlayingIndex, vm.nowPlaying.items.indices.contains(index) else { return }
        let id = vm.nowPlaying.items[index].id
        DispatchQueue.main.async {
            proxy.scrollTo(id, anchor: .center)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "music.note.list")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("播放列表为空")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
