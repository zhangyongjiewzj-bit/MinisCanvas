import Foundation

/// 单个会话的终端标签列表（纯值逻辑，不依赖真实 shell，便于单测）。
/// 标签编号只增不减：关掉“终端 2”后再新建是“终端 3”，已有标签的名字不会变。
struct TerminalPTYTabList: Equatable, Sendable {
    /// 每个会话最多同时开 8 个终端：每个终端是一个常驻 shell 进程加一份回滚缓冲，
    /// 8 个已远超日常并行需求，再多只会拖慢面板并让标签条放不下。
    static let maxTabs = 8

    private(set) var tabs: [Int] = []
    private(set) var selected: Int?
    private var nextNumber = 1

    var canAddTab: Bool { tabs.count < Self.maxTabs }

    /// 新建一个标签并切过去；到上限返回 nil。
    @discardableResult
    mutating func add() -> Int? {
        guard canAddTab else { return nil }
        let number = nextNumber
        nextNumber += 1
        tabs.append(number)
        selected = number
        return number
    }

    /// 只切换当前标签；编号不存在时忽略。
    mutating func select(_ number: Int) {
        guard tabs.contains(number) else { return }
        selected = number
    }

    /// 关闭标签。若关的是当前标签，改选原位置的右邻，没有右邻就选左邻；
    /// 关掉最后一个后 `selected` 为 nil（不自动再开）。返回关闭后的当前标签。
    @discardableResult
    mutating func close(_ number: Int) -> Int? {
        guard let index = tabs.firstIndex(of: number) else { return selected }
        tabs.remove(at: index)
        if selected == number {
            if tabs.isEmpty {
                selected = nil
            } else {
                selected = tabs[min(index, tabs.count - 1)]
            }
        }
        return selected
    }
}

/// 标签条上一项：编号 + 对应终端。
struct TerminalPTYTabItem: Identifiable {
    let number: Int
    let session: TerminalPTYSession
    var id: Int { number }

    /// 标题沿用 shell 设置的标题，空时显示“终端 N”。
    @MainActor var displayTitle: String {
        session.title.isEmpty ? "终端 \(number)" : session.title
    }
}
