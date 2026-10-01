import Foundation

/// 歌单名称校验（FR-011），纯函数。
public enum SonglistName {
    /// - Parameters:
    ///   - input: 用户输入的原始名称
    ///   - existing: 已有歌单的 (id, name) 列表
    ///   - excluding: 改名时排除自身，避免和自己判重（Work → work 允许）
    public static func validate(
        _ input: String,
        existing: [(id: UUID, name: String)],
        excluding selfID: UUID?
    ) -> Result<String, SonglistError> {
        // N-1：半角空格、全角空格 U+3000（属于 Unicode Zs 类，包含在 .whitespaces 里）、
        // 制表符、换行都会被去掉；中间的空白保留。
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)

        // N-2
        guard !trimmed.isEmpty else { return .failure(.nameEmpty) }
        // N-4：按字形簇计数，一个 emoji、一个 𠮷 都算 1
        guard trimmed.count <= 100 else { return .failure(.nameTooLong) }

        // N-3：不区分大小写判重，改名时跳过自身
        for entry in existing {
            if entry.id == selfID { continue }
            let otherTrimmed = entry.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.compare(otherTrimmed, options: .caseInsensitive) == .orderedSame {
                return .failure(.nameDuplicate(existing: entry.name))
            }
        }

        // N-5：不做 Unicode 规范化，原样保存
        return .success(trimmed)
    }
}
