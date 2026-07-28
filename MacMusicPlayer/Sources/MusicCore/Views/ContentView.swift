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
        .task {
            vm.restoreLastSession()
        }
    }
}

private struct HeaderBar: View {
    @EnvironmentObject private var vm: PlayerViewModel

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
            } else if !vm.tracks.isEmpty {
                Text("\(vm.tracks.count) 首")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
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
