import SwiftUI

public struct ContentView: View {
    @EnvironmentObject private var vm: PlayerViewModel

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            HeaderBar()
            Divider()

            if let message = vm.errorMessage {
                ErrorBanner(message: message) { vm.errorMessage = nil }
                Divider()
            }

            HSplitView {
                TrackListView()
                    .frame(minWidth: 260, idealWidth: 320, maxWidth: 460)
                NowPlayingView()
                    .frame(minWidth: 360, maxWidth: .infinity)
            }
            .frame(maxHeight: .infinity)

            Divider()
            ControlsBar()
        }
        .frostedBackground(opacity: vm.backgroundOpacity)
        .task {
            vm.restoreLastSession()
        }
    }
}

private struct HeaderBar: View {
    @EnvironmentObject private var vm: PlayerViewModel
    @State private var showingAppearance = false

    var body: some View {
        HStack(spacing: 12) {
            Button {
                vm.chooseFolder()
            } label: {
                Label("选择文件夹", systemImage: "folder")
            }

            if let folder = vm.folderURL {
                Text(folder.path)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .help(folder.path)
            }

            Spacer()

            if vm.isScanning {
                ProgressView()
                    .controlSize(.small)
                Text("扫描中…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else if !vm.library.isEmpty {
                // 文件夹里的总曲目数。搜索命中数另外显示在列表工具条上。
                Text("共 \(vm.library.count) 首")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            Button {
                showingAppearance.toggle()
            } label: {
                Image(systemName: "circle.lefthalf.filled")
            }
            .help("背景透明度")
            .popover(isPresented: $showingAppearance, arrowEdge: .bottom) {
                AppearancePopover()
                    .environmentObject(vm)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

/// 背景磨砂层的不透明度调节。
///
/// 调的只是背景 —— 文字和控件始终 100% 不透明，所以拉到最低也还能看清。
private struct AppearancePopover: View {
    @EnvironmentObject private var vm: PlayerViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("背景不透明度")
                    .font(.callout.weight(.medium))
                Spacer()
                Text("\(Int((vm.backgroundOpacity * 100).rounded()))%")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                Image(systemName: "circle.dotted")
                    .foregroundStyle(.secondary)
                Slider(value: $vm.backgroundOpacity, in: Preferences.minBackgroundOpacity...1)
                Image(systemName: "circle.fill")
                    .foregroundStyle(.secondary)
            }
            .imageScale(.small)

            HStack {
                Text("最低 \(Int(Preferences.minBackgroundOpacity * 100))%")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("恢复不透明") {
                    vm.backgroundOpacity = 1
                }
                .buttonStyle(.link)
                .font(.caption)
            }
        }
        .padding(14)
        .frame(width: 260)
    }
}

private struct ErrorBanner: View {
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.callout)
                .lineLimit(2)
            Spacer()
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.12))
    }
}
