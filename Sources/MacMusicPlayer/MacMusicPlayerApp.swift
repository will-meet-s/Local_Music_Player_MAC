import SwiftUI
import AppKit
import MusicCore

// PlayerViewModel 是 @MainActor 隔离的，App 也标注上才能在属性初始化处直接构造它。
@main
@MainActor
struct MacMusicPlayerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var viewModel = PlayerViewModel()

    var body: some Scene {
        WindowGroup("音乐播放器", id: PlayerWindow.mainID) {
            ContentView()
                .environmentObject(viewModel)
                .frame(minWidth: 880, minHeight: 560)
        }
        .windowResizability(.contentMinSize)
        .commands {
            // 这不是文档型应用，去掉「新建」菜单项
            CommandGroup(replacing: .newItem) {}

            CommandMenu("播放") {
                Button("播放 / 暂停") { viewModel.togglePlayPause() }
                    .keyboardShortcut("p", modifiers: [.command])
                Button("停止") { viewModel.stop() }
                    .keyboardShortcut(".", modifiers: [.command])
                Divider()
                Button("上一首") { viewModel.previousTrack() }
                    .keyboardShortcut(.leftArrow, modifiers: [.command])
                Button("下一首") { viewModel.nextTrack() }
                    .keyboardShortcut(.rightArrow, modifiers: [.command])
                Divider()
                Button("切换播放顺序") { viewModel.cyclePlayMode() }
                    .keyboardShortcut("l", modifiers: [.command])
                Divider()
                Button("选择文件夹…") { viewModel.chooseFolder() }
                    .keyboardShortcut("o", modifiers: [.command])
            }

            CommandMenu("显示") {
                Button("封面 + 歌词") { viewModel.nowPlayingLayout = .artworkAndLyrics }
                    .keyboardShortcut("1", modifiers: [.command])
                Button("只看封面") { viewModel.nowPlayingLayout = .artworkOnly }
                    .keyboardShortcut("2", modifiers: [.command])
                Button("只看歌词") { viewModel.nowPlayingLayout = .lyricsOnly }
                    .keyboardShortcut("3", modifiers: [.command])
            }
        }

        // 顶部状态栏常驻控制板。主窗口关掉后 App 仍留在这里。
        MenuBarExtra {
            MenuBarPanel()
                .environmentObject(viewModel)
        } label: {
            Image(systemName: viewModel.isPlaying ? "music.note" : "music.note.list")
        }
        .menuBarExtraStyle(.window)
    }
}

/// `swift run` 直接跑未打包的二进制时，进程默认没有 Dock 图标也不会前置，
/// 这里显式设为常规 App 并激活。打包成 .app 后这两句是无害的。
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// 返回 false，这样关掉主窗口后 App 继续在状态栏里播放。
    /// 退出走 ⌘Q 或状态栏面板里的「退出」。
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// 点 Dock 图标时把主窗口叫回来。
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows {
            NSApp.activate(ignoringOtherApps: true)
        }
        return true
    }
}
