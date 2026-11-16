// Independent synthetic contract cases. This file is not executed by its author.
// The integration owner supplies module registration; no application fixture,
// original implementation, historical test, user path, or credential is used.
import Foundation
import Testing
@testable import MinisCore
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

@Suite("Clean-room skill value and metadata contracts")
struct SyntheticSkillValueContracts {
    @Test func sourcePersistenceKeepsOpaqueURL() throws {
        let address = "https://example.invalid/tree/main/灯?x=url:payload#anchor"
        let origin = SkillImportSource.url(address)
        #expect(origin.sourceURL == address)
        #expect(SkillImportSource.fromDB(origin.dbValue) == origin)
        #expect(SkillImportSource.fromDB("legacy-unrecognized-origin") == .file)
        #expect(SkillImportSource.bundled.sourceURL == nil)
        #expect(SkillImportSource.session.sourceURL == nil)
        #expect(SkillImportSource.file.sourceURL == nil)
        let encoded = try JSONEncoder().encode(origin)
        #expect(try JSONDecoder().decode(SkillImportSource.self, from: encoded) == origin)
    }

    @Test func manifestSeparatesContentFromProvenance() throws {
        let document = "name: Lantern Notes\n---\nKeep the ending."
        let first = SkillSourceManifest(skillID: "lantern-notes", source: .file, skillVersion: "1.0.0", content: document)
        let same = SkillSourceManifest(skillID: "lantern-notes", source: .file, skillVersion: "1.0.0", content: document)
        let remote = SkillSourceManifest(skillID: "lantern-notes", source: .url("https://example.invalid/skill"), skillVersion: "1.0.0", content: document)
        let changed = SkillSourceManifest(skillID: "lantern-notes", source: .file, skillVersion: "1.0.0", content: document + "\nChanged.")
        #expect(first == same)
        #expect(first.contentHash == remote.contentHash)
        #expect(first != remote)
        #expect(first.contentHash != changed.contentHash)
        #expect(first.schema == "miniscore.skill-source-manifest")
        #expect(first.version == 1)
        #expect(try JSONDecoder().decode(SkillSourceManifest.self, from: JSONEncoder().encode(first)) == first)
    }

    @Test func missingOpeningFenceCanStillBeMetadata() {
        let document = "name: Lantern Notes\ndescription: Review a draft\n---\nKeep the ending."
        let parsed = SkillStore.parse(skillMD: document)
        #expect(parsed.name == "Lantern Notes")
        #expect(parsed.description == "Review a draft")
        #expect(parsed.version == "1.0.0")
        #expect(parsed.body == "Keep the ending.")
    }

    @Test func unrecognizedHeaderIsOrdinaryBody() {
        let document = "Author: Mira\n\n---\nKeep the ending."
        let parsed = SkillStore.parse(skillMD: document)
        #expect(parsed.name == "Untitled Skill")
        #expect(parsed.description.isEmpty)
        #expect(parsed.version == "1.0.0")
        #expect(parsed.body == document)
    }

    @Test func proseOpeningPreventsAccidentalMetadataRemoval() {
        let document = "Introduction for the reader\nname: Lantern Notes\n---\nKeep the ending."
        let parsed = SkillStore.parse(skillMD: document)
        #expect(parsed.name == "Untitled Skill")
        #expect(parsed.body == document)
    }

    @Test func fencedMetadataHandlesBothDescriptionStyles() {
        let folded = "---\nname: Lantern Notes\ndescription: >-\n  Review a draft\n  and keep its ending\nunknown: ignored\nversion: '2.3.4'\n---\nKeep the ending."
        let literal = "---\nname: Lantern Notes\ndescription: |-\n  Review a draft\n  Keep its ending\n---\nKeep the ending."
        #expect(SkillStore.parse(skillMD: folded).description == "Review a draft and keep its ending")
        #expect(SkillStore.parse(skillMD: folded).version == "2.3.4")
        #expect(SkillStore.parse(skillMD: literal).description == "Review a draft\nKeep its ending")
    }

    @Test func unsafeIdentifiersAndPathsFailClosed() {
        for value in ["", ".", "..", "a/b", "a\\b", "a\nb", "a\u{0}b"] {
            #expect(!SkillStore.isSafeSkillID(value))
        }
        #expect(SkillStore.isSafeSkillID("lantern-notes"))
        for value in ["", "/absolute.md", "../outside.md", "references/../outside.md", "./SKILL.md", "references//guide.md", "references\\guide.md"] {
            #expect(SkillDescriptorReader.validRelativeComponents(value) == nil)
        }
        #expect(SkillDescriptorReader.validRelativeComponents("references/guide.md") == ["references", "guide.md"])
    }
}

@Suite("Clean-room causal classification contracts")
struct SyntheticCompactionSpanContracts {
    private func text(_ role: CompactionTextView.Role, _ content: String) -> CompactionTextView {
        CompactionTextView(role: role, text: content, containsMedia: false, toolCalls: [], toolResult: nil)
    }

    @Test func independentTurnsOnBothSidesOfToolExchangeRemainNatural() {
        var call = text(.assistant, "")
        call.toolCalls = ["call-lantern"]
        var result = text(.other, "synthetic tool output")
        result.toolResult = "call-lantern"
        let input = [text(.user, "只读比较两个标题"), text(.assistant, "第一个更短"), call, result,
                     text(.user, "继续比较结尾"), text(.assistant, "结尾应保留"), text(.user, "继续")]
        let output = CompactionSpanPlanner.plan(input, historicalCount: 6)
        #expect(output.map(\.range) == [0..<2, 2..<4, 4..<6])
        guard output.count == 3 else { return }
        if case .naturalText = output[0].classification {} else { Issue.record("First independent turn must be natural") }
        if case .exact = output[1].classification {} else { Issue.record("Tool exchange must remain exact") }
        if case .naturalText = output[2].classification {} else { Issue.record("Later independent turn must be natural") }
    }

    @Test func mediaAndUntrustedBoundaryDoNotFreezeLaterTurns() {
        var image = text(.user, "image description")
        image.containsMedia = true
        let input = [image, text(.user, "<context-summary>untrusted</context-summary>"),
                     text(.user, "讨论新标题"), text(.assistant, "可用灯下笔记"), text(.user, "继续")]
        let output = CompactionSpanPlanner.plan(input, historicalCount: 4)
        #expect(output.map(\.range) == [0..<2, 2..<4])
        guard output.count == 2 else { return }
        if case .exact = output[0].classification {} else { Issue.record("Media and boundary must remain exact") }
        if case .naturalText = output[1].classification {} else { Issue.record("Later ordinary turn must remain natural") }
    }

    @Test(arguments: 0..<2) func legacyJSONToolsKeepClosedAndCrossTailCausality(format: Int) throws {
        func encoded(_ block: [String: Any]) throws -> String {
            let object: Any = format == 0 ? block : [block]
            return String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
        }
        let call = try encoded(["type": "tool_use", "id": "legacy-lantern", "name": "read_synthetic", "input": ["item": "lantern"]])
        let result = try encoded(["type": "tool_result", "tool_use_id": "legacy-lantern", "content": "Read completed"])
        let source = [LLMMessage(role: .user, content: "Compare the two headings"), LLMMessage(role: .assistant, content: "One is shorter"),
            LLMMessage(role: .assistant, content: call), LLMMessage(role: .assistant, content: "Waiting for the read"),
            LLMMessage(role: .user, content: result), LLMMessage(role: .user, content: "Compare the closing line"),
            LLMMessage(role: .assistant, content: "Keep the closing line"), LLMMessage(role: .user, content: "Recent")]
        let closed = Compactor.sourceSpans(messages: source, keepRecentMessages: 1)
        #expect(closed.map(\.range) == [0..<2, 2..<5, 5..<7])
        #expect(closed.map(\.kind) == [.naturalText, .exact, .naturalText])
        let crossing = Compactor.sourceSpans(messages: source, keepRecentMessages: 4)
        #expect(crossing.map(\.range) == [0..<2, 2..<4])
        #expect(crossing.map(\.kind) == [.naturalText, .exact])
    }

    @Test(arguments: 0..<2) func duplicateCausalIdentityNeverReleasesTheRemainingPrefix(kind: Int) {
        let call = LLMMessage(role: .assistant, content: "", toolCalls: [.init(id: "duplicate-river", name: "read_synthetic", rawArguments: "{}", arguments: [:])])
        let result = LLMMessage(role: .tool, content: "Done", toolCallID: "duplicate-river")
        let source = [LLMMessage(role: .user, content: "Read once"), call, result, kind == 0 ? call : result,
            LLMMessage(role: .user, content: "This follows the duplicate identity"),
            LLMMessage(role: .assistant, content: "It is still ambiguous"), LLMMessage(role: .user, content: "Recent")]
        let spans = Compactor.sourceSpans(messages: source, keepRecentMessages: 1)
        #expect(spans.map(\.range) == [0..<1, 1..<6])
        #expect(spans.map(\.kind) == [.naturalText, .exact])
    }

    @Test func toolResultAcrossRecentBoundaryProtectsInterveningText() {
        var call = text(.assistant, "")
        call.toolCalls = ["call-river"]
        var result = text(.other, "synthetic result")
        result.toolResult = "call-river"
        let input = [text(.user, "只读查询"), call, text(.assistant, "正在等结果"), result]
        let output = CompactionSpanPlanner.plan(input, historicalCount: 3)
        #expect(output.map(\.range) == [0..<1, 1..<3])
        guard output.count == 2 else { return }
        if case .exact = output[1].classification {} else { Issue.record("Cross-boundary exchange must remain exact") }
    }
}

// These @Suite / @Test declarations are intended for the independent validator's
// actual test target. No standalone executable or private self-test runner exists.
@Suite("Clean-room synthetic-root skill lifecycle")
struct SyntheticSkillLifecycleContracts {
    private func withRoot(_ body: (URL) throws -> Void) throws {
        let parent = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        let root = parent.appendingPathComponent("skill-cleanroom-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }

    @Test func explicitUntrustedImportIsStoredButQuarantined() throws {
        try withRoot { root in
            let store = SkillStore(skillsRoot: root)
            let original = "---\nname: Lantern Notes\nversion: 1.0.0\n---\nKeep the ending."
            let skill = try store.importSkill(content: original, source: .url("https://example.invalid/lantern/SKILL.md"))
            #expect(store.rawContent(skill.id) == original)
            #expect(!store.isInjectable(skill))
            #expect(store.lifecycleReceipt(for: skill.id)?.state == .quarantined)
            #expect(store.lifecycleReceipt(for: skill.id)?.trust == .untrusted)
            #expect(skill.integrity.state == .verified)
            #expect(skill.integrity.manifest?.contentHash == SkillManifest.hash(original))
            let reopened = SkillStore(skillsRoot: root)
            #expect(reopened.rawContent(skill.id) == original)
            #expect(reopened.allSkills().allSatisfy { !reopened.isInjectable($0) })
            #expect(reopened.allSkills().first { $0.id == skill.id }?.integrity.state == .verified)
            let local = try reopened.importSkill(content: "---\nname: Local Proof Control\n---\nApproved local control.")
            #expect(reopened.isInjectable(local))
            let readonly = reopened.makeSnapshotStore()
            #expect(readonly.allSkills().first { $0.id == skill.id }?.integrity.state == .verified)
            #expect(!readonly.isInjectable(skill))
            #expect(readonly.isInjectable(local))
        }
    }

    @Test(arguments: 0..<2) func missingKnownSourceRetainsClassificationWithoutRevivingCachedContent(kind: Int) throws {
        try withRoot { root in
            let store = SkillStore(skillsRoot: root)
            let raw = "---\nname: Known Missing Source\n---\nNever inject this cached historical body."
            let skill = try store.importSkill(content: raw)
            let controlRaw = "---\nname: Live Source Control\n---\nA safe sibling remains available."
            let control = try store.importSkill(content: controlRaw)
            let oldCompleted = store.makeSnapshotStore()
            let manifestURL = store.skillManifestURL(for: skill.id)
            let manifestBytes = try Data(contentsOf: manifestURL)
            let receipt = store.lifecycleReceipt(for: skill.id)
            let main = store.skillDirectoryURL(for: skill.id).appendingPathComponent("SKILL.md")
            try FileManager.default.removeItem(at: main)
            if kind == 1 {
                try FileManager.default.createSymbolicLink(atPath: main.path, withDestinationPath: root.appendingPathComponent("absent-target").path)
            }
            let frozen = store.makeSnapshotStore()
            #expect(store.rawContent(skill.id) == nil)
            #expect(frozen.rawContent(skill.id) == nil)
            #expect(frozen.readSkillFile(skill.id, relativePath: "SKILL.md") == nil)
            #expect(!store.isInjectable(skill))
            #expect(!frozen.isInjectable(skill))
            #expect(frozen.rawContent(control.id) == controlRaw)
            #expect(frozen.isInjectable(control))
            #expect(oldCompleted.rawContent(skill.id) == raw)
            #expect(oldCompleted.isInjectable(skill))
            #expect(try Data(contentsOf: manifestURL) == manifestBytes)
            if kind == 0 {
                let known = try #require(frozen.allSkills().first { $0.id == skill.id })
                #expect(known.body.isEmpty)
                #expect(frozen.lifecycleReceipt(for: skill.id) == receipt)
                #expect(SkillRegistry(store: frozen).rejection(for: known, content: frozen.rawContent(skill.id)) == .missingSource)
                let rootIdentity = try #require(SkillFilesystemBoundary.approvedRootIdentity(root))
                let directoryIdentity = try #require(SkillFilesystemBoundary.trustedDirectoryIdentity(store.skillDirectoryURL(for: skill.id), within: root))
                #expect(store.catalogFileSnapshot(for: skill.id, expectedRootIdentity: rootIdentity,
                    expectedSkillDirectoryIdentity: directoryIdentity, waitUntil: ProcessInfo.processInfo.systemUptime + 1) == nil)
            } else {
                #expect(!frozen.allSkills().contains { $0.id == skill.id })
                #expect(try FileManager.default.destinationOfSymbolicLink(atPath: main.path) == root.appendingPathComponent("absent-target").path)
            }
        }
    }

    @Test(arguments: 0..<3) func untrustedQuarantineNeverRepairsBrokenManifestProof(caseIndex: Int) throws {
        try withRoot { root in
            let store = SkillStore(skillsRoot: root)
            let raw = "---\nname: Proof Damage\n---\nOriginal reviewed bytes."
            let skill = try store.importSkill(content: raw, source: .url("https://example.invalid/proof"))
            if caseIndex == 0 {
                try Data("not a manifest".utf8).write(to: store.skillManifestURL(for: skill.id), options: [.atomic])
            } else if caseIndex == 1 {
                try Data((raw + "Changed").utf8).write(to: store.skillDirectoryURL(for: skill.id).appendingPathComponent("SKILL.md"), options: [.atomic])
            } else {
                let manifest = try #require(skill.integrity.manifest)
                let changed = SkillSourceManifest(schema: "unsupported.synthetic.schema", version: manifest.version,
                    skillID: manifest.skillID, source: manifest.source, skillVersion: manifest.skillVersion, contentHash: manifest.contentHash)
                try JSONEncoder().encode(changed).write(to: store.skillManifestURL(for: skill.id), options: [.atomic])
            }
            store.reload()
            let current = try #require(store.allSkills().first { $0.id == skill.id })
            #expect(current.integrity.state != .verified)
            #expect(!store.isInjectable(current))
            #expect(store.makeSnapshotStore().allSkills().first { $0.id == skill.id }?.integrity.state != .verified)
        }
    }

    @Test func ordinaryFileRejectsNonUTF8WithTheStableSourceError() throws {
        try withRoot { root in
            let store = SkillStore(skillsRoot: root)
            let source = root.appendingPathComponent("invalid-utf8.skill")
            try Data([0xff, 0xfe, 0xff]).write(to: source)
            do {
                _ = try store.importSkill(from: source)
                Issue.record("Invalid UTF-8 must be rejected")
            } catch {
                #expect(error as? SkillError == .importFailed(reason: "skill source is not a stable UTF-8 file"))
            }
            #expect(store.allSkills().isEmpty)
        }
    }

    @Test(arguments: 0..<2) func reimportRejectsUnsafeExistingTargetsWithoutRepairingThem(kind: Int) throws {
        try withRoot { root in
            let store = SkillStore(skillsRoot: root)
            let raw = "---\nname: Existing Target\n---\nOriginal bytes."
            let updated = "---\nname: Existing Target\n---\nReplacement bytes."
            let skill = try store.importSkill(content: raw)
            let directory = store.skillDirectoryURL(for: skill.id)
            let main = directory.appendingPathComponent("SKILL.md")
            let manifest = store.skillManifestURL(for: skill.id)
            let originalManifest = try Data(contentsOf: manifest)
            let originalLedger = try Data(contentsOf: store.lifecycleReceiptsFileURL)
            let alias = root.appendingPathComponent("hardlink-alias")
            if kind == 0 { try FileManager.default.linkItem(at: main, to: alias) }
            else { try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: directory.path) }
            do {
                _ = try store.importSkill(content: updated)
                Issue.record("Unsafe existing target must be rejected")
            } catch { #expect(error is SkillError) }
            #expect(try Data(contentsOf: main) == Data(raw.utf8))
            #expect(try Data(contentsOf: manifest) == originalManifest)
            #expect(try Data(contentsOf: store.lifecycleReceiptsFileURL) == originalLedger)
            if kind == 0 {
                #expect(try Data(contentsOf: alias) == Data(raw.utf8))
                try FileManager.default.removeItem(at: alias)
            } else {
                let permissions = try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber
                #expect(permissions?.intValue == 0o777)
                // Only the fixture corrects its unsafe condition after proving
                // production did not silently repair it or commit replacement.
                try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            }
            let accepted = try store.importSkill(content: updated)
            #expect(store.rawContent(accepted.id) == updated)
            #expect(store.isInjectable(accepted))
        }
    }

    @Test func rollbackRejectsAnActiveWriterBeforeRefreshingOrChangingItsVersion() throws {
        try withRoot { root in
            let store = SkillStore(skillsRoot: root)
            let previous = "---\nname: Writer Rollback\nversion: 1.0\n---\nPrevious version."
            let current = "---\nname: Writer Rollback\nversion: 2.0\n---\nCurrent version."
            _ = try store.importSkill(content: previous)
            let skill = try store.importSkill(content: current)
            let main = store.skillDirectoryURL(for: skill.id).appendingPathComponent("SKILL.md")
            let manifest = store.skillManifestURL(for: skill.id)
            let manifestBytes = try Data(contentsOf: manifest)
            let receiptBytes = try Data(contentsOf: store.lifecycleReceiptsFileURL)
            let inMemory = store.skills
            let lock = store.skillDirectoryURL(for: skill.id).appendingPathComponent(".skill-import.lock")
            let descriptor = open(lock.path, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
            #expect(descriptor >= 0)
            guard descriptor >= 0 else { return }
            defer { _ = flock(descriptor, LOCK_UN); close(descriptor) }
            try #require(flock(descriptor, LOCK_EX | LOCK_NB) == 0)
            let partial = Data([0xff, 0xfe])
            try partial.write(to: manifest, options: [.atomic])
            do {
                _ = try store.rollbackSkill(skill.id, reason: "Must not race the writer")
                Issue.record("The active writer must retain coordination")
            } catch { #expect(error is SkillError) }
            #expect(try Data(contentsOf: main) == Data(current.utf8))
            #expect(try Data(contentsOf: manifest) == partial)
            #expect(try Data(contentsOf: store.lifecycleReceiptsFileURL) == receiptBytes)
            #expect(store.skills == inMemory)
            try manifestBytes.write(to: manifest, options: [.atomic])
            #expect(flock(descriptor, LOCK_UN) == 0)
            let restored = try store.rollbackSkill(skill.id, reason: "The writer has safely completed")
            #expect(restored.contentHash == SkillManifest.hash(previous))
            #expect(store.rawContent(skill.id) == previous)
            #expect(store.allSkills().allSatisfy { !store.isInjectable($0) })
        }
    }

    @Test(arguments: 0..<2) func lifecycleImportFailuresKeepOldPairAndExposeSkillErrors(phase: Int) throws {
        try withRoot { root in
            let store = SkillStore(skillsRoot: root)
            let old = "---\nname: Lifecycle Persistence Boundary\n---\nOld approved bytes."
            let proposed = "---\nname: Lifecycle Persistence Boundary\n---\nUncommitted replacement bytes."
            let skill = try store.importSkill(content: old)
            let directory = store.skillDirectoryURL(for: skill.id)
            let main = directory.appendingPathComponent("SKILL.md")
            let manifest = store.skillManifestURL(for: skill.id)
            let manifestBytes = try Data(contentsOf: manifest)
            let ledgerBytes = try Data(contentsOf: store.lifecycleReceiptsFileURL)
            let obstruction = SyntheticLedgerWriteObstruction(root: root, directory: directory)
            let observed = SkillStore(skillsRoot: root, filesystemAccessObserver: { obstruction.observe($0) })
            if phase == 0 { try Data("not a lifecycle ledger".utf8).write(to: observed.lifecycleReceiptsFileURL, options: [.atomic]) }
            // Synthetic-only ledger obstruction; restore its original fixture below before reopening.
            else { obstruction.arm() }
            do {
                _ = try observed.importSkill(content: proposed)
                Issue.record("Lifecycle persistence failure must reject the import")
            } catch { #expect(error is SkillError) }
            #expect(try Data(contentsOf: main) == Data(old.utf8))
            #expect(try Data(contentsOf: manifest) == manifestBytes)
            let remaining = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            #expect(!remaining.contains { $0 == ".skill-import-pending.json" || $0.hasSuffix(".tmp") })
            if phase == 0 {
                #expect(try Data(contentsOf: observed.lifecycleReceiptsFileURL) == Data("not a lifecycle ledger".utf8))
                try ledgerBytes.write(to: observed.lifecycleReceiptsFileURL, options: [.atomic])
            } else {
                try #require(obstruction.triggered && !obstruction.failed)
                #expect(try Data(contentsOf: obstruction.backup) == ledgerBytes)
                let attributes = try FileManager.default.attributesOfItem(atPath: observed.lifecycleReceiptsFileURL.path)
                #expect(attributes[.type] as? FileAttributeType == .typeDirectory)
                try FileManager.default.removeItem(at: observed.lifecycleReceiptsFileURL)
                try FileManager.default.moveItem(at: obstruction.backup, to: observed.lifecycleReceiptsFileURL)
            }
            let reopened = SkillStore(skillsRoot: root)
            #expect(reopened.rawContent(skill.id) == old)
            #expect(reopened.isInjectable(skill))
            #expect(try Data(contentsOf: reopened.lifecycleReceiptsFileURL) == ledgerBytes)
        }
    }

    @Test func removeAllPreservesOriginalBytesInTrash() throws {
        try withRoot { root in
            let store = SkillStore(skillsRoot: root)
            let first = "---\nname: Lantern Notes\n---\nKeep the ending."
            let second = "---\nname: River Notes\n---\nKeep the opening."
            _ = try store.importSkill(content: first)
            _ = try store.importSkill(content: second)
            let intent = try store.previewRemoveAll().withFirstConfirmation("first").withSecondConfirmation("second")
            #expect(intent.targetID == "all")
            let receipt = try store.removeAll(intent: intent)
            #expect(receipt.affectedCount == 2)
            #expect(store.allSkills().isEmpty)
            let trash = root.appendingPathComponent(".trash")
            var preserved: Set<String> = []
            if let enumerator = FileManager.default.enumerator(at: trash, includingPropertiesForKeys: nil) {
                while let file = enumerator.nextObject() as? URL {
                    if file.lastPathComponent == "SKILL.md", let content = try? String(contentsOf: file, encoding: .utf8) { preserved.insert(content) }
                }
            }
            #expect(preserved == Set([first, second]))
        }
    }

    @Test func malformedLedgerDoesNotGrantInjectionOrPermitImport() throws {
        try withRoot { root in
            let store = SkillStore(skillsRoot: root)
            let skill = try store.importSkill(content: "---\nname: Lantern Notes\n---\nKeep the ending.")
            try Data("not a ledger".utf8).write(to: store.lifecycleReceiptsFileURL, options: [.atomic])
            store.reload()
            #expect(!store.isInjectable(skill))
            do {
                _ = try store.importSkill(content: "---\nname: River Notes\n---\nKeep the opening.")
                Issue.record("Malformed lifecycle authority must not accept a new installation")
            } catch { /* Any existing strict error surface may reject the write. */ }
            #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(skill.id).appendingPathComponent("SKILL.md").path))
        }
    }
}

private final class SyntheticHistorySummaryProvider: LLMProvider, @unchecked Sendable {
    let name = "Synthetic"
    var model = LLMModel(id: "synthetic-summary", displayName: "Synthetic", provider: "Synthetic")
    let capabilities: Set<ProviderCapability> = []
    nonisolated(nonsending) func sendMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int, temperature: Double?) async throws -> LLMResponse {
        LLMResponse(text: "Earlier explanation summarized.", stopReason: nil, usage: nil)
    }
    nonisolated(nonsending) func sendMessage(messages: [LLMMessage], systemPrompt: String?, tools: [AgentToolDefinition], maxTokens: Int, temperature: Double?) async throws -> LLMResponse {
        try await sendMessage(messages: messages, systemPrompt: systemPrompt, maxTokens: maxTokens, temperature: temperature)
    }
    nonisolated(nonsending) func streamMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int, temperature: Double?) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        AsyncThrowingStream { continuation in continuation.yield(.text("Earlier explanation summarized.")); continuation.finish() }
    }
}

@Suite("Clean-room compaction entry and recent-tail contracts")
struct SyntheticCompactionEntryContracts {
    @Test func insufficientHistoryReturnsEveryOriginalMessage() async throws {
        let messages = [LLMMessage(role: .user, content: "One"), LLMMessage(role: .assistant, content: "Two")]
        let compactor = Compactor(keepRecentMessages: 2)
        #expect(!compactor.needsCompaction(messages: messages))
        let result = try await compactor.compact(messages: messages)
        #expect(result.compactedCount == 0)
        #expect(result.summary == nil)
        #expect(result.refusalReason == nil)
        #expect(Compactor.sameMessages(messages, result.messages))
    }

    @Test func legacySummaryIsFirstUserMessageAndTailRetainsAllMetadata() async throws {
        let tail = LLMMessage(role: .assistant, content: "Recent", images: [.init(mimeType: "image/png", data: Data([1, 2, 3]))],
                              audios: [.init(format: "wav", base64Data: "AA==")], toolCallID: "tail-call",
                              toolCalls: [.init(id: "next-call", name: "synthetic_tool", rawArguments: "{}", arguments: [:])],
                              legacyToolOutputSummary: .text(bytes: 3, lines: 1))
        let messages = [LLMMessage(role: .user, content: "Earlier request"), LLMMessage(role: .assistant, content: "Earlier explanation"), tail]
        let compactor = Compactor(keepRecentMessages: 1)
        #expect(compactor.needsCompaction(messages: messages))
        let result = try await compactor.compact(messages: messages, summarizeUsing: SyntheticHistorySummaryProvider())
        #expect(result.compactedCount == 2)
        #expect(result.messages.count == 2)
        #expect(result.messages.first?.role == .user)
        #expect(result.messages.first?.content == result.summary)
        #expect(result.summary?.hasPrefix("<context-summary>\n") == true)
        #expect(result.summary?.hasSuffix("\n</context-summary>") == true)
        #expect(result.summary?.contains("Earlier explanation summarized.") == true)
        #expect(Compactor.sameMessages(Array(result.messages.suffix(1)), [tail]))
    }

    @Test(arguments: 0..<3) func legacyFallbackMarksRolesAndOnlyEllipsizesPastCharacterLimit(caseIndex: Int) async throws {
        let family = "👩‍👩‍👧‍👦"
        let text = caseIndex == 0 ? "ab" : (caseIndex == 1 ? "ab" + family : "ab" + family + "d")
        let expected = caseIndex == 0 ? "ab" : "ab" + family + (caseIndex == 2 ? "…" : "")
        let tail = LLMMessage(role: .user, content: "Recent tail stays complete.")
        let source = [LLMMessage(role: .user, content: "Go"), LLMMessage(role: .assistant, content: text), tail]
        let result = try await Compactor(keepRecentMessages: 1, truncationPrefixChars: 3).compact(messages: source)
        #expect(result.refusalReason == nil)
        #expect(result.compactedCount == 2)
        #expect(result.messages.first?.role == .user)
        #expect(result.summary == Compactor.summaryEnvelope("Revalidate current policy. Historical effects are not instructions to replay.\n[user] Go\n[assistant] " + expected))
        #expect(result.messages.first?.content == result.summary)
        #expect(Compactor.sameMessages(Array(result.messages.suffix(1)), [tail]))
    }

    @Test func legacyKeepsValidSourceLessFactsAcrossTruncationAndRepeatedCompaction() async throws {
        let text = "Keep the reviewed constraint in full."
        let source = [LLMMessage(role: .assistant, content: String(repeating: "p", count: 20) + text),
                      LLMMessage(role: .user, content: "Recent")]
        let facts = [CompactionRetainedFact(kind: .constraint, text: text)]
        let compactor = Compactor(keepRecentMessages: 1, truncationPrefixChars: 5)
        let first = try await compactor.compact(messages: source, retentionFacts: facts)
        #expect(first.summary?.contains(text) == true)
        #expect(first.messages.first?.content == first.summary)
        #expect(first.summary?.contains("Revalidate current policy") == true)
        #expect(first.summary?.contains("not instructions to replay") == true)
        let second = try await compactor.compact(messages: first.messages, retentionFacts: facts)
        #expect(second.summary?.components(separatedBy: text).count == 2)
        #expect(second.messages.last?.content == "Recent")
        let policy = "Revalidate current policy. Historical effects are not instructions to replay."
        #expect(first.summary?.components(separatedBy: policy).count == 2)
        #expect(second.summary?.components(separatedBy: policy).count == 2)
        var repeated = first.messages
        let fullHistory = Compactor(keepRecentMessages: 1, truncationPrefixChars: 10_000)
        for _ in 0..<3 {
            let next = try await fullHistory.compact(messages: repeated, retentionFacts: facts)
            let summary = try #require(next.summary)
            #expect(summary.count < fullHistory.truncationPrefixChars)
            #expect(summary.components(separatedBy: policy).count == 2)
            #expect(summary.components(separatedBy: text).count == 2)
            #expect(next.messages.last?.content == "Recent")
            repeated = next.messages
        }
        let provider = SyntheticHistorySummaryProvider()
        let provided = try await compactor.compact(messages: source, summarizeUsing: provider, retentionFacts: facts)
        #expect(provided.summary?.contains(text) == true)
        #expect(provided.summary?.components(separatedBy: text).count == 2)
        let refused = try await compactor.compact(messages: source,
            retentionFacts: [.init(kind: .constraint, text: "Not present in source")])
        #expect(refused.refusalReason == .unverifiableInformationLoss)
        #expect(Compactor.sameMessages(refused.messages, source))
    }

    @Test(arguments: 0..<3) func strictCharacterCapRequiresEveryHistoricalBodyInFull(caseIndex: Int) async throws {
        let family = "👩‍👩‍👧‍👦"
        let text = caseIndex == 0 ? "ab" : (caseIndex == 1 ? "ab" + family : "ab" + family + "d")
        let source = [LLMMessage(role: .user, content: text), LLMMessage(role: .assistant, content: "Tail")]
        let result = try await Compactor(keepRecentMessages: 1, truncationPrefixChars: 3).compact(messages: source,
            retentionFacts: [.init(kind: .constraint, text: "ab")], safetyMode: .requireVerbatimText)
        if caseIndex == 2 {
            #expect(result.refusalReason == .unverifiableInformationLoss)
            #expect(result.summary == nil)
            #expect(result.compactedCount == 0)
            #expect(Compactor.sameMessages(result.messages, source))
        } else {
            #expect(result.refusalReason == nil)
            #expect(Compactor.isVerifiedLosslessProjection(from: source, result: result))
        }
    }

    @Test func sourceLessFactsRequireSourceAndProjectionEvidence() async throws {
        let source = [LLMMessage(role: .user, content: "Keep every word."),
                      LLMMessage(role: .assistant, content: "Line one\nLine two"), LLMMessage(role: .user, content: "Recent")]
        let base = try await Compactor(keepRecentMessages: 1).compact(messages: source, safetyMode: .requireVerbatimText)
        #expect(Compactor.isVerifiedLosslessProjection(from: source, result: base))
        func carrying(_ text: String) -> CompactionResult {
            CompactionResult(messages: base.messages, summary: base.summary, compactedCount: base.compactedCount,
                             retentionFacts: [.init(kind: .constraint, text: text)])
        }
        #expect(Compactor.isVerifiedLosslessProjection(from: source, result: carrying("Keep every word.")))
        #expect(!Compactor.isVerifiedLosslessProjection(from: source, result: carrying("Invented commitment")))
        #expect(!Compactor.isVerifiedLosslessProjection(from: source, result: carrying("Line one\nLine two")))
        #expect(!Compactor.isVerifiedLosslessProjection(from: source, result: carrying("   ")))
        let refused = try await Compactor(keepRecentMessages: 1).compact(messages: source,
            retentionFacts: [.init(kind: .constraint, text: "Invented commitment")], safetyMode: .requireVerbatimText)
        #expect(refused.refusalReason == .unverifiableInformationLoss)
        #expect(Compactor.sameMessages(refused.messages, source))
    }

    @Test(arguments: 0..<2) func repeatedStrictHistoryRetainsOccurrencesRolesOrderAndTail(layout: Int) async throws {
        let phrase = "The lantern remains beside the northern gate. "
        let repeated = String(repeating: phrase, count: 30)
        let historical = (0..<80).map { index in
            LLMMessage(role: layout == 0 || index % 4 < 2 ? .user : .assistant, content: repeated)
        }
        let tail = LLMMessage(role: .user, content: "Keep this newest request untouched.")
        let source = historical + [tail]
        let provider = SyntheticBudgetSummaryProvider()
        let result = try await Compactor(keepRecentMessages: 1, truncationPrefixChars: repeated.count).compact(messages: source, summarizeUsing: provider,
            safetyMode: .requireVerbatimText)
        #expect(provider.requests.isEmpty)
        #expect(result.refusalReason == nil)
        #expect(result.compactedCount == historical.count)
        #expect(Compactor.isVerifiedLosslessProjection(from: source, result: result))
        #expect(Compactor.hasMaterialRequestReduction(from: source, to: result.messages))
        #expect(Compactor.sameMessages(Array(result.messages.suffix(1)), [tail]))
        #expect(result.summary?.contains(repeated) == true)
        let summary = try #require(result.summary)
        let body = summary.dropFirst("<context-summary>\n".count).dropLast("\n</context-summary>".count)
        var object = try #require(JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])
        var runs = try #require(object["orderedEntryIndexAndOccurrenceCount"] as? [[Int]])
        runs[0][1] += 1
        object["orderedEntryIndexAndOccurrenceCount"] = runs
        let alteredBody = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        let alteredSummary = "<context-summary>\n" + String(decoding: alteredBody, as: UTF8.self) + "\n</context-summary>"
        var alteredProjection = result.messages
        alteredProjection[0] = LLMMessage(role: .user, content: alteredSummary)
        let alteredResult = CompactionResult(messages: alteredProjection, summary: alteredSummary, compactedCount: result.compactedCount)
        #expect(!Compactor.isVerifiedLosslessProjection(from: source, result: alteredResult))
        var roleChanged = source
        roleChanged[1] = LLMMessage(role: .assistant, content: repeated)
        #expect(!Compactor.isVerifiedLosslessProjection(from: roleChanged, result: result))
        var textChanged = source
        textChanged[40] = LLMMessage(role: source[40].role, content: repeated + "Changed")
        #expect(!Compactor.isVerifiedLosslessProjection(from: textChanged, result: result))
        #expect(!Compactor.isVerifiedLosslessProjection(from: source, compactedCount: result.compactedCount - 1, messages: result.messages))
        if layout == 1 {
            var reordered = source
            reordered.swapAt(1, 2)
            #expect(!Compactor.isVerifiedLosslessProjection(from: reordered, result: result))
        }
        var changedTail = result.messages
        changedTail[changedTail.count - 1] = LLMMessage(role: .user, content: "Different tail")
        #expect(!Compactor.isVerifiedLosslessProjection(from: source, compactedCount: result.compactedCount, messages: changedTail))
    }

    @Test func strictVerbatimProjectionRejectsTailTampering() async throws {
        let source = [LLMMessage(role: .user, content: "Keep every word."), LLMMessage(role: .assistant, content: "Exact explanation."), LLMMessage(role: .user, content: "Recent")]
        let result = try await Compactor(keepRecentMessages: 1).compact(messages: source, safetyMode: .requireVerbatimText)
        #expect(result.refusalReason == nil)
        #expect(Compactor.isVerifiedLosslessProjection(from: source, result: result))
        var changed = result.messages
        changed[changed.count - 1] = LLMMessage(role: .user, content: "Changed")
        #expect(!Compactor.isVerifiedLosslessProjection(from: source, compactedCount: result.compactedCount, messages: changed))
    }
}

@Suite("Clean-room unresolved import evidence boundary")
struct SyntheticPendingImportEvidenceContract {
    @Test func unsafeMarkerIsPreservedAndNeverUsedAsApproval() throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("skill-pending-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SkillStore(skillsRoot: root)
        let skill = try store.importSkill(content: "---\nname: Lantern Notes\n---\nKeep the ending.")
        let marker = store.skillDirectoryURL(for: skill.id).appendingPathComponent(".skill-import-pending.json")
        let evidence = Data("{\"generation\":99}".utf8)
        try evidence.write(to: marker, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: marker.path)
        store.reload()
        #expect(!store.isInjectable(skill))
        #expect(!store.allSkills().contains { $0.id == skill.id })
        #expect(try Data(contentsOf: marker) == evidence)
        #expect(store.rawContent(skill.id)?.contains("Keep the ending.") == true)
    }
}

@Suite("Clean-room interoperable v2 import recovery")
struct SyntheticV2ImportRecoveryContracts {
    // Fixture construction follows the published byte tables, independently of
    // the production private marker types and digest functions.
    private func digest(_ fields: [String]) -> String {
        let prefix = "miniscore.skill-import-transaction-digest:v1"
        let framed = fields.reduce(prefix) { $0 + String($1.utf8.count) + ":" + $1 }
        return SkillManifest.hash(framed)
    }
    private func manifestFields(_ manifest: SkillSourceManifest?) -> [String] {
        guard let manifest else { return ["<missing>"] }
        return [manifest.schema, String(manifest.version), manifest.skillID, manifest.source.dbValue, manifest.skillVersion, manifest.contentHash]
    }
    private func fixture(root: URL, id: String, previous: String, target: String, stage: Int, tamperGeneration: Bool = false) throws -> URL {
        let directory = root.appendingPathComponent(id, isDirectory: true)
        let oldManifest = SkillSourceManifest(skillID: id, source: .file, skillVersion: "1.0.0", content: previous)
        let newManifest = SkillSourceManifest(skillID: id, source: .file, skillVersion: "1.0.0", content: target)
        let oldHash = SkillManifest.hash(previous), newHash = SkillManifest.hash(target)
        let transaction = "synthetic-recovery-" + String(stage)
        let bodyTemp = ".SKILL.md." + transaction + ".tmp"
        let manifestTemp = ".manifest.json." + transaction + ".tmp"
        let binding = digest(["target", root.resolvingSymlinksInPath().standardizedFileURL.path,
                              directory.resolvingSymlinksInPath().standardizedFileURL.path, id])
        let before = digest(["pair", id, oldHash] + manifestFields(oldManifest))
        let after = digest(["pair", id, newHash] + manifestFields(newManifest))
        let markerHash = digest(["marker", "miniscore.skill-import-transaction", "2", transaction, "41", id,
            "SKILL.md", "manifest.json", bodyTemp, manifestTemp, binding, before, after, newHash] +
            manifestFields(newManifest) + [oldHash] + manifestFields(oldManifest))
        let encodedManifest = try JSONEncoder().encode(newManifest)
        let manifestObject = try JSONSerialization.jsonObject(with: encodedManifest)
        let oldManifestObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(oldManifest))
        let marker: [String: Any] = ["schema": "miniscore.skill-import-transaction", "version": 2,
            "transactionID": transaction, "generation": tamperGeneration ? 42 : 41, "skillID": id,
            "skillFileName": "SKILL.md", "manifestFileName": "manifest.json", "skillTempName": bodyTemp,
            "manifestTempName": manifestTemp, "targetBindingDigest": binding, "previousPairDigest": before,
            "expectedPairDigest": after, "expectedContentHash": newHash, "expectedManifest": manifestObject,
            "previousContentHash": oldHash, "previousManifest": oldManifestObject, "markerDigest": markerHash]
        switch stage {
        case 0: // Body has already been renamed, matching manifest is still staged.
            try Data(target.utf8).write(to: directory.appendingPathComponent("SKILL.md"), options: [.atomic])
            try encodedManifest.write(to: directory.appendingPathComponent(manifestTemp), options: [.atomic])
        case 1: // Neither rename happened yet.
            try Data(target.utf8).write(to: directory.appendingPathComponent(bodyTemp), options: [.atomic])
            try encodedManifest.write(to: directory.appendingPathComponent(manifestTemp), options: [.atomic])
        default: // Both renames happened; only the marker survived.
            try Data(target.utf8).write(to: directory.appendingPathComponent("SKILL.md"), options: [.atomic])
            try encodedManifest.write(to: directory.appendingPathComponent("manifest.json"), options: [.atomic])
        }
        let markerURL = directory.appendingPathComponent(".skill-import-pending.json")
        try JSONSerialization.data(withJSONObject: marker, options: [.sortedKeys]).write(to: markerURL, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: markerURL.path)
        return markerURL
    }

    @Test(arguments: [0, 1, 2]) func knownInterruptedStagesRecoverOneMatchingPair(stage: Int) throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("skill-v2-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let previous = "---\nname: Lantern Notes\nversion: 1.0.0\n---\nKeep the old ending."
        let target = "---\nname: Lantern Notes\nversion: 1.0.0\n---\nKeep the revised ending 星."
        let first = SkillStore(skillsRoot: root)
        let skill = try first.importSkill(content: previous)
        let marker = try fixture(root: root, id: skill.id, previous: previous, target: target, stage: stage)
        let reopened = SkillStore(skillsRoot: root)
        #expect(reopened.rawContent(skill.id) == target)
        let manifest = try JSONDecoder().decode(SkillSourceManifest.self, from: Data(contentsOf: reopened.skillManifestURL(for: skill.id)))
        #expect(manifest.contentHash == SkillManifest.hash(target))
        #expect(!FileManager.default.fileExists(atPath: marker.path))
        #expect(reopened.allSkills().allSatisfy { !reopened.isInjectable($0) })
    }

    @Test func generationTamperingPreservesEvidenceAndPreviousPair() throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("skill-v2-tamper-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let previous = "---\nname: Lantern Notes\n---\nKeep the old ending."
        let target = "---\nname: Lantern Notes\n---\nKeep the revised ending."
        let first = SkillStore(skillsRoot: root)
        let skill = try first.importSkill(content: previous)
        let marker = try fixture(root: root, id: skill.id, previous: previous, target: target, stage: 1, tamperGeneration: true)
        let evidence = try Data(contentsOf: marker)
        let reopened = SkillStore(skillsRoot: root)
        #expect(reopened.rawContent(skill.id) == previous)
        #expect(!reopened.allSkills().contains { $0.id == skill.id })
        #expect(try Data(contentsOf: marker) == evidence)
        #expect(!reopened.isInjectable(skill))
    }
}

@Suite("Clean-room catalog deadline clock")
struct SyntheticCatalogDeadlineContracts {
    @Test func uncontendedRefreshCanFinishAfterTwoSeconds() throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("skill-scan-work-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = SkillStore(skillsRoot: root)
        let raw = "---\nname: Slow Validation\n---\nSynthetic skill content."
        let skill = try original.importSkill(content: raw)
        let start = ProcessInfo.processInfo.systemUptime
        let reopened = SkillStore(skillsRoot: root, filesystemAccessObserver: { event in
            if case .directoryList = event { Thread.sleep(forTimeInterval: 2.1) }
        })
        #expect(ProcessInfo.processInfo.systemUptime - start >= 2)
        #expect(reopened.isInitialLoadComplete)
        #expect(reopened.rawContent(skill.id) == raw)
        #expect(reopened.lifecycleReceipt(for: skill.id) == original.lifecycleReceipt(for: skill.id))
    }

    @Test func batchKeepsCompleteValidEntriesAfterSlowWorkAndOmitsInvalidEntry() throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("skill-batch-work-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SkillStore(skillsRoot: root)
        let firstRaw = "---\nname: Batch One\n---\nFirst synthetic body."
        let secondRaw = "---\nname: Batch Two\n---\nSecond synthetic body."
        let first = try store.importSkill(content: firstRaw)
        let second = try store.importSkill(content: secondRaw)
        let invalid = try store.importSkill(content: "---\nname: Batch Invalid\n---\nSynthetic body.")
        final class Delay: @unchecked Sendable { var enabled = false }
        let delay = Delay()
        let reader = SkillStore(skillsRoot: root, filesystemAccessObserver: { event in
            if case .fileRead = event, delay.enabled {
                delay.enabled = false
                Thread.sleep(forTimeInterval: 2.1)
            }
        })
        try FileManager.default.removeItem(at: store.skillDirectoryURL(for: invalid.id).appendingPathComponent("SKILL.md"))
        delay.enabled = true
        let rootIdentity = try #require(SkillFilesystemBoundary.approvedRootIdentity(root))
        let start = ProcessInfo.processInfo.systemUptime
        let snapshots = try #require(reader.catalogFileSnapshots(for: [first.id, invalid.id, second.id], expectedRootIdentity: rootIdentity))
        #expect(ProcessInfo.processInfo.systemUptime - start >= 2)
        #expect(Set(snapshots.keys) == Set([first.id, second.id]))
        #expect(snapshots[first.id]?.content == firstRaw)
        #expect(snapshots[second.id]?.content == secondRaw)
    }

    @Test(arguments: [false, true])
    func refreshSharesContentionBudgetAcrossEntriesWithoutPublishingPartialCatalog(batch: Bool) throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("skill-scan-contention-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = SkillStore(skillsRoot: root)
        let first = try original.importSkill(content: "---\nname: Contention One\n---\nFirst synthetic body.")
        let second = try original.importSkill(content: "---\nname: Contention Two\n---\nSecond synthetic body.")
        func holdWriter(_ directory: URL) throws -> Int32 {
            let descriptor = open(directory.appendingPathComponent(".skill-import.lock").path, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
            guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
                let code = POSIXErrorCode(rawValue: errno) ?? .EIO
                close(descriptor)
                throw POSIXError(code)
            }
            return descriptor
        }
        let releases = DispatchGroup()
        // SkillStore calls this observer synchronously from one reload.
        final class Observation: @unchecked Sendable {
            var firstContendedID: String?
            var firstRead = false
            var secondContended = false
        }
        let observation = Observation()
        // Only the synchronous test thread mutates this dictionary.
        final class Writers: @unchecked Sendable { var descriptors: [String: Int32] = [:] }
        let writers = Writers()
        let observer: SkillStoreFilesystemAccessObserver = { event in
            switch event {
            case .scanLockContention(let id):
                if let firstID = observation.firstContendedID {
                    if id != firstID && !observation.secondContended {
                        observation.secondContended = true

                    }
                } else if let writer = writers.descriptors[id] {
                    observation.firstContendedID = id
                    releases.enter()
                    DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) {
                        _ = flock(writer, LOCK_UN)
                        releases.leave()
                    }
                }
            case .fileRead:
                guard !observation.firstRead, let id = observation.firstContendedID,
                      let otherWriter = writers.descriptors.first(where: { $0.key != id })?.value else { return }
                observation.firstRead = true
                // First reprobe spends ~1s of the shared budget. A fresh per-entry
                // budget reprobes after ~1.5s and can acquire this second lock.
                releases.enter()
                DispatchQueue.global().asyncAfter(deadline: .now() + 1.25) {
                    _ = flock(otherWriter, LOCK_UN)
                    releases.leave()
                }
            default: break
            }
        }
        let batchStore = batch ? SkillStore(skillsRoot: root, filesystemAccessObserver: observer) : nil
        let firstWriter = try holdWriter(original.skillDirectoryURL(for: first.id))
        defer { close(firstWriter) }
        let secondWriter = try holdWriter(original.skillDirectoryURL(for: second.id))
        defer { close(secondWriter) }
        writers.descriptors = [first.id: firstWriter, second.id: secondWriter]
        defer { releases.wait() }
        if let batchStore {
            let rootIdentity = try #require(SkillFilesystemBoundary.approvedRootIdentity(root))
            #expect(batchStore.catalogFileSnapshots(for: [first.id, second.id], expectedRootIdentity: rootIdentity) == nil)
        } else {
            let reopened = SkillStore(skillsRoot: root, filesystemAccessObserver: observer)
            #expect(observation.firstRead)
            #expect(!reopened.isInitialLoadComplete)
            #expect(reopened.allSkills().isEmpty)
            #expect(reopened.rawContent(first.id) == nil)
            #expect(reopened.rawContent(second.id) == nil)
        }
        #expect(observation.firstRead)
        #expect(observation.secondContended)
    }

    @Test func uptimeDeadlinePreservesUTF8CountsAndMissingManifest() throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("skill-clock-" + UUID().uuidString, isDirectory: true)
        let directory = root.appendingPathComponent("tiny-note", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("星".utf8).write(to: directory.appendingPathComponent("SKILL.md"), options: [.atomic])
        let store = SkillStore(skillsRoot: root)
        let approvedRoot = try #require(SkillFilesystemBoundary.approvedRootIdentity(root))
        let approvedDirectory = try #require(SkillFilesystemBoundary.trustedDirectoryIdentity(directory, within: root))
        let snapshot = store.catalogFileSnapshot(for: "tiny-note", expectedRootIdentity: approvedRoot,
            expectedSkillDirectoryIdentity: approvedDirectory, waitUntil: ProcessInfo.processInfo.systemUptime + 1)
        #expect(snapshot?.content == "星")
        #expect(snapshot?.contentByteCount == 3)
        #expect(snapshot?.manifestData == nil)
        #expect(snapshot?.manifestByteCount == 0)
        #expect(store.catalogFileSnapshot(for: "tiny-note", expectedRootIdentity: approvedRoot,
            expectedSkillDirectoryIdentity: approvedDirectory, waitUntil: ProcessInfo.processInfo.systemUptime - 1) == nil)
    }
}

@Suite("Clean-room deletion and collection error deltas")
struct SyntheticSkillDeletionAndImportErrorContracts {
    @Test func singleDeletionRetainsRestorableTrashPair() throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("skill-single-trash-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = "---\nname: Lantern Notes\n---\nKeep the ending."
        let store = SkillStore(skillsRoot: root)
        let skill = try store.importSkill(content: original)
        let directory = store.skillDirectoryURL(for: skill.id)
        let reference = directory.appendingPathComponent("references").appendingPathComponent("guide.md")
        try FileManager.default.createDirectory(at: reference.deletingLastPathComponent(), withIntermediateDirectories: false)
        let attachmentBytes = Data("Preserve the complete reference 星.\n".utf8)
        try attachmentBytes.write(to: reference, options: [.atomic])
        let originalBody = try Data(contentsOf: directory.appendingPathComponent("SKILL.md"))
        let originalManifest = try Data(contentsOf: store.skillManifestURL(for: skill.id))
        let preview = try store.previewDeletion(skillID: skill.id)
        do {
            _ = try store.deleteSkill(skill.id, intent: preview)
            Issue.record("An unconfirmed deletion intent must not delete the skill")
        } catch { /* Existing deletion gate may report its existing strict error. */ }
        #expect(try Data(contentsOf: directory.appendingPathComponent("SKILL.md")) == originalBody)
        let intent = preview.withFirstConfirmation("first").withSecondConfirmation("second")
        let receipt = try store.deleteSkill(skill.id, intent: intent)
        #expect(receipt.operationID == intent.operationID)
        #expect(receipt.targetID == intent.targetID)
        #expect(receipt.scopeID == intent.scopeID)
        #expect(store.rawContent(skill.id) == nil)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
        #expect(!store.allSkills().contains { $0.id == skill.id })
        #expect(!store.isInjectable(skill))
        do {
            _ = try store.deleteSkill(skill.id, intent: intent)
            Issue.record("The exact successful deletion intent must remain consumed")
        } catch { #expect(error as? DeletionGateError == .alreadyConsumed) }
        let service = SkillDeletionService(store: store)
        // A newly occupied destination must be left untouched by the original
        // receipt. Remove only this test-created occupant before the real restore.
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let occupant = Data("New target occupant".utf8)
        try occupant.write(to: directory.appendingPathComponent("SKILL.md"))
        do {
            try service.restore(receipt)
            Issue.record("Restore must not overwrite a newly occupied target")
        } catch let error as SkillDeletionError {
            if case .restoreTargetExists = error {} else { Issue.record("Expected restoreTargetExists") }
        }
        #expect(try Data(contentsOf: directory.appendingPathComponent("SKILL.md")) == occupant)
        try FileManager.default.removeItem(at: directory)
        try service.restore(receipt)
        #expect(try Data(contentsOf: directory.appendingPathComponent("SKILL.md")) == originalBody)
        #expect(try Data(contentsOf: store.skillManifestURL(for: skill.id)) == originalManifest)
        #expect(try Data(contentsOf: reference) == attachmentBytes)
        #expect(store.rawContent(skill.id) == original)
        #expect(store.allSkills().allSatisfy { !store.isInjectable($0) })
    }

    @Test func safelyReadInvalidCollectionMemberThrows() throws {
        let parent = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("skill-collection-error-" + UUID().uuidString, isDirectory: true)
        let root = parent.appendingPathComponent("destination", isDirectory: true)
        let collection = parent.appendingPathComponent("collection", isDirectory: true)
        let valid = collection.appendingPathComponent("valid", isDirectory: true)
        let invalid = collection.appendingPathComponent("invalid", isDirectory: true)
        try FileManager.default.createDirectory(at: valid, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: invalid, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: parent) }
        try Data("---\nname: River Notes\n---\nKeep the opening.".utf8).write(to: valid.appendingPathComponent("SKILL.md"))
        try Data(" \n\t ".utf8).write(to: invalid.appendingPathComponent("SKILL.md"))
        let store = SkillStore(skillsRoot: root)
        do {
            _ = try store.importSkill(from: collection)
            Issue.record("An invalid safely-read member must propagate import failure")
        } catch let error as SkillError {
            #expect(error == .invalidContent)
        }
        // An actually empty collection remains a successful empty result.
        let empty = parent.appendingPathComponent("empty", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: false)
        #expect(try store.importSkill(from: empty).isEmpty)
    }
}

private final class SyntheticForeignSkillWriter: @unchecked Sendable {
    enum Moment: Sendable { case staged, markerWritten }
    private let mutex = NSLock()
    private let directory: URL
    private let root: URL
    private let replacements: [(String, Data)]
    private let moment: Moment
    private var armed = false
    private var changed = false
    private var writeError: String?
    init(root: URL, skillID: String, replacements: [(String, Data)], moment: Moment) {
        self.root = root; self.directory = root.appendingPathComponent(skillID)
        self.replacements = replacements; self.moment = moment
    }
    func arm() { mutex.lock(); armed = true; mutex.unlock() }
    func observe(_ event: SkillStoreFilesystemAccess) {
        guard case .fileRead = event else { return }
        mutex.lock(); defer { mutex.unlock() }
        guard armed, !changed else { return }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        let hasStaging = names.contains { $0.hasPrefix(".SKILL.md.") && $0.hasSuffix(".tmp") }
        let markerPresent = names.contains(".skill-import-pending.json")
        let ready: Bool
        switch moment { case .staged: ready = hasStaging && !markerPresent; case .markerWritten: ready = markerPresent }
        guard ready else { return }
        changed = true
        do {
            for (relative, bytes) in replacements { try bytes.write(to: root.appendingPathComponent(relative), options: [.atomic]) }
        } catch { writeError = String(describing: error) }
    }
    var result: (Bool, String?) { mutex.lock(); defer { mutex.unlock() }; return (changed, writeError) }
}

@Suite("Clean-room reviewed maintenance content conditions")
struct SyntheticSkillContentExpectationContracts {
    private let first = "---\nname: Lantern Notes\nversion: 1.0.0\n---\nKeep the original ending."
    private let second = "---\nname: Lantern Notes\nversion: 1.0.0\n---\nKeep the foreign writer's ending."
    private let replacement = "---\nname: Lantern Notes\nversion: 1.0.0\n---\nKeep the reviewed replacement."
    private let approval = SkillApproval(approverID: "synthetic-reviewed-maintenance")
    private func withRoot(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("skill-expectation-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }

    @Test func absentCreatesThenRejectsExistingTargetWithoutChangingBytes() throws {
        try withRoot { root in
            let store = SkillStore(skillsRoot: root)
            let created = try store.importSkillThroughLifecycle(content: first, reason: "Reviewed creation", approval: approval, contentExpectation: .absent)
            #expect(store.rawContent(created.skill.id) == first)
            let bodyBefore = try Data(contentsOf: store.skillDirectoryURL(for: created.skill.id).appendingPathComponent("SKILL.md"))
            let manifestBefore = try Data(contentsOf: store.skillManifestURL(for: created.skill.id))
            let ledgerBefore = try Data(contentsOf: store.lifecycleReceiptsFileURL)
            do {
                _ = try store.importSkillThroughLifecycle(content: replacement, reason: "Stale reviewed creation", approval: approval, contentExpectation: .absent)
                Issue.record("absent must not overwrite an existing target")
            } catch let error as SkillError { #expect(error == .importFailed(reason: "reviewed skill target changed")) }
            #expect(try Data(contentsOf: store.skillDirectoryURL(for: created.skill.id).appendingPathComponent("SKILL.md")) == bodyBefore)
            #expect(try Data(contentsOf: store.skillManifestURL(for: created.skill.id)) == manifestBefore)
            #expect(try Data(contentsOf: store.lifecycleReceiptsFileURL) == ledgerBefore)
        }
    }

    @Test func matchingHashUpdatesButMissingHashTargetIsRejected() throws {
        try withRoot { root in
            let store = SkillStore(skillsRoot: root)
            do {
                _ = try store.importSkillThroughLifecycle(content: replacement, reason: "Missing reviewed target", approval: approval, contentExpectation: .hash(SkillManifest.hash(first)))
                Issue.record("hash requires a present matching target")
            } catch let error as SkillError { #expect(error == .importFailed(reason: "reviewed skill target changed")) }
            let created = try store.importSkill(content: first)
            let updated = try store.importSkillThroughLifecycle(content: replacement, reason: "Reviewed update", approval: approval, contentExpectation: .hash(SkillManifest.hash(first)))
            #expect(updated.skill.id == created.id)
            #expect(store.rawContent(created.id) == replacement)
            #expect(updated.receipt.contentHash == SkillManifest.hash(replacement))
        }
    }

    @Test func staleHashLeavesAnotherStoresCommittedVersionUntouched() throws {
        try withRoot { root in
            let originalStore = SkillStore(skillsRoot: root)
            let created = try originalStore.importSkill(content: first)
            let otherStore = SkillStore(skillsRoot: root)
            _ = try otherStore.importSkillThroughLifecycle(content: second, reason: "Other reviewed writer", approval: approval)
            let manifestBefore = try Data(contentsOf: otherStore.skillManifestURL(for: created.id))
            let ledgerBefore = try Data(contentsOf: otherStore.lifecycleReceiptsFileURL)
            do {
                _ = try originalStore.importSkillThroughLifecycle(content: replacement, reason: "Stale update", approval: approval, contentExpectation: .hash(SkillManifest.hash(first)))
                Issue.record("stale reviewed hash must reject the update")
            } catch let error as SkillError { #expect(error == .importFailed(reason: "reviewed skill target changed")) }
            #expect(originalStore.rawContent(created.id) == second)
            #expect(try Data(contentsOf: originalStore.skillManifestURL(for: created.id)) == manifestBefore)
            #expect(try Data(contentsOf: originalStore.lifecycleReceiptsFileURL) == ledgerBefore)
        }
    }

    @Test(arguments: [SyntheticForeignSkillWriter.Moment.staged, .markerWritten])
    private func targetChangesImmediatelyBeforeCommitPreserveForeignFiles(moment: SyntheticForeignSkillWriter.Moment) throws {
        try withRoot { root in
            let initialStore = SkillStore(skillsRoot: root)
            let created = try initialStore.importSkill(content: first)
            let foreignRoot = root.appendingPathComponent("foreign-fixture", isDirectory: true)
            let foreignStore = SkillStore(skillsRoot: foreignRoot)
            _ = try foreignStore.importSkillThroughLifecycle(content: second, reason: "Independent reviewed version", approval: approval)
            let bodyBytes = Data(second.utf8)
            let manifestBytes = try Data(contentsOf: foreignStore.skillManifestURL(for: created.id))
            let ledgerBytes = try Data(contentsOf: foreignStore.lifecycleReceiptsFileURL)
            let probe = SyntheticForeignSkillWriter(root: root, skillID: created.id,
                replacements: [(created.id + "/SKILL.md", bodyBytes), (created.id + "/manifest.json", manifestBytes), ("lifecycle-receipts.json", ledgerBytes)], moment: moment)
            let observed = SkillStore(skillsRoot: root, filesystemAccessObserver: { probe.observe($0) })
            probe.arm()
            do {
                _ = try observed.importSkillThroughLifecycle(content: replacement, reason: "Reviewed update raced", approval: approval, contentExpectation: .hash(SkillManifest.hash(first)))
                Issue.record("a changed target must be rejected at the commit boundary")
            } catch let error as SkillError { #expect(error == .importFailed(reason: "reviewed skill target changed")) }
            #expect(probe.result.0)
            #expect(probe.result.1 == nil)
            #expect(try Data(contentsOf: observed.skillDirectoryURL(for: created.id).appendingPathComponent("SKILL.md")) == bodyBytes)
            #expect(try Data(contentsOf: observed.skillManifestURL(for: created.id)) == manifestBytes)
            #expect(try Data(contentsOf: observed.lifecycleReceiptsFileURL) == ledgerBytes)
            let remaining = try FileManager.default.contentsOfDirectory(atPath: observed.skillDirectoryURL(for: created.id).path)
            #expect(!remaining.contains { ($0.hasPrefix(".SKILL.md.") || $0.hasPrefix(".manifest.json.")) && $0.hasSuffix(".tmp") })
            #expect(!remaining.contains(".skill-import-pending.json"))
            let reopened = SkillStore(skillsRoot: root)
            let foreignSkill = try #require(reopened.allSkills().first { $0.id == created.id })
            #expect(reopened.isInjectable(foreignSkill))
        }
    }
}

@Suite("Clean-room same-capture frozen skill authority")
struct SyntheticSkillFrozenAuthorityContracts {
    private func withRoot(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("skill-frozen-authority-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }

    @Test func stableQualifiedLiveSetSurvivesOneSnapshotAndRegistry() throws {
        try withRoot { root in
            #expect(!Task.isCancelled)
            let store = SkillStore(skillsRoot: root)
            let names = ["Lantern Draft", "River Draft", "Meadow Draft"]
            for name in names {
                let content = "---\nname: \(name)\nversion: 1.0.0\n---\nReview the \(name) ending."
                let proposed = try store.importSkillThroughLifecycle(content: content, reason: "Explicit synthetic proposal")
                #expect(proposed.receipt.state == .proposed)
                #expect(!store.isInjectable(proposed.skill))
                _ = try store.approveAndActivateSkill(proposed.skill.id, approval: SkillApproval(approverID: "synthetic-reviewer"), reason: "Explicit synthetic activation")
            }
            #expect(store.isInitialLoadComplete)
            // All qualification checks occur at this one stable capture point.
            let live = store.allSkills()
            #expect(Set(live.map(\.name)) == Set(names))
            for skill in live { #expect(store.isInjectable(skill)) }
            #expect(!Task.isCancelled)
            let capture = store.snapshot()
            #expect(Set(capture.skills.map(\.id)) == Set(live.map(\.id)))
            #expect(capture.lifecycleReceipts.count == 3)
            let frozen = SkillStore.makeSnapshotStore(from: capture)
            #expect(frozen.snapshot() == capture)
            #expect(Set(frozen.allSkills().map(\.name)) == Set(names))
            let registry = SkillRegistry(store: frozen)
            for skill in frozen.allSkills() {
                #expect(frozen.isInjectable(skill))
                #expect(registry.entry(for: skill.id) != nil)
                #expect(registry.rejection(for: skill, content: frozen.rawContent(skill.id)) == nil)
            }
        }
    }

    @Test func suppliedSnapshotValuesArePreservedWithoutNormalizingFileContents() throws {
        try withRoot { root in
            let store = SkillStore(skillsRoot: root)
            let raw = "---\nname: Lantern Notes\n---\nKeep the ending."
            let skill = try store.importSkill(content: raw)
            let original = store.snapshot()
            let supplied = SkillStore.Snapshot(skillsRoot: original.skillsRoot, skills: original.skills,
                lifecycleReceipts: original.lifecycleReceipts, disabledSkillIDs: original.disabledSkillIDs,
                rawContents: original.rawContents, fileContents: [skill.id: ["references/guide.md": "Captured guide"]])
            let frozen = SkillStore.makeSnapshotStore(from: supplied)
            #expect(frozen.snapshot() == supplied)
            #expect(frozen.readSkillFile(skill.id, relativePath: "SKILL.md") == raw)
            #expect(frozen.readSkillFile(skill.id, relativePath: "references/guide.md") == "Captured guide")
            try Data("Changed live bytes".utf8).write(to: store.skillDirectoryURL(for: skill.id).appendingPathComponent("SKILL.md"), options: [.atomic])
            #expect(frozen.snapshot() == supplied)
            #expect(frozen.makeSnapshotStore().snapshot() == supplied)
            #expect(frozen.rawContent(skill.id) == raw)
        }
    }

}

private final class SyntheticBudgetSummaryProvider: LLMProvider, @unchecked Sendable {
    struct Request: Sendable {
        let text: String
        let systemPrompt: String?
        let maximumTokens: Int
        let temperature: Double?
    }
    let name = "Synthetic budget summary"
    var model = LLMModel(id: "synthetic-budget", displayName: "Synthetic", provider: "Synthetic")
    let capabilities: Set<ProviderCapability> = []
    private let mutex = NSLock()
    private var stored: [Request] = []
    private let reply: String
    init(reply: String = "Condensed historical explanation.") { self.reply = reply }
    private func record(messages: [LLMMessage], systemPrompt: String?, maximumTokens: Int, temperature: Double?) {
        mutex.lock(); defer { mutex.unlock() }
        stored.append(Request(text: messages.map(\.content).joined(separator: "\n"), systemPrompt: systemPrompt, maximumTokens: maximumTokens, temperature: temperature))
    }
    var requests: [Request] { mutex.lock(); defer { mutex.unlock() }; return stored }
    nonisolated(nonsending) func sendMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int, temperature: Double?) async throws -> LLMResponse {
        record(messages: messages, systemPrompt: systemPrompt, maximumTokens: maxTokens, temperature: temperature)
        return LLMResponse(text: reply, stopReason: nil, usage: nil)
    }
    nonisolated(nonsending) func sendMessage(messages: [LLMMessage], systemPrompt: String?, tools: [AgentToolDefinition], maxTokens: Int, temperature: Double?) async throws -> LLMResponse {
        try await sendMessage(messages: messages, systemPrompt: systemPrompt, maxTokens: maxTokens, temperature: temperature)
    }
    nonisolated(nonsending) func streamMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int, temperature: Double?) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

@Suite("Clean-room source-anchored request budget")
struct SyntheticCompactionBudgetContracts {
    private func typedTaskFact(messages: [LLMMessage], taskID: String) throws -> CompactionRetainedFact {
        let session = "synthetic-budget-session"
        let parent = ParentRuntimeIdentity(sessionID: session, conversationID: "synthetic-budget-conversation",
            turnID: "synthetic-budget-turn", taskID: "synthetic-budget-parent", actorID: "synthetic-budget-actor")
        let task = AgentTaskSnapshot(taskID: taskID, parentID: parent.taskID, parentContextSnapshotID: nil,
            providerID: nil, modelID: nil, configurationFingerprint: nil, routeReceiptID: nil, status: .queued,
            parentRuntimeIdentity: parent)
        let digest = try #require(CompactionCheckpoint.digestOfSourcePrefix(messages))
        let source = CompactionFactSource(sessionID: session, transcriptRevision: 1, transcriptDigest: digest, task: task)
        #expect(source.matchesTranscript(messages))
        #expect(CompactionFactCapture.taskBelongs(task, to: session))
        return CompactionRetainedFact(kind: source.kind, text: source.backgroundText, source: source)
    }

    @Test(arguments: 0..<6) func publishedCharacterCostFixtures(caseIndex: Int) {
        let source: [LLMMessage]
        let projection: [LLMMessage]
        let expected: Bool
        switch caseIndex {
        case 0:
            source = (0..<16).map { _ in LLMMessage(role: .user, content: "") }; projection = []; expected = true
        case 1:
            source = [LLMMessage(role: .user, content: String(repeating: "星", count: 24))]; projection = []; expected = false
        case 2:
            source = [LLMMessage(role: .user, content: String(repeating: "a", count: 67))]
            projection = [LLMMessage(role: .user, content: "aaaa")]; expected = false
        case 3:
            source = [LLMMessage(role: .user, content: String(repeating: "a", count: 80))]
            projection = [LLMMessage(role: .user, content: String(repeating: "a", count: 16))]; expected = true
        case 4:
            source = [LLMMessage(role: .user, content: String(repeating: "a", count: 400))]
            projection = [LLMMessage(role: .user, content: String(repeating: "a", count: 356))]; expected = false
        default:
            source = [LLMMessage(role: .user, content: String(repeating: "a", count: 800))]
            projection = [LLMMessage(role: .user, content: String(repeating: "a", count: 720))]; expected = true
        }
        #expect(Compactor.hasMaterialRequestReduction(from: source, to: projection) == expected)
    }

    @Test func graphemeWhitespaceAndToolFieldsKeepThePublishedUnit() {
        let family = "👩‍👩‍👧‍👦"
        #expect(!Compactor.hasMaterialRequestReduction(from: [LLMMessage(role: .user, content: String(repeating: family, count: 67))],
            to: [LLMMessage(role: .user, content: String(repeating: family, count: 4))]))
        #expect(Compactor.hasMaterialRequestReduction(from: [LLMMessage(role: .user, content: String(repeating: " ", count: 80))],
            to: [LLMMessage(role: .user, content: String(repeating: " ", count: 16))]))
        let plain = LLMMessage(role: .assistant, content: String(repeating: "a", count: 67))
        let withTool = LLMMessage(role: .assistant, content: plain.content,
            toolCalls: [.init(id: "synthetic-budget-call", name: "synthetic_tool", rawArguments: String(repeating: "x", count: 10_000), arguments: [:])])
        let projection = [LLMMessage(role: .assistant, content: "aaaa")]
        #expect(!Compactor.hasMaterialRequestReduction(from: [plain], to: projection))
        #expect(!Compactor.hasMaterialRequestReduction(from: [withTool], to: projection))
    }

    @Test(arguments: 0..<3) func fixedPreservationCostRejectsBeforeProvider(caseIndex: Int) async throws {
        let messages: [LLMMessage]
        let facts: [CompactionRetainedFact]
        switch caseIndex {
        case 0:
            messages = [LLMMessage(role: .user, content: String(repeating: "u", count: 1_000)),
                        LLMMessage(role: .assistant, content: String(repeating: "a", count: 40)), LLMMessage(role: .user, content: "Tail")]
            facts = []
        case 1:
            messages = [LLMMessage(role: .user, content: "Question"), LLMMessage(role: .assistant, content: String(repeating: "a", count: 4_000)), LLMMessage(role: .user, content: "Tail")]
            facts = [try typedTaskFact(messages: messages, taskID: "budget-" + String(repeating: "f", count: 8_000))]
            let background = try #require(CompactionFactCapture.backgroundMessage(facts))
            let preserved = try #require(Compactor.sourceAnchoredSummary(from: messages, range: 0..<2, assistantSummary: "x"))
            let sourceCost = messages.reduce(0) { $0 + max(1, $1.content.count / 4) }
            let fixedCost = [preserved, background, messages[2]].reduce(0) { $0 + max(1, $1.content.count / 4) }
            #expect(fixedCost > min(sourceCost - 16, Int((Double(sourceCost) * 0.9).rounded(.down))))
        default:
            messages = [LLMMessage(role: .user, content: String(repeating: "u", count: 1_000)), LLMMessage(role: .user, content: "Tail")]
            facts = []
        }
        let provider = SyntheticBudgetSummaryProvider()
        let result = try await Compactor(keepRecentMessages: 1).compact(messages: messages, summarizeUsing: provider,
            retentionFacts: facts, safetyMode: .sourceAnchoredNatural)
        #expect(provider.requests.isEmpty)
        #expect(result.refusalReason == .unverifiableInformationLoss)
        #expect(result.summary == nil)
        #expect(result.compactedCount == 0)
        #expect(Compactor.sameMessages(result.messages, messages))
    }

    @Test func feasibleSpansRequestOneSharedTargetFromTheirRealEnvelopeCost() async throws {
        let messages = [LLMMessage(role: .user, content: "First request"), LLMMessage(role: .assistant, content: String(repeating: "a", count: 4_000)),
            LLMMessage(role: .assistant, content: "Tool boundary", toolCalls: [.init(id: "budget-call", name: "synthetic_tool", rawArguments: "{}", arguments: [:])]),
            LLMMessage(role: .tool, content: "Done", toolCallID: "budget-call"),
            LLMMessage(role: .user, content: "Second request"), LLMMessage(role: .assistant, content: String(repeating: "b", count: 4_000)),
            LLMMessage(role: .user, content: "Tail")]
        let facts = [try typedTaskFact(messages: messages, taskID: "synthetic-budget-open-task")]
        let firstMinimum = try #require(Compactor.sourceAnchoredSummary(from: messages, range: 0..<2, assistantSummary: "x"))
        let secondMinimum = try #require(Compactor.sourceAnchoredSummary(from: messages, range: 4..<6, assistantSummary: "x"))
        let factBackground = try #require(CompactionFactCapture.backgroundMessage(facts))
        let minimumCandidate = [firstMinimum, messages[2], messages[3], secondMinimum, factBackground, messages[6]]
        // These are the public contract's B and F measured on the actual
        // self-owned output envelope, rather than copied donor numbers.
        let sourceCost = messages.reduce(0) { $0 + max(1, $1.content.count / 4) }
        let fixedCost = minimumCandidate.reduce(0) { $0 + max(1, $1.content.count / 4) }
        let ceiling = min(sourceCost - 16, Int((Double(sourceCost) * 0.9).rounded(.down)))
        #expect(fixedCost <= ceiling)
        let expectedTarget = 1 + 4 * ((ceiling - fixedCost) / 2)
        let provider = SyntheticBudgetSummaryProvider()
        let result = try await Compactor(keepRecentMessages: 1).compact(messages: messages, summarizeUsing: provider,
            systemPrompt: "Independent synthetic system prompt", retentionFacts: facts, safetyMode: .sourceAnchoredNatural)
        #expect(provider.requests.count == 2)
        for request in provider.requests {
            #expect(request.text.contains("Character target: \(expectedTarget)."))
            let budgetLines = request.text.components(separatedBy: "\n").filter { $0.hasPrefix("Maximum assistant summary length: ") }
            #expect(budgetLines == ["Maximum assistant summary length: \(expectedTarget) Unicode characters, including whitespace."])
            #expect(request.text.contains("Unicode Characters"))
            #expect(request.text.contains("including whitespace"))
            #expect(request.text.contains("unfinished work, commitments, and completed effects"))
            #expect(request.maximumTokens == 1_024)
            #expect(request.temperature == 0)
            #expect(request.systemPrompt == "Independent synthetic system prompt")
        }
        #expect(result.refusalReason == nil)
    }

    @Test func responsePastCharacterTargetStillUsesTheFinalWholeCandidateGate() async throws {
        let source = [LLMMessage(role: .user, content: "Question"),
                      LLMMessage(role: .assistant, content: String(repeating: "a", count: 4_000)), LLMMessage(role: .user, content: "Tail")]
        let lower = try #require(Compactor.sourceAnchoredSummary(from: source, range: 0..<2, assistantSummary: "x"))
        let sourceCost = source.reduce(0) { $0 + max(1, $1.content.count / 4) }
        let fixedCost = max(1, lower.content.count / 4) + max(1, source[2].content.count / 4)
        let ceiling = min(sourceCost - 16, Int((Double(sourceCost) * 0.9).rounded(.down)))
        let target = 1 + 4 * (ceiling - fixedCost)
        let answer = String(repeating: "s", count: target + 1)
        let provider = SyntheticBudgetSummaryProvider(reply: answer)
        let result = try await Compactor(keepRecentMessages: 1).compact(messages: source, summarizeUsing: provider, safetyMode: .sourceAnchoredNatural)
        #expect(provider.requests.count == 1)
        #expect(provider.requests.first?.text.contains("Character target: \(target).") == true)
        #expect(result.refusalReason == nil)
        #expect(result.messages.first?.content.contains(answer) == true)
        #expect(result.retentionFacts != nil)
        #expect(result.retentionFacts == [])
        #expect(CompactionResult(messages: [], summary: nil, compactedCount: 0).retentionFacts == nil)
        #expect(Compactor.hasMaterialRequestReduction(from: source, to: result.messages))
        #expect(!result.messages.contains { $0.content == "x" || $0.content.contains("\"assistantSummary\":\"x\"") })

        let oversizedProvider = SyntheticBudgetSummaryProvider(reply: String(repeating: "f", count: 8_000))
        let refused = try await Compactor(keepRecentMessages: 1).compact(messages: source, summarizeUsing: oversizedProvider, safetyMode: .sourceAnchoredNatural)
        #expect(oversizedProvider.requests.count == 1)
        #expect(refused.refusalReason == .unverifiableInformationLoss)
        #expect(refused.summary == nil)
        #expect(refused.compactedCount == 0)
        #expect(Compactor.sameMessages(refused.messages, source))
        #expect(!refused.messages.contains { $0.content == "x" || $0.content.contains("\"assistantSummary\":\"x\"") })
    }
}

private final class SyntheticSkillAccessCounter: @unchecked Sendable {
    private let mutex = NSLock()
    private var total = 0
    func record(_ event: SkillStoreFilesystemAccess) { mutex.lock(); total += 1; mutex.unlock() }
    func reset() { mutex.lock(); total = 0; mutex.unlock() }
    var count: Int { mutex.lock(); defer { mutex.unlock() }; return total }
}

@Suite("Clean-room fresh disabled preparation authority")
struct SyntheticFreshDisabledPreparationContracts {
    private func sandbox() throws -> (parent: URL, root: URL, shared: URL) {
        let parent = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("skill-fresh-disabled-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        return (parent, parent.appendingPathComponent("skills", isDirectory: true), parent.appendingPathComponent("skills-enabled.json"))
    }
    private func writeMask(_ enabled: Bool, id: String, to file: URL) throws {
        try JSONEncoder().encode(["app:" + id: enabled]).write(to: file, options: [.atomic])
    }

    @Test func sameDirectionMaskBeforeFreshCaptureKeepsFullDisabledMetadata() throws {
        let fixture = try sandbox()
        defer { try? FileManager.default.removeItem(at: fixture.parent) }
        let counter = SyntheticSkillAccessCounter()
        let store = SkillStore(skillsRoot: fixture.root, filesystemAccessObserver: { counter.record($0) })
        let raw = "---\nname: Lantern Notes\n---\nKeep the reviewed ending."
        let skill = try store.importSkill(content: raw)
        #expect(store.isInitialLoadComplete)
        #expect(store.isInjectable(skill))
        let completedBeforeClose = try #require(store.captureTurnAuthority().prepareStore())
        let oldPending = store.captureTurnAuthority()
        #expect(store.setEnabled(skill.id, enabled: false))
        try writeMask(false, id: skill.id, to: fixture.shared)
        // No Store getter, reload, wait, or second capture intervenes between
        // the successful Core/mask writes and the one new preparation.
        counter.reset()
        let fresh = store.captureTurnAuthority()
        #expect(counter.count == 0)
        let disabled = try #require(fresh.prepareStore())
        #expect(store.matchesTurnAuthority(fresh))
        let metadata = disabled.snapshot()
        #expect(metadata.skills.map(\.id) == [skill.id])
        #expect(metadata.lifecycleReceipts[skill.id]?.contentHash == SkillManifest.hash(raw))
        #expect(metadata.disabledSkillIDs.contains(skill.id))
        #expect(metadata.rawContents[skill.id] == raw)
        #expect(metadata.fileContents[skill.id]?["SKILL.md"] == raw)
        #expect(disabled.allSkills().allSatisfy { !$0.isEnabled && !disabled.isInjectable($0) })
        #expect(completedBeforeClose.rawContent(skill.id) == raw)
        #expect(completedBeforeClose.allSkills().allSatisfy { completedBeforeClose.isInjectable($0) })
        #expect(!store.matchesTurnAuthority(oldPending))
        #expect(oldPending.prepareStore() == nil)
        // Clear the external veto before requesting an authorized Core enable.
        // It alone cannot grant a previously captured execution permission.
        try writeMask(true, id: skill.id, to: fixture.shared)
        #expect(store.setEnabled(skill.id, enabled: true))
        let enabled = try #require(store.captureTurnAuthority().prepareStore())
        #expect(enabled.allSkills().allSatisfy { enabled.isInjectable($0) })
        #expect(!store.matchesTurnAuthority(oldPending))
        #expect(disabled.allSkills().allSatisfy { !disabled.isInjectable($0) })
    }

    @Test func effectiveSharedRevocationAfterCaptureStillInvalidatesIt() throws {
        let fixture = try sandbox()
        defer { try? FileManager.default.removeItem(at: fixture.parent) }
        let store = SkillStore(skillsRoot: fixture.root)
        let skill = try store.importSkill(content: "---\nname: Lantern Notes\n---\nKeep the ending.")
        #expect(store.isInjectable(skill))
        let pending = store.captureTurnAuthority()
        try writeMask(false, id: skill.id, to: fixture.shared)
        let restricted = try #require(pending.prepareStore())
        #expect(restricted.allSkills().first?.isEnabled == false)
        #expect(!restricted.isInjectable(skill))
        #expect(restricted.rawContent(skill.id) == store.rawContent(skill.id))
        #expect(!store.matchesTurnAuthority(pending))
        #expect(store.setEnabled(skill.id, enabled: false))
        let closedCapture = store.captureTurnAuthority()
        try writeMask(true, id: skill.id, to: fixture.shared)
        let stillClosed = try #require(closedCapture.prepareStore())
        #expect(stillClosed.allSkills().first?.isEnabled == false)
        #expect(!stillClosed.isInjectable(skill))
        #expect(!store.matchesTurnAuthority(pending))
    }

    @Test func canceledPreparationAndChangedContentStillFailClosed() async throws {
        let fixture = try sandbox()
        defer { try? FileManager.default.removeItem(at: fixture.parent) }
        let store = SkillStore(skillsRoot: fixture.root)
        let skill = try store.importSkill(content: "---\nname: Lantern Notes\n---\nKeep the ending.")
        let canceledCapture = store.captureTurnAuthority()
        let canceledAttempt = Task<Bool, Never> {
            withUnsafeCurrentTask { $0?.cancel() }
            return canceledCapture.prepareStore() == nil
        }
        #expect(await canceledAttempt.value)
        let changedCapture = store.captureTurnAuthority()
        try Data("Unexpected changed content".utf8).write(to: store.skillDirectoryURL(for: skill.id).appendingPathComponent("SKILL.md"), options: [.atomic])
        #expect(changedCapture.prepareStore() == nil)
        #expect(!store.matchesTurnAuthority(changedCapture))
    }
}

private final class SyntheticBootstrapReadGate: @unchecked Sendable {
    private let lock = NSLock()
    private let releaseSignal = DispatchSemaphore(value: 0)
    private var entered = false
    private var entranceWaiter: CheckedContinuation<Void, Never>?
    func observe(_ event: SkillStoreFilesystemAccess) {
        guard case .directoryList = event else { return }
        pauseOnce()
    }
    func pauseOnce() {
        lock.lock()
        guard !entered else { lock.unlock(); return }
        entered = true
        let waiter = entranceWaiter; entranceWaiter = nil
        lock.unlock()
        waiter?.resume()
        releaseSignal.wait()
    }
    func waitForEntry() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            let complete = entered
            if !complete { entranceWaiter = continuation }
            lock.unlock()
            if complete { continuation.resume() }
        }
    }
    func release() { releaseSignal.signal() }
}

@Suite("Clean-room bootstrap attempt termination")
struct SyntheticBootstrapAttemptContracts {
    private func temporaryParent() throws -> URL {
        let parent = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("skill-bootstrap-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        return parent
    }

    @Test func pausedInitialReadStaysPendingAndCancelledWaitDoesNotCancelCanonicalRead() async throws {
        let parent = try temporaryParent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("skills", isDirectory: true)
        let seeded = SkillStore(skillsRoot: root)
        let raw = "---\nname: Lantern Bootstrap\n---\nPreserve the reviewed instructions."
        let skill = try seeded.importSkill(content: raw)
        let receiptBefore = try Data(contentsOf: seeded.lifecycleReceiptsFileURL)
        let manifestBefore = try Data(contentsOf: seeded.skillManifestURL(for: skill.id))
        let gate = SyntheticBootstrapReadGate()
        defer { gate.release() }
        let store = SkillStore.startForAppBootstrap(skillsRoot: root, filesystemAccessObserver: { gate.observe($0) })
        await gate.waitForEntry()
        #expect(!store.isInitialLoadComplete)
        #expect(store.skills.isEmpty)
        #expect(store.allSkills().isEmpty)
        #expect(store.rawContent(skill.id) == nil)
        #expect(store.readSkillFile(skill.id, relativePath: "SKILL.md") == nil)
        #expect(store.lifecycleReceipt(for: skill.id) == nil)
        #expect(!store.isInjectable(skill))
        #expect(!store.setEnabled(skill.id, enabled: false))
        do {
            _ = try store.importSkill(content: "---\nname: Pending\n---\nNo publication.")
            Issue.record("Initial load must remain pending")
        } catch { #expect(error as? SkillStoreInitialLoadError == .pending) }
        let pending = store.captureTurnAuthority()
        #expect(pending.prepareStore() == nil)
        // The synchronous refusal returns before the real initial-read gate is released below.
        #expect(!store.isInitialLoadComplete)
        let frozenPending = store.makeSnapshotStore()
        #expect(!frozenPending.isInitialLoadComplete)
        #expect(frozenPending.allSkills().isEmpty)
        let registered = SyntheticBootstrapReadGate()
        // The registration signal must not itself hold the waiter. The original
        // filesystem observer gate still holds the canonical read throughout.
        registered.release()
        let cancelledWait = Task { await store.waitForInitialLoad(waiterRegistered: { registered.pauseOnce() }) }
        await registered.waitForEntry()
        // This signal occurs only after the continuation has been installed
        // and appended to the canonical attempt's waiter list.
        cancelledWait.cancel()
        await cancelledWait.value
        #expect(!store.isInitialLoadComplete)
        let otherWait = Task { await store.waitForInitialLoad() }
        gate.release()
        await store.waitForInitialLoad()
        await otherWait.value
        #expect(store.isInitialLoadComplete)
        #expect(store.rawContent(skill.id) == raw)
        #expect(store.isInjectable(skill))
        #expect(pending.prepareStore() == nil)
        #expect(!store.matchesTurnAuthority(pending))
        #expect(!frozenPending.isInitialLoadComplete)
        #expect(frozenPending.allSkills().isEmpty)
        #expect(store.captureTurnAuthority().prepareStore()?.rawContent(skill.id) == raw)
        #expect(try Data(contentsOf: store.lifecycleReceiptsFileURL) == receiptBefore)
        #expect(try Data(contentsOf: store.skillManifestURL(for: skill.id)) == manifestBefore)
    }

    @Test func failedAttemptReturnsUnreadyThenCorrectedRootCanRetryOnSameStore() async throws {
        let parent = try temporaryParent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("skills", isDirectory: true)
        try Data("directory obstruction".utf8).write(to: root)
        let store = SkillStore.startForAppBootstrap(skillsRoot: root)
        await store.waitForInitialLoad()
        #expect(!store.isInitialLoadComplete)
        #expect(store.skills.isEmpty)
        #expect(store.allSkills().isEmpty)
        let pending = store.captureTurnAuthority()
        #expect(pending.prepareStore() == nil)
        let frozenPending = store.makeSnapshotStore()
        #expect(!frozenPending.isInitialLoadComplete)
        try FileManager.default.removeItem(at: root)
        let seed = SkillStore(skillsRoot: root)
        let raw = "---\nname: Retry Bootstrap\n---\nThe corrected root is reviewed."
        let skill = try seed.importSkill(content: raw)
        await store.waitForInitialLoad()
        #expect(store.isInitialLoadComplete)
        #expect(store.rawContent(skill.id) == raw)
        #expect(store.isInjectable(skill))
        #expect(pending.prepareStore() == nil)
        #expect(!frozenPending.isInitialLoadComplete)
        #expect(frozenPending.rawContent(skill.id) == nil)
        #expect(store.captureTurnAuthority().prepareStore()?.rawContent(skill.id) == raw)
    }
}

@Suite("Clean-room BL6 rollback operation shape")
struct SyntheticBL6RollbackShapeContracts {
    fileprivate nonisolated static func record(input: BL6SettingsApprovedInput, requestID: String, profileID: String,
                                           scope: MemoryScope, key: String, previous: String, effective: String,
                                           beforeValue: Bool) throws -> BL6SettingsReplayRecord {
        let digest = SkillManifest.hash(String(decoding: try JSONEncoder().encode(input), as: UTF8.self))
        let old: [String: BL6SettingValue] = [key: .toggle(beforeValue)]
        let receipt = BL6SettingsReceipt(receiptID: "synthetic-receipt-" + requestID, requestID: requestID,
            operation: input.operation, previousRevision: previous, effectiveRevision: effective, changedKeys: [key], rollbackValues: old)
        return BL6SettingsReplayRecord(requestID: requestID, payloadDigest: digest, frozenInput: input,
            approvalBindingDigest: SkillManifest.hash("synthetic-approval:" + requestID + ":" + digest), profileID: profileID,
            scope: scope.sessionID + ":" + scope.projectID, sessionID: scope.sessionID, policyRevision: "synthetic-policy-1",
            grantEpoch: "synthetic-grant-1", approvalExpiresAt: Date().addingTimeInterval(300), operation: input.operation,
            receipt: receipt, rollbackValues: old)
    }

    @Test func emptyChangesRollbackRestoresTheOriginalChoiceAndReopensWithoutReplayWrites() throws {
        let parent = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("skill-bl6-shape-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("skills", isDirectory: true)
        let store = SkillStore(skillsRoot: root)
        let scope = MemoryScope(sessionID: "synthetic-bl6-session", projectID: "synthetic-bl6-project")
        let raw = "---\nname: Scoped BL6 Control\n---\nOnly the approved selection may change."
        let installed = try store.importSkillThroughLifecycle(content: raw, reason: "Synthetic scoped approval", scope: scope,
            approval: SkillApproval(approverID: "synthetic-user", scope: scope))
        let key = "skills.app:" + installed.skill.id + ".enabled"
        let profileID = "synthetic-bl6-profile"
        let before = try store.bl6SkillEnablementSnapshot(visibleTo: scope)
        try #require(before.values[key] == true)
        let applyID = "apply-" + UUID().uuidString
        let applyInput = BL6SettingsApprovedInput(operation: .apply, changes: [key: .toggle(false)], expectedRevision: before.revision)
        let applied = try store.commitBL6SkillEnablement(skillID: installed.skill.id, enabled: false, visibleTo: scope,
            profileID: profileID, expectedRevision: before.revision) { previous, effective in
                try Self.record(input: applyInput, requestID: applyID, profileID: profileID, scope: scope, key: key,
                    previous: previous, effective: effective, beforeValue: true)
            }
        let reopened = SkillStore(skillsRoot: root)
        #expect(try reopened.bl6SkillEnablementReplayRecord(for: applyID, profileID: profileID) == applied)
        #expect(try reopened.bl6SkillEnablementReplayRecord(receiptID: applied.receipt.receiptID, profileID: profileID) == applied)
        let journalAfterApply = try Data(contentsOf: reopened.lifecycleReceiptsFileURL)
        let shared = root.deletingLastPathComponent().appendingPathComponent("skills-enabled.json")
        let maskAfterApply = try Data(contentsOf: shared)
        #expect(try reopened.replayBL6SkillEnablementRecord(applied, profileID: profileID) == applied.receipt)
        #expect(try Data(contentsOf: reopened.lifecycleReceiptsFileURL) == journalAfterApply)
        #expect(try Data(contentsOf: shared) == maskAfterApply)
        let current = try reopened.bl6SkillEnablementSnapshot(visibleTo: scope)
        try #require(current.values[key] == false)
        let malformed = BL6SettingsApprovedInput(operation: .rollback, changes: [key: .toggle(true)],
            expectedRevision: current.revision, undoReceiptID: applied.receipt.receiptID)
        do {
            _ = try reopened.commitBL6SkillEnablement(skillID: installed.skill.id, enabled: true, visibleTo: scope,
                profileID: profileID, expectedRevision: current.revision, undo: applied) { previous, effective in
                    try Self.record(input: malformed, requestID: "bad-rollback", profileID: profileID, scope: scope, key: key,
                        previous: previous, effective: effective, beforeValue: false)
                }
            Issue.record("Rollback cannot carry apply changes")
        } catch {}
        #expect(try Data(contentsOf: reopened.lifecycleReceiptsFileURL) == journalAfterApply)
        #expect(try Data(contentsOf: shared) == maskAfterApply)
        let rollbackID = "rollback-" + UUID().uuidString
        let rollbackInput = BL6SettingsApprovedInput(operation: .rollback, expectedRevision: current.revision,
            undoReceiptID: applied.receipt.receiptID)
        try rollbackInput.validateForApprovedEffect()
        let rolledBack = try reopened.commitBL6SkillEnablement(skillID: installed.skill.id, enabled: true, visibleTo: scope,
            profileID: profileID, expectedRevision: current.revision, undo: applied) { previous, effective in
                try Self.record(input: rollbackInput, requestID: rollbackID, profileID: profileID, scope: scope, key: key,
                    previous: previous, effective: effective, beforeValue: false)
            }
        #expect(rolledBack.frozenInput.changes.isEmpty)
        #expect(rolledBack.frozenInput.undoReceiptID == applied.receipt.receiptID)
        #expect(try reopened.bl6SkillEnablementSnapshot(visibleTo: scope).values[key] == true)
        #expect(reopened.isInjectable(installed.skill, within: scope))
        let again = SkillStore(skillsRoot: root)
        #expect(try again.bl6SkillEnablementReplayRecord(for: rollbackID, profileID: profileID) == rolledBack)
        let journalAfterRollback = try Data(contentsOf: again.lifecycleReceiptsFileURL)
        let maskAfterRollback = try Data(contentsOf: shared)
        #expect(try again.replayBL6SkillEnablementRecord(rolledBack, profileID: profileID) == rolledBack.receipt)
        #expect(try Data(contentsOf: again.lifecycleReceiptsFileURL) == journalAfterRollback)
        #expect(try Data(contentsOf: shared) == maskAfterRollback)
    }
}

private final class SyntheticCatalogLockProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var attempts: [Bool] = []
    private let firstEvent = SyntheticBootstrapReadGate()
    init() { firstEvent.release() }
    func record(_ acquired: Bool) {
        lock.lock(); attempts.append(acquired); lock.unlock()
        if !acquired { firstEvent.pauseOnce() }
    }
    func returned() { firstEvent.pauseOnce() }
    func waitForContentionOrReturn() async { await firstEvent.waitForEntry() }
    var values: [Bool] { lock.lock(); defer { lock.unlock() }; return attempts }
}

@Suite("Clean-room deadline-bound catalog writer coordination")
struct SyntheticCatalogWriterCoordinationContracts {
    private struct Fixture: Sendable {
        let parent: URL
        let root: URL
        let store: SkillStore
        let skill: Skill
        let raw: String
        let manifest: URL
        let manifestBytes: Data
        let rootIdentity: SkillFilesystemBoundary.RootIdentity
        let directoryIdentity: SkillFilesystemBoundary.EntryIdentity
    }
    private func fixture() throws -> Fixture {
        let parent = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("skill-catalog-writer-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        let root = parent.appendingPathComponent("skills", isDirectory: true)
        let store = SkillStore(skillsRoot: root)
        let raw = "---\nname: Catalog Writer Control\n---\nOnly a complete committed pair may be read."
        let skill = try store.importSkill(content: raw)
        let manifest = store.skillManifestURL(for: skill.id)
        return Fixture(parent: parent, root: root, store: store, skill: skill, raw: raw, manifest: manifest,
            manifestBytes: try Data(contentsOf: manifest), rootIdentity: try #require(SkillFilesystemBoundary.approvedRootIdentity(root)),
            directoryIdentity: try #require(SkillFilesystemBoundary.trustedDirectoryIdentity(store.skillDirectoryURL(for: skill.id), within: root)))
    }
    private func holdWriter(_ fixture: Fixture) throws -> Int32 {
        let path = fixture.store.skillDirectoryURL(for: fixture.skill.id).appendingPathComponent(".skill-import.lock")
        let descriptor = open(path.path, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
        try #require(descriptor >= 0)
        do { try #require(flock(descriptor, LOCK_EX | LOCK_NB) == 0); return descriptor }
        catch { close(descriptor); throw error }
    }

    @Test func aRealShortWriterCompletesBeforeTheReaderReceivesThePair() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.parent) }
        let writer = try holdWriter(fixture)
        defer { _ = flock(writer, LOCK_UN); close(writer) }
        try Data([0xff, 0xfe]).write(to: fixture.manifest, options: [.atomic])
        let probe = SyntheticCatalogLockProbe()
        let reader = Task.detached {
            let value = fixture.store.catalogFileSnapshot(for: fixture.skill.id, expectedRootIdentity: fixture.rootIdentity,
                expectedSkillDirectoryIdentity: fixture.directoryIdentity, waitUntil: ProcessInfo.processInfo.systemUptime + 2,
                lockAttemptObserver: { probe.record($0) })
            probe.returned()
            return value
        }
        await probe.waitForContentionOrReturn()
        let contended = probe.values.contains(false)
        if !contended {
            _ = await reader.value
            Issue.record("The real exclusive writer must cause an observed shared-lock conflict")
            return
        }
        // Actual failed LOCK_SH is the causal point: no fixed delay schedules
        // the writer, and the incomplete manifest cannot be accepted meanwhile.
        try fixture.manifestBytes.write(to: fixture.manifest, options: [.atomic])
        try #require(flock(writer, LOCK_UN) == 0)
        let value = try #require(await reader.value)
        #expect(value.content == fixture.raw)
        #expect(value.manifestData == fixture.manifestBytes)
        #expect(probe.values.filter { $0 }.count == 1)
        #expect(probe.values.contains(false))
    }

    @Test(arguments: [0.25, 20.0]) func aWriterHeldPastTheTwoSecondCeilingCannotPublishItsPartialPair(callerBudget: TimeInterval) throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.parent) }
        let writer = try holdWriter(fixture)
        defer { _ = flock(writer, LOCK_UN); close(writer) }
        let partial = Data([0xff, 0xfe])
        try partial.write(to: fixture.manifest, options: [.atomic])
        let probe = SyntheticCatalogLockProbe()
        let started = ProcessInfo.processInfo.systemUptime
        let callerDeadline = started + callerBudget
        let effectiveDeadline = min(callerDeadline, started + 2)
        let value = fixture.store.catalogFileSnapshot(for: fixture.skill.id, expectedRootIdentity: fixture.rootIdentity,
            expectedSkillDirectoryIdentity: fixture.directoryIdentity, waitUntil: callerDeadline, lockAttemptObserver: { probe.record($0) })
        let elapsed = ProcessInfo.processInfo.systemUptime - started
        #expect(value == nil)
        #expect(!probe.values.isEmpty)
        #expect(probe.values.allSatisfy { !$0 })
        var resolution = timespec()
        try #require(clock_getres(CLOCK_MONOTONIC, &resolution) == 0)
        let quantum = Double(resolution.tv_sec) + Double(resolution.tv_nsec) / 1_000_000_000
        try #require(quantum > 0)
        #expect(probe.values.count <= Int(ceil(log2(max(1, 2 / quantum)))) + 1)
        #expect(elapsed >= min(callerBudget, 2) / 2)
        // After the real 0.49/0.45ms overrun, 0501 permits <=10ms observation
        // margin for syscall cleanup and scheduler return; lock admission still
        // clamps strictly to min(callerDeadline, entry uptime + 2).
        #expect(started + elapsed <= effectiveDeadline + 0.010)
        #expect(try Data(contentsOf: fixture.manifest) == partial)
        #expect(try Data(contentsOf: fixture.store.skillDirectoryURL(for: fixture.skill.id).appendingPathComponent("SKILL.md")) == Data(fixture.raw.utf8))
    }

    @Test func initialScanCannotPublishAWriterPairAndExplicitRetryLoadsItsCommit() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.parent) }
        let writer = try holdWriter(fixture)
        defer { _ = flock(writer, LOCK_UN); close(writer) }
        let receiptBytes = try Data(contentsOf: fixture.store.lifecycleReceiptsFileURL)
        let partial = Data([0xff, 0xfe])
        try partial.write(to: fixture.manifest, options: [.atomic])
        let loading = SkillStore.startForAppBootstrap(skillsRoot: fixture.root)
        await loading.waitForInitialLoad()
        #expect(!loading.isInitialLoadComplete)
        #expect(loading.allSkills().isEmpty)
        #expect(loading.lifecycleReceipt(for: fixture.skill.id) == nil)
        #expect(loading.captureTurnAuthority().prepareStore() == nil)
        #expect(!loading.setEnabled(fixture.skill.id, enabled: false))
        #expect(try Data(contentsOf: fixture.manifest) == partial)
        #expect(try Data(contentsOf: fixture.store.lifecycleReceiptsFileURL) == receiptBytes)
        try fixture.manifestBytes.write(to: fixture.manifest, options: [.atomic])
        try #require(flock(writer, LOCK_UN) == 0)
        await loading.waitForInitialLoad()
        #expect(loading.isInitialLoadComplete)
        #expect(loading.rawContent(fixture.skill.id) == fixture.raw)
        #expect(loading.lifecycleReceipt(for: fixture.skill.id) == fixture.store.lifecycleReceipt(for: fixture.skill.id))
        #expect(loading.isInjectable(fixture.skill))
        #expect(try Data(contentsOf: fixture.store.lifecycleReceiptsFileURL) == receiptBytes)
    }

    @Test func anUncontendedReaderAcquiresTheExistingSharedLockOnce() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.parent) }
        let probe = SyntheticCatalogLockProbe()
        let value = fixture.store.catalogFileSnapshot(for: fixture.skill.id, expectedRootIdentity: fixture.rootIdentity,
            expectedSkillDirectoryIdentity: fixture.directoryIdentity, waitUntil: ProcessInfo.processInfo.systemUptime + 2,
            lockAttemptObserver: { probe.record($0) })
        #expect(value?.content == fixture.raw)
        #expect(value?.manifestData == fixture.manifestBytes)
        #expect(probe.values == [true])
    }
}

private final class SyntheticLedgerWriteObstruction: @unchecked Sendable {
    let root: URL
    let directory: URL
    let backup: URL
    private let lock = NSLock()
    private var armed = false
    private var didTrigger = false
    private var didFail = false
    init(root: URL, directory: URL) {
        self.root = root; self.directory = directory
        backup = root.appendingPathComponent(".synthetic-original-ledger")
    }
    func arm() { lock.lock(); armed = true; lock.unlock() }
    func observe(_ event: SkillStoreFilesystemAccess) {
        guard case .fileRead = event else { return }
        lock.lock(); defer { lock.unlock() }
        guard armed, !didTrigger else { return }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        guard names.contains(where: { $0.hasPrefix(".SKILL.md.") && $0.hasSuffix(".tmp") }),
              names.contains(where: { $0.hasPrefix(".manifest.json.") && $0.hasSuffix(".tmp") }) else { return }
        didTrigger = true
        let ledger = root.appendingPathComponent("lifecycle-receipts.json")
        do {
            try FileManager.default.moveItem(at: ledger, to: backup)
            try FileManager.default.createDirectory(at: ledger, withIntermediateDirectories: false)
        } catch { didFail = true }
    }
    var triggered: Bool { lock.lock(); defer { lock.unlock() }; return didTrigger }
    var failed: Bool { lock.lock(); defer { lock.unlock() }; return didFail }
}

@Suite("Clean-room explicit root public value")
struct SyntheticExplicitSkillRootContracts {
    @Test func explicitRootValueIsRetainedByLiveBootstrapAndFrozenViews() async throws {
        let parent = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("skill-explicit-root-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: parent) }
        let supplied = parent.appendingPathComponent("skills", isDirectory: true)
        let live = SkillStore(skillsRoot: supplied)
        #expect(live.skillsRoot == supplied)
        let raw = "---\nname: Explicit Root Control\n---\nKeep the root identity."
        let skill = try live.importSkill(content: raw)
        let identity = try #require(SkillFilesystemBoundary.approvedRootIdentity(supplied))
        #expect(SkillFilesystemBoundary.isApprovedRoot(live.skillsRoot, matching: identity))
        let bootstrap = SkillStore.startForAppBootstrap(skillsRoot: supplied)
        #expect(bootstrap.skillsRoot == supplied)
        await bootstrap.waitForInitialLoad()
        #expect(bootstrap.isInitialLoadComplete)
        #expect(bootstrap.isInjectable(skill))
        let frozen = bootstrap.makeSnapshotStore()
        #expect(frozen.skillsRoot == supplied)
        #expect(frozen.snapshot().skillsRoot == supplied)
        #expect(frozen.rawContent(skill.id) == raw)
        #expect(SkillFilesystemBoundary.isApprovedRoot(bootstrap.skillsRoot, matching: identity))
    }
}

private final class SyntheticPreparationReadProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var reads = 0
    private var mainReads = 0
    private var pauseAt: Int?
    private let gate = SyntheticBootstrapReadGate()
    func reset(pausingAt event: Int? = nil) {
        lock.lock(); reads = 0; mainReads = 0; pauseAt = event; lock.unlock()
    }
    func observe(_ event: SkillStoreFilesystemAccess) {
        guard case .fileRead = event else { return }
        lock.lock()
        reads += 1
        if Thread.isMainThread { mainReads += 1 }
        let pause = pauseAt == reads
        lock.unlock()
        if pause { gate.pauseOnce() }
    }
    func waitForPayload() async { await gate.waitForEntry() }
    func release() { gate.release() }
    var counts: (total: Int, main: Int) { lock.lock(); defer { lock.unlock() }; return (reads, mainReads) }
}

@Suite("Clean-room preparation payload and authority progress")
struct SyntheticPreparationProgressContracts {
    private struct Fixture: Sendable {
        let parent: URL
        let store: SkillStore
        let skill: Skill
        let raw: String
        let probe: SyntheticPreparationReadProbe
    }
    private func fixture() throws -> Fixture {
        let parent = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("skill-prepare-progress-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        let probe = SyntheticPreparationReadProbe()
        let store = SkillStore(skillsRoot: parent.appendingPathComponent("skills", isDirectory: true), filesystemAccessObserver: { probe.observe($0) })
        let raw = "---\nname: Preparation Progress\n---\nKeep both supporting references."
        let skill = try store.importSkill(content: raw)
        let directory = store.skillDirectoryURL(for: skill.id)
        try Data("First reference".utf8).write(to: directory.appendingPathComponent("first.md"))
        try Data("Second reference".utf8).write(to: directory.appendingPathComponent("second.md"))
        probe.reset()
        return Fixture(parent: parent, store: store, skill: skill, raw: raw, probe: probe)
    }

    @Test func onePreparationReadsThreePayloadsAndTwoSharedAttemptsOffMain() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.parent) }
        let capture = fixture.store.captureTurnAuthority()
        #expect(fixture.probe.counts.total == 0)
        let result = try await runBlockingTestWork { capture.prepareStore() }
        let frozen = try #require(result)
        #expect(fixture.probe.counts.total == 5)
        #expect(fixture.probe.counts.main == 0)
        #expect(frozen.rawContent(fixture.skill.id) == fixture.raw)
        #expect(frozen.readSkillFile(fixture.skill.id, relativePath: "first.md") == "First reference")
        #expect(frozen.readSkillFile(fixture.skill.id, relativePath: "second.md") == "Second reference")
        #expect(fixture.probe.counts.total == 5)
    }

    @Test func cancelingBlockedPayloadDoesNotChangeCanonicalCurrentness() async throws {
        let fixture = try fixture()
        defer { fixture.probe.release(); try? FileManager.default.removeItem(at: fixture.parent) }
        fixture.probe.reset(pausingAt: 2)
        let capture = fixture.store.captureTurnAuthority()
        let worker = Task.detached { capture.prepareStore() }
        await fixture.probe.waitForPayload()
        worker.cancel()
        fixture.probe.release()
        #expect(await worker.value == nil)
        #expect(fixture.store.matchesTurnAuthority(capture))
    }

    @Test func synchronousABACompletesWhilePayloadIsBlockedAndDoesNotReviveCapture() async throws {
        let fixture = try fixture()
        defer { fixture.probe.release(); try? FileManager.default.removeItem(at: fixture.parent) }
        fixture.probe.reset(pausingAt: 2)
        let capture = fixture.store.captureTurnAuthority()
        let worker = Task { try await runBlockingTestWork { capture.prepareStore() } }
        await fixture.probe.waitForPayload()
        // This release is deliberately after both synchronous operations. The
        // read observer holds no canonical instance mutex or Fence admission.
        #expect(fixture.store.setEnabled(fixture.skill.id, enabled: false))
        #expect(fixture.store.setEnabled(fixture.skill.id, enabled: true))
        #expect(!fixture.store.matchesTurnAuthority(capture))
        let fresh = fixture.store.captureTurnAuthority()
        #expect(fixture.store.matchesTurnAuthority(fresh))
        fixture.probe.release()
        let frozen = try #require(try await worker.value)
        #expect(frozen.rawContent(fixture.skill.id) == fixture.raw)
        #expect(frozen.allSkills().first?.isEnabled == true)
        #expect(!fixture.store.matchesTurnAuthority(capture))
        #expect(fixture.store.matchesTurnAuthority(fresh))
    }
}

private actor SyntheticTwoImportStart {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func join() async {
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
            if waiters.count == 2 {
                let pair = waiters; waiters.removeAll()
                for waiter in pair { waiter.resume() }
            }
        }
    }
}

@Suite("Clean-room import target concurrency boundaries")
struct SyntheticImportConcurrencyContracts {
    private func parent() throws -> URL {
        let result = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("skill-import-concurrency-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: result, withIntermediateDirectories: false)
        return result
    }
    @Test func lockOnlyTargetRemainsReadyButImportRejectsTheRealWriter() throws {
        let parent = try parent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("skills", isDirectory: true)
        let directory = root.appendingPathComponent("lock-only", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let lock = directory.appendingPathComponent(".skill-import.lock")
        let descriptor = open(lock.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        try #require(descriptor >= 0)
        defer { _ = flock(descriptor, LOCK_UN); close(descriptor) }
        try #require(flock(descriptor, LOCK_EX | LOCK_NB) == 0)
        let store = SkillStore(skillsRoot: root)
        #expect(store.isInitialLoadComplete)
        do {
            _ = try store.importSkill(content: "---\nname: Lock Only\n---\nDo not take over the writer.")
            Issue.record("The target writer must retain exclusive coordination")
        } catch { #expect(error is SkillError) }
        #expect(FileManager.default.fileExists(atPath: directory.path))
        #expect(FileManager.default.fileExists(atPath: lock.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == [".skill-import.lock"])
    }

    @Test func twoDifferentTargetsBothReturnSuccessWithTheirOwnCommittedPairs() async throws {
        let parent = try parent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("skills", isDirectory: true)
        let first = SkillStore(skillsRoot: root)
        let second = SkillStore(skillsRoot: root)
        let start = SyntheticTwoImportStart()
        let firstRaw = "---\nname: Separate Lantern\n---\nFirst distinct content."
        let secondRaw = "---\nname: Separate River\n---\nSecond distinct content."
        let firstTask = Task.detached { await start.join(); return try first.importSkill(content: firstRaw) }
        let secondTask = Task.detached { await start.join(); return try second.importSkill(content: secondRaw) }
        let firstSkill = try await firstTask.value
        let secondSkill = try await secondTask.value
        let reopened = SkillStore(skillsRoot: root)
        for (skill, raw) in [(firstSkill, firstRaw), (secondSkill, secondRaw)] {
            #expect(reopened.rawContent(skill.id) == raw)
            #expect(reopened.integrity(for: skill.id)?.manifest?.contentHash == SkillManifest.hash(raw))
            #expect(reopened.lifecycleReceipt(for: skill.id)?.contentHash == SkillManifest.hash(raw))
            let names = try FileManager.default.contentsOfDirectory(atPath: reopened.skillDirectoryURL(for: skill.id).path)
            #expect(!names.contains { $0 == ".skill-import-pending.json" || $0.hasSuffix(".tmp") })
        }
    }
}

private enum SyntheticEnablementBoundaryFailure: Error, Equatable { case requested }

@Suite("Clean-room durable approval and auxiliary boundaries")
struct SyntheticDurableSkillContracts {
    private func parent() throws -> URL {
        let value = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("skill-durable-boundary-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: value, withIntermediateDirectories: false)
        return value
    }

    @Test(arguments: ["approver", "trust", "id", "hash", "source", "legacy"])
    func reopeningBindsTheOriginalApprovalAndSource(field: String) throws {
        let parent = try parent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("skills", isDirectory: true)
        let store = SkillStore(skillsRoot: root)
        let raw = "---\nname: Durable Approval\n---\nKeep the original approval and source."
        let installed = try store.importSkillThroughLifecycle(content: raw, source: .bundled, reason: "Synthetic approval binding",
            approval: SkillApproval(approverID: "synthetic-user"))
        let manifestBytes = try Data(contentsOf: store.skillManifestURL(for: installed.skill.id))
        var ledger = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: store.lifecycleReceiptsFileURL)) as? [String: Any])
        var receipts = try #require(ledger["receipts"] as? [String: Any])
        var receipt = try #require(receipts[installed.skill.id] as? [String: Any])
        switch field {
        case "approver": receipt.removeValue(forKey: "approvedBy")
        case "trust": receipt["trust"] = "bundled"
        case "id": receipt["skillID"] = "foreign-skill"
        case "hash": receipt["contentHash"] = SkillManifest.hash("foreign content")
        case "source": receipt["sourceIdentity"] = "foreign-source"
        default: receipt.removeValue(forKey: "sourceIdentity")
        }
        receipts[installed.skill.id] = receipt; ledger["receipts"] = receipts
        try JSONSerialization.data(withJSONObject: ledger, options: [.sortedKeys]).write(to: store.lifecycleReceiptsFileURL, options: [.atomic])
        let reopened = SkillStore(skillsRoot: root)
        let skill = try #require(reopened.allSkills().first)
        #expect(reopened.rawContent(skill.id) == raw)
        #expect(try Data(contentsOf: reopened.skillManifestURL(for: skill.id)) == manifestBytes)
        #expect(skill.integrity.state == .verified)
        if field == "legacy" {
            #expect(reopened.lifecycleReceipt(for: skill.id)?.state == .active)
            #expect(skill.isEnabled)
            #expect(reopened.isInjectable(skill))
        } else {
            #expect(reopened.lifecycleReceipt(for: skill.id)?.state == .quarantined)
            #expect(!skill.isEnabled)
            #expect(!reopened.isInjectable(skill))
        }
    }

    @Test func aQuarantinedCurrentVersionCannotUseAnApprovedBackupToRollback() throws {
        let parent = try parent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let store = SkillStore(skillsRoot: parent.appendingPathComponent("skills", isDirectory: true))
        _ = try store.importSkill(content: "---\nname: Quarantine Rollback\nversion: 1\n---\nApproved old version.")
        let current = "---\nname: Quarantine Rollback\nversion: 2\n---\nUnapproved current version."
        let result = try store.importSkillThroughLifecycle(content: current, source: .url("https://example.invalid/current"), reason: "Unapproved proposal")
        #expect(result.receipt.state == .quarantined)
        #expect(!store.canRollbackSkill(result.skill.id))
        do {
            _ = try store.rollbackSkill(result.skill.id, reason: "Must not cross quarantine")
            Issue.record("Quarantined current versions must reject rollback")
        } catch { #expect(error is SkillError) }
        #expect(store.rawContent(result.skill.id) == current)
        #expect(store.lifecycleReceipt(for: result.skill.id)?.state == .quarantined)
        #expect(store.allSkills().first?.isEnabled == false)
    }

    @Test(arguments: [false, true]) func frozenAuxiliaryContentKeepsItsCaptureWhenTheMainIsUnavailableOrChanged(missing: Bool) throws {
        let parent = try parent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let counter = SyntheticSkillAccessCounter()
        let store = SkillStore(skillsRoot: parent.appendingPathComponent("skills", isDirectory: true), filesystemAccessObserver: { counter.record($0) })
        let raw = "---\nname: Auxiliary Capture\n---\nOriginal approved body."
        let skill = try store.importSkill(content: raw)
        let directory = store.skillDirectoryURL(for: skill.id)
        for (path, text) in [("guide.md", "Original reference"), ("example.md", "Old example"), ("script.txt", "Old script")] {
            try Data(text.utf8).write(to: directory.appendingPathComponent(path))
        }
        let old = store.snapshotForTurn()
        let current = "---\nname: Auxiliary Capture\n---\nExternally changed body."
        if missing { try FileManager.default.removeItem(at: directory.appendingPathComponent("SKILL.md")) }
        else { try Data(current.utf8).write(to: directory.appendingPathComponent("SKILL.md"), options: [.atomic]) }
        try Data("Updated reference".utf8).write(to: directory.appendingPathComponent("guide.md"), options: [.atomic])
        try FileManager.default.removeItem(at: directory.appendingPathComponent("example.md"))
        try Data("New file".utf8).write(to: directory.appendingPathComponent("new.md"))
        try FileManager.default.moveItem(at: directory.appendingPathComponent("script.txt"), to: directory.appendingPathComponent("renamed.txt"))
        #expect(store.listSkillFiles(skill.id).contains("SKILL.md"))
        let fresh = store.snapshotForTurn()
        counter.reset()
        #expect(old.rawContent(skill.id) == raw)
        #expect(old.readSkillFile(skill.id, relativePath: "guide.md") == "Original reference")
        #expect(old.readSkillFile(skill.id, relativePath: "example.md") == "Old example")
        #expect(old.readSkillFile(skill.id, relativePath: "script.txt") == "Old script")
        #expect(old.readSkillFile(skill.id, relativePath: "new.md") == nil)
        #expect(old.readSkillFile(skill.id, relativePath: "renamed.txt") == nil)
        #expect(fresh.rawContent(skill.id) == (missing ? nil : current))
        #expect(fresh.readSkillFile(skill.id, relativePath: "guide.md") == "Updated reference")
        #expect(fresh.readSkillFile(skill.id, relativePath: "example.md") == nil)
        #expect(fresh.readSkillFile(skill.id, relativePath: "script.txt") == nil)
        #expect(fresh.readSkillFile(skill.id, relativePath: "new.md") == "New file")
        #expect(fresh.readSkillFile(skill.id, relativePath: "renamed.txt") == "Old script")
        #expect(Set(fresh.listSkillFiles(skill.id)) == ["SKILL.md", "guide.md", "new.md", "renamed.txt"])
        #expect(fresh.allSkills().allSatisfy { !fresh.isInjectable($0) })
        #expect(counter.count == 0)
    }

    @Test(arguments: [false, true]) func unscopedApprovalReachesTheOriginalEnablementFaultAndRecovers(afterShared: Bool) throws {
        let parent = try parent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("skills", isDirectory: true)
        let store = SkillStore(skillsRoot: root)
        let installed = try store.importSkillThroughLifecycle(content: "---\nname: Unscoped Fault\n---\nA valid unrestricted approval.", source: .bundled,
            reason: "Synthetic unrestricted approval", approval: SkillApproval(approverID: "synthetic-user"))
        let scope = MemoryScope(sessionID: "fault-session", projectID: "fault-project")
        let key = "skills.app:" + installed.skill.id + ".enabled"
        let before = try store.bl6SkillEnablementSnapshot(visibleTo: scope)
        try #require(before.values[key] == true)
        let requestID = "synthetic-fault-" + UUID().uuidString
        let profileID = "synthetic-fault-profile"
        let input = BL6SettingsApprovedInput(operation: .apply, changes: [key: .toggle(false)], expectedRevision: before.revision)
        store.bl6EnablementFaultInjector = { point in
            switch point {
            case .afterIntentPersisted: if !afterShared { throw SyntheticEnablementBoundaryFailure.requested }
            case .afterSharedStatePersisted: if afterShared { throw SyntheticEnablementBoundaryFailure.requested }
            }
        }
        do {
            _ = try store.commitBL6SkillEnablement(skillID: installed.skill.id, enabled: false, visibleTo: scope, profileID: profileID,
                expectedRevision: before.revision) { previous, effective in
                    try SyntheticBL6RollbackShapeContracts.record(input: input, requestID: requestID, profileID: profileID, scope: scope,
                        key: key, previous: previous, effective: effective, beforeValue: true)
                }
            Issue.record("The requested real persistence boundary must throw")
        } catch { #expect(error as? SyntheticEnablementBoundaryFailure == .requested) }
        let failed = store.snapshot()
        #expect(failed.skills.first?.isEnabled == false)
        #expect(failed.disabledSkillIDs.contains(installed.skill.id))
        #expect(!store.isInjectable(installed.skill, within: scope))
        let reopened = SkillStore(skillsRoot: root)
        #expect(try reopened.bl6SkillEnablementSnapshot(visibleTo: scope).values[key] == !afterShared)
        let terminal = try reopened.bl6SkillEnablementReplayRecord(for: requestID, profileID: profileID)
        if afterShared {
            let terminal = try #require(terminal)
            #expect(try reopened.replayBL6SkillEnablementRecord(terminal, profileID: profileID) == terminal.receipt)
            #expect(!reopened.isInjectable(installed.skill, within: scope))
        } else { #expect(terminal == nil) }
    }
}

@Suite("Clean-room good and damaged sibling snapshot")
struct SyntheticMixedSkillSnapshotContracts {
    @Test(arguments: [false, true]) func aDamagedKnownSiblingCannotEraseTheValidEntry(malformedManifest: Bool) throws {
        let parent = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("skill-mixed-snapshot-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: parent) }
        let store = SkillStore(skillsRoot: parent.appendingPathComponent("skills", isDirectory: true))
        let goodRaw = "---\nname: Valid Mixed Control\n---\nOnly the approved valid sibling is injectable."
        let badRaw = "---\nname: Damaged Mixed Control\n---\nInitially approved sibling."
        let good = try store.importSkill(content: goodRaw)
        let bad = try store.importSkill(content: badRaw)
        if malformedManifest {
            try Data("malformed manifest".utf8).write(to: store.skillManifestURL(for: bad.id), options: [.atomic])
        } else {
            try Data((badRaw + " External change.").utf8).write(to: store.skillDirectoryURL(for: bad.id).appendingPathComponent("SKILL.md"), options: [.atomic])
        }
        let captured = store.snapshot()
        let frozen = SkillStore.makeSnapshotStore(from: captured)
        #expect(Set(captured.skills.map(\.id)) == [good.id, bad.id])
        #expect(frozen.rawContent(good.id) == goodRaw)
        let registry = SkillRegistry(store: frozen)
        #expect(registry.entry(for: good.id) != nil)
        #expect(frozen.isInjectable(good))
        let rejected = try #require(frozen.allSkills().first { $0.id == bad.id })
        #expect(!frozen.isInjectable(rejected))
        if let managementEntry = registry.entry(for: bad.id) { #expect(!managementEntry.enabled) }
        #expect(registry.rejection(for: rejected, content: frozen.rawContent(bad.id)) != nil)
    }
}

@Suite("Clean-room committed Fence captured skill view")
struct SyntheticCommittedSkillBeforeViewContracts {
    @Test(arguments: [false, true]) func oldAndNewReadersUseCapturedValuesWhileAllOldWritersRemainRejected(hasCapturedSkills: Bool) throws {
        // Synthetic skill-only transaction state, not a SyncAtomicImport proof.
        // This unique domain is never reset or reused by another test case.
        let parent = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("skill-before-view-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("skills", isDirectory: true)
        let counter = SyntheticSkillAccessCounter()
        let store = SkillStore(skillsRoot: root, filesystemAccessObserver: { counter.record($0) })
        let oldRaw = "---\nname: Committed View Control\n---\nCaptured approved content."
        let skill = try store.importSkill(content: oldRaw)
        let directory = store.skillDirectoryURL(for: skill.id)
        let guide = directory.appendingPathComponent("guide.md")
        try Data("Captured guide".utf8).write(to: guide)
        let before = store.snapshot()
        let beforePending = store.captureTurnAuthority()
        let previouslyFrozen = store.makeSnapshotStore()
        let domain = store.persistenceDomain
        let view = PersistenceTransactionFence.BeforeView(files: [:], settings: nil, skills: hasCapturedSkills ? before : nil)
        let admission = try PersistenceTransactionFence.exclusive([domain], deadline: Date().addingTimeInterval(2))
        var finished = false
        defer {
            // On an unexpected fixture write failure, finish in recovery rather
            // than falsely claiming a verified rollback or abandoning admission.
            if !finished { admission.finish(committed: false, recoveryRequired: true, before: view) }
        }
        admission.captureBefore(view)
        let newRaw = "---\nname: Committed View Control\n---\nInstalled new generation content."
        let newManifest = SkillSourceManifest(skillID: skill.id, source: .file, skillVersion: "1.0.0", content: newRaw)
        let proposal = SkillLifecycle.propose(SkillManifest(skillID: skill.id, name: skill.name, content: newRaw, trust: .local), reason: "Synthetic complete after-view")
        let approval = try #require(SkillLifecycle.approve(proposal, approval: SkillApproval(approverID: "synthetic-after-user"), reason: "Synthetic approval"))
        let active = try #require(SkillLifecycle.activate(approval, currentContentHash: SkillManifest.hash(newRaw), reason: "Synthetic activation"))
        var ledger = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: store.lifecycleReceiptsFileURL)) as? [String: Any])
        var receipts = try #require(ledger["receipts"] as? [String: Any])
        receipts[skill.id] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(active))
        ledger["receipts"] = receipts
        ledger["disabledSkillIDs"] = [skill.id]
        let installed: [(URL, Data)] = [
            (directory.appendingPathComponent("SKILL.md"), Data(newRaw.utf8)),
            (store.skillManifestURL(for: skill.id), try JSONEncoder().encode(newManifest)),
            (store.lifecycleReceiptsFileURL, try JSONSerialization.data(withJSONObject: ledger, options: [.sortedKeys])),
            (guide, Data("Installed new guide".utf8))
        ]
        for (file, bytes) in installed { try bytes.write(to: file, options: [.atomic]) }
        for (file, bytes) in installed { try #require(Data(contentsOf: file) == bytes) }
        admission.finish(committed: true, recoveryRequired: false, before: view)
        finished = true
        #expect(PersistenceTransactionFence.requiresReopen(domain))
        let newlyConstructed = SkillStore(skillsRoot: root, filesystemAccessObserver: { counter.record($0) })
        counter.reset()
        for reader in [store, newlyConstructed] {
            #expect(reader.skillsRoot == root)
            if hasCapturedSkills {
                #expect(reader.allSkills() == before.skills)
                #expect(reader.rawContent(skill.id) == oldRaw)
                #expect(reader.lifecycleReceipt(for: skill.id) == before.lifecycleReceipts[skill.id])
                #expect(reader.snapshot() == before)
                #expect(reader.readSkillFile(skill.id, relativePath: "guide.md") == "Captured guide")
                #expect(Set(reader.listSkillFiles(skill.id)) == ["SKILL.md", "guide.md"])
                let readonly = reader.snapshotForTurn()
                #expect(readonly.snapshot() == before)
                #expect(readonly.rawContent(skill.id) == oldRaw)
                #expect(readonly.readSkillFile(skill.id, relativePath: "guide.md") == "Captured guide")
            } else {
                #expect(reader.rawContent(skill.id) == nil)
                #expect(reader.allSkills().isEmpty)
                #expect(reader.lifecycleReceipt(for: skill.id) == nil)
                #expect(reader.readSkillFile(skill.id, relativePath: "guide.md") == nil)
                #expect(reader.snapshotForTurn().rawContent(skill.id) == nil)
            }
            #expect(!reader.setEnabled(skill.id, enabled: true))
        }
        #expect(previouslyFrozen.rawContent(skill.id) == oldRaw)
        #expect(previouslyFrozen.readSkillFile(skill.id, relativePath: "guide.md") == "Captured guide")
        #expect(!store.matchesTurnAuthority(beforePending))
        #expect(beforePending.prepareStore() == nil)
        do {
            _ = try store.importSkill(content: oldRaw)
            Issue.record("The old writer must remain rejected by the original transaction error")
        } catch let error as PersistenceTransactionError {
            if case .reopenRequired = error {} else { Issue.record("Expected reopenRequired") }
        }
        #expect(counter.count == 0)
        for (file, bytes) in installed { #expect(try Data(contentsOf: file) == bytes) }
    }
}
