import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

@Suite("SKILL05 default injection budget in a large directory", .serialized)
@MainActor
struct SKILL05DefaultBudgetDirectoryConsumerTests {
    @Test func defaultFiveAndTwoLimitActualOutgoingPromptFromSixtyFourSkills() async throws {
        let formal = try #require(try FormalTestIsolationPaths.resolveCurrentProcess())
        let root = formal.temporaryDirectory
            .appendingPathComponent("skill05-default-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = SkillStore(skillsRoot: root.appendingPathComponent("skills", isDirectory: true))
        var relevantIDs: [String] = []
        var relevantBodies: [String] = []
        let weakBody = "SKILL05_WEAK_SINGLE_BIGRAM_BODY"
        var importIndex = -1
        var importStarted = ProcessInfo.processInfo.systemUptime
        do {
            for index in 0..<6 {
                let name = String(format: "skill05-match-%02d", index)
                let body = "SKILL05_RELEVANT_BODY_\(index)_\(String(repeating: "x", count: 96))"
                importIndex = index
                importStarted = ProcessInfo.processInfo.systemUptime
                let imported = try store.importSkillThroughLifecycle(
                    content: "---\nname: \(name)\ndescription: budgetprobe\nversion: 1.0.0\n---\n\n\(body)",
                    source: .file, reason: "isolated SKILL05 default budget fixture",
                    approval: SkillApproval(approverID: "skill05-test-reviewer")
                )
                relevantIDs.append(imported.skill.id)
                relevantBodies.append(body)
            }
            importIndex = 6
            importStarted = ProcessInfo.processInfo.systemUptime
            _ = try store.importSkillThroughLifecycle(
                content: "---\nname: skill05-weak\ndescription: 视频制作笔记\nversion: 1.0.0\n---\n\n\(weakBody)",
                source: .file, reason: "isolated SKILL05 minimum score fixture",
                approval: SkillApproval(approverID: "skill05-test-reviewer")
            )
            for index in 0..<57 {
                let name = String(format: "skill05-background-%02d", index)
                importIndex = index + 7
                importStarted = ProcessInfo.processInfo.systemUptime
                _ = try store.importSkillThroughLifecycle(
                    content: "---\nname: \(name)\ndescription: unrelatedfield\(index)\nversion: 1.0.0\n---\n\nSKILL05_BACKGROUND_BODY_\(index)",
                    source: .file, reason: "isolated SKILL05 directory size fixture",
                    approval: SkillApproval(approverID: "skill05-test-reviewer")
                )
            }
        } catch {
            // Failure-only preparation evidence; this does not classify the scan's nil branch.
            let elapsed = ProcessInfo.processInfo.systemUptime - importStarted
            let attributes = try? FileManager.default.attributesOfItem(atPath: store.skillsRoot.path)
            let mode = (attributes?[.posixPermissions] as? NSNumber)?.intValue ?? -1
            let device = (attributes?[.systemNumber] as? NSNumber)?.uint64Value ?? 0
            let inode = (attributes?[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
            print("SKILL05_IMPORT_FAILURE index=\(importIndex) elapsedSeconds=\(elapsed) cancelled=\(Task.isCancelled) initialLoadComplete=\(store.isInitialLoadComplete) rootStatAvailable=\(attributes != nil) rootMode=\(mode) rootDevice=\(device) rootInode=\(inode)")
            throw error
        }
        #expect(store.allSkills().count == 64)
        let injectorStore = SkillStore(skillsRoot: store.skillsRoot)
        let injector = SkillInjector(store: injectorStore)
        #expect(injector.maxInjectedSkills == 3) // 第七版：每回合最多 3 篇
        #expect(injector.minimumScore == 2)
        #expect(
            injector.matchingSkills(for: "budgetprobe").map(\.id) == Array(relevantIDs.prefix(3)),
            "injector store isInitialLoadComplete: \(injectorStore.isInitialLoadComplete)"
        )
        #expect(injector.matchingSkills(for: "随便看看视频").isEmpty)

        let defaultsName = formal.userDefaultsSuiteName + ".skill05." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let chat = ChatStore(
            preferencesDefaults: defaults,
            logManager: LogManager(directory: root.appendingPathComponent("logs", isDirectory: true))
        )
        let engine = U4SystemPromptRecordingEngine()
        chat.agentEngine = engine
        chat.streamingProviderOverride = MockProvider.shared
        chat.turnRuntimeSnapshotFactory = { turn, _ in
            ChatTurnRuntimeSnapshot(turn: turn, skillInjector: injector.snapshotForTurn(), mcpBridge: nil)
        }
        chat.pickerCatalogLoader = { SkillCatalogLoader.storeSkillItems(from: store) }
        chat.loadPickerCatalog()
        #expect(chat.pickerCatalog.count == 64)

        chat.draftText = "budgetprobe"
        chat.sendDraft()
        for _ in 0..<200 where chat.isStreaming {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(!chat.isStreaming)
        let first = try #require(engine.systemPrompts.first)
        #expect(first.components(separatedBy: "<skill name=").count - 1 == 3)
        for body in relevantBodies.prefix(3) { #expect(first.contains(body)) }
        #expect(!first.contains(relevantBodies[3]))
        #expect(!first.contains(weakBody))
        #expect(!first.contains("SKILL05_BACKGROUND_BODY_"))
        #expect(Set(chat.lastSkillInjectionReceipts.filter(\.injected).map(\.skillID))
            == Set(relevantIDs.prefix(3)))

        chat.draftText = "随便看看视频"
        chat.sendDraft()
        for _ in 0..<200 where chat.isStreaming {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(!chat.isStreaming)
        #expect(engine.systemPrompts.count == 2)
        let second = try #require(engine.systemPrompts.last)
        // 第七版：本会话命中过的技能后续回合最多再带 2 篇。
        #expect(second.contains("<injected_skills>"))
        for body in relevantBodies.prefix(2) { #expect(second.contains(body)) }
        #expect(!second.contains(relevantBodies[2]))
        #expect(!second.contains(weakBody))
        #expect(Set(chat.lastSkillInjectionReceipts.filter(\.injected).map(\.skillID)) == Set(relevantIDs.prefix(2)))
    }
}
