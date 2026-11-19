import Foundation
import Darwin
import Testing
@testable import MinisCore

// B1c Skill system tests: frontmatter parsing, import/list/search/remove,
// injector matching, and a real-world import of the manju-core skill.
// NOTE: Swift Testing (CLT toolchain, no XCTest) — see SanitizeToolIdTests header.

private func makeTempStore() throws -> (SkillStore, URL) {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("SkillStoreTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return (SkillStore(skillsRoot: dir), dir)
}

private let sampleSkillMD = """
---
name: image-prompt-writer
description: 图片和视频的提示词怎么写。为文生图、图生图、局部重绘、首尾帧视频、镜头分镜编写稳定中文提示词。
version: 1.2.0
---

# Image Prompt Writer

Write stable Chinese prompts for text-to-image generation.
"""

private struct SkillStoreFilesystemAccessCounts: Equatable {
    var fileReads = 0
    var directoryLists = 0
    var recursiveEnumerations = 0
    var resourceValueReads = 0
    var symlinkResolutions = 0

    static let zero = SkillStoreFilesystemAccessCounts()
}

private final class SkillStoreFilesystemAccessCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var counts = SkillStoreFilesystemAccessCounts.zero

    var snapshot: SkillStoreFilesystemAccessCounts {
        lock.withLock { counts }
    }

    func reset() {
        lock.withLock {
            counts = .zero
        }
    }

    func record(_ access: SkillStoreFilesystemAccess) {
        lock.withLock {
            switch access {
            case .fileRead:
                counts.fileReads += 1
            case .directoryList:
                counts.directoryLists += 1
            case .recursiveEnumeration:
                counts.recursiveEnumerations += 1
            case .resourceValues:
                counts.resourceValueReads += 1
            case .symlinkResolution:
                counts.symlinkResolutions += 1
            case .scanLockContention:
                break
            }
        }
    }
}

struct SkillModelsTests {
    @Test func skillImportSourceCodableRoundTrip() throws {
        let sources: [SkillImportSource] = [.url("https://github.com/x/y"), .file, .bundled, .session]
        for source in sources {
            let data = try JSONEncoder().encode(source)
            let decoded = try JSONDecoder().decode(SkillImportSource.self, from: data)
            #expect(decoded == source)
        }
    }

    @Test func skillImportSourceDBValues() {
        #expect(SkillImportSource.url("https://a.b").dbValue == "url:https://a.b")
        #expect(SkillImportSource.fromDB("url:https://a.b") == .url("https://a.b"))
        #expect(SkillImportSource.fromDB("bundled") == .bundled)
        #expect(SkillImportSource.fromDB("session") == .session)
        #expect(SkillImportSource.fromDB("file") == .file)
        #expect(SkillImportSource.fromDB("unknown") == .file)
    }

    @Test func slugify() {
        #expect(SkillStore.slugify("Manju Core") == "manju-core")
        #expect(SkillStore.slugify("image-prompt_writer") == "image-prompt-writer")
        #expect(SkillStore.slugify("曼剧 Core!") == "曼剧-core")
    }
}

struct FrontmatterParsingTests {
    @Test func standardFencedFrontmatter() {
        let parsed = SkillStore.parse(skillMD: sampleSkillMD)
        #expect(parsed.name == "image-prompt-writer")
        #expect(parsed.description.hasPrefix("图片和视频的提示词怎么写"))
        #expect(parsed.version == "1.2.0")
        #expect(parsed.body.contains("Write stable Chinese prompts"))
        #expect(!parsed.body.contains("name:"))
    }

    @Test func headlessFrontmatterWithoutOpeningFence() {
        let md = """
        name: headless-skill
        description: A skill whose opening fence was stripped.
        version: 0.9.0
        ---

        # Body here
        """
        let parsed = SkillStore.parse(skillMD: md)
        #expect(parsed.name == "headless-skill")
        #expect(parsed.description == "A skill whose opening fence was stripped.")
        #expect(parsed.version == "0.9.0")
        #expect(parsed.body == "# Body here")
    }

    @Test func plainMarkdownWithoutFrontmatterFallsThroughToBody() {
        let md = "# Just a doc\n\nNo frontmatter here.\n"
        let parsed = SkillStore.parse(skillMD: md)
        #expect(parsed.name == SkillStore.defaultSkillName)
        #expect(parsed.body == md) // falls through verbatim (matches reference)
    }

    @Test func markdownWithIntroLineBeforeFenceIsNotSwallowed() {
        // A regular markdown file that happens to have `Author: x` then `---`
        // must NOT be parsed as headless frontmatter (no recognized key).
        let md = "Author: Alice\n\n---\n\n# Real content\n"
        let parsed = SkillStore.parse(skillMD: md)
        #expect(parsed.name == SkillStore.defaultSkillName)
        #expect(parsed.body == md) // falls through verbatim (matches reference)
    }

    @Test func blockScalarDescriptionFolded() {
        let md = """
        ---
        name: folded-skill
        description: >-
          First line of a long description
          that folds into a single paragraph.
        ---

        Body.
        """
        let parsed = SkillStore.parse(skillMD: md)
        #expect(parsed.name == "folded-skill")
        #expect(parsed.description == "First line of a long description that folds into a single paragraph.")
    }

    @Test func blockScalarDescriptionLiteral() {
        let md = """
        ---
        name: literal-skill
        description: |
          Line one
          Line two
        ---

        Body.
        """
        let parsed = SkillStore.parse(skillMD: md)
        #expect(parsed.description == "Line one\nLine two")
    }

    @Test func extraFrontmatterFieldsIgnored() {
        let md = """
        ---
        name: extra-fields
        description: Has extra fields.
        author: Someone
        tags: [a, b]
        ---

        Body.
        """
        let parsed = SkillStore.parse(skillMD: md)
        #expect(parsed.name == "extra-fields")
        #expect(parsed.description == "Has extra fields.")
        #expect(parsed.body == "Body.")
    }
}

struct SkillStoreImportTests {
    @Test func importContentPersistsToDiskAndLists() throws {
        let (store, root) = try makeTempStore()
        defer { try? FileManager.default.removeItem(at: root) }

        let skill = try store.importSkill(content: sampleSkillMD, source: .url("https://example.com/skills"))
        #expect(skill.id == "image-prompt-writer")
        #expect(skill.name == "image-prompt-writer")
        #expect(skill.version == "1.2.0")
        #expect(skill.sourceURL == "https://example.com/skills")

        // Persisted to disk
        let file = root.appendingPathComponent("image-prompt-writer/SKILL.md")
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(try String(contentsOf: file, encoding: .utf8) == sampleSkillMD)

        // Reload from disk reconstructs the same metadata
        let store2 = SkillStore(skillsRoot: root)
        #expect(store2.allSkills().count == 1)
        #expect(store2.allSkills().first?.id == "image-prompt-writer")
        #expect(store2.allSkills().first?.description.hasPrefix("图片和视频的提示词怎么写") == true)
    }

    @Test func importFromSkillMDFileURL() throws {
        let (store, root) = try makeTempStore()
        defer { try? FileManager.default.removeItem(at: root) }

        let src = root.appendingPathComponent("src-skill", isDirectory: true)
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        try sampleSkillMD.write(to: src.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)

        let imported = try store.importSkill(from: src.appendingPathComponent("SKILL.md"))
        #expect(imported.count == 1)
        #expect(imported.first?.id == "image-prompt-writer")
    }

    @Test func importFromDirectoryOfSkills() throws {
        let (store, root) = try makeTempStore()
        defer { try? FileManager.default.removeItem(at: root) }

        let src = root.appendingPathComponent("src-bundle", isDirectory: true)
        let s1 = src.appendingPathComponent("skill-a", isDirectory: true)
        let s2 = src.appendingPathComponent("skill-b", isDirectory: true)
        try FileManager.default.createDirectory(at: s1, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: s2, withIntermediateDirectories: true)
        try """
        ---
        name: skill-a
        description: First skill.
        ---

        A body.
        """.write(to: s1.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        try """
        ---
        name: skill-b
        description: Second skill.
        ---

        B body.
        """.write(to: s2.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)

        let imported = try store.importSkill(from: src)
        #expect(imported.map(\.id).sorted() == ["skill-a", "skill-b"])
    }

    @Test func reimportPreservesEnabledState() throws {
        let (store, root) = try makeTempStore()
        defer { try? FileManager.default.removeItem(at: root) }

        _ = try store.importSkill(content: sampleSkillMD)
        store.setEnabled("image-prompt-writer", enabled: false)
        _ = try store.importSkill(content: sampleSkillMD)
        #expect(store.allSkills().first?.isEnabled == false)
    }

    @Test func skillContentReturnsBodyOnly() throws {
        let (store, root) = try makeTempStore()
        defer { try? FileManager.default.removeItem(at: root) }

        _ = try store.importSkill(content: sampleSkillMD)
        #expect(store.skillContent("image-prompt-writer")?.contains("Write stable Chinese prompts") == true)
        #expect(store.skillContent("image-prompt-writer")?.contains("name:") == false)
        #expect(store.skillContent("missing") == nil)
    }

    @Test func searchMatchesNameAndDescription() throws {
        let (store, root) = try makeTempStore()
        defer { try? FileManager.default.removeItem(at: root) }

        _ = try store.importSkill(content: sampleSkillMD)
        _ = try store.importSkill(content: """
        ---
        name: blender-bridge
        description: Render 3D scenes via Blender for video previs.
        ---

        Blender body.
        """)

        #expect(store.search("blender").map(\.id) == ["blender-bridge"])
        #expect(store.search("提示词").map(\.id) == ["image-prompt-writer"])
        #expect(store.search("image").map(\.id) == ["image-prompt-writer"]) // name token
        #expect(store.search("nonexistent").isEmpty)
    }

    @Test func removeSkillDeletesFolderAndEntry() throws {
        let (store, root) = try makeTempStore()
        defer { try? FileManager.default.removeItem(at: root) }

        _ = try store.importSkill(content: sampleSkillMD)
        #expect(store.allSkills().count == 1)
        let intent = try store.previewDeletion(skillID: "image-prompt-writer")
            .withFirstConfirmation("I reviewed this exact skill")
            .withSecondConfirmation("永久删除")
        try store.removeSkill("image-prompt-writer", intent: intent)
        #expect(store.allSkills().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("image-prompt-writer").path))
        let trash = root.appendingPathComponent(".trash", isDirectory: true)
        #expect(try FileManager.default.contentsOfDirectory(at: trash, includingPropertiesForKeys: nil).count == 1)
    }

    @Test func bundledSkillFilesReadable() throws {
        let (store, root) = try makeTempStore()
        defer { try? FileManager.default.removeItem(at: root) }

        _ = try store.importSkill(content: sampleSkillMD)
        let ref = root.appendingPathComponent("image-prompt-writer/references/api.md")
        try FileManager.default.createDirectory(at: ref.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "# API notes".write(to: ref, atomically: true, encoding: .utf8)

        #expect(store.listSkillFiles("image-prompt-writer").contains("references/api.md"))
        #expect(store.readSkillFile("image-prompt-writer", relativePath: "references/api.md") == "# API notes")
    }

    @Test func skillStoreListSkillFilesPreservesLegacySkillMDEntryWhenMissing() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SkillStoreMissingLegacyEntry-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let counter = SkillStoreFilesystemAccessCounter()
        let store = SkillStore(
            skillsRoot: root,
            filesystemAccessObserver: { counter.record($0) }
        )

        _ = try store.importSkill(content: sampleSkillMD)
        let skillRoot = root.appendingPathComponent("image-prompt-writer", isDirectory: true)
        let reference = skillRoot.appendingPathComponent("references/api.md")
        try FileManager.default.createDirectory(
            at: reference.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "# API notes".write(to: reference, atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: skillRoot.appendingPathComponent("SKILL.md"))

        let expectedFiles = ["SKILL.md", "references/api.md"]
        #expect(store.listSkillFiles("image-prompt-writer") == expectedFiles)
        let frozen = store.snapshotForTurn()
        counter.reset()

        #expect(frozen.listSkillFiles("image-prompt-writer") == expectedFiles)
        #expect(frozen.readSkillFile("image-prompt-writer", relativePath: "SKILL.md") == nil)
        #expect(
            frozen.readSkillFile(
                "image-prompt-writer",
                relativePath: "references/api.md"
            ) == "# API notes"
        )
        #expect(counter.snapshot == .zero)
    }

    @Test func frozenSkillStoreAuxiliaryQueriesPerformZeroLiveFilesystemReads() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SkillStoreZeroReads-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let counter = SkillStoreFilesystemAccessCounter()
        let store = SkillStore(
            skillsRoot: root,
            filesystemAccessObserver: { counter.record($0) }
        )

        _ = try store.importSkill(content: sampleSkillMD)
        let reference = root.appendingPathComponent("image-prompt-writer/references/api.md")
        try FileManager.default.createDirectory(
            at: reference.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "# Captured API".write(to: reference, atomically: true, encoding: .utf8)

        let frozen = store.snapshotForTurn()
        #expect(counter.snapshot != .zero)
        counter.reset()

        #expect(frozen.rawContent("image-prompt-writer") == sampleSkillMD)
        #expect(
            frozen.listSkillFiles("image-prompt-writer")
                == ["SKILL.md", "references/api.md"]
        )
        #expect(
            frozen.readSkillFile(
                "image-prompt-writer",
                relativePath: "references/api.md"
            ) == "# Captured API"
        )
        #expect(frozen.readSkillFile("image-prompt-writer", relativePath: "/tmp/outside") == nil)
        #expect(frozen.readSkillFile("image-prompt-writer", relativePath: "../outside") == nil)
        #expect(frozen.readSkillFile("image-prompt-writer", relativePath: "./SKILL.md") == nil)
        #expect(counter.snapshot == .zero)
    }

    @Test func frozenSkillStoreAuxiliaryProjectionDoesNotDriftAfterLiveChanges() throws {
        let (store, root) = try makeTempStore()
        defer { try? FileManager.default.removeItem(at: root) }

        _ = try store.importSkill(content: sampleSkillMD)
        let skillRoot = root.appendingPathComponent("image-prompt-writer", isDirectory: true)
        let reference = skillRoot.appendingPathComponent("references/original.md")
        let example = skillRoot.appendingPathComponent("examples/old.txt")
        try FileManager.default.createDirectory(
            at: reference.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: example.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let renamedScript = skillRoot.appendingPathComponent("scripts/rename-me.sh")
        try FileManager.default.createDirectory(
            at: renamedScript.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "original reference".write(to: reference, atomically: true, encoding: .utf8)
        try "old example".write(to: example, atomically: true, encoding: .utf8)
        try "original script".write(to: renamedScript, atomically: true, encoding: .utf8)

        let frozen = store.snapshotForTurn()
        let expectedFiles = [
            "SKILL.md",
            "examples/old.txt",
            "references/original.md",
            "scripts/rename-me.sh",
        ]

        let updatedSkill = sampleSkillMD.replacingOccurrences(
            of: "Write stable Chinese prompts",
            with: "live updated body"
        )
        try updatedSkill.write(
            to: skillRoot.appendingPathComponent("SKILL.md"),
            atomically: true,
            encoding: .utf8
        )
        try "updated reference".write(to: reference, atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: example)
        let newExample = skillRoot.appendingPathComponent("examples/new.txt")
        try "new example".write(to: newExample, atomically: true, encoding: .utf8)
        let renamedScriptDestination = skillRoot.appendingPathComponent("scripts/renamed.sh")
        try FileManager.default.moveItem(at: renamedScript, to: renamedScriptDestination)

        #expect(frozen.listSkillFiles("image-prompt-writer") == expectedFiles)
        #expect(frozen.readSkillFile("image-prompt-writer", relativePath: "SKILL.md") == sampleSkillMD)
        #expect(
            frozen.readSkillFile(
                "image-prompt-writer",
                relativePath: "references/original.md"
            ) == "original reference"
        )
        #expect(
            frozen.readSkillFile(
                "image-prompt-writer",
                relativePath: "examples/old.txt"
            ) == "old example"
        )
        #expect(frozen.readSkillFile("image-prompt-writer", relativePath: "examples/new.txt") == nil)
        #expect(
            frozen.readSkillFile(
                "image-prompt-writer",
                relativePath: "scripts/rename-me.sh"
            ) == "original script"
        )
        #expect(frozen.readSkillFile("image-prompt-writer", relativePath: "scripts/renamed.sh") == nil)

        let liveSnapshot = store.snapshotForTurn()
        #expect(
            liveSnapshot.listSkillFiles("image-prompt-writer")
                == [
                    "SKILL.md",
                    "examples/new.txt",
                    "references/original.md",
                    "scripts/renamed.sh",
                ]
        )
        #expect(
            liveSnapshot.readSkillFile(
                "image-prompt-writer",
                relativePath: "SKILL.md"
            ) == updatedSkill
        )
        #expect(
            liveSnapshot.readSkillFile(
                "image-prompt-writer",
                relativePath: "references/original.md"
            ) == "updated reference"
        )
        #expect(liveSnapshot.readSkillFile("image-prompt-writer", relativePath: "examples/old.txt") == nil)
        #expect(
            liveSnapshot.readSkillFile(
                "image-prompt-writer",
                relativePath: "examples/new.txt"
            ) == "new example"
        )
        #expect(liveSnapshot.readSkillFile("image-prompt-writer", relativePath: "scripts/rename-me.sh") == nil)
        #expect(
            liveSnapshot.readSkillFile(
                "image-prompt-writer",
                relativePath: "scripts/renamed.sh"
            ) == "original script"
        )
    }

    @Test func frozenSkillStoreResnapshotPerformsZeroLiveFilesystemReads() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SkillStoreZeroResnapshot-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let counter = SkillStoreFilesystemAccessCounter()
        let store = SkillStore(
            skillsRoot: root,
            filesystemAccessObserver: { counter.record($0) }
        )

        _ = try store.importSkill(content: sampleSkillMD)
        let reference = root.appendingPathComponent("image-prompt-writer/references/api.md")
        try FileManager.default.createDirectory(
            at: reference.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "# Captured API".write(to: reference, atomically: true, encoding: .utf8)
        let frozen = store.snapshotForTurn()
        counter.reset()

        let frozenAgain = frozen.snapshotForTurn()
        #expect(counter.snapshot == .zero)
        #expect(frozenAgain.rawContent("image-prompt-writer") == sampleSkillMD)
        #expect(
            frozenAgain.listSkillFiles("image-prompt-writer")
                == ["SKILL.md", "references/api.md"]
        )
        #expect(
            frozenAgain.readSkillFile(
                "image-prompt-writer",
                relativePath: "references/api.md"
            ) == "# Captured API"
        )
        #expect(counter.snapshot == .zero)
    }

    @Test func importEmptyContentThrowsInvalidContent() throws {
        let (store, root) = try makeTempStore()
        defer { try? FileManager.default.removeItem(at: root) }

        // 空内容 / 纯空白内容都必须被拒绝，不能落盘 untitled-skill 空目录
        #expect(throws: SkillError.invalidContent) {
            _ = try store.importSkill(content: "")
        }
        #expect(throws: SkillError.invalidContent) {
            _ = try store.importSkill(content: "   \n\t\n  ")
        }
        #expect(store.allSkills().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("untitled-skill").path))
    }

    @Test func importEmptyFileURLThrowsInvalidContent() throws {
        let (store, root) = try makeTempStore()
        defer { try? FileManager.default.removeItem(at: root) }

        let emptyFile = root.appendingPathComponent("empty.md")
        try Data().write(to: emptyFile)
        #expect(throws: SkillError.invalidContent) {
            _ = try store.importSkill(from: emptyFile)
        }
        #expect(store.allSkills().isEmpty)
    }

    @Test func removeNonexistentSkillIsNoOp() throws {
        let (store, root) = try makeTempStore()
        defer { try? FileManager.default.removeItem(at: root) }

        _ = try store.importSkill(content: sampleSkillMD)
        // 删除不存在的 skill 不崩溃、不影响其余 skill
        store.removeSkill("no-such-skill")
        #expect(store.allSkills().count == 1)
        #expect(store.allSkills().first?.id == "image-prompt-writer")
        let intent = try store.previewRemoveAll()
            .withFirstConfirmation("I reviewed every installed skill")
            .withSecondConfirmation("永久删除")
        try store.removeAll(intent: intent)
        #expect(store.allSkills().isEmpty)
    }

    @Test func removeAllMovesEverySkillToTrashAfterConfirmation() throws {
        let (store, root) = try makeTempStore()
        defer { try? FileManager.default.removeItem(at: root) }

        _ = try store.importSkill(content: sampleSkillMD)
        _ = try store.importSkill(content: """
        ---
        name: second-skill
        description: second
        ---
        body
        """)

        let intent = try store.previewRemoveAll()
            .withFirstConfirmation("I reviewed every installed skill")
            .withSecondConfirmation("永久删除")
        let receipt = try store.removeAll(intent: intent)

        #expect(store.allSkills().isEmpty)
        let operationTrash = root
            .appendingPathComponent(".trash", isDirectory: true)
            .appendingPathComponent(receipt.operationID.uuidString, isDirectory: true)
        #expect(try FileManager.default.contentsOfDirectory(at: operationTrash, includingPropertiesForKeys: nil).count == 2)
    }

    @Test func searchIsCaseInsensitiveAndMultiToken() throws {
        let (store, root) = try makeTempStore()
        defer { try? FileManager.default.removeItem(at: root) }

        _ = try store.importSkill(content: sampleSkillMD)
        _ = try store.importSkill(content: """
        ---
        name: blender-bridge
        description: Render 3D scenes via Blender for video previs.
        ---

        Blender body.
        """)

        // 大小写不敏感
        #expect(store.search("BLENDER").map(\.id) == ["blender-bridge"])
        #expect(store.search("Image").map(\.id) == ["image-prompt-writer"])
        // 多 token AND 语义
        #expect(store.search("blender video").map(\.id) == ["blender-bridge"])
        #expect(store.search("blender image").isEmpty)
        // 空查询 → 空结果
        #expect(store.search("").isEmpty)
        #expect(store.search("   ").isEmpty)
    }

    @Test func reloadSkipsCorruptSkillDirectories() throws {
        let (store, root) = try makeTempStore()
        defer { try? FileManager.default.removeItem(at: root) }

        _ = try store.importSkill(content: sampleSkillMD)

        // 磁盘上放一个空 SKILL.md 目录 → reload 必须跳过，不崩溃
        let corruptDir = root.appendingPathComponent("corrupt", isDirectory: true)
        try FileManager.default.createDirectory(at: corruptDir, withIntermediateDirectories: true)
        try Data().write(to: corruptDir.appendingPathComponent("SKILL.md"))

        // 无 frontmatter 的普通 md 目录 → 作为 Untitled Skill 载入（名称兜底）
        let bareDir = root.appendingPathComponent("bare", isDirectory: true)
        try FileManager.default.createDirectory(at: bareDir, withIntermediateDirectories: true)
        try "# Just body\nno frontmatter".write(to: bareDir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)

        let store2 = SkillStore(skillsRoot: root)
        let ids = store2.allSkills().map(\.id)
        #expect(!ids.contains("corrupt"))           // 空文件被跳过
        #expect(ids.contains("image-prompt-writer")) // 正常 skill 保留
        #expect(ids.contains("bare"))               // 无 frontmatter 仍载入（body 全量）
        #expect(store2.skillContent("bare")?.contains("Just body") == true)
    }
}

struct ManjuCoreImportTests {
    /// Synthetic file-import compatibility of the original seven assertions.
    /// The historical selector name remains; no actual user skill is accessed.
    @Test func importActualManjuCoreSkill() throws {
        func fixtureError(_ stage: String) -> NSError {
            NSError(domain: "ManjuSyntheticImportFixture", code: Int(errno),
                    userInfo: [NSLocalizedDescriptionKey: stage])
        }
        guard let formal = try FormalTestIsolationPaths.resolveCurrentProcess(),
              let canonical = PolicyRuntimePathBoundary.canonicalPath(formal.rootDirectory.path) else {
            throw fixtureError("formal owned-root contract is required")
        }
        let parent = URL(fileURLWithPath: canonical, isDirectory: true)
        var parentIdentity = stat()
        guard lstat(parent.path, &parentIdentity) == 0,
              parentIdentity.st_mode & S_IFMT == S_IFDIR,
              parentIdentity.st_mode & 0o777 == 0o700,
              parentIdentity.st_uid == geteuid(), parentIdentity.st_uid == formal.rootOwner,
              UInt64(parentIdentity.st_dev) == formal.rootDevice,
              UInt64(parentIdentity.st_ino) == formal.rootInode else {
            throw fixtureError("formal physical parent identity mismatch")
        }
        let root = parent.appendingPathComponent("ManjuSyntheticImport-\(UUID().uuidString)", isDirectory: true)
        guard mkdir(root.path, 0o700) == 0 else { throw fixtureError("create exclusive synthetic root") }
        var identity = stat()
        guard lstat(root.path, &identity) == 0 else {
            // Identity was not pinned; preserve instead of deleting an unknown entry.
            throw fixtureError("pin synthetic root identity")
        }
        let pinned = identity
        defer {
            var current = stat()
            if lstat(root.path, &current) == 0,
               current.st_mode & S_IFMT == S_IFDIR, current.st_mode & 0o777 == 0o700,
               current.st_uid == geteuid(), current.st_dev == pinned.st_dev, current.st_ino == pinned.st_ino {
                do {
                    try FileManager.default.removeItem(at: root)
                    var absent = stat()
                    if lstat(root.path, &absent) != -1 || errno != ENOENT {
                        Issue.record("synthetic Manju fixture cleanup did not establish absence")
                    }
                } catch { Issue.record(error) }
            } else { Issue.record("synthetic Manju root identity changed; preserve fixture") }
        }
        guard identity.st_mode & S_IFMT == S_IFDIR, identity.st_mode & 0o777 == 0o700,
              identity.st_uid == geteuid(), identity.st_uid == formal.rootOwner,
              identity.st_dev == parentIdentity.st_dev, identity.st_ino != parentIdentity.st_ino else {
            throw fixtureError("synthetic root uid/device/inode/mode mismatch")
        }
        let source = root.appendingPathComponent("source", isDirectory: true)
        let destination = root.appendingPathComponent("store", isDirectory: true)
        guard mkdir(source.path, 0o700) == 0, mkdir(destination.path, 0o700) == 0 else {
            throw fixtureError("create separate source and store directories")
        }
        let file = source.appendingPathComponent("SKILL.md")
        let manjuPath = file.path
        let descriptor = Darwin.open(manjuPath, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw fixtureError("create synthetic SKILL.md") }
        defer { if Darwin.close(descriptor) != 0 { Issue.record("close synthetic SKILL.md writer") } }
        var fileIdentity = stat()
        guard fstat(descriptor, &fileIdentity) == 0,
              fileIdentity.st_mode & S_IFMT == S_IFREG, fileIdentity.st_mode & 0o777 == 0o600,
              fileIdentity.st_uid == geteuid(), fileIdentity.st_dev == identity.st_dev else {
            throw fixtureError("synthetic SKILL.md uid/device/type/mode mismatch")
        }
        let content = """
        ---
        name: manju-core
        description: 铁律测试夹具，仅用于文件导入兼容性。
        version: 1.0.0
        ---
        # 十二条铁律
        This is synthetic fixture content, not a copied user skill.
        """
        let bytes = Array(content.utf8)
        try bytes.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw fixtureError("write synthetic SKILL.md") }
                offset += count
            }
        }
        guard fsync(descriptor) == 0 else { throw fixtureError("sync synthetic SKILL.md") }
        let store = SkillStore(skillsRoot: destination)

        let imported = try store.importSkill(from: URL(fileURLWithPath: manjuPath))
        #expect(imported.count == 1)
        let skill = try #require(imported.first)
        #expect(skill.name == "manju-core")
        #expect(skill.id == "manju-core")
        #expect(skill.description.contains("铁律"))
        #expect(skill.body.contains("十二条铁律"))
        #expect(store.allSkills().count == 1)
    }
}

struct SkillInjectorTests {
    private func makeStore() throws -> (SkillStore, URL) {
        try makeTempStore()
    }

    @Test func untrustedLifecycleImportIsQuarantinedAndNeverInjected() throws {
        let (store, root) = try makeTempStore()
        defer { try? FileManager.default.removeItem(at: root) }

        let result = try store.importSkillThroughLifecycle(
            content: """
            ---
            name: remote-skill
            description: remote content
            ---

            Do not trust this body.
            """,
            source: .url("https://example.invalid/skill.md"),
            reason: "remote import"
        )

        #expect(result.receipt.state == .quarantined)
        #expect(result.skill.isEnabled == false)
        let injector = SkillInjector(store: store)
        #expect(injector.matchingSkills(for: "remote content").isEmpty)
    }

    @Test func lifecycleImportWithoutExplicitApprovalStaysProposedAndCannotInject() throws {
        let (store, root) = try makeTempStore()
        defer { try? FileManager.default.removeItem(at: root) }

        let result = try store.importSkillThroughLifecycle(
            content: sampleSkillMD,
            source: .file,
            reason: "unreviewed import"
        )

        #expect(result.receipt.state == .proposed)
        #expect(result.skill.isEnabled == false)
        #expect(SkillInjector(store: store).matchingSkills(for: "写一个图片提示词").isEmpty)
        let reloaded = SkillStore(skillsRoot: root)
        #expect(reloaded.lifecycleReceipt(for: result.skill.id)?.state == .proposed)
        #expect(reloaded.allSkills().first?.isEnabled == false)
    }

    @Test func redeployPreservesMatchingApprovedReceiptButHashChangeNeedsApproval() throws {
        let (store, root) = try makeTempStore()
        defer { try? FileManager.default.removeItem(at: root) }

        let approved = try store.importSkillThroughLifecycle(
            content: sampleSkillMD,
            source: .bundled,
            reason: "initial bundled deployment",
            approval: SkillApproval(approverID: "test-user")
        )
        store.setEnabled(approved.skill.id, enabled: false)

        let redeployed = try store.importSkillThroughLifecycle(
            content: sampleSkillMD,
            source: .bundled,
            reason: "repeat bundled deployment"
        )
        #expect(redeployed.receipt.state == .active)
        #expect(redeployed.receipt.receiptID == approved.receipt.receiptID)
        #expect(store.allSkills().first?.isEnabled == false)

        let changed = sampleSkillMD.replacingOccurrences(
            of: "Write stable Chinese prompts",
            with: "Changed bundled skill body."
        )
        let changedResult = try store.importSkillThroughLifecycle(
            content: changed,
            source: .bundled,
            reason: "changed bundled deployment"
        )
        #expect(changedResult.receipt.state == .proposed)
        #expect(changedResult.skill.isEnabled == false)
        #expect(SkillInjector(store: store).matchingSkills(for: "写一个图片提示词").isEmpty)
    }

    @Test func lifecycleReceiptPersistenceFailureRollsBackSkillFilesAndMemory() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SkillStoreReceiptFailure-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // A directory at the receipt path makes the lifecycle receipt write fail
        // after the SKILL.md write, exposing partial-import cleanup.
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("lifecycle-receipts.json"),
            withIntermediateDirectories: true
        )
        let store = SkillStore(skillsRoot: root)

        #expect(throws: SkillError.self) {
            _ = try store.importSkillThroughLifecycle(
                content: sampleSkillMD,
                source: .file,
                reason: "receipt failure"
            )
        }
        #expect(store.allSkills().isEmpty)
        #expect(!FileManager.default.fileExists(
            atPath: root.appendingPathComponent("image-prompt-writer/SKILL.md").path
        ))
    }

    @Test func activeReceiptAndContentHashAreRequiredForInjection() throws {
        let (store, root) = try makeTempStore()
        defer { try? FileManager.default.removeItem(at: root) }

        let result = try store.importSkillThroughLifecycle(
            content: sampleSkillMD,
            source: .file,
            reason: "explicit local import",
            approval: SkillApproval(approverID: "test-user")
        )
        #expect(result.receipt.state == .active)
        #expect(store.lifecycleReceipt(for: result.skill.id)?.contentHash == SkillManifest.hash(sampleSkillMD))

        try "tampered".write(
            to: store.skillDirectoryURL(for: result.skill.id).appendingPathComponent("SKILL.md"),
            atomically: true,
            encoding: .utf8
        )
        #expect(!store.isInjectable(result.skill))
        #expect(store.lifecycleReceipt(for: result.skill.id)?.state == .quarantined)
        #expect(SkillInjector(store: store).matchingSkills(for: "写一个图片提示词").isEmpty)
    }

    @Test func approvalScopeAndExpiryAreRequiredForScopedInjection() throws {
        let (store, root) = try makeTempStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let scope = MemoryScope(sessionID: "session-a", projectID: "project-a")
        let otherScope = MemoryScope(sessionID: "session-b", projectID: "project-a")

        let result = try store.importSkillThroughLifecycle(
            content: sampleSkillMD,
            source: .file,
            reason: "scoped proposal",
            scope: scope
        )
        #expect(result.receipt.state == .proposed)
        let active = try store.approveAndActivateSkill(
            result.skill.id,
            approval: SkillApproval(
                approverID: "test-user",
                scope: scope,
                expiresAt: Date().addingTimeInterval(60)
            ),
            reason: "approved scoped skill"
        )
        #expect(active.state == .active)
        let injector = SkillInjector(store: store)
        #expect(injector.matchingSkills(for: "写一个图片提示词", within: scope).count == 1)
        #expect(injector.matchingSkills(for: "写一个图片提示词", within: otherScope).isEmpty)
        #expect(injector.matchingSkills(for: "写一个图片提示词").isEmpty)
        // 匹配上但在别的作用域未批准：不注入，但要能给用户一条轻提示。
        #expect(injector.unapprovedMatchingSkillIDs(for: "写一个图片提示词", within: otherScope) == [result.skill.id])
        #expect(injector.unapprovedMatchingSkillIDs(for: "写一个图片提示词", within: scope).isEmpty)
        #expect(injector.unapprovedMatchingSkillIDs(for: "完全无关的内容 zzz", within: otherScope).isEmpty)
    }

    @Test func scopedRollbackNeedsFreshApprovalAndExplicitMatchingEnablementScope() throws {
        let formal = try #require(try FormalTestIsolationPaths.resolveCurrentProcess())
        let root = formal.temporaryDirectory.appendingPathComponent("skillb-core-enable-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SkillStore(skillsRoot: root.appendingPathComponent("skills"))
        let scope = MemoryScope(sessionID: "owned-session", projectID: "owned-project")
        let otherSession = MemoryScope(sessionID: "other-session", projectID: "owned-project")
        let otherProject = MemoryScope(sessionID: "owned-session", projectID: "other-project")
        let expiry = Date().addingTimeInterval(3600)
        let old = "---\nname: skillb-core-enable\ndescription: scoped rollback\nversion: 1.0.0\n---\nold scoped body"
        let current = "---\nname: skillb-core-enable\ndescription: global replacement\nversion: 2.0.0\n---\nnew global body"
        let previous = try store.importSkillThroughLifecycle(
            content: old, source: .bundled, reason: "old scoped version", scope: scope,
            approval: SkillApproval(approverID: "old-reviewer", scope: scope, expiresAt: expiry)
        )
        let previousManifest = try Data(contentsOf: store.skillManifestURL(for: previous.skill.id))
        _ = try store.importSkillThroughLifecycle(
            content: current, source: .file, reason: "current global version",
            approval: SkillApproval(approverID: "current-reviewer", expiresAt: expiry)
        )
        let restored = try store.rollbackSkill(previous.skill.id, reason: "restore scoped version")
        #expect(restored.state == .rolledBack)
        #expect(restored.scope == scope)
        #expect(restored.approvedBy == previous.receipt.approvedBy)
        #expect(restored.expiresAt == previous.receipt.expiresAt)
        #expect(restored.sourceIdentity == previous.receipt.sourceIdentity)
        #expect(restored.contentHash == previous.receipt.contentHash)
        #expect(store.rawContent(previous.skill.id) == old)
        #expect(try Data(contentsOf: store.skillManifestURL(for: previous.skill.id)) == previousManifest)
        #expect(store.allSkills().first { $0.id == previous.skill.id }?.importSource == .bundled)
        #expect(store.allSkills().first { $0.id == previous.skill.id }?.isEnabled == false)
        store.setEnabled(previous.skill.id, enabled: true, within: scope)
        #expect(store.allSkills().first { $0.id == previous.skill.id }?.isEnabled == false)

        let fresh = try store.importSkillThroughLifecycle(
            content: old, source: .bundled, reason: "new explicit scoped review", scope: scope,
            approval: SkillApproval(approverID: "fresh-reviewer", scope: scope, expiresAt: expiry)
        )
        #expect(fresh.receipt.state == .active)
        #expect(fresh.receipt.sourceIdentity == previous.receipt.sourceIdentity)
        #expect(store.allSkills().first { $0.id == previous.skill.id }?.isEnabled == false)
        store.setEnabled(previous.skill.id, enabled: true)
        #expect(store.allSkills().first { $0.id == previous.skill.id }?.isEnabled == false)
        store.setEnabled(previous.skill.id, enabled: true, within: otherSession)
        #expect(store.allSkills().first { $0.id == previous.skill.id }?.isEnabled == false)
        store.setEnabled(previous.skill.id, enabled: true, within: otherProject)
        #expect(store.allSkills().first { $0.id == previous.skill.id }?.isEnabled == false)

        store.setEnabled(previous.skill.id, enabled: true, within: scope)
        let enabled = try #require(store.allSkills().first { $0.id == previous.skill.id })
        #expect(enabled.isEnabled)
        #expect(store.isInjectable(enabled, within: scope))
        #expect(!store.isInjectable(enabled))
        #expect(!store.isInjectable(enabled, within: otherSession))
        #expect(!store.isInjectable(enabled, within: otherProject))
        let restarted = SkillStore(skillsRoot: store.skillsRoot)
        let durable = try #require(restarted.allSkills().first { $0.id == previous.skill.id })
        #expect(durable.isEnabled)
        #expect(restarted.isInjectable(durable, within: scope))
        #expect(!restarted.isInjectable(durable, within: otherSession))
    }

    @Test func expiredApprovalCannotActivateOrInject() throws {
        let (store, root) = try makeTempStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let result = try store.importSkillThroughLifecycle(
            content: sampleSkillMD,
            source: .file,
            reason: "expired proposal"
        )

        #expect(throws: SkillError.self) {
            _ = try store.approveAndActivateSkill(
                result.skill.id,
                approval: SkillApproval(
                    approverID: "test-user",
                    expiresAt: Date().addingTimeInterval(-1)
                ),
                reason: "expired approval"
            )
        }
        #expect(store.lifecycleReceipt(for: result.skill.id)?.state == .proposed)
        #expect(SkillInjector(store: store).matchingSkills(for: "写一个图片提示词").isEmpty)
    }

    @Test func rollbackRestoresPreviousContentAndKeepsSkillDisabled() throws {
        let (store, root) = try makeTempStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let updated = sampleSkillMD.replacingOccurrences(
            of: "Write stable Chinese prompts",
            with: "Updated skill body."
        )

        let first = try store.importSkillThroughLifecycle(
            content: sampleSkillMD,
            source: .file,
            reason: "initial",
            approval: SkillApproval(approverID: "test-user")
        )
        _ = try store.importSkillThroughLifecycle(
            content: updated,
            source: .file,
            reason: "upgrade without review"
        )
        let rollback = try store.rollbackSkill(first.skill.id, reason: "reject upgrade")

        #expect(rollback.state == .rolledBack)
        #expect(store.rawContent(first.skill.id) == sampleSkillMD)
        #expect(store.allSkills().first?.isEnabled == false)
        #expect(SkillInjector(store: store).matchingSkills(for: "写一个图片提示词").isEmpty)
    }

    @Test func disabledStateSurvivesStoreReload() throws {
        let (store, root) = try makeTempStore()
        defer { try? FileManager.default.removeItem(at: root) }

        let skill = try store.importSkill(content: sampleSkillMD, source: .file)
        store.setEnabled(skill.id, enabled: false)

        let reloaded = SkillStore(skillsRoot: root)
        #expect(reloaded.allSkills().first?.isEnabled == false)
        #expect(SkillInjector(store: reloaded).matchingSkills(for: "写一个图片提示词").isEmpty)
    }

    @Test func skillFileTraversalIsRejected() throws {
        let (store, root) = try makeTempStore()
        defer { try? FileManager.default.removeItem(at: root) }

        _ = try store.importSkill(content: sampleSkillMD, source: .file)
        let outside = root.deletingLastPathComponent().appendingPathComponent("outside.txt")
        try "secret".write(to: outside, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: outside) }

        #expect(store.readSkillFile("image-prompt-writer", relativePath: "../outside.txt") == nil)
        #expect(store.readSkillFile("image-prompt-writer", relativePath: "../../outside.txt") == nil)
    }

    @Test func zeroSkillLimitFailsClosedWithoutCrashing() throws {
        let (store, root) = try makeTempStore()
        defer { try? FileManager.default.removeItem(at: root) }

        _ = try store.importSkill(content: sampleSkillMD, source: .file)
        let injector = SkillInjector(store: store, maxInjectedSkills: 0)
        #expect(injector.matchingSkills(for: "写一个图片提示词").isEmpty)
        #expect(injector.buildInjectionFragment(for: "写一个图片提示词") == nil)
    }

    @Test func matchesByDescriptionKeyword() throws {
        let (store, root) = try makeTempStore()
        defer { try? FileManager.default.removeItem(at: root) }

        _ = try store.importSkill(content: """
        ---
        name: manju-core
        description: 漫剧/短剧/AI视频制作的铁律层。每次生产任务必须加载本层。
        ---

        # 十二条铁律
        """)
        _ = try store.importSkill(content: """
        ---
        name: blender-bridge
        description: Render 3D scenes via Blender.
        ---

        Blender body.
        """)

        let injector = SkillInjector(store: store)
        // CJK bigram matching on the Chinese description.
        // P2-5: message must reach minimumScore — 「漫剧」+「制作」= 2 bigram hits.
        let manjuHits = injector.matchingSkills(for: "帮我做漫剧分镜的制作")
        #expect(manjuHits.contains { $0.id == "manju-core" })
        // English token matching
        let blenderHits = injector.matchingSkills(for: "please render a Blender scene")
        #expect(blenderHits.contains { $0.id == "blender-bridge" })
        // No match
        #expect(injector.matchingSkills(for: "nothing relevant here").isEmpty)
    }

    @Test func buildInjectionFragmentContainsBodies() throws {
        let (store, root) = try makeTempStore()
        defer { try? FileManager.default.removeItem(at: root) }

        _ = try store.importSkill(content: sampleSkillMD)
        let injector = SkillInjector(store: store)

        let fragment = injector.buildInjectionFragment(for: "写一个图片提示词")
        #expect(fragment != nil)
        #expect(fragment?.contains("<injected_skills>") == true)
        #expect(fragment?.contains("image-prompt-writer") == true)
        #expect(fragment?.contains("Write stable Chinese prompts") == true)

        #expect(injector.buildInjectionFragment(for: "totally unrelated") == nil)
    }

    @Test func disabledSkillsAreNotInjected() throws {
        let (store, root) = try makeTempStore()
        defer { try? FileManager.default.removeItem(at: root) }

        _ = try store.importSkill(content: sampleSkillMD)
        store.setEnabled("image-prompt-writer", enabled: false)
        let injector = SkillInjector(store: store)
        #expect(injector.matchingSkills(for: "写一个图片提示词").isEmpty)
    }

    @Test func skillNameWithXMLSpecialCharsIsEscaped() throws {
        let (store, root) = try makeTempStore()
        defer { try? FileManager.default.removeItem(at: root) }

        _ = try store.importSkill(content: """
        ---
        name: A&B <C> "Quoted"
        description: special chars skill
        ---

        Body text.
        """)
        let injector = SkillInjector(store: store)
        let fragment = try #require(injector.buildInjectionFragment(for: "A&B <C> \"Quoted\" special chars"))
        // name 属性里的 & < > " 必须被转义，XML 不破
        #expect(fragment.contains("A&amp;B &lt;C&gt; &quot;Quoted&quot;"))
        #expect(!fragment.contains("name=\"A&B")) // 未转义的 & 不能出现在属性里
    }

    @Test func liveMatchingSharesOneCatalogRefreshAcrossApprovedCandidates() throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("skill-match-refresh-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let counter = SkillStoreFilesystemAccessCounter()
        let store = SkillStore(skillsRoot: root, filesystemAccessObserver: { counter.record($0) })
        var ids: [String] = []
        for index in 1...8 {
            let skill = try store.importSkill(content: "---\nname: match-\(index)\ndescription: shared needle\n---\nSynthetic body \(index).")
            ids.append(skill.id)
        }
        let injector = SkillInjector(store: store, maxInjectedSkills: ids.count)
        counter.reset()
        let matched = injector.matchingSkills(for: "shared needle")
        #expect(matched.map(\.id) == ids.sorted())
        #expect(counter.snapshot.directoryLists <= 2)
    }

    @Test func maxInjectedSkillsCapsResults() throws {
        let (store, root) = try makeTempStore()
        defer { try? FileManager.default.removeItem(at: root) }

        for i in 1...6 {
            _ = try store.importSkill(content: """
            ---
            name: skill-\(i)
            description: shares keyword alpha beta
            ---

            Body \(i).
            """)
        }
        let injector = SkillInjector(store: store, maxInjectedSkills: 3)
        let matched = injector.matchingSkills(for: "alpha beta")
        #expect(matched.count == 3)
    }

    @Test func bodyOnlyInjectionWhenBodyEmpty() throws {
        // 无 body 的 skill：injectableBodies 不产出该 skill，但 fragment 仍可含空壳
        let (store, root) = try makeTempStore()
        defer { try? FileManager.default.removeItem(at: root) }

        _ = try store.importSkill(content: """
        ---
        name: empty-body
        description: no body here
        ---
        """)
        let injector = SkillInjector(store: store)
        #expect(injector.matchingSkills(for: "no body here").map(\.id) == ["empty-body"])
        #expect(injector.injectableBodies(for: "no body here").isEmpty)
        let fragment = injector.buildInjectionFragment(for: "no body here")
        #expect(fragment?.contains("<skill name=\"empty-body\">") == true)
        #expect(fragment?.contains("</skill>") == true)
    }

    @Test func minimumScoreThresholdFiltersWeakMatches() throws {
        // P2-5: score>=minimumScore (default 2) — a single CJK bigram hit
        // (score 1) must NOT qualify; two bigram hits (score 2) must.
        let (store, root) = try makeTempStore()
        defer { try? FileManager.default.removeItem(at: root) }

        _ = try store.importSkill(content: """
        ---
        name: video-notes
        description: 视频制作笔记
        ---

        Body.
        """)
        let injector = SkillInjector(store: store)
        // desc bigrams ∩ msg bigrams = 「制作」「视频」 → score 2 ≥ 2 → passes.
        #expect(injector.matchingSkills(for: "帮我制作视频").map(\.id) == ["video-notes"])
        // 「视频」alone = 1 bigram hit → score 1 < 2 → filtered out.
        #expect(injector.matchingSkills(for: "随便看看视频").isEmpty)
        #expect(injector.buildInjectionFragment(for: "随便看看视频") == nil)
        // Threshold is configurable.
        let strict = SkillInjector(store: store, minimumScore: 3)
        #expect(strict.matchingSkills(for: "帮我制作视频").isEmpty)
        let loose = SkillInjector(store: store, minimumScore: 1)
        #expect(loose.matchingSkills(for: "随便看看视频").map(\.id) == ["video-notes"])
    }

    @Test func characterBudgetTruncatesWithOmissionMarker() throws {
        // P2-5: total injected fragment must respect maxInjectedCharacters;
        // dropped skills are counted in a 「已省略 N 篇技能」 marker.
        let (store, root) = try makeTempStore()
        defer { try? FileManager.default.removeItem(at: root) }

        // skill-1 matches strongest (2 description tokens) so rank order is
        // deterministic; its big body still fits the 800-char budget, the
        // two smaller ones do not.
        _ = try store.importSkill(content: """
        ---
        name: budget-skill-1
        description: budgetkey alpha
        ---

        \(String(repeating: "x", count: 650))
        """)
        for i in 2...3 {
            _ = try store.importSkill(content: """
            ---
            name: budget-skill-\(i)
            description: budgetkey
            ---

            \(String(repeating: "x", count: 500))
            """)
        }
        let injector = SkillInjector(store: store, maxInjectedCharacters: 800)
        let fragment = try #require(injector.buildInjectionFragment(for: "budgetkey alpha"))
        #expect(fragment.count <= 800)
        #expect(fragment.contains("budget-skill-1"))
        #expect(!fragment.contains("budget-skill-2"))
        #expect(!fragment.contains("budget-skill-3"))
        #expect(fragment.contains("已省略 2 篇技能"))
        #expect(fragment.hasSuffix("</injected_skills>"))
    }

    @Test func characterBudgetTooSmallForAnySkillReturnsNil() throws {
        // P2-5: if nothing fits the budget, inject nothing rather than a
        // marker-only fragment.
        let (store, root) = try makeTempStore()
        defer { try? FileManager.default.removeItem(at: root) }

        _ = try store.importSkill(content: """
        ---
        name: too-big
        description: budgetkey
        ---

        \(String(repeating: "y", count: 500))
        """)
        let injector = SkillInjector(store: store, maxInjectedCharacters: 200)
        #expect(injector.buildInjectionFragment(for: "budgetkey") == nil)
    }

    @Test func injectionReceiptsAreStableAndExplainBudgetDecisions() throws {
        let (store, root) = try makeTempStore()
        defer { try? FileManager.default.removeItem(at: root) }

        _ = try store.importSkill(content: """
        ---
        name: receipt-skill
        description: receipt keyword
        ---

        (String(repeating: "r", count: 180))
        """)

        let injector = SkillInjector(store: store, maxInjectedCharacters: 800)
        let first = injector.buildInjection(for: "receipt keyword")
        let second = injector.buildInjection(for: "receipt keyword")
        #expect(first.receipts == second.receipts)
        let receipt = try #require(first.receipts.first)
        #expect(receipt.injected)
        #expect(!receipt.skipped)
        #expect(receipt.reason == nil)
        #expect(receipt.hash == receipt.contentHash)

        let skipped = SkillInjector(store: store, maxCharactersPerSkill: 20)
            .buildInjection(for: "receipt keyword")
        let skippedReceipt = try #require(skipped.receipts.first)
        #expect(skippedReceipt.skipped)
        #expect(skippedReceipt.reason == "skill_character_budget")
        #expect(skippedReceipt.hash == skippedReceipt.contentHash)
    }
}

// Swift Testing helper: skip a test when a precondition isn't met.
struct SkipConfirmationError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// The existing filesystem observer runs immediately before SkillStore's
/// actual primitive. It records that executor synchronously, without a hop.
private final class SkillSnapshotThread709Probe: @unchecked Sendable {
    private let lock = NSLock()
    private var fileReads = 0
    private var mainFileReads = 0

    func record(_ access: SkillStoreFilesystemAccess) {
        guard case .fileRead = access else { return }
        let isMain = Thread.isMainThread
        lock.withLock {
            fileReads += 1
            if isMain { mainFileReads += 1 }
        }
    }

    func reset() { lock.withLock { fileReads = 0; mainFileReads = 0 } }
    var counts: (reads: Int, mainReads: Int) {
        lock.withLock { (fileReads, mainFileReads) }
    }
}

struct SkillSnapshotPreprocessing709Tests {
    @Test("Normal turn's actual immutable Skill capture must not perform filesystem reads on the UI actor")
    @MainActor
    func normalTurnSkillSnapshotReadsLeaveMainThread() async throws {
        // Own formal runtime only. This fixture never discovers a real skill
        // directory, user environment credential, network or Keychain value.
        let rootPath = try #require(ProcessInfo.processInfo.environment["MINISCANVAS_TEST_DIRECTORY"])
        let rawRoot = URL(fileURLWithPath: rootPath, isDirectory: true)
            .appendingPathComponent("SkillSnapshot709-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rawRoot, withIntermediateDirectories: true)
        let root = try canonicalOwnedFixtureURL709(rawRoot)
        let probe = SkillSnapshotThread709Probe()
        let store = SkillStore(skillsRoot: root, filesystemAccessObserver: { probe.record($0) })
        _ = try store.importSkill(content: sampleSkillMD)
        let content = String(repeating: "owned reference line\n", count: 8_192)
        for name in ["one.md", "two.md"] {
            let file = root.appendingPathComponent("image-prompt-writer/references/\(name)")
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try content.write(to: file, atomically: true, encoding: .utf8)
        }
        let injector = SkillInjector(store: store)
        probe.reset()
        // Capture is the cheap BridgeStore MainActor boundary; preparation
        // invokes the real production worker, without a detached test hop.
        let preparation = injector.captureTurnPreparation()
        #expect(probe.counts.reads == 0)
        let frozen = try #require(await preparation.prepare())
        let captured = probe.counts
        print("TASK709_SKILL_SNAPSHOT_READS=\(captured.reads) MAIN_READS=\(captured.mainReads)")
        // Three owned payload reads plus two shared enablement read attempts.
        #expect(captured.reads == 5)
        #expect(captured.mainReads == 0)
        probe.reset()
        #expect(frozen.store.readSkillFile("image-prompt-writer", relativePath: "references/one.md") == content)
        #expect(frozen.store.readSkillFile("image-prompt-writer", relativePath: "references/two.md") == content)
        #expect(probe.counts.reads == 0)
    }
}


/// Blocks only the actual worker read primitive, never the MainActor. Awaiting
/// the owned preparation Task (not a sleep) witnesses completion/publication.
private final class SkillReadGate709: @unchecked Sendable {
    private let lock = NSLock()
    private let releaseRead = DispatchSemaphore(value: 0)
    private var armed = false
    private var didEnter = false
    private var readsToSkip = 1
    var entered: Bool { lock.withLock { didEnter } }
    func arm() { lock.withLock { armed = true } }
    func release() { releaseRead.signal() }
    func observe(_ access: SkillStoreFilesystemAccess) {
        guard case .fileRead = access else { return }
        let shouldWait = lock.withLock {
            guard armed, !didEnter else { return false }
            if readsToSkip > 0 { readsToSkip -= 1; return false }
            didEnter = true
            return true
        }
        if shouldWait, !Thread.isMainThread { releaseRead.wait() }
    }
}

extension SkillSnapshotPreprocessing709Tests {
    private func gatedStore(_ gate: SkillReadGate709) throws -> (SkillStore, URL, String) {
        let parent = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["MINISCANVAS_TEST_DIRECTORY"]))
            .appendingPathComponent("SkillGate709-\(UUID().uuidString)")
        let store = SkillStore(skillsRoot: parent.appendingPathComponent("skills"),
            filesystemAccessObserver: { gate.observe($0) })
        let skill = try store.importSkill(content: sampleSkillMD)
        return (store, parent, skill.id)
    }
    private func waitForRead(_ gate: SkillReadGate709) async throws {
        for _ in 0..<200 {
            if gate.entered { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(gate.entered, "production file read never entered")
    }

    @Test @MainActor
    func cancelledActualReadCannotReturnAFrozenStore() async throws {
        let gate = SkillReadGate709()
        let (store, _, _) = try gatedStore(gate)
        let input = SkillInjector(store: store).captureTurnPreparation()
        gate.arm()
        let task = Task { await input.prepare() }
        defer { gate.release() }
        try await waitForRead(gate)
        task.cancel(); gate.release()
        #expect(await task.value == nil)
        #expect(input.matchesCurrentStore(store))
    }

    @Test @MainActor
    func disableEnableABACannotRestoreAnOldCaptureAuthority() async throws {
        let gate = SkillReadGate709()
        let (store, _, id) = try gatedStore(gate)
        let input = SkillInjector(store: store).captureTurnPreparation()
        gate.arm()
        let task = Task { await input.prepare() }
        defer { gate.release() }
        try await waitForRead(gate)
        store.setEnabled(id, enabled: false)
        store.setEnabled(id, enabled: true)
        gate.release()
        let frozen = try #require(await task.value)
        #expect(frozen.store.allSkills().first?.isEnabled == true)
        #expect(!input.matchesCurrentStore(store))
        #expect(SkillInjector(store: store).captureTurnPreparation().matchesCurrentStore(store))
    }

    @Test @MainActor
    func sharedProjectionMayRevokeButCannotExpandCopiedAuthority() async throws {
        let gate = SkillReadGate709()
        let (store, parent, id) = try gatedStore(gate)
        let stateURL = parent.appendingPathComponent("skills-enabled.json")
        let initial = SkillInjector(store: store).captureTurnPreparation()
        try JSONEncoder().encode(["app:\(id)": false]).write(to: stateURL, options: .atomic)
        let disabled = try #require(await initial.prepare())
        #expect(disabled.buildInjectionFragment(for: "image-prompt-writer") == nil)
        store.setEnabled(id, enabled: false)
        let copiedDisabled = SkillInjector(store: store).captureTurnPreparation()
        try JSONEncoder().encode(["app:\(id)": true]).write(to: stateURL, options: .atomic)
        let cannotExpand = try #require(await copiedDisabled.prepare())
        #expect(cannotExpand.buildInjectionFragment(for: "image-prompt-writer") == nil)
        // A new explicit existing lifecycle-authorized enable is legitimate.
        store.setEnabled(id, enabled: true)
        let fresh = try #require(await SkillInjector(store: store).captureTurnPreparation().prepare())
        #expect(fresh.buildInjectionFragment(for: "image-prompt-writer") != nil)
    }

    @Test @MainActor
    func sharedProjectionChangingDuringActualReadRejectsPreparation() async throws {
        let gate = SkillReadGate709()
        let (store, parent, id) = try gatedStore(gate)
        let stateURL = parent.appendingPathComponent("skills-enabled.json")
        try JSONEncoder().encode(["app:\(id)": true]).write(to: stateURL, options: .atomic)
        let input = SkillInjector(store: store).captureTurnPreparation()
        gate.arm()
        let task = Task { await input.prepare() }
        defer { gate.release() }
        try await waitForRead(gate)
        try JSONEncoder().encode(["app:\(id)": false]).write(to: stateURL, options: .atomic)
        gate.release()
        #expect(await task.value == nil)
    }
}

// Formal test roots may use a data-volume spelling that Foundation does not
// preserve in canonical policy URLs or enumerated child URL components.
// Normalize only this already-created owned fixture object; never a production
// allow-root or runner environment. Refuse any physical identity change.
private func canonicalOwnedFixtureURL709(_ raw: URL) throws -> URL {
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
        "helper": "canonicalOwnedFixtureURL709",
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
