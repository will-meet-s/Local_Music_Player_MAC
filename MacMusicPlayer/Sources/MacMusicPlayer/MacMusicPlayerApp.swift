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
        WindowGroup("音乐播放器") {
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
        }
    }
}

/// `swift run` 直接跑未打包的二进制时，进程默认没有 Dock 图标也不会前置，
/// 这里显式设为常规 App 并激活。打包成 .app 后这两句是无害的。
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
