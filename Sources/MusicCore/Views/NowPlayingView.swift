import SwiftUI
import AppKit

/// 右侧「正在播放」区。三种展示模式：封面+歌词 / 只看封面 / 只看歌词。
struct NowPlayingView: View {
    @EnvironmentObject private var vm: PlayerViewModel

    var body: some View {
        Group {
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
        // 浮在右上角，不占布局空间 —— 整块区域的点击要留给歌词跳播
        .overlay(alignment: .topTrailing) {
            LayoutThumbnailButton()
                .padding(10)
        }
        .animation(.easeInOut(duration: 0.2), value: vm.nowPlayingLayout)
    }

    // MARK: - 三种模式

    private var artworkAndLyrics: some View {
        VStack(spacing: 16) {
            ArtworkView(data: vm.currentTrack?.artworkData)
                .frame(width: 180, height: 180)

            TrackTitleView(track: vm.currentTrack, compact: false)
            MissingFileNotice()

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
            MissingFileNotice()
        }
    }

    /// 歌词占满整区，曲目信息压成一行。
    private var lyricsOnly: some View {
        VStack(spacing: 10) {
            TrackTitleView(track: vm.currentTrack, compact: true)
            MissingFileNotice()

            Divider()

            LyricsView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// 文件已从曲库消失时的提示。
///
/// 这首歌还能放完（文件句柄已经打开），但列表里不再有它，所以要说明白，
/// 免得以为是被搜索过滤掉了。
private struct MissingFileNotice: View {
    @EnvironmentObject private var vm: PlayerViewModel

    var body: some View {
        if vm.playingTrackMissing {
            HStack(spacing: 5) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("文件已不在曲库中，本曲仍可播完")
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
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
                AddCurrentTrackToSonglistButton(track: track)
            }
            .frame(maxWidth: .infinity)
        } else {
            VStack(spacing: 4) {
                HStack(spacing: 6) {
                    Text(track?.title ?? "未在播放")
                        .font(.title3.weight(.semibold))
                        .lineLimit(1)
                    AddCurrentTrackToSonglistButton(track: track)
                }
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

/// T-004 §2.5：右侧「正在播放」区的"添加到歌单"入口，对象恒为当前这一首。
private struct AddCurrentTrackToSonglistButton: View {
    let track: Track?

    var body: some View {
        AddToSonglistMenu(tracks: { track.map { [$0] } ?? [] }, excluding: nil) {
            Image(systemName: "text.badge.plus")
        }
        .menuStyle(.borderlessButton)
        .frame(width: 20)
        .help("添加到歌单")
        .disabled(track == nil)
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
