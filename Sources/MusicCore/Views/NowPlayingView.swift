import SwiftUI
import AppKit

/// 右侧「正在播放」区。三种展示模式：封面+歌词 / 只看封面 / 只看歌词。
struct NowPlayingView: View {
    @EnvironmentObject private var vm: PlayerViewModel

    var body: some View {
        VStack(spacing: 12) {
            LayoutPicker()

            switch vm.nowPlayingLayout {
            case .artworkAndLyrics:
                artworkAndLyrics
            case .artworkOnly:
                artworkOnly
            case .lyricsOnly:
                lyricsOnly
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeInOut(duration: 0.2), value: vm.nowPlayingLayout)
    }

    // MARK: - 三种模式

    private var artworkAndLyrics: some View {
        VStack(spacing: 16) {
            ArtworkView(data: vm.currentTrack?.artworkData)
                .frame(width: 180, height: 180)

            TrackTitleView(track: vm.currentTrack, compact: false)

            Divider()

            LyricsView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// 封面尽可能放大，保持正方形。
    private var artworkOnly: some View {
        VStack(spacing: 16) {
            ArtworkView(data: vm.currentTrack?.artworkData)
                .aspectRatio(1, contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            TrackTitleView(track: vm.currentTrack, compact: false)
        }
    }

    /// 歌词占满整区，曲目信息压成一行。
    private var lyricsOnly: some View {
        VStack(spacing: 10) {
            TrackTitleView(track: vm.currentTrack, compact: true)

            Divider()

            LyricsView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// 模式切换的分段控件。
private struct LayoutPicker: View {
    @EnvironmentObject private var vm: PlayerViewModel

    var body: some View {
        HStack {
            Spacer()
            Picker("展示模式", selection: $vm.nowPlayingLayout) {
                ForEach(NowPlayingLayout.allCases, id: \.self) { layout in
                    Image(systemName: layout.symbolName)
                        .help(layout.displayName)
                        .tag(layout)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 130)
        }
    }
}

/// 曲目标题与副标题。`compact` 时压成单行，给歌词腾地方。
private struct TrackTitleView: View {
    let track: Track?
    let compact: Bool

    var body: some View {
        if compact {
            HStack(spacing: 8) {
                Text(track?.title ?? "未在播放")
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                if let subtitle = track?.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity)
        } else {
            VStack(spacing: 4) {
                Text(track?.title ?? "未在播放")
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                if let subtitle = track?.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
    }
}

private struct ArtworkView: View {
    let data: Data?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.secondary.opacity(0.12))

            if let data, let image = NSImage(data: data) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            } else {
                Image(systemName: "music.note")
                    .font(.system(size: 48))
                    .foregroundStyle(.secondary)
            }
        }
    }
}
