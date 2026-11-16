import Foundation
import Testing
@testable import MinisCore

/// Unique temp directory per test (tests run in parallel; never share paths).
private func makeTempDir(_ name: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("MinisCore-\(name)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

// MARK: - File type classification

struct FileTypeClassificationTests {

    @Test func classifiesTextExtensions() {
        #expect(FileImporter.classify(url: URL(fileURLWithPath: "/tmp/notes.txt")) == .text)
        #expect(FileImporter.classify(url: URL(fileURLWithPath: "/tmp/app.log")) == .text)
        #expect(FileImporter.classify(url: URL(fileURLWithPath: "/tmp/data.csv")) == .text)
        #expect(FileImporter.classify(url: URL(fileURLWithPath: "/tmp/style.css")) == .text)
        #expect(FileImporter.classify(url: URL(fileURLWithPath: "/tmp/main.swift")) == .text)
    }

    @Test func classifiesMarkdownExtensions() {
        #expect(FileImporter.classify(url: URL(fileURLWithPath: "/tmp/README.md")) == .markdown)
        #expect(FileImporter.classify(url: URL(fileURLWithPath: "/tmp/doc.markdown")) == .markdown)
        #expect(FileImporter.classify(url: URL(fileURLWithPath: "/tmp/notes.mkd")) == .markdown)
    }

    @Test func classifiesJSONExtensions() {
        #expect(FileImporter.classify(url: URL(fileURLWithPath: "/tmp/config.json")) == .json)
        #expect(FileImporter.classify(url: URL(fileURLWithPath: "/tmp/events.jsonl")) == .json)
        #expect(FileImporter.classify(url: URL(fileURLWithPath: "/tmp/map.geojson")) == .json)
    }

    @Test func classifiesMediaExtensions() {
        #expect(FileImporter.classify(url: URL(fileURLWithPath: "/tmp/photo.png")) == .image)
        #expect(FileImporter.classify(url: URL(fileURLWithPath: "/tmp/photo.JPG")) == .image) // case-insensitive
        #expect(FileImporter.classify(url: URL(fileURLWithPath: "/tmp/anim.webp")) == .image)
        #expect(FileImporter.classify(url: URL(fileURLWithPath: "/tmp/song.mp3")) == .audio)
        #expect(FileImporter.classify(url: URL(fileURLWithPath: "/tmp/voice.m4a")) == .audio)
        #expect(FileImporter.classify(url: URL(fileURLWithPath: "/tmp/movie.mp4")) == .video)
        #expect(FileImporter.classify(url: URL(fileURLWithPath: "/tmp/clip.mov")) == .video)
    }

    @Test func unknownExtensionFallsBackToUnknown() {
        #expect(FileImporter.classify(url: URL(fileURLWithPath: "/tmp/blob.xyz")) == .unknown)
        #expect(FileImporter.classify(url: URL(fileURLWithPath: "/tmp/noextension")) == .unknown)
    }

    @Test func mimeTypeClassification() {
        #expect(FileImporter.type(forMIME: "text/plain") == .text)
        #expect(FileImporter.type(forMIME: "text/markdown") == .markdown)
        #expect(FileImporter.type(forMIME: "application/json") == .json)
        #expect(FileImporter.type(forMIME: "application/ld+json") == .json)
        #expect(FileImporter.type(forMIME: "image/png") == .image)
        #expect(FileImporter.type(forMIME: "audio/wav") == .audio)
        #expect(FileImporter.type(forMIME: "video/mp4") == .video)
        #expect(FileImporter.type(forMIME: "application/pdf") == nil)
    }

    @Test func mimeSniffFromMagicBytes() throws {
        let dir = try makeTempDir("MimeSniff")
        defer { try? FileManager.default.removeItem(at: dir) }

        let png = dir.appendingPathComponent("magic.png")
        // Minimal PNG signature (8 bytes) + padding.
        try Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x00]).write(to: png)
        #expect(FileImporter.mimeType(of: png) == "image/png")

        let jpeg = dir.appendingPathComponent("magic.jpg")
        try Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]).write(to: jpeg)
        #expect(FileImporter.mimeType(of: jpeg) == "image/jpeg")

        // Extensionless file with known magic bytes still classifies.
        let bare = dir.appendingPathComponent("extensionless")
        try Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x00]).write(to: bare)
        #expect(FileImporter.mimeType(of: bare) == "image/png")
        #expect(FileImporter.classify(url: bare) == .image)
    }
}

// MARK: - File import (copy)

struct FileImportTests {

    @Test func importFileCopiesIntoDestination() throws {
        let dir = try makeTempDir("ImportCopy")
        defer { try? FileManager.default.removeItem(at: dir) }

        let source = dir.appendingPathComponent("draft.md")
        try "# Hello\n\nBody text".write(to: source, atomically: true, encoding: .utf8)

        let inbox = dir.appendingPathComponent("Inbox", isDirectory: true)
        let imported = try FileImporter.importFile(from: source, to: inbox)

        // Destination exists, content matches, extension preserved.
        #expect(FileManager.default.fileExists(atPath: imported.path))
        #expect(imported.pathExtension == "md")
        #expect(try String(contentsOf: imported, encoding: .utf8) == "# Hello\n\nBody text")
        // Original untouched.
        #expect(try String(contentsOf: source, encoding: .utf8) == "# Hello\n\nBody text")
    }

    @Test func importFileUniqueNamesDoNotCollide() throws {
        let dir = try makeTempDir("ImportUnique")
        defer { try? FileManager.default.removeItem(at: dir) }

        let source = dir.appendingPathComponent("note.txt")
        try "one".write(to: source, atomically: true, encoding: .utf8)

        let inbox = dir.appendingPathComponent("Inbox", isDirectory: true)
        let first = try FileImporter.importFile(from: source, to: inbox)
        let second = try FileImporter.importFile(from: source, to: inbox)

        #expect(first != second)
        #expect(FileManager.default.fileExists(atPath: first.path))
        #expect(FileManager.default.fileExists(atPath: second.path))
        #expect(try String(contentsOf: second, encoding: .utf8) == "one")
    }

    @Test func importFileRejectsNonFileURL() {
        #expect(throws: FileImportError.self) {
            try FileImporter.importFile(
                from: URL(string: "https://example.com/file.txt")!,
                to: FileManager.default.temporaryDirectory
            )
        }
    }

    @Test func describeReportsTypeAndSize() throws {
        let dir = try makeTempDir("Describe")
        defer { try? FileManager.default.removeItem(at: dir) }

        let source = dir.appendingPathComponent("data.json")
        try #"{"a":1}"#.write(to: source, atomically: true, encoding: .utf8)

        let described = FileImporter.describe(url: source)
        #expect(described.type == .json)
        #expect(described.suggestedName == "data.json")
        #expect(described.size == 7)
    }
}

// MARK: - Markdown import

struct MarkdownImporterTests {

    @Test func parsesTitleAndSections() {
        let md = """
        # My Document

        Intro paragraph before any section.

        ## Section One

        First section body.

        ### Sub Point

        Nested content under a subsection.

        ## Section Two

        Second section body.
        """
        let content = MarkdownImporter.importMarkdown(md)

        #expect(content.title == "My Document")
        #expect(content.sections.count == 4)
        #expect(content.sections[0].contains("Intro paragraph"))
        #expect(content.sections[1].contains("## Section One"))
        #expect(content.sections[1].contains("First section body."))
        #expect(content.sections[2].contains("### Sub Point"))
        #expect(content.sections[3].contains("## Section Two"))
        #expect(content.fullText.hasPrefix("# My Document"))
    }

    @Test func titleOnlyMarkdownHasNoSections() {
        let content = MarkdownImporter.importMarkdown("# Just a Title")
        #expect(content.title == "Just a Title")
        #expect(content.sections.isEmpty)
        #expect(content.fullText == "# Just a Title")
    }

    @Test func markdownWithoutTitleHasNoTitle() {
        let content = MarkdownImporter.importMarkdown("Plain paragraph one.\n\nPlain paragraph two.")
        #expect(content.title == nil)
        #expect(content.sections.count == 1)
        #expect(content.sections[0].contains("Plain paragraph one."))
    }

    @Test func secondLevelHeadingBecomesTitle() {
        // First `#` heading anywhere wins as title.
        let md = "Preamble text.\n\n# The Title\n\n## Sub\n\nBody."
        let content = MarkdownImporter.importMarkdown(md)
        #expect(content.title == "The Title")
        #expect(content.sections.count == 2)
        #expect(content.sections[0].contains("Preamble text."))
        #expect(content.sections[1].contains("## Sub"))
    }

    @Test func importPlainTextSplitsParagraphs() {
        let content = MarkdownImporter.importPlainText("Para one.\n\nPara two.\n\nPara three.")
        #expect(content.title == nil)
        #expect(content.sections == ["Para one.", "Para two.", "Para three."])
        #expect(content.fullText == "Para one.\n\nPara two.\n\nPara three.")
    }

    @Test func importFileReadsMarkdownFromDisk() throws {
        let dir = try makeTempDir("MarkdownFile")
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = dir.appendingPathComponent("readme.md")
        try "# Project\n\n## Setup\n\nRun it.".write(to: url, atomically: true, encoding: .utf8)

        let content = try MarkdownImporter.importFile(at: url)
        #expect(content.title == "Project")
        #expect(content.sections.count == 1)
        #expect(content.sections[0].contains("## Setup"))
        #expect(content.sections[0].contains("Run it."))
    }
}

// MARK: - Share bridge

struct ShareBridgeTests {

    @Test func exportTextPayload() {
        let payload = ShareBridge.exportText("hello world", title: "Greeting")
        #expect(payload.type == .text)
        #expect(payload.title == "Greeting")
        #expect(payload.content == "hello world")
        #expect(payload.dataPath == nil)
    }

    @Test func exportJSONPayloadFromEncodable() throws {
        struct Note: Encodable {
            let id: Int
            let body: String
        }
        let payload = try ShareBridge.exportJSON(Note(id: 1, body: "hi"), title: "Note 1")
        #expect(payload.type == .json)
        #expect(payload.content.contains("\"id\":1"))
        #expect(payload.content.contains("\"body\":\"hi\""))
    }

    @Test func exportTextWritesFile() throws {
        let dir = try makeTempDir("ShareText")
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = try ShareBridge.exportText("shared text", to: dir, fileName: "note.txt")
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(url.pathExtension == "txt")
        #expect(try String(contentsOf: url, encoding: .utf8) == "shared text")
    }

    @Test func exportJSONWritesValidJSONFile() throws {
        let dir = try makeTempDir("ShareJSON")
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = try ShareBridge.exportJSON(["a": 1, "b": 2], to: dir, fileName: "payload.json")
        let data = try Data(contentsOf: url)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Int]
        #expect(object?["a"] == 1)
        #expect(object?["b"] == 2)
    }

    @Test func writeCollisionGetsNumericSuffix() throws {
        let dir = try makeTempDir("ShareCollision")
        defer { try? FileManager.default.removeItem(at: dir) }

        let first = try ShareBridge.write(Data("first".utf8), to: dir, fileName: "doc.txt")
        let second = try ShareBridge.write(Data("second".utf8), to: dir, fileName: "doc.txt")

        #expect(first.lastPathComponent == "doc.txt")
        #expect(second.lastPathComponent == "doc-1.txt")
        #expect(try String(contentsOf: second, encoding: .utf8) == "second")
    }

    @Test func stageTextPayloadWritesFile() throws {
        let dir = try makeTempDir("ShareStage")
        defer { try? FileManager.default.removeItem(at: dir) }

        let payload = ShareBridge.exportText("to share", title: "My Notes")
        let staged = try ShareBridge.stage(payload, to: dir)

        #expect(staged.dataPath != nil)
        #expect(FileManager.default.fileExists(atPath: staged.dataPath!))
        #expect(staged.dataPath!.hasSuffix(".txt"))
        #expect(try String(contentsOf: URL(fileURLWithPath: staged.dataPath!), encoding: .utf8) == "to share")
    }

    @Test func sanitizedTitleBecomesSafeFileName() {
        #expect(ShareBridge.sanitized("My Notes") == "My-Notes")
        #expect(ShareBridge.sanitized("a/b/c") == "abc")
        #expect(ShareBridge.sanitized("   ") == "share")
        #expect(ShareBridge.sanitized("日本語 ドキュメント") == "日本語-ドキュメント")
    }
}
