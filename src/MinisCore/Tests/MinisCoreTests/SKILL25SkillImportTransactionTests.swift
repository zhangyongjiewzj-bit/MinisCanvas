import Foundation
import Testing
@testable import MinisCore

@Suite("SKILL-25 skill import transaction recovery")
struct SKILL25SkillImportTransactionTests {
    private let originalContent = "---\nname: Transactional\nversion: 1.0.0\n---\nold body\n"
    private let updatedContent = "---\nname: Transactional\nversion: 1.0.0\n---\nnew body\n"

    private struct MarkerFixture: Encodable {
        let schema: String = "miniscore.skill-import-transaction"
        let version: Int = 2
        let transactionID: String
        let generation: UInt64
        let skillID: String
        let skillFileName = "SKILL.md"
        let manifestFileName = "manifest.json"
        let skillTempName: String
        let manifestTempName: String
        let targetBindingDigest: String
        let previousPairDigest: String
        let expectedPairDigest: String
        let expectedContentHash: String
        let expectedManifest: SkillSourceManifest
        let previousContentHash: String?
        let previousManifest: SkillSourceManifest?
        let markerDigest: String
    }

    private func temporaryRoot(_ label: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SKILL25-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func skillDirectory(in root: URL) -> URL {
        root.appendingPathComponent("transactional", isDirectory: true)
    }

    private func manifest(at directory: URL) throws -> SkillSourceManifest {
        let data = try Data(contentsOf: directory.appendingPathComponent("manifest.json"))
        return try JSONDecoder().decode(SkillSourceManifest.self, from: data)
    }

    private func digest(_ fields: [String]) -> String {
        var canonical = "miniscore.skill-import-transaction-digest:v1"
        for field in fields {
            canonical += "\(field.utf8.count):\(field)"
        }
        return SkillManifest.hash(canonical)
    }

    private func manifestFields(_ manifest: SkillSourceManifest?) -> [String] {
        guard let manifest else { return ["<missing>"] }
        return [
            manifest.schema,
            String(manifest.version),
            manifest.skillID,
            manifest.source.dbValue,
            manifest.skillVersion,
            manifest.contentHash
        ]
    }

    private func pairDigest(
        skillID: String,
        contentHash: String?,
        manifest: SkillSourceManifest?
    ) -> String {
        digest(["pair", skillID, contentHash ?? "<missing>"] + manifestFields(manifest))
    }

    private func markerDigest(_ marker: MarkerFixture) -> String {
        digest([
            "marker",
            marker.schema,
            String(marker.version),
            marker.transactionID,
            String(marker.generation),
            marker.skillID,
            marker.skillFileName,
            marker.manifestFileName,
            marker.skillTempName,
            marker.manifestTempName,
            marker.targetBindingDigest,
            marker.previousPairDigest,
            marker.expectedPairDigest,
            marker.expectedContentHash
        ] + manifestFields(marker.expectedManifest)
            + [marker.previousContentHash ?? "<missing>"]
            + manifestFields(marker.previousManifest))
    }

    private func writeCrashMarker(
        root: URL,
        at directory: URL,
        skillTempName: String,
        manifestTempName: String,
        expectedContent: String,
        expectedManifest: SkillSourceManifest,
        previousContent: String?,
        previousManifest: SkillSourceManifest?
    ) throws {
        let transactionID = UUID().uuidString
        let generation: UInt64 = 1
        let previousContentHash = previousContent.map(SkillManifest.hash)
        let previousPairDigest = pairDigest(
            skillID: "transactional",
            contentHash: previousContentHash,
            manifest: previousManifest
        )
        let expectedPairDigest = pairDigest(
            skillID: "transactional",
            contentHash: expectedManifest.contentHash,
            manifest: expectedManifest
        )
        let canonicalRoot = root.resolvingSymlinksInPath().standardizedFileURL.path
        let canonicalDirectory = directory.resolvingSymlinksInPath().standardizedFileURL.path
        let targetBindingDigest = digest([
            "target",
            canonicalRoot,
            canonicalDirectory,
            "transactional"
        ])
        let unsignedMarker = MarkerFixture(
            transactionID: transactionID,
            generation: generation,
            skillID: "transactional",
            skillTempName: skillTempName,
            manifestTempName: manifestTempName,
            targetBindingDigest: targetBindingDigest,
            previousPairDigest: previousPairDigest,
            expectedPairDigest: expectedPairDigest,
            expectedContentHash: SkillManifest.hash(expectedContent),
            expectedManifest: expectedManifest,
            previousContentHash: previousContentHash,
            previousManifest: previousManifest,
            markerDigest: ""
        )
        let marker = MarkerFixture(
            transactionID: unsignedMarker.transactionID,
            generation: unsignedMarker.generation,
            skillID: unsignedMarker.skillID,
            skillTempName: unsignedMarker.skillTempName,
            manifestTempName: unsignedMarker.manifestTempName,
            targetBindingDigest: unsignedMarker.targetBindingDigest,
            previousPairDigest: unsignedMarker.previousPairDigest,
            expectedPairDigest: unsignedMarker.expectedPairDigest,
            expectedContentHash: unsignedMarker.expectedContentHash,
            expectedManifest: unsignedMarker.expectedManifest,
            previousContentHash: unsignedMarker.previousContentHash,
            previousManifest: unsignedMarker.previousManifest,
            markerDigest: markerDigest(unsignedMarker)
        )
        let data = try JSONEncoder().encode(marker)
        let markerURL = directory.appendingPathComponent(".skill-import-pending.json")
        try data.write(to: markerURL, options: .atomic)
        #expect(Darwin.chmod(markerURL.path, mode_t(0o600)) == 0)
    }

    private func prepareMixedTransaction(at root: URL) throws -> URL {
        let store = SkillStore(skillsRoot: root)
        _ = try store.importSkill(content: originalContent)
        let directory = skillDirectory(in: root)
        let previousManifest = try manifest(at: directory)
        let expectedManifest = SkillSourceManifest(
            skillID: "transactional",
            source: .file,
            skillVersion: "1.0.0",
            content: updatedContent
        )
        try updatedContent.write(
            to: directory.appendingPathComponent("SKILL.md"),
            atomically: true,
            encoding: .utf8
        )
        let stagedManifestName = ".manifest.json.crash-stage.tmp"
        let stagedManifestURL = directory.appendingPathComponent(stagedManifestName)
        try JSONEncoder().encode(expectedManifest).write(to: stagedManifestURL, options: .atomic)
        #expect(Darwin.chmod(stagedManifestURL.path, mode_t(0o600)) == 0)
        try writeCrashMarker(
            root: root,
            at: directory,
            skillTempName: ".SKILL.md.crash-stage.tmp",
            manifestTempName: stagedManifestName,
            expectedContent: updatedContent,
            expectedManifest: expectedManifest,
            previousContent: originalContent,
            previousManifest: previousManifest
        )
        return directory
    }

    @Test func secondRenameCrashCompletesTheMissingManifestWithoutMixingVersions() throws {
        let root = try temporaryRoot("second-rename")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SkillStore(skillsRoot: root)
        _ = try store.importSkill(content: originalContent)

        let directory = skillDirectory(in: root)
        let previousManifest = try manifest(at: directory)
        let expectedManifest = SkillSourceManifest(
            skillID: "transactional",
            source: .file,
            skillVersion: "1.0.0",
            content: updatedContent
        )
        // Simulate SKILL.md's rename having succeeded while manifest.json's
        // rename was interrupted. The staged manifest is the only safe
        // completion candidate recorded by the marker.
        try updatedContent.write(
            to: directory.appendingPathComponent("SKILL.md"),
            atomically: true,
            encoding: .utf8
        )
        let stagedManifestName = ".manifest.json.crash-stage.tmp"
        try JSONEncoder().encode(expectedManifest).write(
            to: directory.appendingPathComponent(stagedManifestName),
            options: .atomic
        )
        #expect(Darwin.chmod(
            directory.appendingPathComponent(stagedManifestName).path,
            mode_t(0o600)
        ) == 0)
        try writeCrashMarker(
            root: root,
            at: directory,
            skillTempName: ".SKILL.md.crash-stage.tmp",
            manifestTempName: stagedManifestName,
            expectedContent: updatedContent,
            expectedManifest: expectedManifest,
            previousContent: originalContent,
            previousManifest: previousManifest
        )

        let recovered = SkillStore(skillsRoot: root)
        #expect(recovered.rawContent("transactional") == updatedContent)
        #expect(try manifest(at: directory) == expectedManifest)
        #expect(!FileManager.default.fileExists(
            atPath: directory.appendingPathComponent(".skill-import-pending.json").path
        ))
        #expect(!FileManager.default.fileExists(
            atPath: directory.appendingPathComponent(stagedManifestName).path
        ))
    }

    @Test func crashBeforeEitherRenameReplaysBothDurableStages() throws {
        let root = try temporaryRoot("before-renames")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SkillStore(skillsRoot: root)
        _ = try store.importSkill(content: originalContent)

        let directory = skillDirectory(in: root)
        let previousManifest = try manifest(at: directory)
        let expectedManifest = SkillSourceManifest(
            skillID: "transactional",
            source: .file,
            skillVersion: "1.0.0",
            content: updatedContent
        )
        let stagedSkillName = ".SKILL.md.crash-stage.tmp"
        let stagedManifestName = ".manifest.json.crash-stage.tmp"
        try updatedContent.write(
            to: directory.appendingPathComponent(stagedSkillName),
            atomically: true,
            encoding: .utf8
        )
        #expect(Darwin.chmod(
            directory.appendingPathComponent(stagedSkillName).path,
            mode_t(0o600)
        ) == 0)
        try JSONEncoder().encode(expectedManifest).write(
            to: directory.appendingPathComponent(stagedManifestName),
            options: .atomic
        )
        #expect(Darwin.chmod(
            directory.appendingPathComponent(stagedManifestName).path,
            mode_t(0o600)
        ) == 0)
        try writeCrashMarker(
            root: root,
            at: directory,
            skillTempName: stagedSkillName,
            manifestTempName: stagedManifestName,
            expectedContent: updatedContent,
            expectedManifest: expectedManifest,
            previousContent: originalContent,
            previousManifest: previousManifest
        )

        let recovered = SkillStore(skillsRoot: root)
        #expect(recovered.rawContent("transactional") == updatedContent)
        #expect(try manifest(at: directory) == expectedManifest)
        #expect(!FileManager.default.fileExists(
            atPath: directory.appendingPathComponent(".skill-import-pending.json").path
        ))
    }

    @Test func unknownMixedPairKeepsMarkerAndEvidenceOutOfCatalog() throws {
        let root = try temporaryRoot("unknown-residue")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SkillStore(skillsRoot: root)
        _ = try store.importSkill(content: originalContent)

        let directory = skillDirectory(in: root)
        let previousManifest = try manifest(at: directory)
        let expectedManifest = SkillSourceManifest(
            skillID: "transactional",
            source: .file,
            skillVersion: "1.0.0",
            content: updatedContent
        )
        try updatedContent.write(
            to: directory.appendingPathComponent("SKILL.md"),
            atomically: true,
            encoding: .utf8
        )
        try writeCrashMarker(
            root: root,
            at: directory,
            skillTempName: ".SKILL.md.missing-stage.tmp",
            manifestTempName: ".manifest.json.missing-stage.tmp",
            expectedContent: updatedContent,
            expectedManifest: expectedManifest,
            previousContent: originalContent,
            previousManifest: previousManifest
        )

        let recovered = SkillStore(skillsRoot: root)
        #expect(recovered.allSkills().isEmpty)
        #expect(recovered.rawContent("transactional") == updatedContent)
        #expect(try manifest(at: directory) == previousManifest)
        #expect(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent(".skill-import-pending.json").path
        ))
    }

    @Test func markerCopiedToAnotherSkillRootCannotBeReplayed() throws {
        let sourceRoot = try temporaryRoot("source-root")
        let replayRoot = try temporaryRoot("replay-root")
        defer {
            try? FileManager.default.removeItem(at: sourceRoot)
            try? FileManager.default.removeItem(at: replayRoot)
        }
        let sourceDirectory = try prepareMixedTransaction(at: sourceRoot)
        try FileManager.default.copyItem(
            at: sourceDirectory,
            to: skillDirectory(in: replayRoot)
        )

        let replayed = SkillStore(skillsRoot: replayRoot)
        #expect(replayed.allSkills().isEmpty)
        #expect(replayed.rawContent("transactional") == updatedContent)
        #expect(FileManager.default.fileExists(
            atPath: skillDirectory(in: replayRoot)
                .appendingPathComponent(".skill-import-pending.json").path
        ))
    }

    @Test func tamperedGenerationDigestCannotReplayMarker() throws {
        let root = try temporaryRoot("generation-tamper")
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = try prepareMixedTransaction(at: root)
        let markerURL = directory.appendingPathComponent(".skill-import-pending.json")
        var object = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: markerURL)) as? [String: Any]
        )
        object["generation"] = 2
        try JSONSerialization.data(withJSONObject: object).write(to: markerURL, options: .atomic)
        #expect(Darwin.chmod(markerURL.path, mode_t(0o600)) == 0)

        let recovered = SkillStore(skillsRoot: root)
        #expect(recovered.allSkills().isEmpty)
        #expect(FileManager.default.fileExists(atPath: markerURL.path))
    }

    @Test func nonPrivateMarkerIsNotAcceptedForRecovery() throws {
        let root = try temporaryRoot("marker-mode")
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = try prepareMixedTransaction(at: root)
        let markerURL = directory.appendingPathComponent(".skill-import-pending.json")
        #expect(Darwin.chmod(markerURL.path, mode_t(0o644)) == 0)

        let recovered = SkillStore(skillsRoot: root)
        #expect(recovered.allSkills().isEmpty)
        #expect(FileManager.default.fileExists(atPath: markerURL.path))
    }

    @Test func committedPairWithMarkerLeftoverIsReconciledIdempotently() throws {
        let root = try temporaryRoot("committed-leftover")
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = try prepareMixedTransaction(at: root)
        let expectedManifest = SkillSourceManifest(
            skillID: "transactional",
            source: .file,
            skillVersion: "1.0.0",
            content: updatedContent
        )
        let manifestURL = directory.appendingPathComponent("manifest.json")
        try JSONEncoder().encode(expectedManifest).write(to: manifestURL, options: .atomic)
        #expect(Darwin.chmod(manifestURL.path, mode_t(0o600)) == 0)
        try FileManager.default.removeItem(
            at: directory.appendingPathComponent(".manifest.json.crash-stage.tmp")
        )

        let recovered = SkillStore(skillsRoot: root)
        #expect(recovered.rawContent("transactional") == updatedContent)
        #expect(try manifest(at: directory) == expectedManifest)
        #expect(!FileManager.default.fileExists(
            atPath: directory.appendingPathComponent(".skill-import-pending.json").path
        ))
    }
}
