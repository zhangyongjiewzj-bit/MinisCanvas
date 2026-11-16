import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

@Suite("P3-ISO Canvas/Chat read-only settings projection")
struct CanvasChatIsolationSettingsTests {
    @Test("descriptor is true, read-only, non-persisted, and bound to the production guard")
    func descriptorIsMandatoryAndReadOnly() {
        let descriptor = CanvasChatIsolationPolicyDescriptor.current

        #expect(descriptor.key == "policy.canvas_chat_isolation")
        #expect(descriptor.effectiveValue)
        #expect(descriptor.defaultValue)
        #expect(descriptor.isReadOnly)
        #expect(!descriptor.canDisable)
        #expect(descriptor.resetValue == "N-A")
        #expect(descriptor.range == "N-A")
        #expect(
            descriptor.productionGuardCapability
                == ChatCanvasBoundaryContract.canvasMutationCapability
        )
    }

    @Test("SettingsCenter projects the mandatory policy without adding a settings field")
    @MainActor
    func settingsCenterProjectionDoesNotPersistPolicy() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "CanvasChatIsolationSettings-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let center = SettingsCenter(
            settingsStore: SettingsStore(directory: directory),
            envStore: EnvVarStore(directory: directory),
            memoryStore: MemoryStore(directory: directory),
            sessionStore: SessionStore(directory: directory),
            logManager: LogManager(directory: directory, ringCapacity: 20)
        )
        let projected = center.canvasChatIsolationPolicy
        let persisted = try String(
            contentsOf: directory.appendingPathComponent("settings.json"),
            encoding: .utf8
        )

        #expect(projected == CanvasChatIsolationPolicyDescriptor.current)
        #expect(projected.effectiveValue)
        #expect(projected.isReadOnly)
        #expect(!persisted.contains("policy.canvas_chat_isolation"))
    }

    @Test("Settings UI exposes a disabled read-only projection with no close path")
    func settingsUIProjectionIsVisibleAndDisabled() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/MinisCanvasApp/SettingsView.swift"
            ),
            encoding: .utf8
        )

        #expect(source.contains("Section(\"画布与对话隔离\")"))
        #expect(source.contains("center.canvasChatIsolationPolicy"))
        #expect(source.contains("isOn: .constant(isolation.effectiveValue)"))
        #expect(source.contains(".disabled(true)"))
        #expect(source.contains("settings.policy.canvas-chat-isolation"))
        #expect(source.contains("无需重置，始终保持隔离"))
        #expect(source.contains("对话不能直接修改画布内容"))
        #expect(source.contains("画布与对话独立运行，此保护始终开启。"))
        #expect(!source.contains("policyBoundaryRow(\"设置键\""))
        #expect(!source.contains("value: isolation.productionGuardCapability"))
        #expect(!source.contains("\"true，只读，不可关闭\""))
        #expect(source.contains("\"已启用，只读，不可关闭\""))
        #expect(!source.contains("center.canvasChatIsolationPolicy ="))
    }
}
