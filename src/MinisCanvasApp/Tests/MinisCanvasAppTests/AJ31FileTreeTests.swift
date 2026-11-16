import Testing
import Foundation
@testable import MinisCanvasApp

// MARK: - AJ-31 文件树 tab：目录遍历 / 搜索过滤 / 预览（纯逻辑）

/// 造测试目录树，返回 (根 URL, 清理闭包)。
private func makeTreeDir() throws -> URL {
    let fm = FileManager.default
    let dir = fm.temporaryDirectory.appendingPathComponent("aj31-tree-\(UUID().uuidString)", isDirectory: true)
    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    // 文件
    try Data("hello".utf8).write(to: dir.appendingPathComponent("a.txt"))
    try Data("{\"name\":\"x\"}".utf8).write(to: dir.appendingPathComponent("config.json"))
    try Data("img".utf8).write(to: dir.appendingPathComponent("pic.png"))
    // 子目录
    let sub = dir.appendingPathComponent("src", isDirectory: true)
    try fm.createDirectory(at: sub, withIntermediateDirectories: true)
    try Data("x".utf8).write(to: sub.appendingPathComponent("main.swift"))
    try Data("y".utf8).write(to: sub.appendingPathComponent("note.md"))
    // 隐藏目录
    let hidden = dir.appendingPathComponent(".git", isDirectory: true)
    try fm.createDirectory(at: hidden, withIntermediateDirectories: true)
    try Data("z".utf8).write(to: hidden.appendingPathComponent("head"))
    return dir
}

@Suite("AJ-31 目录树扫描")
struct FileTreeScanTests {
    @Test func scanBuildsSortedTreeAndSkipsHidden() throws {
        let root = try makeTreeDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let nodes = FileTreeLogic.scanDirectory(at: root)
        // 根下：a.txt / config.json / pic.png / src（.git 被跳过）
        #expect(nodes.count == 4)
        // 排序：目录 src 也在其中
        #expect(nodes.contains { $0.name == "src" && $0.isDirectory })
        #expect(nodes.contains { $0.name == "a.txt" && !$0.isDirectory })
        #expect(!nodes.contains { $0.name == ".git" })

        if let src = nodes.first(where: { $0.name == "src" }) {
            #expect(src.children.count == 2)
            #expect(src.children.contains { $0.name == "main.swift" })
            #expect(src.children.contains { $0.name == "note.md" })
        } else {
            Issue.record("src 目录未找到")
        }
    }

    @Test func scanNonexistentReturnsEmpty() {
        let bad = URL(fileURLWithPath: "/nonexistent-aj31-\(UUID().uuidString)")
        #expect(FileTreeLogic.scanDirectory(at: bad).isEmpty)
    }
}

@Suite("AJ-31 搜索过滤")
struct FileTreeFilterTests {
    @Test func emptyQueryReturnsAll() throws {
        let root = try makeTreeDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let nodes = FileTreeLogic.scanDirectory(at: root)
        let filtered = FileTreeLogic.filter(nodes: nodes, query: "   ")
        #expect(filtered.count == nodes.count)
    }

    @Test func filterMatchesFilenameCaseInsensitive() throws {
        let root = try makeTreeDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let nodes = FileTreeLogic.scanDirectory(at: root)

        // 匹配 "config" → 只有 config.json
        let byConfig = FileTreeLogic.filter(nodes: nodes, query: "config")
        #expect(byConfig.count == 1)
        #expect(byConfig[0].name == "config.json")

        // 大小写不敏感：MAIN
        let nodes2 = FileTreeLogic.scanDirectory(at: root)
        let byMain = FileTreeLogic.filter(nodes: nodes2, query: "MAIN")
        #expect(byMain.count == 1)
        #expect(byMain[0].name == "src")
        #expect(byMain[0].children.count == 1)
        #expect(byMain[0].children[0].name == "main.swift")
    }

    @Test func filterNoMatchReturnsEmpty() throws {
        let root = try makeTreeDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let nodes = FileTreeLogic.scanDirectory(at: root)
        #expect(FileTreeLogic.filter(nodes: nodes, query: "zzz-not-exist").isEmpty)
    }
}

@Suite("AJ-31 文件类型 / 预览")
struct FileKindAndPreviewTests {
    @Test func kindClassifiesByExtension() {
        #expect(FileKind(url: URL(fileURLWithPath: "/x/config.json")) == .json)
        #expect(FileKind(url: URL(fileURLWithPath: "/x/pic.png")) == .image)
        #expect(FileKind(url: URL(fileURLWithPath: "/x/a.txt")) == .text)
        #expect(FileKind(url: URL(fileURLWithPath: "/x/a.info")) == .other)
    }

    @Test func textDecodesUtf8AndTruncates() throws {
        let s = String(repeating: "a", count: 300)
        let data = Data(s.utf8)
        #expect(FilePreview.text(from: data) == s)
        let short = FilePreview.truncated(s, limit: 10)
        #expect(short.count == 10)
    }

    @Test func loadReadsTextAndImageKinds() throws {
        let root = try makeTreeDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let txt = FilePreview.load(url: root.appendingPathComponent("a.txt"))
        #expect(txt.kind == .text)
        #expect(txt.text == "hello")
        #expect(txt.error == nil)

        let json = FilePreview.load(url: root.appendingPathComponent("config.json"))
        #expect(json.kind == .json)
        #expect(json.text?.contains("name") == true)

        let img = FilePreview.load(url: root.appendingPathComponent("pic.png"))
        #expect(img.kind == .image)
        #expect(img.imageData != nil)

        let missing = FilePreview.load(url: root.appendingPathComponent("nope.txt"))
        #expect(missing.error != nil)
    }
}