import XCTest
@testable import MusicCore

final class SonglistNameTests: XCTestCase {

    private func assertFails(_ input: String, existing: [(id: UUID, name: String)] = [], excluding: UUID? = nil, expected: SonglistError, file: StaticString = #filePath, line: UInt = #line) {
        switch SonglistName.validate(input, existing: existing, excluding: excluding) {
        case .success:
            XCTFail("期望失败但成功了：\(input)", file: file, line: line)
        case .failure(let error):
            XCTAssertEqual(error, expected, file: file, line: line)
        }
    }

    private func assertSucceeds(_ input: String, existing: [(id: UUID, name: String)] = [], excluding: UUID? = nil, expected: String, file: StaticString = #filePath, line: UInt = #line) {
        switch SonglistName.validate(input, existing: existing, excluding: excluding) {
        case .success(let trimmed):
            XCTAssertEqual(trimmed, expected, file: file, line: line)
        case .failure(let error):
            XCTFail("期望成功但失败了：\(input)，错误：\(error)", file: file, line: line)
        }
    }

    // MARK: - #2 空名称

    func testEmptyAndWhitespaceOnlyNamesAreRejected() {
        assertFails("", expected: .nameEmpty)
        assertFails("   ", expected: .nameEmpty)
        assertFails("\u{3000}\u{3000}", expected: .nameEmpty) // 全角空格
        assertFails("\t\n", expected: .nameEmpty)
    }

    func testDuplicateIgnoringCaseAndSurroundingWhitespace() {
        let existing = [(id: UUID(), name: "Work")]
        assertFails("work", existing: existing, expected: .nameDuplicate(existing: "Work"))

        let existing2 = [(id: UUID(), name: "通勤")]
        assertFails(" 通勤\u{3000}", existing: existing2, expected: .nameDuplicate(existing: "通勤"))
    }

    // MARK: - #2a 改名跳过自身

    func testRenameToSameNameDifferentCaseSucceedsWhenExcludingSelf() {
        let id = UUID()
        assertSucceeds("work", existing: [(id: id, name: "Work")], excluding: id, expected: "work")
    }

    func testRenameTrimsButPreservesInnerSpaces() {
        let id = UUID()
        assertSucceeds(" 上 班 ", existing: [(id: id, name: "通勤")], excluding: id, expected: "上 班")
    }

    // MARK: - #2b 长度边界（按字形簇计数）

    func testLengthBoundary() {
        assertSucceeds(String(repeating: "长", count: 100), expected: String(repeating: "长", count: 100))
        assertSucceeds(String(repeating: "🎵", count: 100), expected: String(repeating: "🎵", count: 100))

        let ninetyNinePlusSurrogatePair = String(repeating: "长", count: 99) + "𠮷"
        assertSucceeds(ninetyNinePlusSurrogatePair, expected: ninetyNinePlusSurrogatePair)

        assertFails(String(repeating: "长", count: 101), expected: .nameTooLong)
    }

    // MARK: - 允许任意字符（路径特殊字符只是普通字符串）

    func testSpecialCharactersAreAllowedAsPlainText() {
        assertSucceeds("🎵通勤🚇", expected: "🎵通勤🚇")
        assertSucceeds("周杰倫・𠮷野家", expected: "周杰倫・𠮷野家")
        assertSucceeds("../../x", expected: "../../x")
        assertSucceeds("a/b", expected: "a/b")
        assertSucceeds("a:b", expected: "a:b")
        assertSucceeds("<>\"|?*", expected: "<>\"|?*")
    }

    func testEmbeddedNewlineIsTrimmedOnlyAtEnds() {
        // trimmingCharacters 只去首尾，中间的换行原样保留（输入框层面的替换是 T-003 §2.6 UI 逻辑，不在这里）
        assertSucceeds("第一行\n第二行", expected: "第一行\n第二行")
    }
}
