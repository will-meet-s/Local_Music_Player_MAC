import SwiftUI

/// 左侧曲目列表：搜索框 + 排序控件 + 列表。单击选中，双击播放。
struct TrackListView: View {
    @EnvironmentObject private var vm: PlayerViewModel
    @State private var selection: URL?

    var body: some View {
        VStack(spacing: 0) {
            ListToolbar()
            Divider()
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var content: some View {
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
}

/// 搜索框 + 排序维度 + 升降序。
private struct ListToolbar: View {
    @EnvironmentObject private var vm: PlayerViewModel

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

                Spacer()

                Text(countText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private var countText: String {
        vm.isFiltering
            ? "\(vm.tracks.count) / \(vm.library.count) 首"
            : "\(vm.library.count) 首"
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
