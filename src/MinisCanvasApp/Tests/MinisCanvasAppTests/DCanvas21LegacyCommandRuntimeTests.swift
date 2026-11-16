import Foundation
import Testing
@testable import MinisCanvasApp

@Suite("D-CANVAS-21 legacy command runtime boundary", .serialized)
@MainActor
struct DCanvas21LegacyCommandRuntimeTests {
    @Test("closed Canvas rejects the legacy Chat command visibly without mutating")
    func closedCanvasLegacyCommandIsVisibleAndSideEffectFree() async throws {
        let bridge = BridgeStore(
            canvasRuntimeState: .enabled,
            allowsLegacyCanvasCommandExecutionForTests: true,
            canvasFeatureLane: .phase4OptIn
        )
        _ = bridge.updateSafetyRuntimeSnapshot(
            SafetyRuntimeSnapshot(safeModeEnabled: true)
        )
        let messageCountBefore = bridge.chat.messages.count

        bridge.chat.draftText = "建节点 text"
        bridge.chat.submitComposer()

        for _ in 0..<100 where bridge.chat.messages.count == messageCountBefore {
            try await Task.sleep(for: .milliseconds(10))
        }

        let rejection = try #require(bridge.chat.messages.dropFirst(messageCountBefore).last)
        #expect(rejection.role == .assistant)
        #expect(rejection.content.contains("画布功能当前已关闭"))
        #expect(bridge.canvas.graph.nodes.isEmpty)
        #expect(bridge.canvasMutationReceipts.isEmpty)
        #expect(bridge.composerCanvasDispatchCount == 0)
        #expect(bridge.lastCanvasMutationTask == nil)
    }
}
