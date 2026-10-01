import SwiftUI

/// 底部传输控制条：上一首 / 播放暂停 / 停止 / 下一首 / 进度 / 播放模式 / 音量。
struct ControlsBar: View {
    @EnvironmentObject private var vm: PlayerViewModel
    /// T-019：播放列表面板的开关。
    @Binding var showNowPlaying: Bool

    /// 拖动进度条期间用本地值，避免播放进度回调把滑块拽回去。
    @State private var seekValue: Double = 0
    @State private var isSeeking = false

    private var hasTrack: Bool { vm.currentTrack != nil }
    private var sliderRange: ClosedRange<Double> { 0...max(vm.duration, 0.01) }

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                Text(TimeFormat.string(isSeeking ? seekValue : vm.currentTime))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 46, alignment: .trailing)

                Slider(
                    value: $seekValue,
                    in: sliderRange,
                    onEditingChanged: { editing in
                        if editing {
                            isSeeking = true
                        } else {
                            isSeeking = false
                            vm.seek(to: seekValue)
                        }
                    }
                )
                .disabled(!hasTrack || vm.duration <= 0)

                Text(TimeFormat.string(vm.duration))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 46, alignment: .leading)
            }

            HStack(spacing: 18) {
                Spacer()

                // 顺序：上一首 → 播放/暂停 → 下一首 → 停止 → 播放顺序
                Button {
                    vm.previousTrack()
                } label: {
                    Image(systemName: "backward.fill").font(.title3)
                }
                .buttonStyle(.plain)
                .disabled(vm.tracks.isEmpty)

                Button {
                    vm.togglePlayPause()
                } label: {
                    Image(systemName: vm.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 34))
                }
                .buttonStyle(.plain)
                .disabled(vm.tracks.isEmpty)
                .keyboardShortcut(.space, modifiers: [])

                Button {
                    vm.nextTrack()
                } label: {
                    Image(systemName: "forward.fill").font(.title3)
                }
                .buttonStyle(.plain)
                .disabled(vm.tracks.isEmpty)

                Button {
                    vm.stop()
                } label: {
                    Image(systemName: "stop.fill").font(.title3)
                }
                .buttonStyle(.plain)
                .disabled(!hasTrack)

                Button {
                    vm.cyclePlayMode()
                } label: {
                    Image(systemName: vm.playMode.symbolName)
                        .frame(width: 22)
                }
                .buttonStyle(.plain)
                .help(vm.playMode.displayName)

                // T-019：播放列表面板开关（FR-030 ①②）。
                Button {
                    if !showNowPlaying { PerfTrace.begin("nowplaying.open") }
                    showNowPlaying.toggle()
                } label: {
                    Image(systemName: "list.bullet")
                        .frame(width: 22)
                }
                .buttonStyle(.plain)
                .foregroundStyle(showNowPlaying ? Color.accentColor : Color.secondary)
                .help(showNowPlaying ? "隐藏播放列表" : "显示播放列表")

                Spacer()

                HStack(spacing: 6) {
                    Image(systemName: volumeSymbol)
                        .foregroundStyle(.secondary)
                        .frame(width: 16)
                    Slider(value: $vm.volume, in: 0...1)
                        .frame(width: 90)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .onChange(of: vm.currentTime) { _, newValue in
            if !isSeeking { seekValue = newValue }
        }
        .onChange(of: vm.currentIndex) { _, _ in
            seekValue = 0
            isSeeking = false
        }
    }

    private var volumeSymbol: String {
        if vm.volume <= 0.001 { return "speaker.slash.fill" }
        if vm.volume < 0.4 { return "speaker.wave.1.fill" }
        if vm.volume < 0.75 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }
}
