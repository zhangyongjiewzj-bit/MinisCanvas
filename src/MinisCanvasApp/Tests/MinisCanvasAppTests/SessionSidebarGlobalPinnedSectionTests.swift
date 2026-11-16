import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

/// P3-SESSION-02 聚焦测试：全局置顶区投影（SessionSidebarPinnedSection）。
/// 仅验证纯投影语义：跨组聚合、组内剔除、行守恒（不重复、不丢失）、
/// 稳定排序与空态；不触碰 ChatStore 生命周期，也不引入任何新会话状态。
@Suite("P3-SESSION-02 sidebar global pinned section")
@MainActor
struct SessionSidebarGlobalPinnedSectionTests {
    private func thread(
        _ title: String,
        pinned: Bool = false,
        updatedAt: Date
    ) -> ChatThread {
        ChatThread(
            title: title,
            createdAt: updatedAt.addingTimeInterval(-60),
            updatedAt: updatedAt,
            pinned: pinned
        )
    }

    private func item(
        _ title: String,
        pinned: Bool = false,
        updatedAt: Date
    ) -> ChatStore.SessionListItem {
        ChatStore.SessionListItem(
            session: thread(title, pinned: pinned, updatedAt: updatedAt),
            execution: nil
        )
    }

    private func group(
        _ name: String,
        projectID: String?,
        items: [ChatStore.SessionListItem]
    ) -> ChatStore.SessionGroup {
        ChatStore.SessionGroup(kind: .project(projectID), name: name, items: items)
    }

    private let base = Date(timeIntervalSince1970: 2_000_000_000)

    @Test("pinned rows from different groups converge into one section, newest first")
    func aggregatesAcrossGroupsByRecency() {
        let older = item("older-pin", pinned: true, updatedAt: base.addingTimeInterval(-300))
        let newer = item("newer-pin", pinned: true, updatedAt: base)
        let plain = item("plain", updatedAt: base.addingTimeInterval(-60))
        let groups = [
            group("A", projectID: "pa", items: [older, plain]),
            group("B", projectID: "pb", items: [newer]),
        ]
        let section = SessionSidebarPinnedSection.pinnedItems(from: groups)
        #expect(section.map(\.id) == [newer.id, older.id])
    }

    @Test("same-activity pins keep a deterministic ID-ordered tie without dropping rows")
    func stableTieBreak() {
        let shared = base.addingTimeInterval(-42)
        let groups = [
            group("A", projectID: "pa", items: [
                item("tie-a", pinned: true, updatedAt: shared),
                item("tie-b", pinned: true, updatedAt: shared),
            ]),
        ]
        let section = SessionSidebarPinnedSection.pinnedItems(from: groups)
        #expect(section.count == 2)
        let expected = section.map(\.id).sorted { $0.uuidString < $1.uuidString }
        #expect(section.map(\.id) == expected)
    }

    @Test("group rows drop pinned members and preserve the remaining order")
    func groupRowsExcludePinned() {
        let first = item("first", updatedAt: base.addingTimeInterval(-10))
        let pinned = item("pinned", pinned: true, updatedAt: base)
        let last = item("last", updatedAt: base.addingTimeInterval(-20))
        let groups = [group("A", projectID: "pa", items: [first, pinned, last])]
        #expect(SessionSidebarPinnedSection.visibleItems(in: groups[0]).map(\.id) == [first.id, last.id])
    }

    @Test("section + group rows conserve every session exactly once (no loss, no duplicate)")
    func projectionConservesRows() {
        let pins = (0..<3).map { i in
            item("pin-\(i)", pinned: true, updatedAt: base.addingTimeInterval(TimeInterval(i)))
        }
        let plains = (0..<4).map { i in
            item("plain-\(i)", updatedAt: base.addingTimeInterval(TimeInterval(i)))
        }
        let groups = [
            group("A", projectID: "pa", items: [pins[0], plains[0], plains[1]]),
            group("B", projectID: nil, items: [pins[1], plains[2]]),
            group("C", projectID: "pc", items: [pins[2], plains[3]]),
        ]
        let section = SessionSidebarPinnedSection.pinnedItems(from: groups)
        let renderedGroups = groups.flatMap { SessionSidebarPinnedSection.visibleItems(in: $0) }
        #expect(section.count == 3)
        #expect(renderedGroups.count == 4)
        let renderedIDs = Set(section.map(\.id) + renderedGroups.map(\.id))
        #expect(renderedIDs.count == section.count + renderedGroups.count)
        #expect(renderedIDs == Set(pins.map(\.id) + plains.map(\.id)))
    }

    @Test("no pinned sessions yields an empty section and untouched group rows")
    func emptySectionWhenNothingPinned() {
        let items = [item("a", updatedAt: base), item("b", updatedAt: base.addingTimeInterval(-5))]
        let groups = [group("A", projectID: "pa", items: items)]
        #expect(SessionSidebarPinnedSection.pinnedItems(from: groups).isEmpty)
        #expect(SessionSidebarPinnedSection.visibleItems(in: groups[0]) == items)
    }

    @Test("a fully pinned group still projects (header semantics keep the real entity)")
    func fullyPinnedGroupRemainsProjectable() {
        let pinned = item("only-pin", pinned: true, updatedAt: base)
        let groups = [group("A", projectID: "pa", items: [pinned])]
        #expect(SessionSidebarPinnedSection.pinnedItems(from: groups).map(\.id) == [pinned.id])
        #expect(SessionSidebarPinnedSection.visibleItems(in: groups[0]).isEmpty)
    }

    @Test("projection is pure: repeated calls never mutate source groups")
    func projectionIsPure() {
        let mixed = item("mixed", pinned: true, updatedAt: base)
        let plain = item("plain", updatedAt: base.addingTimeInterval(-1))
        let groups = [group("A", projectID: "pa", items: [mixed, plain])]
        let snapshot = groups
        _ = SessionSidebarPinnedSection.pinnedItems(from: groups)
        _ = SessionSidebarPinnedSection.visibleItems(in: groups[0])
        #expect(groups == snapshot)
        #expect(groups[0].items.count == 2)
    }

}
