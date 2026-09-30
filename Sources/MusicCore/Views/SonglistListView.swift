import SwiftUI

/// 歌单列表页：新建、进入详情、重命名、删除。
struct SonglistListView: View {
    @EnvironmentObject private var songlists: SonglistService
    @State private var openedSonglist: UUID?
    @State private var showingCreateSheet = false
    @State private var renamingID: UUID?
    @State private var deletingID: UUID?

    var body: some View {
        Group {
            if let openedSonglist, songlists.summaries.contains(where: { $0.id == openedSonglist }) {
                SonglistDetailView(id: openedSonglist) {
                    self.openedSonglist = nil
                }
            } else {
                listBody
            }
        }
        .task {
            await songlists.refresh()
        }
    }

    private var listBody: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(VisualEffectView(material: .sidebar, opacity: 1))
        .sheet(isPresented: $showingCreateSheet) {
            SonglistNameSheet(
                title: "新建歌单",
                existing: songlists.summaries.map { ($0.id, $0.name) },
                excluding: nil
            ) { name in
                let result = await songlists.create(name: name)
                if case .failure(let error) = result { return error }
                return nil
            }
        }
        .sheet(isPresented: Binding(get: { renamingID != nil }, set: { if !$0 { renamingID = nil } })) {
            if let id = renamingID, let current = songlists.summaries.first(where: { $0.id == id }) {
                SonglistNameSheet(
                    title: "重命名歌单",
                    initialText: current.name,
                    existing: songlists.summaries.map { ($0.id, $0.name) },
                    excluding: id
                ) { name in
                    let result = await songlists.rename(id, to: name)
                    if case .failure(let error) = result { return error }
                    return nil
                }
            }
        }
        .alert("删除歌单", isPresented: Binding(get: { deletingID != nil }, set: { if !$0 { deletingID = nil } })) {
            Button("删除", role: .destructive) {
                if let id = deletingID {
                    Task { _ = await songlists.delete(id) }
                }
                deletingID = nil
            }
            Button("取消", role: .cancel) { deletingID = nil }
        } message: {
            if let id = deletingID, let name = songlists.summaries.first(where: { $0.id == id })?.name {
                Text("确定删除歌单「\(name)」吗？歌单里的歌曲文件不会被删除。")
            }
        }
    }

    private var header: some View {
        HStack {
            Text("歌单")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                showingCreateSheet = true
            } label: {
                Label("新建歌单", systemImage: "plus")
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var content: some View {
        if !songlists.isLoaded {
            VStack {
                ProgressView()
                Text("正在读取歌单…")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if songlists.summaries.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "music.note.list")
                    .font(.system(size: 40))
                    .foregroundStyle(.secondary)
                Text("还没有歌单")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(songlists.summaries) { summary in
                HStack {
                    Text(summary.name)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(summary.name)
                    Spacer()
                    Text("\(summary.count) 首")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
                .onTapGesture { openedSonglist = summary.id }
                .contextMenu {
                    Button("重命名…") { renamingID = summary.id }
                    Button("删除…", role: .destructive) { deletingID = summary.id }
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
        }
    }
}
