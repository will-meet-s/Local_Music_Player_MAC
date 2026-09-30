import SwiftUI

/// 歌单详情页：显示歌单里的曲目，支持多选、右键菜单、删除键（T-004）。
/// 信息展示逻辑见 `SonglistService.resolve(_:)`（FR-012、FR-020）。
///
/// 双击播放歌单由 T-006 接入（`entries(of:)` + `resolve(_:)` 得到 `[Track]`，
/// 传给 `NowPlayingList.playFromSonglist`）。
struct SonglistDetailView: View {
    let id: UUID
    let onBack: () -> Void

    @EnvironmentObject private var songlists: SonglistService
    @EnvironmentObject private var vm: PlayerViewModel
    @State private var selection = Set<URL>()
    /// F-7：不在曲库里的曲目，后台读到的元数据先放这里，读到一首就更新一首。
    @State private var loadedMetadata: [TrackIdentity: Track] = [:]

    private var name: String {
        songlists.summaries.first(where: { $0.id == id })?.name ?? ""
    }

    private var entries: [SonglistEntry] {
        songlists.entries(of: id) ?? []
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(VisualEffectView(material: .sidebar, opacity: vm.backgroundOpacity))
        .task(id: id) {
            await loadMissingMetadataAndRefreshCache()
        }
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
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var content: some View {
        if entries.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "music.note.list")
                    .font(.system(size: 40))
                    .foregroundStyle(.secondary)
                Text("歌单里还没有歌曲")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            // entries 里 path 按 TrackIdentity 不重复（§3.2），resolve 出来的 Track.id
            // 因此也不重复，可以直接当多选的 tag 用。
            List(selection: $selection) {
                ForEach(entries, id: \.path) { entry in
                    let track = resolvedTrack(for: entry)
                    TrackRow(track: track, isCurrent: false, isPlaying: false)
                        .tag(track.id)
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
            .contextMenu(forSelectionType: URL.self) { urls in
                contextMenuItems(for: urls)
            }
            .onDeleteCommand {
                removeSelected()
            }
        }
    }

    @ViewBuilder
    private func contextMenuItems(for urls: Set<URL>) -> some View {
        let selectedTracks = selectedTracks(for: urls)
        Button("下一首播放") { vm.playNext(selectedTracks) }
        Button("添加到播放列表末尾") { vm.appendToNowPlaying(selectedTracks) }
        AddToSonglistMenu(tracks: { selectedTracks }, excluding: id)
        Divider()
        Button("从歌单移除", role: .destructive) {
            removeByIdentity(Set(selectedTracks.map(\.identity)))
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
