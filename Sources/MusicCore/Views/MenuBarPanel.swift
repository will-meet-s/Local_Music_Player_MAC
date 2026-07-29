import SwiftUI
import AppKit

/// 顶部状态栏图标点开后的小控制板：当前曲目 + 切歌 / 暂停 + 播放顺序。
///
/// 主窗口关掉之后 App 仍驻留在状态栏，所以这里还要提供「显示主窗口」和「退出」。
public struct MenuBarPanel: View {
    @EnvironmentObject private var vm: PlayerViewModel
    @Environment(\.openWindow) private var openWindow

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            nowPlaying

            HStack(spacing: 14) {
                Button {
                    vm.previousTrack()
                } label: {
                    Image(systemName: "backward.fill")
                }
                .disabled(vm.tracks.isEmpty)

                Button {
                    vm.togglePlayPause()
                } label: {
                    Image(systemName: vm.isPlaying ? "pause.fill" : "play.fill")
                        .frame(width: 16)
                }
                .disabled(vm.tracks.isEmpty)

                Button {
                    vm.nextTrack()
                } label: {
                    Image(systemName: "forward.fill")
                }
                .disabled(vm.tracks.isEmpty)

                Spacer()

                Button {
                    vm.cyclePlayMode()
                } label: {
                    Image(systemName: vm.playMode.symbolName)
                }
                .help(vm.playMode.displayName)
            }
            .buttonStyle(.borderless)
            .imageScale(.large)

            Divider()

            Button("刷新曲库") {
                vm.refreshLibrary()
            }
            .buttonStyle(.plain)
            .disabled(vm.folderURL == nil || vm.isScanning)

            Button("显示主窗口") {
                showMainWindow()
            }
            .buttonStyle(.plain)

            Button("退出") {
                NSApp.terminate(nil)
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .frame(width: 250)
    }

    @ViewBuilder
    private var nowPlaying: some View {
        if let track = vm.currentTrack {
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                if !track.subtitle.isEmpty {
                    Text(track.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        } else {
            Text("未在播放")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    /// 窗口还在就前置，已关闭才新开一个 —— 直接 openWindow 会开出第二个主窗口。
    ///
    /// `.window` 风格的状态栏面板自身也是个 NSPanel，所以判断时要把 NSPanel 排除掉。
    private func showMainWindow() {
        let existing = NSApp.windows.first { window in
            !(window is NSPanel) && window.contentView != nil && window.canBecomeMain
        }

        if let existing {
            existing.makeKeyAndOrderFront(nil)
        } else {
            openWindow(id: PlayerWindow.mainID)
        }

        NSApp.activate(ignoringOtherApps: true)
    }
}

/// 主窗口的标识，供 `WindowGroup(id:)` 与 `openWindow(id:)` 共用。
public enum PlayerWindow {
    public static let mainID = "main"
}
