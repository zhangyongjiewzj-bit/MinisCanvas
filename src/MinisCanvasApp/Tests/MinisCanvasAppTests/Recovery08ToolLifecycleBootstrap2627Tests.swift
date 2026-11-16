import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

/// The App's real production attachment must survive a durable lifecycle
/// projection that the canonical consumer rejects. These roots are synthetic.
@Suite("D-RECOVERY-08 tool lifecycle bootstrap", .serialized)
@MainActor
struct Recovery08ToolLifecycleBootstrap2627Tests {
    private func makeRoot() throws -> URL {
        let formalRoot = try #require(ProcessInfo.processInfo.environment["MINISCANVAS_TEST_DIRECTORY"])
        let root = URL(fileURLWithPath: formalRoot, isDirectory: true)
            .appendingPathComponent("recovery08-lifecycle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test("Future lifecycle schema preserves bytes, reports failure, and closes new turns")
    func futureSchemaDoesNotCrashProductionAttachment() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessions = root.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let journal = sessions.appendingPathComponent("tool-lifecycle-events-v1.json")
        let original = Data(#"{"schemaVersion":99,"events":[]}"#.utf8)
        try original.write(to: journal)

        // Core already rejects an unknown schema without rewriting it. The
        // missing coverage is the App assembly that currently traps on it.
        #expect(throws: ToolLifecycleConsumerError.corruptPersistence) {
            _ = try ToolLifecycleConsumer(persistenceURL: journal)
        }
        let bridge = BridgeStore()
        await bridge.attachProductionServices(
            sessionDirectory: sessions,
            mcpManager: MCPServerManager(fileURL: root.appendingPathComponent("mcps.json")),
            skillStore: SkillStore(skillsRoot: root.appendingPathComponent("skills"))
        ).value

        #expect(try Data(contentsOf: journal) == original)
        #expect(bridge.toolLifecycleRecoveryFailureURL == journal)
        #expect(bridge.recoveryNotices.contains { $0.contains("工具生命周期记录") })
        do {
            _ = try await bridge.chat.awaitApprovalRecovery()
            Issue.record("损坏的生命周期记录不得开放新回合")
        } catch {
            #expect(error.localizedDescription.contains("工具生命周期记录无法恢复"))
        }
    }

    @Test("Current lifecycle schema allows normal production attachment")
    func currentSchemaProductionAttachment() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessions = root.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let journal = sessions.appendingPathComponent("tool-lifecycle-events-v1.json")
        let valid = Data(#"{"schemaVersion":1,"events":[]}"#.utf8)
        try valid.write(to: journal)
        let bridge = BridgeStore()
        await bridge.attachProductionServices(
            sessionDirectory: sessions,
            mcpManager: MCPServerManager(fileURL: root.appendingPathComponent("mcps.json")),
            skillStore: SkillStore(skillsRoot: root.appendingPathComponent("skills"))
        ).value

        #expect(try Data(contentsOf: journal) == valid)
        #expect(bridge.toolLifecycleRecoveryFailureURL == nil)
        #expect(bridge.recoveryNotices.isEmpty)
        _ = try await bridge.chat.awaitApprovalRecovery()
    }
}
