import SwiftUI

/// 左侧曲目列表。单击选中，双击（或回车）播放。
struct TrackListView: View {
    @EnvironmentObject private var vm: PlayerViewModel
    @State private var selection: URL?

    var body: some View {
        Group {
            if vm.tracks.isEmpty {
                EmptyLibraryView()
            } else {
                List(selection: $selection) {
                    ForEach(Array(vm.tracks.enumerated()), id: \.element.id) { index, track in
                        TrackRow(track: track, isCurrent: index == vm.currentIndex, isPlaying: vm.isPlaying)
                            .tag(track.id)
                            .contentShape(Rectangle())
                            .onTapGesture(count: 2) {
                                vm.play(at: index)
                            }
                    }
                }
                .listStyle(.inset)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct TrackRow: View {
    let track: Track
    let isCurrent: Bool
    let isPlaying: Bool

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                if isCurrent {
                    Image(systemName: isPlaying ? "speaker.wave.2.fill" : "pause.fill")
                        .foregroundStyle(.tint)
                }
            }
            .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .lineLimit(1)
                    .fontWeight(isCurrent ? .semibold : .regular)
                if !track.subtitle.isEmpty {
                    Text(track.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            if track.duration > 0 {
                Text(TimeFormat.string(track.duration))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
    }
}

private struct EmptyLibraryView: View {
    @EnvironmentObject private var vm: PlayerViewModel

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "music.note.list")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text(vm.folderURL == nil ? "还没有选择音乐文件夹" : "该文件夹里没有音频文件")
                .foregroundStyle(.secondary)
            Button("选择文件夹…") {
                vm.chooseFolder()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
