import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

/// Registry/consumer source coverage, not native button or shortcut evidence.
/// No BridgeStore is constructed: its WorkflowStore.shared seam is not isolated.
@Suite("D-COMMAND-02 Composer stop consumes registered menu facts")
@MainActor
struct ComposerStopRegistryConsumer369Tests {
    private actor Calls {
        private(set) var count = 0
        func record() { count += 1 }
    }

    @MainActor
    private final class StopSession {
        var activeSessionID: UUID? = UUID()
        var stoppedSessions: [UUID?] = []
        func stop() { stoppedSessions.append(activeSessionID) }
    }

    private final class LifecycleProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var deinitCount = 0
        private var stopCount = 0
        var deinits: Int { lock.withLock { deinitCount } }
        var stops: Int { lock.withLock { stopCount } }
        func recordDeinit() { lock.withLock { deinitCount += 1 } }
        func recordStop() { lock.withLock { stopCount += 1 } }
    }

    @MainActor
    private final class LifecycleOwner {
        let sessionID = UUID()
        let probe: LifecycleProbe
        var registry: CommandRegistry?
        init(probe: LifecycleProbe) { self.probe = probe }
        func stop() { probe.recordStop() }
        deinit { probe.recordDeinit() }
    }

    @Test func visibleButtonAndMenuUseTheSameUpdatedStopFacts() throws {
        let registry = CommandRegistry(commands: [CommandDefinition(
            id: "ui.chat.stop", title: "停止生成", category: .session
        ) { _ in .success("") }])
        let original = try #require(AppCommandMenuBuilder.command(
            id: "ui.chat.stop", registry: registry, display: [:]
        ))
        #expect(original.isEnabled)

        registry.register(CommandDefinition(
            id: "ui.chat.stop", title: "合成停止命令", category: .session,
            availability: { .disabled(reason: "合成停止阻断") }
        ) { _ in .failure("disabled executor must not run") })
        let button = try #require(AppCommandMenuBuilder.command(
            id: "ui.chat.stop", registry: registry, display: [:]
        ))
        let menu = try #require(AppCommandMenuBuilder.sections(
            registry: registry, display: [:]
        ).flatMap(\.commands).first { $0.id == "ui.chat.stop" })
        #expect(button.id == menu.id)
        #expect(button.title == "合成停止命令")
        #expect(button.title == menu.title)
        #expect(!button.isEnabled && !menu.isEnabled)
        #expect(button.disabledReason == "合成停止阻断")
        #expect(button.disabledReason == menu.disabledReason)
    }

    @Test func existingRunnerStopsOnceAndRechecksDisabledFactsAtExecution() async throws {
        let calls = Calls()
        let registry = CommandRegistry(commands: [CommandDefinition(
            id: "ui.chat.stop", title: "停止生成", category: .session
        ) { _ in
            await calls.record()
            return .success("")
        }])
        let button = try #require(AppCommandMenuBuilder.command(
            id: "ui.chat.stop", registry: registry, display: [:]
        ))
        #expect(button.isEnabled)
        #expect(registry.command(id: button.id)?.requiresConfirmation == false)
        let result = try await registry.execute(id: button.id)
        #expect(result.text.isEmpty)
        #expect(await calls.count == 1)

        // A captured enabled button cannot bypass a later registered blocker.
        registry.register(CommandDefinition(
            id: "ui.chat.stop", title: "停止生成", category: .session,
            availability: { .disabled(reason: "执行时已禁用") }
        ) { _ in
            await calls.record()
            return .success("")
        })
        await #expect(throws: CommandExecutionError.disabled(
            commandID: "ui.chat.stop", reason: "执行时已禁用"
        )) {
            try await registry.execute(id: button.id)
        }
        #expect(await calls.count == 1)

        // Keep the existing runner's confirmation gate; no confirmation bypass.
        registry.register(CommandDefinition(
            id: "ui.chat.stop", title: "合成需确认命令", category: .session,
            requiresConfirmation: true
        ) { _ in
            await calls.record()
            return .success("")
        })
        await #expect(throws: CommandExecutionError.confirmationRequired("ui.chat.stop")) {
            try await registry.execute(id: button.id)
        }
        #expect(await calls.count == 1)
    }

    @Test func absentAndComposerOnlyCommandsNeverGainAButtonExecutor() throws {
        let registry = CommandRegistry()
        #expect(AppCommandMenuBuilder.command(
            id: "ui.chat.stop", registry: registry, display: [:]
        ) == nil)
        registry.registerComposerCommands()
        let command = try #require(AppCommandMenuBuilder.command(
            // /compact now has the real adjudicated replay consumer. Canvas
            // execution is still unavailable in the Phase 3 composer catalog.
            id: "canvas.run", registry: registry, display: [:]
        ))
        #expect(!command.isEnabled)
        #expect(command.disabledReason != nil)
        #expect(command.disabledReason == "当前没有已接线的生产执行入口")
    }

    @Test func actualRegisteredStopConsumerRejectsLateSessionAndKeepsSameSessionAndMenuCalls() async throws {
        let session = StopSession()
        let originalID = try #require(session.activeSessionID)
        let spec = AppCommandCatalog.stopGenerationSpec(
            activeSessionID: { session.activeSessionID },
            stopStreaming: { session.stop() }
        )
        let registry = CommandRegistry(commands: [spec.definition])
        #expect(!spec.definition.requiresConfirmation)
        let capturedArgs = ["session_id": originalID.uuidString]
        session.activeSessionID = UUID()
        await #expect(throws: CommandExecutionError.invalidArgument(
            commandID: "ui.chat.stop", argument: "session_id",
            reason: "停止操作所属会话已切换，未停止当前会话"
        )) {
            try await registry.execute(id: spec.definition.id, args: capturedArgs)
        }
        #expect(session.stoppedSessions.isEmpty)

        session.activeSessionID = originalID
        let sameSession = try await registry.execute(id: spec.definition.id, args: capturedArgs)
        #expect(sameSession.text.isEmpty)
        #expect(session.stoppedSessions == [originalID])

        let menuSession = UUID()
        session.activeSessionID = menuSession
        let menu = try await registry.execute(id: spec.definition.id)
        #expect(menu.text.isEmpty)
        #expect(session.stoppedSessions == [originalID, menuSession])
    }

    @Test func bothProductionStopButtonsConsumeProjectionAndExistingBridgeRunner() throws {
        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/MinisCanvasApp")
        for name in ["GlobalComposerView.swift", "ChatSidebarView.swift"] {
            let source = try String(contentsOf: sourceRoot.appendingPathComponent(name), encoding: .utf8)
            let start = try #require(source.range(of: "if chat.isActiveSessionStreaming {"))
            let end = try #require(source.range(of: "} else {", range: start.upperBound..<source.endIndex))
            let stop = String(source[start.lowerBound..<end.lowerBound])
            #expect(stop.contains("AppCommandMenuBuilder.command("))
            #expect(stop.contains("id: \"ui.chat.stop\", registry: bridge.commandRegistry"))
            #expect(stop.contains("bridge.runCommand(id: stopCommand.id, args:"))
            #expect(stop.contains("\"session_id\": chat.activeSessionID?.uuidString ?? \"\""))
            #expect(stop.contains(".disabled(!stopCommand.isEnabled)"))
            #expect(stop.contains(".accessibilityLabel(stopCommand.title)"))
            #expect(stop.contains("stopCommand.disabledReason"))
            #expect(!stop.contains("chat.stopStreaming()"))
        }
    }

    @Test func registryDoesNotRetainItsStopOwnerAndReleasedOwnerIsTypedDisabled() async throws {
        let probe = LifecycleProbe()
        var owner: LifecycleOwner? = LifecycleOwner(probe: probe)
        weak let witness = owner
        let capturedSession = try #require(owner?.sessionID)
        let spec = AppCommandCatalog.stopGenerationSpec(
            activeSessionID: { [weak owner] in
                guard let owner else {
                    throw CommandExecutionError.disabled(
                        commandID: "ui.chat.stop", reason: "命令宿主已释放"
                    )
                }
                return owner.sessionID
            },
            stopStreaming: { [weak owner] in
                guard let owner else {
                    throw CommandExecutionError.disabled(
                        commandID: "ui.chat.stop", reason: "命令宿主已释放"
                    )
                }
                owner.stop()
            }
        )
        let registry = CommandRegistry(commands: [spec.definition])
        owner?.registry = registry
        owner = nil
        #expect(witness == nil)
        #expect(probe.deinits == 1)

        for args in [[:], ["session_id": capturedSession.uuidString]] {
            await #expect(throws: CommandExecutionError.disabled(
                commandID: "ui.chat.stop", reason: "命令宿主已释放"
            )) {
                try await registry.execute(id: spec.definition.id, args: args)
            }
        }
        #expect(probe.stops == 0)
    }
}
