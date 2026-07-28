import SwiftUI

/// 歌词区：带时间戳时逐行高亮并自动滚动；无时间戳时静态展示全文。
struct LyricsView: View {
    @EnvironmentObject private var vm: PlayerViewModel

    var body: some View {
        Group {
            if vm.lyrics.isEmpty {
                placeholder
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        LazyVStack(spacing: 10) {
                            // 顶部留白，让首行也能滚到视图中部
                            Color.clear.frame(height: 60)

                            ForEach(vm.lyrics) { line in
                                lyricRow(line)
                                    .id(line.id)
                            }

                            Color.clear.frame(height: 60)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 8)
                    }
                    .onChange(of: vm.currentLyricIndex) { _, newValue in
                        guard let newValue else { return }
                        withAnimation(.easeInOut(duration: 0.25)) {
                            proxy.scrollTo(newValue, anchor: .center)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func lyricRow(_ line: LyricLine) -> some View {
        let isCurrent = vm.lyricsAreSynced && line.id == vm.currentLyricIndex

        Text(line.text.isEmpty ? " " : line.text)
            .font(isCurrent ? .body.weight(.semibold) : .body)
            .foregroundStyle(isCurrent ? Color.primary : Color.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .scaleEffect(isCurrent ? 1.06 : 1.0)
            .animation(.easeInOut(duration: 0.2), value: isCurrent)
            .onTapGesture {
                // 点歌词跳播到该行
                if vm.lyricsAreSynced && line.time >= 0 {
                    vm.seek(to: line.time)
                }
            }
    }

    private var placeholder: some View {
        VStack(spacing: 8) {
            Image(systemName: "text.quote")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
            Text("暂无歌词")
                .foregroundStyle(.secondary)
            Text("把同名 .lrc 文件放在音频旁边即可显示")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
