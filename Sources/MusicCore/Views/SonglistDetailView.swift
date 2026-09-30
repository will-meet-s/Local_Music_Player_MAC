import SwiftUI

/// 歌单详情页：显示歌单里的曲目。信息展示逻辑见 `SonglistService.resolve(_:)`（FR-012、FR-020）。
///
/// 本任务（T-003）只做浏览；双击播放歌单由 T-006 接入
/// （`entries(of:)` + `resolve(_:)` 得到 `[Track]`，传给 `NowPlayingList.playFromSonglist`）。
struct SonglistDetailView: View {
    let id: UUID
    let onBack: () -> Void

    @EnvironmentObject private var songlists: SonglistService
    @EnvironmentObject private var vm: PlayerViewModel

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
            // entries 里 path 按 TrackIdentity 不重复（§3.2），可以直接当 id 用。
            List {
                ForEach(entries, id: \.path) { entry in
                    TrackRow(track: songlists.resolve(entry), isCurrent: false, isPlaying: false)
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
        }
    }
}
