import SwiftUI
import AppKit

/// 右侧：封面 + 曲目信息 + 歌词。
struct NowPlayingView: View {
    @EnvironmentObject private var vm: PlayerViewModel

    var body: some View {
        VStack(spacing: 16) {
            ArtworkView(data: vm.currentTrack?.artworkData)
                .frame(width: 180, height: 180)

            VStack(spacing: 4) {
                Text(vm.currentTrack?.title ?? "未在播放")
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                if let subtitle = vm.currentTrack?.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Divider()

            LyricsView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
