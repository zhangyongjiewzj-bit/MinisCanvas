import Foundation
import Testing
@testable import MinisCore

@Suite("SKILL-05 manifest identity admission")
struct SkillManifestIdentityTests {
    private let content = "---\nname: Demo\nversion: 2.1.0\n---\nbody"

    @Test func sidecarFreeLegacyIdentityUsesStableCurrentDefaults() throws {
        let identity = try #require(
            SkillManifestIdentity.resolve(
                skillID: "demo",
                skillVersion: "2.1.0",
                content: content
            )
        )
        #expect(identity.skillID == "demo")
        #expect(identity.skillVersion == "2.1.0")
        #expect(identity.manifestSchema == SkillSourceManifest.currentSchema)
        #expect(identity.manifestVersion == SkillSourceManifest.currentVersion)
        #expect(identity.source == nil)
        #expect(identity.isLegacy)
    }

    @Test func exactSourceManifestBindsIDVersionAndContentHash() throws {
        let manifest = SkillSourceManifest(
            skillID: "demo",
            source: .file,
            skillVersion: "2.1.0",
            content: content
        )
        let data = try JSONEncoder().encode(manifest)
        let identity = try #require(
            SkillManifestIdentity.resolve(
                skillID: "demo",
                skillVersion: "2.1.0",
                content: content,
                manifestData: data
            )
        )
        #expect(identity.source == .file)
        #expect(!identity.isLegacy)
        #expect(SkillManifestIdentity.rejection(
            skillID: "demo",
            skillVersion: "2.1.0",
            content: content,
            manifestData: data
        ) == nil)
    }

    @Test func reopenedStoreAcceptsLegacyUnsortedManifestWithoutRewritingBytes() throws {
        let formal = try #require(try FormalTestIsolationPaths.resolveCurrentProcess())
        let root = formal.temporaryDirectory.appendingPathComponent("skill432-legacy-order-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SkillStore(skillsRoot: root)
        let imported = try store.importSkill(content: content, source: .file)
        // A complete historical manifest with deliberately unsorted keys.
        // Reads must accept its schema and values without canonicalizing its bytes.
        let legacyData = Data(#"{"version":1,"source":{"file":{}},"skillVersion":"2.1.0","skillID":"\#(imported.id)","schema":"miniscore.skill-source-manifest","contentHash":"\#(SkillManifest.hash(content))"}"#.utf8)
        try legacyData.write(to: store.skillManifestURL(for: imported.id), options: .atomic)

        let reopened = SkillStore(skillsRoot: root)
        let restored = try #require(reopened.allSkills().first { $0.id == imported.id })
        #expect(restored.integrity.state == .verified)
        #expect(restored.importSource == .file)
        #expect(restored.version == "2.1.0")
        #expect(reopened.rawContent(imported.id) == content)
        #expect(try Data(contentsOf: reopened.skillManifestURL(for: imported.id)) == legacyData)
        let identity = try #require(SkillManifestIdentity.resolve(
            skillID: imported.id, skillVersion: "2.1.0", content: content, manifestData: legacyData
        ))
        #expect(identity.source == .file)
        #expect(!identity.isLegacy)
    }

    @Test func unknownSchemaAndVersionFailClosedWithoutPathBearingErrors() throws {
        let unknownSchema = SkillSourceManifest(
            skillID: "demo",
            source: .file,
            skillVersion: "2.1.0",
            content: content,
            schema: "miniscore.skill-source-manifest.future",
            version: SkillSourceManifest.currentVersion
        )
        let unknownVersion = SkillSourceManifest(
            skillID: "demo",
            source: .file,
            skillVersion: "2.1.0",
            content: content,
            version: SkillSourceManifest.currentVersion + 1
        )
        #expect(SkillManifestIdentity.rejection(
            skillID: "demo",
            skillVersion: "2.1.0",
            content: content,
            manifestData: try JSONEncoder().encode(unknownSchema)
        ) == .unknownSchema)
        #expect(SkillManifestIdentity.rejection(
            skillID: "demo",
            skillVersion: "2.1.0",
            content: content,
            manifestData: try JSONEncoder().encode(unknownVersion)
        ) == .unknownManifestVersion)
        #expect(SkillManifestIdentity.resolve(
            skillID: "demo",
            skillVersion: "2.1.0",
            content: content,
            manifestData: Data("{\"schema\":\"future\"}".utf8)
        ) == nil)
    }

    @Test func invalidAndOverlongIdentityFieldsAreRejected() {
        let longID = String(repeating: "x", count: SkillManifestIdentity.maxSkillIDBytes + 1)
        let longVersion = String(repeating: "v", count: SkillManifestIdentity.maxSkillVersionBytes + 1)
        #expect(!SkillManifestIdentity.isValidSkillID(longID))
        #expect(!SkillManifestIdentity.isValidSkillID("../escape"))
        #expect(!SkillManifestIdentity.isValidSkillVersion(longVersion))
        #expect(SkillManifestIdentity.rejection(
            skillID: longID,
            skillVersion: "1.0.0",
            content: content
        ) == .invalidSkillID)
        #expect(SkillManifestIdentity.rejection(
            skillID: "demo",
            skillVersion: longVersion,
            content: content
        ) == .invalidSkillVersion)
    }

    @Test func manifestVersionAndHashMismatchAreRejected() throws {
        let mismatchedID = SkillSourceManifest(
            skillID: "other",
            source: .file,
            skillVersion: "2.1.0",
            content: content
        )
        let mismatchedVersion = SkillSourceManifest(
            skillID: "demo",
            source: .file,
            skillVersion: "3.0.0",
            content: content
        )
        let mismatchedHash = SkillSourceManifest(
            skillID: "demo",
            source: .file,
            skillVersion: "2.1.0",
            content: "different"
        )
        #expect(SkillManifestIdentity.rejection(
            skillID: "demo", skillVersion: "2.1.0", content: content,
            manifestData: try JSONEncoder().encode(mismatchedID)
        ) == .manifestSkillIDMismatch)
        #expect(SkillManifestIdentity.rejection(
            skillID: "demo", skillVersion: "2.1.0", content: content,
            manifestData: try JSONEncoder().encode(mismatchedVersion)
        ) == .manifestSkillVersionMismatch)
        #expect(SkillManifestIdentity.rejection(
            skillID: "demo", skillVersion: "2.1.0", content: content,
            manifestData: try JSONEncoder().encode(mismatchedHash)
        ) == .manifestHashMismatch)
    }

    @Test func canonicalCatalogIDRemovesOnlyKnownNamespaces() {
        #expect(SkillManifestIdentity.canonicalCatalogID("skill:demo") == "demo")
        #expect(SkillManifestIdentity.canonicalCatalogID("app:demo") == "demo")
        #expect(SkillManifestIdentity.canonicalCatalogID("hermes:demo") == "demo")
        #expect(SkillManifestIdentity.canonicalCatalogID("plugin:demo") == "demo")
        #expect(SkillManifestIdentity.canonicalCatalogID("../demo") == nil)
    }
}
