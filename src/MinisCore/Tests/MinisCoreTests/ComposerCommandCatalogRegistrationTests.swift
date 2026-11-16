import Testing
import Foundation
@testable import MinisCore

// W5-COMMAND-REGISTRY-041: Phase 3 slash command registration in MinisCore.
//
// Consumes the dangling donor fbef9ecb9 CommandRegistry semantics (21-command
// bilingual catalog) plus the canonically routed `model` ID already present in
// the baseline, so the 17 Composer menu rows that W4-SLASHMENU-036 rendered as
// 阻断（尚未接入 Composer 路由）become real tri-state rows. The menu catalog
// order in MinisCanvasApp/ComposerSlashCommandMenu.swift and the ID list below
// must stay identical.
//
// Fail-closed invariants pinned here:
//  - an ID outside the vocabulary never builds a pending request,
//  - confirmation-required commands still refuse direct execution,
//  - composer vocabulary never resolves from natural-language prose,
//  - the registered closures still return the pending-request failure.

private let expectedComposerVocabulary: [String] = [
    "help", "commands", "boundary", "boundary.set", "add-dir", "status", "copy", "tasks",
    "stop", "compact", "retry", "canvas.run", "canvas.cancel",
    "canvas.minimap", "provider", "provider.use", "model", "workflow",
    "approve", "reject", "memory", "memory.propose", "skills", "permissions", "mcp",
    "context", "clear", "rewind", "doctor", "usage", "export", "rename", "resume", "plan", "shortcuts",
]

private let policyApprovalGatedIDs: Set<String> = [
    "boundary.set", "canvas.run", "provider.use", "workflow",
    "approve", "memory.propose", "compact", "add-dir",
]

private func makeComposerRegistry() -> CommandRegistry {
    let registry = CommandRegistry()
    registry.registerComposerCommands()
    return registry
}

@Suite("Phase 3 composer command registration (W5-041)")
struct ComposerCommandCatalogRegistrationTests {

    private let parser = CommandParser()

    @Test func phaseThreeSlashVocabularyIsFullyRegistered() {
        let registry = makeComposerRegistry()
        #expect(registry.count == expectedComposerVocabulary.count)
        #expect(registry.allCommands().map(\.id) == expectedComposerVocabulary)
        #expect(CommandRegistry.composerCommandIDs == Set(expectedComposerVocabulary))
        for id in expectedComposerVocabulary {
            #expect(registry.command(id: id) != nil, "三期常用命令 /\(id) 必须进入 registry")
        }
    }

    @Test func stopAndRetryHelpOmitUnusedTaskID() throws {
        for id in ["stop", "retry"] {
            let metadata = try #require(CommandRegistry.composerCommandMetadata.first { $0.id == id })
            #expect(metadata.parameterSummary == "无 / none")
            #expect(metadata.argumentSpecs.isEmpty)
            #expect(!metadata.argumentSpecs.contains { $0.name == "task_id" })
        }
    }

    @Test func localizedAliasesResolveToCanonicalComposerIDs() {
        let registry = makeComposerRegistry()
        let aliases: [(String, String)] = [
            // Baseline canonical identities must not regress.
            ("/compact", "compact"),
            ("/压缩", "compact"),
            ("/help", "help"),
            ("/帮助", "help"),
            ("/status", "status"),
            ("/状态", "status"),
            ("/tasks", "tasks"),
            ("/任务", "tasks"),
            ("/model", "model"),
            ("/模型", "model"),
            // Newly routed Phase 3 vocabulary.
            ("/命令列表", "commands"),
            ("/安全边界", "boundary"),
            ("/设置安全边界", "boundary.set"),
            ("/添加目录", "add-dir"),
            ("/停止", "stop"),
            ("/重试", "retry"),
            ("/执行画布", "canvas.run"),
            ("/取消画布", "canvas.cancel"),
            ("/小地图", "canvas.minimap"),
            ("/提供商", "provider"),
            ("/选择提供商", "provider.use"),
            // Single-token structured matching resolves the prefix command
            // first: "/provider …" is the `provider` command (the donor's
            // two-word alias "provider use" on provider.use is only a
            // metadata/alias key, not a parse override).
            ("/provider", "provider"),
            ("/工作流", "workflow"),
            ("/批准", "approve"),
            ("/拒绝", "reject"),
            ("/记忆", "memory"),
            ("/提议记忆", "memory.propose"),
            ("/技能", "skills"),
            ("/快捷键", "shortcuts"),
        ]
        for (input, expectedID) in aliases {
            let parsed = parser.parse(input, registry: registry)
            #expect(parsed.command?.id == expectedID, "输入 \(input) 应解析为 \(expectedID)")
            #expect(parsed.disposition == .command)
        }
    }

    @Test func policyApprovalGateCoversStateChangingCommands() {
        let registry = makeComposerRegistry()
        #expect(registry.command(id: "model")?.requiresConfirmation == false)
        for id in expectedComposerVocabulary {
            let parsed = parser.parse("/\(id)", registry: registry)
            let request = registry.makePendingRequest(for: parsed)
            #expect(request?.commandID == id)
            #expect(
                request?.requiresPolicyApproval == policyApprovalGatedIDs.contains(id),
                "审批位错误：/\(id)"
            )
        }
    }

    @Test func addDirectoryPreservesRawPathAndRequiresApproval() {
        let registry = makeComposerRegistry()
        let parsed = parser.parse("/add-dir /synthetic/with spaces", registry: registry)
        let request = registry.makePendingRequest(for: parsed)
        #expect(request?.commandID == "add-dir")
        #expect(request?.args["path"] == "/synthetic/with spaces")
        #expect(request?.requiresPolicyApproval == true)
        #expect(CommandRegistry.composerMetadata(for: "add-dir")?.risk == .high)
        #expect(CommandRegistry.runsDuringGeneration("add-dir") == false)
        #expect(CommandRegistry.composerMetadata(for: "add-dir")?.argumentSpecs.first?.required == true)
        let missing = parser.parse("/add-dir", registry: registry)
        #expect(registry.validatedComposerPendingRequest(for: missing)
            == .failure(.missingArgument(commandID: "add-dir", argument: "path")))
    }

    @Test func unregisteredCommandsStayUnroutable() {
        let registry = makeComposerRegistry()
        for input in ["/notacommand", "/memory.deleteme", "/canvas.unknown"] {
            let parsed = parser.parse(input, registry: registry)
            #expect(registry.makePendingRequest(for: parsed) == nil, "\(input) 不得生成 pending request")
        }
    }

    @Test func registeredComposerCommandsStillRefuseDirectExecution() async throws {
        let registry = makeComposerRegistry()

        // Approval-gated IDs keep the confirmation boundary even when routed.
        for id in policyApprovalGatedIDs {
            do {
                _ = try await registry.execute(id: id, args: [:], confirmation: false)
                Issue.record("\(id) 未经确认不得执行")
            } catch let error as CommandExecutionError {
                #expect(error == .confirmationRequired(id))
            }
        }

        // Opening the picker is approval-free, but the Core registry cannot
        // dispatch that desktop consumer or write model/provider settings.
        for id in ["model", "模型"] {
            let result = try await registry.execute(id: id, args: [:], confirmation: false)
            #expect(result.ok == false)
            #expect(result.text == "Composer 命令必须先创建 pending request")
        }

        // Even with confirmation the canonical closure refuses: registration
        // adds routing presence, not execution capability.
        for id in ["help", "compact", "approve"] {
            let result = try await registry.execute(id: id, args: [:], confirmation: true)
            #expect(!result.ok)
            #expect(result.text.contains("pending request"))
        }
    }

    @Test func composerVocabularyNeverEntersNaturalLanguageMatching() {
        // Composer IDs are explicit slash commands only; prose must not
        // resolve into actions through natural-language scoring.
        let registry = makeComposerRegistry()
        for prose in [
            "please approve and reject the boundary later",
            "stop retry the shortcuts",
            "how do I run workflow and use provider models",
        ] {
            let parsed = parser.parse(prose, registry: registry)
            #expect(parsed.command == nil, "散文不得命中 Composer 命令：\(prose)")
            #expect(parsed.disposition == .message)
        }
    }

    @Test func completionStateCoversFullCatalogInStableOrder() {
        let registry = makeComposerRegistry()
        let broad = parser.completionState(for: "/", registry: registry)
        #expect(broad.suggestions.map(\.id) == expectedComposerVocabulary)
        #expect(broad.selected?.id == "help")

        #expect(parser.completionState(for: "/co", registry: registry)
            .suggestions.map(\.id) == ["commands", "copy", "compact", "context", "usage"])
        #expect(parser.completionState(for: "/canvas.", registry: registry)
            .suggestions.map(\.id) == ["canvas.run", "canvas.cancel", "canvas.minimap"])
        // `model` keeps its own canonical row: the donor's provider.use alias
        // absorption (model/模型) was intentionally not consumed.
        #expect(parser.completionState(for: "/模型", registry: registry)
            .suggestions.map(\.id) == ["model"])
    }

    @Test func metadataLookupResolvesCanonicalAndLocalizedKeys() {
        #expect(CommandRegistry.composerMetadata(for: "CompAct")?.id == "compact")
        #expect(CommandRegistry.composerMetadata(for: "小地图")?.id == "canvas.minimap")
        #expect(CommandRegistry.composerMetadata(for: "PROVIDER USE")?.id == "provider.use")
        #expect(CommandRegistry.composerMetadata(for: "not.a.command") == nil)
        #expect(CommandRegistry.composerMetadata(for: "模型")?.requiresPolicyApproval == false)
        #expect(CommandRegistry.composerMetadata(for: "模型")?.risk == .low)
        #expect(CommandRegistry.composerMetadata(for: "停止")?.risk == .medium)
    }
}
