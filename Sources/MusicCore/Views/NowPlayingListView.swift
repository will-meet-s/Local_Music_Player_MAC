import SwiftUI

/// 播放列表（PL）页。支持多选、右键菜单、拖动排序、删除键、清空（T-008）。
struct NowPlayingListView: View {
    @EnvironmentObject private var vm: PlayerViewModel
    @EnvironmentObject private var availability: AvailabilityStore
    @EnvironmentObject private var songlists: SonglistService
    @State private var selection = Set<URL>()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // 背景与曲库列表相同：磨砂 + 隐藏 List 自带的不透明背景
        .background(VisualEffectView(material: .sidebar, opacity: vm.backgroundOpacity))
        // T-007 §2.3：打开 PL 页时这一页的全部曲目用 high 优先级检查，
        // 离开时把还没查完的降级为 low（不丢弃、不打断正在检查的那个）。
        .task { vm.checkAvailabilityHigh(vm.nowPlaying.items) }
        .onDisappear { vm.demoteAvailabilityChecks() }
    }

    private var header: some View {
        HStack {
            Text(vm.nowPlayingHeader)
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
            // T-011：点按钮时就取快照（vm.nowPlaying.items 是值类型），不要等 sheet
            // 确定时再读——那时播放列表可能已经变了（方案 §7 易踩的坑）。
            Button {
                songlists.pendingCreate = PendingCreate(tracks: vm.nowPlaying.items, origin: .saveNowPlaying)
            } label: {
                Label("存为歌单", systemImage: "square.and.arrow.down")
            }
            .disabled(vm.nowPlaying.items.isEmpty)
            Button("清空") { vm.clearNowPlaying() }
                .disabled(vm.nowPlaying.items.isEmpty)
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
                        TrackRow(
                            track: track, isCurrent: index == vm.nowPlayingIndex, isPlaying: vm.isPlaying,
                            isAvailable: availability.isAvailable(track.identity)
                        )
                        .tag(track.id)
                        .onAppear {
                            // T-014 §2.4（TC-190 ②）：nowplaying.open 的结束点。
                            if index == 0 { PerfTrace.end("nowplaying.open") }
                        }
                    }
                    .onMove(perform: handleMove)
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
                .contextMenu(forSelectionType: URL.self) { urls in
                    contextMenuItems(for: urls)
                } primaryAction: { urls in
                    guard urls.count == 1, let url = urls.first,
                          let index = vm.nowPlaying.items.firstIndex(where: { $0.id == url }) else { return }
                    vm.playInNowPlaying(at: index)
                }
                .onDeleteCommand {
                    removeSelected()
                }
                .onAppear { scrollToCurrent(proxy) }
            }
        }
    }

    @ViewBuilder
    private func contextMenuItems(for urls: Set<URL>) -> some View {
        let selected = SelectionOrder.byListOrder(urls, in: vm.nowPlaying.items)
        Button("下一首播放") { vm.playNext(selected) }
        Button("移到末尾") { vm.appendToNowPlaying(selected) }
        AddToSonglistMenu(tracks: { SelectionOrder.byListOrder(urls, in: vm.nowPlaying.items) }, excluding: nil)
        Divider()
        Button("从播放列表移除", role: .destructive) {
            removeByIdentity(Set(selected.map(\.identity)))
        }
    }

    private func removeSelected() {
        removeByIdentity(Set(selection.compactMap { url in
            vm.nowPlaying.items.first { $0.id == url }?.identity
        }))
    }

    private func removeByIdentity(_ identities: Set<TrackIdentity>) {
        guard !identities.isEmpty else { return }
        let indices = IndexSet(vm.nowPlaying.items.indices.filter { identities.contains(vm.nowPlaying.items[$0].identity) })
        vm.removeFromNowPlaying(at: indices)
        selection.removeAll()
    }

    /// SwiftUI 的 `destination` 是「移除前」的插入点，要换算成 `NowPlayingList.move`
    /// 要求的「移除后」位置；多行拖动不处理，只支持单行。
    private func handleMove(from source: IndexSet, to destination: Int) {
        guard source.count == 1, let from = source.first else { return }
        let to = destination > from ? destination - 1 : destination
        vm.moveInNowPlaying(from: from, to: to)
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
