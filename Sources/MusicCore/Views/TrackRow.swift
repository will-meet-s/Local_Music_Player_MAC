import SwiftUI

/// 一行曲目信息，曲库列表、播放列表（T-001）、歌单详情（T-003）共用，
/// 保证同一首歌在三处显示的信息项完全一致（FR-012）。
struct TrackRow: View {
    let track: Track
    let isCurrent: Bool
    let isPlaying: Bool
    /// 找不到文件时（T-007）整行变淡、标题后面加「不可用」标记。默认 true，
    /// 不关心可用性的调用方（目前没有）不用特地传。
    var isAvailable: Bool = true

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
                HStack(spacing: 6) {
                    Text(track.title)
                        .lineLimit(1)
                        .fontWeight(isCurrent ? .semibold : .regular)
                    if !isAvailable {
                        Text("不可用")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
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
        .opacity(isAvailable ? 1 : 0.45)
        .help(isAvailable ? "" : "找不到文件：\(track.url.path)")
    }
}
