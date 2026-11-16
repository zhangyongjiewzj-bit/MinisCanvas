import Foundation
import Testing
import Darwin
@testable import MinisCore

@Suite("D-RECOVERY-03 settings attachment", .serialized)
struct Recovery03SettingsAttachment2263Tests {
    private enum Injected: Error { case interruption }
    private struct RecoveryRequest: Codable {
        let layout: SyncAtomicImport.Layout
        let root: URL
        let suite: String
        let parentPID: Int32
        let nonce: String
        let expectedComponents: [String]
        let proof: URL
    }
    private struct RecoveryProof: Codable {
        let nonce: String
        let childPID: Int32
        let parentPID: Int32
        let components: [String]
        let restoredBeforeStores: Bool
    }
    private struct Fixture {
        let root: URL
        let suite: String
        let defaults: UserDefaults
        let keys: KeychainStore
        let env: EnvVarStore
        let manager: SyncManager

        init(_ label: String) throws {
            let formal = try #require(ProcessInfo.processInfo.environment["MINISCANVAS_TEST_DIRECTORY"])
            let rawRoot = URL(fileURLWithPath: formal, isDirectory: true)
                .appendingPathComponent("Recovery03-\(label)-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: rawRoot, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            root = try canonicalOwnedFixtureURL2263(rawRoot)
            suite = "recovery03.\(UUID().uuidString)"
            defaults = try #require(UserDefaults(suiteName: suite))
            let core = root.appendingPathComponent("core", isDirectory: true)
            let chat = root.appendingPathComponent("chat", isDirectory: true)
            let provider = core.appendingPathComponent("providers", isDirectory: true)
            keys = KeychainStore(backing: InMemoryKeychainBacking())
            env = EnvVarStore(directory: provider, keychain: keys)
            manager = SyncManager(
                sessionStore: SessionStore(directory: chat),
                memoryStore: MemoryStore(directory: chat),
                skillStore: SkillStore(skillsRoot: core.appendingPathComponent("skills", isDirectory: true)),
                settingsStore: SettingsStore(directory: core),
                providerConfigurationDirectory: provider,
                shortcutRecoveryTarget: ShortcutRecoveryTarget(defaults: defaults, suiteName: suite)
            )
        }

        func close() {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }

        var shortcut: Data? { defaults.data(forKey: SettingsRecoveryAttachment.shortcutDefaultsKey) }
        func setShortcut(_ value: Data) { defaults.set(value, forKey: SettingsRecoveryAttachment.shortcutDefaultsKey) }
        func saveProvider(_ name: String, model: String) -> Bool {
            env.saveProvider(name: name, credential: .replace("synthetic credential"),
                             baseURL: "https://example.invalid/v1", modelNames: [model],
                             protocolType: .openaiCompatible)
        }
    }

    @Test func strictDecoderAndPureProjection() throws {
        let source = try Fixture("strict"); defer { source.close() }
        #expect(source.env.setEnvVar(name: "ORDINARY03", value: "ordinary", isSecret: false))
        #expect(source.saveProvider("PROVIDER03", model: "source-model"))
        let attachment = try SettingsRecoveryAttachment(
            providers: source.env.providerRecoveryMetadata(), shortcutOverrides: [])
        let bytes = try JSONEncoder().encode(attachment)
        let text = try #require(String(data: bytes, encoding: .utf8))
        #expect(attachment.providers.count == 1)
        #expect(!text.contains("synthetic credential"))
        #expect(!text.contains("ORDINARY03"))
        #expect(!text.contains("valueInKeychain"))
        #expect(try JSONDecoder().decode(SettingsRecoveryAttachment.self, from: bytes) == attachment)

        let original = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        func rejected(_ transform: (inout [String: Any]) -> Void) throws {
            var altered = original
            transform(&altered)
            let data = try JSONSerialization.data(withJSONObject: altered)
            #expect(throws: (any Error).self) {
                try JSONDecoder().decode(SettingsRecoveryAttachment.self, from: data)
            }
        }
        try rejected { $0["version"] = 2 }
        try rejected { $0["unexpected"] = "extra" }
        try rejected { object in
            var providers = object["providers"] as! [[String: Any]]
            var duplicateID = providers[0]
            duplicateID["name"] = "DIFFERENT03"
            providers.append(duplicateID); object["providers"] = providers
        }
        try rejected { object in
            var providers = object["providers"] as! [[String: Any]]
            var duplicateName = providers[0]
            duplicateName["id"] = UUID().uuidString
            providers.append(duplicateName); object["providers"] = providers
        }
        try rejected { object in
            var providers = object["providers"] as! [[String: Any]]
            providers[0]["baseURL"] = "file:///invalid"; object["providers"] = providers
        }
        try rejected { object in
            var providers = object["providers"] as! [[String: Any]]
            providers[0]["protocolType"] = "unknown"; object["providers"] = providers
        }
        try rejected { object in
            var providers = object["providers"] as! [[String: Any]]
            providers[0]["value"] = "unallowed"; object["providers"] = providers
        }
    }

    @Test func atomicSettingsImportRestoresColdProviderAndShortcutAfterReopen() throws {
        let source = try Fixture("source"); defer { source.close() }
        let target = try Fixture("target"); defer { target.close() }
        #expect(source.saveProvider("PROVIDER03", model: "source-model"))
        #expect(target.saveProvider("PROVIDER03", model: "target-model"))
        #expect(target.env.setEnvVar(name: "ORDINARY03", value: "target ordinary", isSecret: false))
        _ = source.manager.settingsStore.update(\.storage.sessionRetentionDays, to: 83)
        _ = target.manager.settingsStore.update(\.storage.sessionRetentionDays, to: 41)
        let sourceShortcut = Data("synthetic source shortcut".utf8)
        let targetShortcut = Data("synthetic target shortcut".utf8)
        source.setShortcut(sourceShortcut); target.setShortcut(targetShortcut)
        let attachment = try SettingsRecoveryAttachment(
            providers: source.env.providerRecoveryMetadata(), shortcutOverrides: [])
        let snapshot = try source.manager.exportSnapshot(scopes: [.settings], settingsRecovery: attachment)
        let snapshotText = try #require(String(data: snapshot, encoding: .utf8))
        #expect(!snapshotText.contains("synthetic credential"))
        #expect(!snapshotText.contains("synthetic source shortcut"))
        #expect(throws: (any Error).self) {
            try target.manager.importSnapshot(snapshot, restoring: [.settings])
        }
        let before = try Data(contentsOf: target.env.metadataDirectory.appendingPathComponent(EnvVarStore.fileName))
        let plan = ShortcutRecoveryPlan(suiteName: target.suite, beforeData: targetShortcut,
                                        afterData: sourceShortcut)
        let importer = try SyncAtomicImport(manager: target.manager)
        let preview = try importer.preview(snapshot, selecting: [.settings], shortcutPlan: plan)
        #expect(target.shortcut == targetShortcut)
        #expect(try Data(contentsOf: target.env.metadataDirectory.appendingPathComponent(EnvVarStore.fileName)) == before)
        let receipt = try importer.confirm(preview, snapshot: snapshot, confirmation: .init(preview: preview))
        #expect(receipt.committed && receipt.reopenRequired)
        let reopened = EnvVarStore(directory: target.env.metadataDirectory, keychain: target.keys)
        #expect(reopened.providerRecords.map(\.name) == ["PROVIDER03"])
        #expect(reopened.providerRecords[0].value.isEmpty)
        #expect(!reopened.providerRecords[0].valueInKeychain)
        #expect(reopened.credentialBinding(name: "PROVIDER03") == nil)
        #expect(reopened.entry(name: "ORDINARY03")?.value == "target ordinary")
        #expect(target.shortcut == sourceShortcut)
        let settingsBytes = try Data(contentsOf: target.root.appendingPathComponent("core/settings.json"))
        #expect(try JSONDecoder().decode(AppSettings.self, from: settingsBytes).storage.sessionRetentionDays == 83)
    }

    /// C8：备份投影与冷恢复不丢自定义模型窗口；旧快照（无该键）仍可解码为 nil；窗口键必须属于模型列表。
    @Test func modelContextWindowsSurviveBackupAndColdRestore() throws {
        let source = try Fixture("windows-source"); defer { source.close() }
        let target = try Fixture("windows-target"); defer { target.close() }
        #expect(source.env.saveProvider(
            name: "WINDOWS03", credential: .replace("synthetic credential"),
            baseURL: "https://example.invalid/v1", modelNames: ["small-local", "other"],
            protocolType: .openaiCompatible, modelContextWindows: ["small-local": 32_000]))
        let projected = try source.env.providerRecoveryMetadata()
        #expect(projected.first?.modelContextWindows == ["small-local": 32_000])

        let attachment = try SettingsRecoveryAttachment(providers: projected, shortcutOverrides: [])
        let snapshot = try source.manager.exportSnapshot(scopes: [.settings], settingsRecovery: attachment)
        let snapshotText = try #require(String(data: snapshot, encoding: .utf8))
        #expect(!snapshotText.contains("synthetic credential"))
        let plan = ShortcutRecoveryPlan(suiteName: target.suite, beforeData: nil,
                                        afterData: Data("synthetic shortcut".utf8))
        let importer = try SyncAtomicImport(manager: target.manager)
        let preview = try importer.preview(snapshot, selecting: [.settings], shortcutPlan: plan)
        _ = try importer.confirm(preview, snapshot: snapshot, confirmation: .init(preview: preview))
        let reopened = EnvVarStore(directory: target.env.metadataDirectory, keychain: target.keys)
        #expect(reopened.entry(name: "WINDOWS03")?.modelContextWindows == ["small-local": 32_000])
        #expect(reopened.entry(name: "WINDOWS03")?.value.isEmpty == true)

        let legacy = Data("""
        {"id":"\(UUID().uuidString)","name":"LEGACY03","createdAt":0,"baseURL":null,
         "modelNames":["m"],"protocolType":"openai_compatible"}
        """.utf8)
        #expect(try JSONDecoder().decode(ProviderRecoveryMetadata.self, from: legacy).modelContextWindows == nil)
        #expect(throws: (any Error).self) {
            try ProviderRecoveryMetadata(
                id: UUID().uuidString, name: "BAD03", createdAt: Date(timeIntervalSince1970: 0),
                baseURL: "https://example.invalid/v1", modelNames: ["m"], protocolType: .openaiCompatible,
                modelContextWindows: ["not-listed": 1_000])
        }
    }

    @Test func unselectedSettingsLeavesProviderAndShortcutUntouched() throws {
        let source = try Fixture("select-source"); defer { source.close() }
        let target = try Fixture("select-target"); defer { target.close() }
        #expect(source.saveProvider("SOURCE03", model: "source-model"))
        #expect(target.saveProvider("TARGET03", model: "target-model"))
        let beforeShortcut = Data("target synthetic shortcut".utf8)
        target.setShortcut(beforeShortcut)
        _ = try source.manager.sessionStore.createSession(id: "session03", title: "source title")
        _ = try target.manager.sessionStore.createSession(id: "session03", title: "target title")
        let attachment = try SettingsRecoveryAttachment(
            providers: source.env.providerRecoveryMetadata(), shortcutOverrides: [])
        let snapshot = try source.manager.exportSnapshot(scopes: [.settings, .sessions], settingsRecovery: attachment)
        let providerFile = target.env.metadataDirectory.appendingPathComponent(EnvVarStore.fileName)
        let beforeProvider = try Data(contentsOf: providerFile)
        let importer = try SyncAtomicImport(manager: target.manager)
        let preview = try importer.preview(snapshot, selecting: [.sessions])
        let receipt = try importer.confirm(preview, snapshot: snapshot, confirmation: .init(preview: preview))
        #expect(receipt.committed)
        #expect(try Data(contentsOf: providerFile) == beforeProvider)
        #expect(target.shortcut == beforeShortcut)
        #expect(target.env.providerRecords.map(\.name) == ["TARGET03"])
        #expect(throws: (any Error).self) {
            try source.manager.exportSnapshot(scopes: [.sessions], settingsRecovery: attachment)
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["RECOVERY03_CHILD_REQUEST"] != nil))
    func bootstrapRecoveryChild() throws {
        let encoded = try #require(ProcessInfo.processInfo.environment["RECOVERY03_CHILD_REQUEST"])
        let request = try JSONDecoder().decode(RecoveryRequest.self,
                                               from: #require(Data(base64Encoded: encoded)))
        let id = try #require(Test.current?.id)
        try #require(id.nameComponents == request.expectedComponents)
        try #require(getpid() != request.parentPID)
        try #require(request.root.lastPathComponent.hasPrefix("Recovery03-"))
        try SyncAtomicImport.recoverBeforeStores(layout: request.layout)
        let sessions = SessionStore(directory: request.layout.sessionDirectory)
        #expect(sessions.loadSession(id: "session03")?.title == "target title")
        let memory = MemoryStore(directory: request.layout.memoryDirectory)
        #expect(try memory.facts().contains { $0.text == "target memory" })
        let skills = SkillStore(skillsRoot: request.layout.skillsRoot)
        #expect(skills.rawContent("recovery03-skill")?.contains("target skill") == true)
        let settings = SettingsStore(directory: request.layout.settingsDirectory)
        #expect(settings.settings.storage.sessionRetentionDays == 41)
        let provider = try #require(request.layout.providerConfigurationDirectory)
        let env = EnvVarStore(directory: provider,
                              keychain: KeychainStore(backing: InMemoryKeychainBacking()))
        #expect(env.providerRecords.map(\.name) == ["TARGET03"])
        let defaults = try #require(UserDefaults(suiteName: request.suite))
        #expect(defaults.data(forKey: SettingsRecoveryAttachment.shortcutDefaultsKey)
            == Data("target synthetic shortcut".utf8))
        _ = try sessions.createSession(id: "recovery03-child-writer", title: "admitted")
        let proof = RecoveryProof(nonce: request.nonce, childPID: getpid(), parentPID: request.parentPID,
                                  components: id.nameComponents, restoredBeforeStores: true)
        try JSONEncoder().encode(proof).write(to: request.proof)
    }

    @Test(arguments: ["sessions", "memories", "skills", "settings", "shortcut"])
    func faultAtDomainWriteRecoversBeforeNewProcessStores(boundary: String) throws {
        let source = try Fixture("fault-source"); defer { source.close() }
        let target = try Fixture("fault-target"); defer { target.close() }
        let scope = MemoryScope(sessionID: "session03", projectID: "project03")
        _ = try source.manager.sessionStore.createSession(id: "session03", title: "source title")
        _ = try target.manager.sessionStore.createSession(id: "session03", title: "target title")
        _ = try source.manager.memoryStore.addFact("source memory", sourceSessionID: "session03", memoryScope: scope)
        _ = try target.manager.memoryStore.addFact("target memory", sourceSessionID: "session03", memoryScope: scope)
        _ = try source.manager.skillStore.importSkill(content: "---\nname: Recovery03 Skill\ndescription: synthetic\n---\nsource skill")
        _ = try target.manager.skillStore.importSkill(content: "---\nname: Recovery03 Skill\ndescription: synthetic\n---\ntarget skill")
        _ = source.manager.settingsStore.update(\.storage.sessionRetentionDays, to: 83)
        _ = target.manager.settingsStore.update(\.storage.sessionRetentionDays, to: 41)
        #expect(source.saveProvider("SOURCE03", model: "source-model"))
        #expect(target.saveProvider("TARGET03", model: "target-model"))
        source.setShortcut(Data("source synthetic shortcut".utf8))
        let targetShortcut = Data("target synthetic shortcut".utf8)
        target.setShortcut(targetShortcut)
        let attachment = try SettingsRecoveryAttachment(
            providers: source.env.providerRecoveryMetadata(), shortcutOverrides: [])
        let snapshot = try source.manager.exportSnapshot(settingsRecovery: attachment)
        let importer = try SyncAtomicImport(manager: target.manager, fault: { point, path in
            if point == .rollbackFile { throw Injected.interruption }
            if boundary == "shortcut" && point == .beforeCommitMarker { throw Injected.interruption }
            guard point == .afterFile, let path else { return }
            let match = boundary == "sessions" ? path.contains("/sessions/")
                : boundary == "memories" ? path.contains("/memory/")
                : boundary == "skills" ? path.contains("/skills/") || path.hasSuffix("/skills-enabled.json")
                : boundary == "settings" ? path.hasSuffix("/settings.json") : false
            if match { throw Injected.interruption }
        })
        let plan = ShortcutRecoveryPlan(suiteName: target.suite, beforeData: targetShortcut,
                                        afterData: Data("source synthetic shortcut".utf8))
        let preview = try importer.preview(snapshot, memoryScope: scope, shortcutPlan: plan)
        #expect(throws: SyncAtomicImportError.rollbackIncomplete) {
            try importer.confirm(preview, snapshot: snapshot, confirmation: .init(preview: preview))
        }
        let inherited = CommandLine.arguments
        let flag = try #require(inherited.firstIndex(of: "--test-bundle-path"))
        try #require(flag + 1 < inherited.count)
        let payload = inherited[flag + 1]
        try #require(inherited[0].hasSuffix("/usr/libexec/swift/pm/swiftpm-testing-helper"))
        try #require(payload.hasSuffix("/MinisCorePackageTests.xctest/Contents/MacOS/MinisCorePackageTests"))
        let current = try #require(Test.current?.id)
        let expectedComponents = Array(current.nameComponents.dropLast()) + ["bootstrapRecoveryChild()"]
        let childEvidence = target.root.deletingLastPathComponent()
            .appendingPathComponent("recovery03-child-\(boundary)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: childEvidence, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let request = RecoveryRequest(
            layout: importer.layout, root: target.root, suite: target.suite,
            parentPID: getpid(), nonce: UUID().uuidString,
            expectedComponents: expectedComponents,
            proof: childEvidence.appendingPathComponent("proof.json")
        )
        let process = Process()
        process.executableURL = URL(fileURLWithPath: inherited[0])
        process.arguments = ["--test-bundle-path", payload, "--testing-library", "swift-testing",
                             "--filter", "bootstrapRecoveryChild\\(\\)"]
        var environment = ProcessInfo.processInfo.environment
        environment["RECOVERY03_CHILD_REQUEST"] = try JSONEncoder().encode(request).base64EncodedString()
        process.environment = environment
        let log = childEvidence.appendingPathComponent("child.raw.log")
        try #require(FileManager.default.createFile(atPath: log.path, contents: nil))
        let handle = try FileHandle(forWritingTo: log)
        process.standardOutput = handle
        process.standardError = handle
        defer { try? handle.close() }
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        try process.run()
        let timedOut = done.wait(timeout: .now() + 20) != .success
        if timedOut {
            process.terminate()
            if done.wait(timeout: .now() + 2) != .success { kill(process.processIdentifier, SIGKILL) }
        }
        process.waitUntilExit()
        try handle.synchronize()
        let raw = try String(contentsOf: log, encoding: .utf8)
        print("RECOVERY03_CHILD_RAW path=\(log.path) exit=\(process.terminationStatus)")
        try #require(!timedOut && process.terminationStatus == 0)
        try #require(raw.contains("Test bootstrapRecoveryChild() started."))
        try #require(raw.contains("Test bootstrapRecoveryChild() passed after"))
        try #require(raw.contains("Test run with 1 test in 1 suite passed after"))
        let proof = try JSONDecoder().decode(RecoveryProof.self, from: Data(contentsOf: request.proof))
        #expect(proof.nonce == request.nonce)
        #expect(proof.parentPID == getpid() && proof.childPID == process.processIdentifier)
        #expect(proof.components == expectedComponents && proof.restoredBeforeStores)
    }
}

// Formal test roots may use a data-volume spelling that Foundation does not
// preserve in canonical policy URLs or enumerated child URL components.
// Normalize only this already-created owned fixture object; never a production
// allow-root or runner environment. Refuse any physical identity change.
private func canonicalOwnedFixtureURL2263(_ raw: URL) throws -> URL {
    let canonical = raw.standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL
    let before = try FileManager.default.attributesOfItem(atPath: raw.path)
    let after = try FileManager.default.attributesOfItem(atPath: canonical.path)
    for key in [FileAttributeKey.systemNumber, .systemFileNumber, .ownerAccountID] {
        guard let original = before[key] as? NSNumber,
              let resolved = after[key] as? NSNumber,
              original == resolved else {
            throw NSError(domain: "MinisCanvas.OwnedFixtureCanonicalIdentity", code: 1,
                          userInfo: [NSLocalizedDescriptionKey:
                            "Fixture canonicalization changed device, inode or owner"])
        }
    }
    let metadata: [String: Any] = [
        "event": "CORE424_OWNED_FIXTURE_CANONICAL_IDENTITY",
        "helper": "canonicalOwnedFixtureURL2263",
        "sampling_point": "after_identity_guard_before_return",
        "sampled_at_epoch": Date().timeIntervalSince1970,
        "original_path": raw.path,
        "stable_path": canonical.path,
        "before": ["device": before[.systemNumber]!,
                   "inode": before[.systemFileNumber]!,
                   "UID": before[.ownerAccountID]!],
        "after": ["device": after[.systemNumber]!,
                  "inode": after[.systemFileNumber]!,
                  "UID": after[.ownerAccountID]!]
    ]
    let encoded = try JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys])
    print("CORE424_FIXTURE_METADATA " + String(decoding: encoded, as: UTF8.self))
    return canonical
}
