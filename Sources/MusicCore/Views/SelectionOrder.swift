import Foundation

enum SelectionOrder {
    /// 按 list 里的上下顺序返回被选中的曲目，与点选先后无关（FR-004 ①、FR-005、FR-015）。
    ///
    /// `Set` 本身无序，所以不存在「点选先后」的问题；关键是不能把 `Set` 直接
    /// `map` 成数组传下去。
    static func byListOrder(_ selection: Set<URL>, in list: [Track]) -> [Track] {
        list.filter { selection.contains($0.id) }
    }
}
