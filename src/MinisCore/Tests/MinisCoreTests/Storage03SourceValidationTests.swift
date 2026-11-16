import Foundation
import Testing
import CryptoKit
@testable import MinisCore

@Suite("D-STORAGE-03 snapshot source validation", .serialized)
struct Storage03SourceValidationTests {
    private struct Fixture {
        let root: URL
        let manager: SyncManager
        let memoryScope = MemoryScope(sessionID: "storage03-session", projectID: "storage03-project")

        init(_ label: String, source: Bool) throws {
            root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
                .appendingPathComponent("Storage03-\(label)-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let chat = root.appendingPathComponent("chat", isDirectory: true)
            let core = root.appendingPathComponent("core", isDirectory: true)
            manager = SyncManager(sessionStore: SessionStore(directory: chat), memoryStore: MemoryStore(directory: chat),
                                  skillStore: SkillStore(skillsRoot: core.appendingPathComponent("skills", isDirectory: true)),
                                  settingsStore: SettingsStore(directory: core),
                                  deviceName: source ? "Another Mac" : "This Mac")
            _ = try manager.sessionStore.createSession(id: memoryScope.sessionID,
                                                       title: source ? "imported session" : "existing session")
            _ = try manager.memoryStore.addFact(source ? "imported memory" : "existing memory",
                                                 sourceSessionID: memoryScope.sessionID, memoryScope: memoryScope)
            _ = try manager.skillStore.importSkill(content: "---\nname: Storage03 Skill\ndescription: synthetic\n---\n\(source ? "imported" : "existing") skill")
            _ = manager.settingsStore.update(\.storage.sessionRetentionDays, to: source ? 83 : 41)
        }

        func remove() { try? FileManager.default.removeItem(at: root) }

        func diskBytes() throws -> [String: Data] {
            guard let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else {
                return [:]
            }
            var result: [String: Data] = [:]
            for case let url as URL in files {
                if try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                    result[String(url.path.dropFirst(root.path.count + 1))] = try Data(contentsOf: url)
                }
            }
            return result
        }

        func domainHashes() throws -> [String: String] {
            let paths: [String: URL] = [
                "sessions": manager.sessionStore.sessionsDirectory.appendingPathComponent("storage03-session.json"),
                "memories": manager.memoryStore.fileURL,
                "skills": manager.skillStore.skillsRoot.appendingPathComponent("storage03-skill/SKILL.md"),
                "settings": manager.settingsStore.fileURL,
            ]
            return try paths.mapValues { url in
                SHA256.hash(data: try Data(contentsOf: url))
                    .map { String(format: "%02x", $0) }.joined()
            }
        }
    }

    private func changing(_ snapshot: Data, manifest: (inout [String: Any]) -> Void) throws -> Data {
        var object = try #require(JSONSerialization.jsonObject(with: snapshot) as? [String: Any])
        var fields = try #require(object["manifest"] as? [String: Any])
        manifest(&fields)
        object["manifest"] = fields
        return try JSONSerialization.data(withJSONObject: object)
    }

    @Test func corruptOldAndExplicitForeignAppSnapshotsRejectBeforeFourDomainWrite() throws {
        let source = try Fixture("source", source: true); defer { source.remove() }
        let target = try Fixture("target", source: false); defer { target.remove() }
        let snapshot = try source.manager.exportSnapshot()
        let before = try target.diskBytes()
        let beforeHashes = try target.domainHashes()
        #expect(before.count >= 4)
        #expect(Set(beforeHashes.keys) == ["sessions", "memories", "skills", "settings"])

        let corrupt = Data("{broken json".utf8)
        let oldVersion = try changing(snapshot) { $0["version"] = 0 }
        let foreignApp = try changing(snapshot) { $0["sourceApplicationID"] = "com.example.OtherApp" }

        #expect(throws: SyncAtomicImportError.invalidSnapshot) {
            try target.manager.previewAtomicImport(corrupt, memoryScope: source.memoryScope)
        }
        #expect(try target.diskBytes() == before)
        #expect(try target.domainHashes() == beforeHashes)
        #expect(throws: SyncManifestError.unsupportedVersion(expected: 1, found: 0)) {
            try target.manager.previewAtomicImport(oldVersion, memoryScope: source.memoryScope)
        }
        #expect(try target.diskBytes() == before)
        #expect(try target.domainHashes() == beforeHashes)
        #expect(throws: SyncManifestError.wrongSourceApplication("com.example.OtherApp")) {
            try target.manager.previewAtomicImport(foreignApp, memoryScope: source.memoryScope)
        }
        #expect(try target.diskBytes() == before)
        #expect(try target.domainHashes() == beforeHashes)
    }

    @Test func sameAppCrossDeviceAndUnmarkedLegacySnapshotsStillCommitFourDomains() throws {
        let source = try Fixture("cross-device-source", source: true); defer { source.remove() }
        let snapshot = try source.manager.exportSnapshot()
        let object = try #require(JSONSerialization.jsonObject(with: snapshot) as? [String: Any])
        let manifest = try #require(object["manifest"] as? [String: Any])
        #expect(manifest["deviceName"] as? String == "Another Mac")
        #expect(manifest["sourceApplicationID"] as? String == SyncManifest.applicationIdentifier)

        for legacy in [false, true] {
            let target = try Fixture(legacy ? "legacy-target" : "marked-target", source: false)
            defer { target.remove() }
            let data = legacy ? try changing(snapshot) { $0.removeValue(forKey: "sourceApplicationID") } : snapshot
            let preview = try target.manager.previewAtomicImport(data, memoryScope: source.memoryScope)
            #expect(preview.selected == Set(SyncScope.allCases))
            let receipt = try target.manager.confirmAtomicImport(preview, snapshot: data,
                                                                 confirmation: .init(preview: preview))
            #expect(receipt.committed && receipt.reopenRequired)
            // Atomic commit deliberately leaves the old Store instances stale.
            // Read the four published domain files, as a fresh process would.
            let session = try JSONDecoder().decode(ChatSession.self,
                from: Data(contentsOf: target.manager.sessionStore.sessionsDirectory
                    .appendingPathComponent("storage03-session.json")))
            #expect(session.title == "imported session")
            let memories = try JSONDecoder().decode([MemoryFact].self,
                from: Data(contentsOf: target.manager.memoryStore.fileURL))
            #expect(memories.map(\.text) == ["imported memory"])
            let skill = try Data(contentsOf: target.manager.skillStore.skillsRoot
                .appendingPathComponent("storage03-skill/SKILL.md"))
            #expect(String(data: skill, encoding: .utf8)?.contains("imported skill") == true)
            let settings = try JSONDecoder().decode(AppSettings.self,
                from: Data(contentsOf: target.manager.settingsStore.fileURL))
            #expect(settings.storage.sessionRetentionDays == 83)
        }
    }

    @Test func directImportAndWrongProjectPreviewRejectBeforeFourDomainOverwrite() throws {
        let source = try Fixture("direct-source", source: true); defer { source.remove() }
        let target = try Fixture("direct-target", source: false); defer { target.remove() }
        let snapshot = try source.manager.exportSnapshot()
        let oldVersion = try changing(snapshot) { $0["version"] = 0 }
        let foreignApp = try changing(snapshot) { $0["sourceApplicationID"] = "com.example.OtherApp" }
        let corrupt = Data("{broken json".utf8)
        let before = try target.diskBytes()
        let beforeHashes = try target.domainHashes()
        #expect(Set(beforeHashes.keys) == ["sessions", "memories", "skills", "settings"])

        // The ordinary SyncManager consumer must reject malformed format and
        // an explicitly foreign application before any per-scope write begins.
        #expect(throws: (any Error).self) {
            try target.manager.importSnapshot(corrupt, memoryScope: source.memoryScope)
        }
        #expect(try target.diskBytes() == before)
        #expect(try target.domainHashes() == beforeHashes)
        #expect(throws: SyncManifestError.unsupportedVersion(expected: 1, found: 0)) {
            try target.manager.importSnapshot(oldVersion, memoryScope: source.memoryScope)
        }
        #expect(try target.diskBytes() == before)
        #expect(try target.domainHashes() == beforeHashes)
        #expect(throws: SyncManifestError.wrongSourceApplication("com.example.OtherApp")) {
            try target.manager.importSnapshot(foreignApp, memoryScope: source.memoryScope)
        }
        #expect(try target.diskBytes() == before)
        #expect(try target.domainHashes() == beforeHashes)

        // This checks the caller-selected target scope. The App currently
        // pre-fills that scope from its active context but lets the user edit it;
        // this assertion does not authenticate an actual project or device.
        let wrongProject = MemoryScope(sessionID: source.memoryScope.sessionID,
                                       projectID: "different-project")
        #expect(throws: SyncAtomicImportError.foreignMemoryScope) {
            try target.manager.previewAtomicImport(snapshot, memoryScope: wrongProject)
        }
        #expect(try target.diskBytes() == before)
        #expect(try target.domainHashes() == beforeHashes)
    }
}
