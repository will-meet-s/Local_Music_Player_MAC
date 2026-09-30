import SwiftUI

/// 歌单详情页：显示歌单里的曲目，支持多选、右键菜单、删除键（T-004），
/// 双击和「播放全部」播放歌单（T-006）。
/// 信息展示逻辑见 `SonglistService.resolve(_:)`（FR-012、FR-020）。
struct SonglistDetailView: View {
    let id: UUID
    let onBack: () -> Void

    @EnvironmentObject private var songlists: SonglistService
    @EnvironmentObject private var vm: PlayerViewModel
    @EnvironmentObject private var availability: AvailabilityStore
    @State private var selection = Set<URL>()
    /// F-7：不在曲库里的曲目，后台读到的元数据先放这里，读到一首就更新一首。
    @State private var loadedMetadata: [TrackIdentity: Track] = [:]
    /// T-012：歌单内搜索，不保存。
    @State private var searchText = ""

    private var name: String {
        songlists.summaries.first(where: { $0.id == id })?.name ?? ""
    }

    private var entries: [SonglistEntry] {
        songlists.entries(of: id) ?? []
    }

    /// T-012：和 `PlayerViewModel.isFiltering` 同一写法；T-005 用它禁止挪动顺序。
    private var isFiltering: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// T-006：详情页当前显示的曲目。点播时把这个数组本身传给 `playSonglist`/
    /// `playSonglistAll`——不要重新从 `SonglistService` 取，Swift 数组是值类型，
    /// 传过去就是一份独立快照。T-012：按歌单内搜索过滤，只过滤不排序（`filtered`
    /// 不是 `apply`），保持歌单里的原顺序。
    private var displayedTracks: [Track] {
        let allTracks = entries.map { resolvedTrack(for: $0) }
        return TrackFilter.filtered(allTracks, search: searchText)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            searchBar
            Divider()
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(VisualEffectView(material: .sidebar, opacity: vm.backgroundOpacity))
        .task(id: id) {
            await loadMissingMetadataAndRefreshCache()
        }
        // T-007 §2.3：打开某个歌单时，这一页的全部曲目用 high 优先级检查；
        // 离开时（切到别的歌单或返回列表）降级为 low。
        .task(id: id) { vm.checkAvailabilityHigh(displayedTracks) }
        .onDisappear { vm.demoteAvailabilityChecks() }
        // T-009 §6：登记「当前打开的歌单」，刷新曲库完成时 performScan 用它
        // 决定要不要额外给这个歌单的曲目排一次 high 优先级检查。
        .task(id: id) { songlists.openedID = id }
        .onDisappear { songlists.openedID = nil }
        // T-012：切换到另一个歌单时清空搜索词，不带着上一个歌单的搜索词进来。
        .onChange(of: id) { _, _ in searchText = "" }
    }

    /// T-012：样式照搬 `TrackListView` 的 `ListToolbar` 搜索框。
    private var searchBar: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .font(.callout)

                TextField("在歌单内搜索", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.callout)

                if isFiltering {
                    Button {
                        searchText = ""
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

            // T-005 §2：搜索时禁止挪动顺序，这里说明原因。
            if isFiltering {
                Text("清空搜索后可以调整顺序")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, isFiltering ? 4 : 8)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Button {
                onBack()
            } label: {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(.borderless)
            .help("返回歌单列表")

            Text(name)
                .lineLimit(2)
                .help(name)

            Spacer()

            Text("\(entries.count) 首")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button {
                let tracks = displayedTracks
                let songlistName = name
                Task { await vm.playSonglistAll(tracks, name: songlistName) }
            } label: {
                Label("播放全部", systemImage: "play.fill")
            }
            .disabled(displayedTracks.isEmpty)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var content: some View {
        if entries.isEmpty {
            emptyState(message: "歌单里还没有歌曲")
        } else if displayedTracks.isEmpty {
            // T-012：歌单本身不为空，只是搜索没有命中（FR-018、FR-022）。
            emptyState(message: "没有匹配「\(searchText)」的歌曲")
        } else {
            // Track.id（url）在 displayedTracks 里不重复（§3.2 entries 按 identity
            // 不重复，resolve 出来的也不重复），可以直接当多选的 tag 用。
            List(selection: $selection) {
                ForEach(displayedTracks, id: \.id) { track in
                    TrackRow(
                        track: track, isCurrent: track.identity == vm.playingTrack?.identity, isPlaying: vm.isPlaying,
                        isAvailable: availability.isAvailable(track.identity)
                    )
                    .tag(track.id)
                }
                // T-005 §2：搜索时禁止挪动（过滤后的「挪到第几位」对应不到完整
                // 列表里的确定位置）。
                .onMove(perform: isFiltering ? nil : handleMove)
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
            .contextMenu(forSelectionType: URL.self) { urls in
                contextMenuItems(for: urls)
            } primaryAction: { urls in
                // 双击用 primaryAction，不要再加 onTapGesture(count: 2)，否则会和多选冲突。
                guard urls.count == 1, let url = urls.first,
                      let index = displayedTracks.firstIndex(where: { $0.id == url }) else { return }
                let tracks = displayedTracks
                let songlistName = name
                Task { await vm.playSonglist(tracks, at: index, name: songlistName) }
            }
            .onDeleteCommand {
                removeSelected()
            }
        }
    }

    private func emptyState(message: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "music.note.list")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text(message)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func contextMenuItems(for urls: Set<URL>) -> some View {
        let selectedTracks = selectedTracks(for: urls)
        Button("下一首播放") { vm.playNext(selectedTracks) }
        Button("添加到播放列表末尾") { vm.appendToNowPlaying(selectedTracks) }
        AddToSonglistMenu(tracks: { selectedTracks }, excluding: id)
        // T-005 §2：恰好选中 1 首、且不在搜索中时才显示。
        if !isFiltering, urls.count == 1, let url = urls.first, let index = entryIndex(for: url) {
            Divider()
            Button("上移一位") { moveEntry(at: index, to: index - 1) }
                .disabled(index == 0)
            Button("下移一位") { moveEntry(at: index, to: index + 1) }
                .disabled(index == entries.count - 1)
        }
        Divider()
        Button("从歌单移除", role: .destructive) {
            removeByIdentity(Set(selectedTracks.map(\.identity)))
        }
    }

    /// `entries` 里 identity 与 `url`（`Track.id`）相同的下标。
    private func entryIndex(for url: URL) -> Int? {
        let target = TrackIdentity(url: url)
        return entries.firstIndex { TrackIdentity(path: $0.path) == target }
    }

    /// `onMove` 的 `destination` 是移除前的插入点，换算成「移除后的新位置」
    /// 和 T-008 §4.4 相同。`toIndex` 越界由 `MoveEntryOperation` 钳制。
    private func handleMove(from source: IndexSet, to destination: Int) {
        guard source.count == 1, let from = source.first, entries.indices.contains(from) else { return }
        let to = destination > from ? destination - 1 : destination
        moveEntry(at: from, to: to)
    }

    private func moveEntry(at index: Int, to toIndex: Int) {
        guard entries.indices.contains(index) else { return }
        let identity = TrackIdentity(path: entries[index].path)
        Task {
            _ = await songlists.move(identity, to: toIndex, in: id)
        }
    }

    /// 按 entries 的顺序解析出选中的曲目（`SelectionOrder.byListOrder` 按的是 `vm.tracks`
    /// 这份曲库列表；歌单详情页自己的列表另算，直接按 entries 顺序过滤即可）。
    private func selectedTracks(for urls: Set<URL>) -> [Track] {
        entries
            .map { resolvedTrack(for: $0) }
            .filter { urls.contains($0.id) }
    }

    private func removeSelected() {
        removeByIdentity(Set(selectedTracks(for: selection).map(\.identity)))
    }

    private func removeByIdentity(_ identities: Set<TrackIdentity>) {
        guard !identities.isEmpty else { return }
        Task {
            _ = await songlists.remove(Array(identities), from: id)
        }
        selection.removeAll()
    }

    /// 曲库里有就用曲库里已读好元数据的 Track（TC-036）；没有就先用 entry 里缓存的信息，
    /// 后台读到真实元数据后（F-7）用 `loadedMetadata` 覆盖显示。
    private func resolvedTrack(for entry: SonglistEntry) -> Track {
        let identity = TrackIdentity(path: entry.path)
        if let index = vm.libraryIndex[identity], vm.library.indices.contains(index) {
            return vm.library[index]
        }
        return loadedMetadata[identity] ?? songlists.resolve(entry)
    }

    /// F-7：详情页出现时，把「resolve 结果不在曲库里」的条目交给后台依次读元数据；
    /// 视图消失或切到别的歌单时 `.task(id:)` 自动取消。全部读完后，把和缓存不同的
    /// 那些条目合并成一次 `RefreshCacheOperation`，一个歌单只写一次，不出提示。
    private func loadMissingMetadataAndRefreshCache() async {
        let currentEntries = entries
        var updates: [TrackIdentity: SonglistEntry] = [:]

        for entry in currentEntries {
            if Task.isCancelled { return }
            let identity = TrackIdentity(path: entry.path)
            // 曲库里已经有的，不需要单独读（详情页会用 vm.library 的那份，且 vm 自己会刷新）。
            if vm.libraryIndex[identity] != nil { continue }

            let loaded = await MetadataLoader.load(url: URL(fileURLWithPath: entry.path))
            if Task.isCancelled { return }
            loadedMetadata[identity] = loaded

            if loaded.title != entry.title || loaded.artist != entry.artist
                || loaded.album != entry.album || loaded.duration != entry.duration {
                updates[identity] = SonglistEntry(
                    path: entry.path, title: loaded.title, artist: loaded.artist,
                    album: loaded.album, duration: loaded.duration
                )
            }
        }

        guard !Task.isCancelled, !updates.isEmpty else { return }
        // 失败也不提示，只是缓存没更新；不影响本次已经在界面上显示的内容。
        await songlists.refreshCacheSilently(RefreshCacheOperation(id: id, updates: updates))
    }
}
