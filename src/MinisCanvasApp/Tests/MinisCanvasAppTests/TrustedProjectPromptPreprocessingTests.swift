import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

@Suite("Parent project instruction snapshot")
struct TrustedProjectPromptPreprocessingTests {
    @Test @MainActor func pinnedParentKeepsProjectInstructionsSeparateFromUserMaterial() throws {
        let profile = try #require(RuntimeIsolationProfile.formalTestProfileForDefaultConsumer())
        let configuredRoot = profile.rootDirectory
            .appendingPathComponent("M01-parent-synthetic-" + UUID().uuidString, isDirectory: true)
        let physicalPath = try DarwinSystemPathResolver.resolve(configuredRoot)
        let root = URL(fileURLWithPath: physicalPath, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("project rule".utf8).write(to: root.appendingPathComponent("CLAUDE.md"))
        let result = try ChatTurnPromptPreprocessor.preparePinnedPromptResult(
            basePrompt: "base", userMessage: "@untrusted.md user material",
            memoryInjector: nil, memoryScope: MemoryScope(sessionID: "synthetic-session", projectID: "synthetic-project"), skillInjector: nil,
            trustedProjectRoot: root)
        let trusted = try #require(result.trustedProjectInstructions)
        #expect(result.systemPrompt == "base\n\n" + trusted.systemPromptPrefix)
        #expect(trusted.loadedRelativePaths == ["CLAUDE.md"])
        #expect(!trusted.systemPromptPrefix.contains("user material"))
        // Mapping itself is pure; the formal root is not required to live in
        // a system-alias subtree. Real loading below stays inside that root.
        let systemAlias = URL(fileURLWithPath: "/var/G22-synthetic-project-instructions", isDirectory: true)
        #expect(try DarwinSystemPathResolver.resolve(systemAlias) == "/private/var/G22-synthetic-project-instructions")
        let ordinary = ChatTurnPromptPreprocessor.prepare(ChatTurnPromptPreprocessInput(
            basePrompt: "base", userMessage: "user material", memoryEnabled: false,
            memoryInjector: nil, memoryScope: MemoryScope(sessionID: "synthetic-session", projectID: "synthetic-project"),
            skillInjector: nil, legacySkillResult: .init(fragment: nil, receipts: []), pickerCatalog: [], steers: [],
            intentText: "user material", trustedProjectRoot: root))
        #expect(ordinary?.trustedProjectInstructions?.loadedRelativePaths == ["CLAUDE.md"])
        #expect(ordinary?.systemPrompt == result.systemPrompt)
        let absent = try ChatTurnPromptPreprocessor.preparePinnedPromptResult(
            basePrompt: "base", userMessage: "@untrusted.md user material",
            memoryInjector: nil, memoryScope: MemoryScope(sessionID: "synthetic-session", projectID: "synthetic-project"),
            skillInjector: nil)
        #expect(result.excludingProjectInstructions().systemPrompt == absent.systemPrompt)
        #expect(result.excludingProjectInstructions().trustedProjectInstructions == nil)
        #expect(ordinary?.excludingProjectInstructions().systemPrompt == absent.systemPrompt)
        #expect(result.excludingProjectInstructions().memoryFactIDs == absent.memoryFactIDs)
        let chat = ChatStore()
        let scope = MemoryScope(sessionID: "synthetic-session", projectID: "synthetic-project")
        let missingCallback = chat.admittedProjectPrompt(result, scope: scope, allowPrompt: true, isCurrent: { true })
        #expect(missingCallback.systemPrompt == absent.systemPrompt)
        #expect(chat.sessionContinuationNotice != nil)
        chat.projectInstructionApproval = { _, candidate, _, isCurrent, _ in
            isCurrent() && candidate == trusted
        }
        let accepted = chat.admittedProjectPrompt(result, scope: scope, allowPrompt: true, isCurrent: { true })
        #expect(accepted.systemPrompt == result.systemPrompt)
        #expect(accepted.trustedProjectInstructions == trusted)
        let stale = chat.admittedProjectPrompt(result, scope: scope, allowPrompt: true, isCurrent: { false })
        #expect(stale.systemPrompt == absent.systemPrompt)
        let memory = MemoryStore(directory: root.appendingPathComponent("memory", isDirectory: true))
        _ = try memory.addFact("weather owned fact", memoryScope: scope)
        let injector = MemoryInjector(store: memory)
        func frozenInput(_ trustedRoot: URL?) -> ChatTurnPromptPreprocessInput {
            ChatTurnPromptPreprocessInput(basePrompt: "base", userMessage: "weather",
                memoryEnabled: true, memoryInjector: injector, memoryScope: scope,
                skillInjector: nil, legacySkillResult: .init(fragment: "frozen skill", receipts: []),
                pickerCatalog: [], steers: ["frozen steer"], intentText: "weather", trustedProjectRoot: trustedRoot)
        }
        let withMemory = try #require(ChatTurnPromptPreprocessor.prepare(frozenInput(root)))
        let withoutFile = try #require(ChatTurnPromptPreprocessor.prepare(frozenInput(nil)))
        #expect(withMemory.excludingProjectInstructions().systemPrompt == withoutFile.systemPrompt)
        #expect(withMemory.excludingProjectInstructions().memoryFactIDs == withoutFile.memoryFactIDs)
        _ = try memory.addFact("weather later fact", memoryScope: scope)
        #expect(!withMemory.excludingProjectInstructions().systemPrompt.contains("weather later fact"))
        #expect(withMemory.excludingProjectInstructions().systemPrompt.contains("weather owned fact"))
    }
}
