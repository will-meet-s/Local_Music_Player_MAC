import SwiftUI

public struct ContentView: View {
    @EnvironmentObject private var vm: PlayerViewModel
    @EnvironmentObject private var songlists: SonglistService

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            HeaderBar()
            Divider()

            if let message = vm.errorMessage {
                ErrorBanner(message: message) { vm.errorMessage = nil }
                Divider()
            }

            // T-004：SonglistService 的错误（saveFailed 等）和 vm.errorMessage 一样显示。
            if let message = songlists.errorMessage {
                ErrorBanner(message: message) { songlists.errorMessage = nil }
                Divider()
            }

            if let notice = vm.notice {
                NoticeBanner(message: notice)
                Divider()
            }

            HSplitView {
                LeftPaneView()
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
            songlists.playerViewModel = vm
            await songlists.loadAll()
        }
        // F-12：四个「添加到歌单」入口共用这一个 sheet；菜单项自己不再各挂一个 .sheet。
        // F-13：直接用 $songlists.pendingCreate 的 Binding，不要在 get 里现造包装值——
        // 那样每次重绘都会是新 UUID，sheet 会被判定成换了一个，反复关闭重开。
        .sheet(item: $songlists.pendingCreate) { pending in
            SonglistNameSheet(
                title: "新建歌单",
                existing: songlists.summaries.map { ($0.id, $0.name) },
                excluding: nil
            ) { name in
                let result = await songlists.create(name: name, with: pending.tracks)
                switch result {
                case .success(let addResult):
                    vm.showNotice(addResult.noticeText)
                    return nil
                case .failure(let error):
                    return error
                }
            }
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
                Button {
                    vm.refreshLibrary()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(vm.isScanning)
                .help("重新扫描该文件夹，同步新增或删除的歌曲（不打断播放）")

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
                Image(systemName: "slider.horizontal.3")
            }
            .help("设置")
            .popover(isPresented: $showingAppearance, arrowEdge: .bottom) {
                AppearancePopover()
                    .environmentObject(vm)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

/// 设置面板：音频处理 + 外观。
private struct AppearancePopover: View {
    @EnvironmentObject private var vm: PlayerViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            audioSection
            Divider()
            appearanceSection
        }
        .padding(14)
        .frame(width: 300)
    }

    private var audioSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("音频")
                .font(.callout.weight(.semibold))

            Toggle(isOn: $vm.replayGainEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("音量归一化")
                    Text("按文件里的 ReplayGain 标签补偿响度差异。没打标签的文件不受影响。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Toggle(isOn: $vm.sampleRateMatchingEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("匹配输出采样率")
                    Text("把系统输出设备切到与文件相同的采样率，避免重采样。会影响其他 App，"
                         + "且相邻曲目采样率不同时切歌会有停顿。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// 调的只是背景 —— 文字和控件始终 100% 不透明，所以拉到最低也还能看清。
    private var appearanceSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("背景不透明度")
                    .font(.callout.weight(.semibold))
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

/// 提示性文字（T-008）：3 秒后由 ViewModel 自动置 nil，这里不需要手动关闭按钮。
private struct NoticeBanner: View {
    let message: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle.fill")
                .foregroundStyle(Color.accentColor)
            Text(message)
                .font(.callout)
                .lineLimit(2)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.accentColor.opacity(0.12))
    }
}
