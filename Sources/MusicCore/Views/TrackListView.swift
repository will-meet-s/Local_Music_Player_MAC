import SwiftUI

/// 左侧曲目列表：搜索框 + 排序控件 + 列表。单击选中（支持 ⌘ / Shift 多选），双击播放。
struct TrackListView: View {
    @EnvironmentObject private var vm: PlayerViewModel
    @EnvironmentObject private var availability: AvailabilityStore
    @State private var selection = Set<URL>()
    /// T-016：当前曲目被搜索过滤掉时的提示条（只在用户点 × 、搜索词变化、
    /// 当前曲目变化时消失，其他什么都不变）。
    @State private var showFilteredPrompt = false

    var body: some View {
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                ListToolbar(onLocate: { locate(proxy) })
                if showFilteredPrompt {
                    filteredPrompt(proxy)
                }
                Divider()
                content(proxy)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // 侧栏用更通透的材质，和右侧拉开层次 —— 这是 macOS 原生的双色调做法
        .background(VisualEffectView(material: .sidebar, opacity: vm.backgroundOpacity))
        .onChange(of: vm.searchText) { _, _ in showFilteredPrompt = false }
        .onChange(of: vm.playingTrack?.identity) { _, _ in showFilteredPrompt = false }
    }

    @ViewBuilder
    private func content(_ proxy: ScrollViewProxy) -> some View {
        if vm.tracks.isEmpty {
            EmptyLibraryView()
        } else {
            List(selection: $selection) {
                ForEach(Array(vm.tracks.enumerated()), id: \.element.id) { index, track in
                    TrackRow(
                        track: track, isCurrent: index == vm.currentIndex, isPlaying: vm.isPlaying,
                        isAvailable: availability.isAvailable(track.identity)
                    )
                    .tag(track.id)
                }
            }
            .listStyle(.inset)
            // List 默认铺一层不透明背景，会把磨砂盖掉
            .scrollContentBackground(.hidden)
            // 双击播放；右键菜单作用于右键时的选中集合，在未选中的行上右键只作用于这一行
            // （contextMenu(forSelectionType:) 的默认行为）。
            .contextMenu(forSelectionType: URL.self) { urls in
                contextMenuItems(for: urls)
            } primaryAction: { urls in
                guard urls.count == 1, let url = urls.first,
                      let index = vm.tracks.firstIndex(where: { $0.id == url }) else { return }
                vm.play(at: index)
            }
            // List 在内容变化时会保留原来的滚动偏移，搜索或改排序之后
            // 看到的是列表中段，必须手动回顶。
            .onChange(of: vm.searchText) { _, _ in scrollToTop(proxy) }
            .onChange(of: vm.sortOrder) { _, _ in scrollToTop(proxy) }
            .onChange(of: vm.sortAscending) { _, _ in scrollToTop(proxy) }
        }
    }

    /// T-016 §2.3：被搜索过滤掉时的提示条，放在 `ListToolbar` 下面、列表上面。
    private func filteredPrompt(_ proxy: ScrollViewProxy) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle")
                .foregroundStyle(.secondary)
            Text("当前播放的歌曲不在搜索结果中")
                .font(.callout)
            Spacer()
            Button("清空搜索并定位") {
                clearSearchAndLocate(proxy)
            }
            .buttonStyle(.link)
            .font(.callout)
            Button {
                showFilteredPrompt = false
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .help("关闭")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private func contextMenuItems(for urls: Set<URL>) -> some View {
        Button("下一首播放") { vm.playNext(SelectionOrder.byListOrder(urls, in: vm.tracks)) }
        Button("添加到播放列表末尾") { vm.appendToNowPlaying(SelectionOrder.byListOrder(urls, in: vm.tracks)) }
        AddToSonglistMenu(tracks: { SelectionOrder.byListOrder(urls, in: vm.tracks) }, excluding: nil)
    }

    /// 新的行还没完成布局就 scrollTo 会没反应，所以放到下一个 runloop。
    private func scrollToTop(_ proxy: ScrollViewProxy) {
        guard let first = vm.tracks.first else { return }
        DispatchQueue.main.async {
            proxy.scrollTo(first.id, anchor: .top)
        }
    }

    // MARK: - T-016：定位当前播放的歌曲

    private func locate(_ proxy: ScrollViewProxy) {
        // T-014 §2.4（TC-276）：结束点是 scrollTo 所在的那次主队列跳转执行完，
        // 不是这个方法返回的时候。
        PerfTrace.begin("library.locate")
        switch vm.locateCurrent() {
        case .found(let index):
            showFilteredPrompt = false
            scrollAndSelect(proxy, index: index, extraHop: false) {
                PerfTrace.end("library.locate")
            }
        case .filteredOut:
            showFilteredPrompt = true
        case .notInFolder, .noTrack:
            break
        }
    }

    private func clearSearchAndLocate(_ proxy: ScrollViewProxy) {
        showFilteredPrompt = false
        switch vm.clearSearchAndLocate() {
        case .found(let index):
            // §4.2：searchText 变化会触发上面 content 里的 scrollToTop（下一个 runloop），
            // 这次的滚动要排在它后面，多跳一次主队列。
            scrollAndSelect(proxy, index: index, extraHop: true)
        case .filteredOut, .notInFolder, .noTrack:
            break
        }
    }

    private func scrollAndSelect(_ proxy: ScrollViewProxy, index: Int, extraHop: Bool, onScrolled: (() -> Void)? = nil) {
        guard vm.tracks.indices.contains(index) else { return }
        let id = vm.tracks[index].id
        selection = [id]
        let scrollToCenter = {
            proxy.scrollTo(id, anchor: .center)
            onScrolled?()
        }
        if extraHop {
            DispatchQueue.main.async { DispatchQueue.main.async(execute: scrollToCenter) }
        } else {
            DispatchQueue.main.async(execute: scrollToCenter)
        }
    }
}

/// 搜索框 + 排序维度 + 升降序 + 定位当前播放的歌曲。
private struct ListToolbar: View {
    @EnvironmentObject private var vm: PlayerViewModel
    let onLocate: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .font(.callout)

                TextField("搜索歌曲、歌手、专辑", text: $vm.searchText)
                    .textFieldStyle(.plain)
                    .font(.callout)

                if vm.isFiltering {
                    Button {
                        vm.clearSearch()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("清除搜索")
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))

            HStack(spacing: 6) {
                Picker("排序", selection: $vm.sortOrder) {
                    ForEach(TrackSortOrder.allCases, id: \.self) { order in
                        Text(order.displayName).tag(order)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .controlSize(.small)

                Button {
                    vm.toggleSortDirection()
                } label: {
                    Image(systemName: vm.sortAscending ? "arrow.up" : "arrow.down")
                }
                .buttonStyle(.borderless)
                .help(vm.sortAscending ? "升序" : "降序")

                // T-016：定位当前播放的歌曲。
                Button(action: onLocate) {
                    Image(systemName: "scope")
                }
                .buttonStyle(.borderless)
                .help("定位当前播放的歌曲")
                .disabled(!vm.canLocateCurrent)

                Spacer()

                // 总数在顶部标题栏，这里只在搜索时补一个命中数
                if vm.isFiltering {
                    Text("匹配 \(vm.tracks.count) 首")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }
}

private struct EmptyLibraryView: View {
    @EnvironmentObject private var vm: PlayerViewModel

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text(message)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            if vm.isFiltering {
                Button("清除搜索") { vm.clearSearch() }
            } else {
                Button("选择文件夹…") { vm.chooseFolder() }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var icon: String {
        vm.isFiltering ? "magnifyingglass" : "music.note.list"
    }

    private var message: String {
        if vm.isFiltering {
            return "没有匹配「\(vm.searchText)」的歌曲"
        }
        return vm.folderURL == nil ? "还没有选择音乐文件夹" : "该文件夹里没有音频文件"
    }
}
