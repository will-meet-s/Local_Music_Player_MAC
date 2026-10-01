import SwiftUI

/// 新建 / 重命名歌单的名称输入框。
struct SonglistNameSheet: View {
    let title: String
    let existing: [(id: UUID, name: String)]
    let excluding: UUID?
    let onConfirm: (String) async -> SonglistError?

    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @State private var validationMessage: String?
    @State private var isSaving = false

    init(
        title: String,
        initialText: String = "",
        existing: [(id: UUID, name: String)],
        excluding: UUID?,
        onConfirm: @escaping (String) async -> SonglistError?
    ) {
        self.title = title
        self.existing = existing
        self.excluding = excluding
        self.onConfirm = onConfirm
        self._text = State(initialValue: initialText)
    }

    private var isValid: Bool {
        switch SonglistName.validate(text, existing: existing, excluding: excluding) {
        case .success: return true
        case .failure: return false
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)

            TextField("歌单名称", text: $text)
                .textFieldStyle(.roundedBorder)
                .onChange(of: text) { _, newValue in
                    text = Self.sanitize(newValue)
                    validationMessage = nil
                }
                .onSubmit(confirm)

            if let validationMessage {
                Text(validationMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("确定") { confirm() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isValid || isSaving)
            }
        }
        .padding(20)
        .frame(width: 320)
    }

    /// ① 把换行替换成一个半角空格（单行输入框，粘贴带换行的文字时）；
    /// ② 替换后如果超过 100 个字符就截断。不在输入法组字过程中触发（macOS TextField
    /// 组字期间不回写绑定），所以不会打断拼音输入。
    private static func sanitize(_ input: String) -> String {
        var result = input
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
        if result.count > 100 {
            result = String(result.prefix(100))
        }
        return result
    }

    private func confirm() {
        guard isValid, !isSaving else { return }
        isSaving = true
        Task {
            let error = await onConfirm(text)
            isSaving = false
            if let error {
                validationMessage = error.message
            } else {
                dismiss()
            }
        }
    }
}
