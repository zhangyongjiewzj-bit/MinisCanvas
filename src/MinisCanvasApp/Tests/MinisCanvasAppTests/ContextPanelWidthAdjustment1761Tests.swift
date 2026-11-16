import Foundation
import Testing
@testable import MinisCanvasApp

@Suite("D-APP-05 context width accessible adjustment")
struct ContextPanelWidthAdjustment1761Tests {
    @Test func pointerAndAccessibleAdjustmentSharePersistedWidthAndResetDragOrigin() throws {
        let suite = "ContextPanel1761-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var state = ContextPanelWidthDragState(defaults: defaults)

        state.applyPersistedTranslation(-40, defaults: defaults)
        #expect(state.width == 340)
        state.adjustPersisted(by: 32, defaults: defaults)
        #expect(state.width == 372)
        #expect(state.dragStartWidth == nil)
        #expect(defaults.double(forKey: ContextPanelWidthDragState.settingsKey) == 372)

        // A fresh pointer gesture must use 372, not the old 300-point origin.
        state.applyPersistedTranslation(16, defaults: defaults)
        #expect(state.width == 356)
        state.endDrag()
        defaults.synchronize()
        let reopened = ContextPanelWidthDragState(defaults: try #require(UserDefaults(suiteName: suite)))
        #expect(reopened.width == 356)
    }

    @Test func accessibleAdjustmentPreservesMinimumAndRejectsInvalidDeltas() throws {
        let suite = "ContextPanel1761-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var state = ContextPanelWidthDragState(defaults: defaults)

        state.adjustPersisted(by: -10_000, defaults: defaults)
        #expect(state.width == SidebarWidthMemory.minWidth)
        for invalid in [Double.nan, .infinity, -.infinity] {
            state.adjustPersisted(by: invalid, defaults: defaults)
            #expect(state.width == SidebarWidthMemory.minWidth)
        }
        state.adjustPersisted(by: 32, defaults: defaults)
        #expect(state.width == SidebarWidthMemory.minWidth + 32)
        #expect(ContextPanelWidthDragState(defaults: defaults).width == state.width)
    }
}
