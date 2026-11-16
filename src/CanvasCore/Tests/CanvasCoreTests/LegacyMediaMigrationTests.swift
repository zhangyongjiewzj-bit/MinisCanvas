import Testing
import Foundation
@testable import CanvasCore

struct LegacyMediaMigrationTests {
    @Test func legacyImageMigrationIsDeterministicAndPreservesURL() {
        let canvasID = UUID()
        let nodeID = UUID()
        let node = CanvasNode(id: nodeID, type: "assetRef", title: "图", backendConfig: NodeBackendConfig(params: ["result.path": "/tmp/a.png", "result.kind": "image", "result.name": "a.png"]))
        let first = LegacyMediaMigration.asset(from: node, canvasID: canvasID)
        let second = LegacyMediaMigration.asset(from: node, canvasID: canvasID)
        #expect(first == second)
        #expect(first?.kind == .image)
        #expect(first?.localURL == "/tmp/a.png")
    }

    @Test func missingOrUnknownLegacyFieldsAreRejected() {
        let missing = CanvasNode(type: "assetRef", title: "空")
        #expect(LegacyMediaMigration.asset(from: missing, canvasID: UUID()) == nil)
        let unknown = CanvasNode(type: "assetRef", title: "未知", backendConfig: NodeBackendConfig(params: ["result.path": "/tmp/a", "result.kind": "audio"]))
        #expect(LegacyMediaMigration.asset(from: unknown, canvasID: UUID()) == nil)
    }
}
