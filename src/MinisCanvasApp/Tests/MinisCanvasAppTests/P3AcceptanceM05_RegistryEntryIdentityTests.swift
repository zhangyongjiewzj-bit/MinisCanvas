import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

@Suite("D-COMMAND-02 shared registered facts across non-UI entries")
@MainActor
struct P3AcceptanceM05RegistryEntryIdentityTests {
    @Test func oneRegistryMutationReachesPaletteMenuSlashAndHelpWithoutGrantingExecution() async throws {
        guard let isolation = try FormalTestIsolationPaths.resolveCurrentProcess() else {
            Issue.record("formal test isolation contract missing")
            return
        }
        let defaults = try #require(UserDefaults(
            suiteName: "\(isolation.userDefaultsSuiteName).m05-registry-\(UUID().uuidString)"
        ))
        let registry = CommandRegistry()
        registry.registerComposerCommands()
        let center = ComposerCommandAdjudicationCenter()
        #expect(center.installCommandRegistry(registry))
        #expect(center.installCommandRegistry(registry))
        #expect(!center.installCommandRegistry(CommandRegistry()))
        #expect(center.commandRegistry === registry)

        let palette = CommandPaletteModel(
            registry: registry,
            display: [:],
            favorites: FavoriteCommandsStore(defaults: defaults),
            debounceInterval: .zero
        )

        // Change the registered fact once. The four entry projections must
        // observe this instance instead of separately copied vocabularies.
        registry.register(CommandDefinition(
            id: "status", title: "合成禁用状态", aliases: ["状态"],
            category: .session,
            availability: { .disabled(reason: "合成阻断原因") }
        ) { _ in
            .failure("disabled command must never execute")
        })
        palette.refresh()

        let paletteStatus = try #require(palette.sections
            .flatMap(\.commands).first { $0.id == "status" })
        let menuStatus = try #require(AppCommandMenuBuilder.sections(
            registry: registry, display: [:]
        ).flatMap(\.commands).first { $0.id == "status" })
        let slashStatus = try #require(ComposerSlashCommandMenu.entries(
            matching: "/status", registry: registry
        ).first { $0.id == "status" })
        #expect(paletteStatus.title == "合成禁用状态")
        #expect(menuStatus.title == "合成禁用状态")
        #expect(!paletteStatus.isEnabled)
        #expect(!menuStatus.isEnabled)
        #expect(paletteStatus.disabledReason == "合成阻断原因")
        #expect(menuStatus.disabledReason == "合成阻断原因")
        #expect(slashStatus.descriptor.zhTitle == "合成禁用状态")
        #expect(slashStatus.state == .blocked(reason: "合成阻断原因"))

        let now = Date()
        let facts = ComposerPolicyFactSource(
            knownCapabilities: [], grantedCapabilities: [], allowedWriteRoots: [],
            workspaceID: "m05-registry-workspace",
            revision: "m05-registry-revision", grantEpoch: "m05-registry-epoch",
            leaseID: "m05-registry-lease", expiresAt: now.addingTimeInterval(600),
            revoked: false
        )
        let snapshot = ComposerSubmissionSnapshot(
            mode: .manual, approvalScope: .request, effort: .standard,
            sessionID: "m05-registry-session", turnID: 1,
            taskID: "chat:m05-registry-session:1:attempt",
            workspaceID: "m05-registry-workspace", createdAt: now,
            policyRevision: facts.revision, grantEpoch: facts.grantEpoch
        )
        let help = PendingCommandRequest(
            id: UUID(), commandID: "help", args: ["command_id": "status"],
            requiresPolicyApproval: false
        )
        #expect(center.evaluate(request: help, snapshot: snapshot, facts: facts) == .execute)
        #expect(center.projection?.text.contains("/status · 合成禁用状态") == true)
        #expect(center.projection?.text.contains("当前阻断：合成阻断原因") == true)

        // Registry presence is a discovery fact, never execution authority.
        await #expect(throws: CommandExecutionError.disabled(
            commandID: "status", reason: "合成阻断原因"
        )) {
            try await registry.execute(id: "status")
        }
    }
    @Test func installationPreservesRegisteredOverridesAndRejectsLateReplacement() {
        let registry = CommandRegistry()
        registry.registerComposerCommands()
        registry.register(CommandDefinition(
            id: "status", title: "保留当前注册事实", category: .session,
            availability: { .disabled(reason: "当前事实") }
        ) { _ in .failure("must never execute") })
        let center = ComposerCommandAdjudicationCenter()
        #expect(center.installCommandRegistry(registry))
        #expect(registry.command(id: "status")?.title == "保留当前注册事实")
        #expect(registry.command(id: "status")?.currentAvailability == .disabled(reason: "当前事实"))
        #expect(!center.installCommandRegistry(CommandRegistry()))
        #expect(center.commandRegistry === registry)
    }

}
