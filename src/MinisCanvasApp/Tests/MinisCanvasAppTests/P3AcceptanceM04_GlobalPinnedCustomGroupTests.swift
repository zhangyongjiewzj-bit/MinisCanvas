import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

@Suite("D-SESSION-19 global pinned rows across group kinds")
@MainActor
struct P3AcceptanceM04_GlobalPinnedCustomGroupTests {
    @Test func customAndProjectPinsShareOneSectionWithoutDuplicateGroupRows() {
        let earlier = Date(timeIntervalSince1970: 2_000_000_000)
        let later = earlier.addingTimeInterval(60)
        func item(_ title: String, pinned: Bool, updatedAt: Date) -> ChatStore.SessionListItem {
            ChatStore.SessionListItem(
                session: ChatThread(
                    title: title,
                    createdAt: updatedAt.addingTimeInterval(-60),
                    updatedAt: updatedAt,
                    pinned: pinned
                ),
                execution: nil
            )
        }

        let customPin = item("自定义组置顶", pinned: true, updatedAt: earlier)
        let customPlain = item("自定义组普通", pinned: false, updatedAt: later)
        let projectPin = item("项目组置顶", pinned: true, updatedAt: later)
        let projectPlain = item("项目组普通", pinned: false, updatedAt: earlier)
        let groups = [
            ChatStore.SessionGroup(
                kind: .custom(UUID()),
                name: "自定义组",
                items: [customPin, customPlain]
            ),
            ChatStore.SessionGroup(
                kind: .project("synthetic-project"),
                name: "项目组",
                items: [projectPin, projectPlain]
            ),
        ]

        let pinned = SessionSidebarPinnedSection.pinnedItems(from: groups)
        #expect(pinned.map(\.id) == [projectPin.id, customPin.id])
        #expect(SessionSidebarPinnedSection.visibleItems(in: groups[0]).map(\.id) == [customPlain.id])
        #expect(SessionSidebarPinnedSection.visibleItems(in: groups[1]).map(\.id) == [projectPlain.id])
        let allVisibleIDs = pinned.map(\.id)
            + groups.flatMap { SessionSidebarPinnedSection.visibleItems(in: $0).map(\.id) }
        #expect(Set(allVisibleIDs).count == 4)
    }
}
