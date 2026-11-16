import Foundation
import Darwin
import Testing
@testable import MinisCore

private func makeMemoryFileStoreTestDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("MinisCore-MemoryFileStoreTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

struct MemoryFileStoreTests {

    enum NonDocumentEntry: CaseIterable, Sendable {
        case globalDirectory, soulDirectory, dailyDirectory
        case outsideFileLink, outsideDailyLink
        case insideFileLink
    }

    @Test(arguments: NonDocumentEntry.allCases)
    func listedDocumentsExcludeNonFilesAndEscapedTargetsAcrossReopen(entry: NonDocumentEntry) throws {
        let directory = try makeMemoryFileStoreTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let manager = FileManager.default
        let store = MemoryFileStore(directory: directory)
        var expected = [
            "GLOBAL.md": "全局原文🧠\n第二行",
            "SOUL.md": "角色原文🌱\n第二行",
            "daily/2026-08-22.md": "日志原文📝\n第二行"
        ]
        for (path, content) in expected {
            #expect(try store.writeDocument(named: path, content: content))
        }
        let outside = directory.appendingPathComponent("outside", isDirectory: true)
        try manager.createDirectory(at: outside, withIntermediateDirectories: true)
        let outsideFile = outside.appendingPathComponent("foreign.md")
        let outsideBytes = Data("外域文件不得进入列表".utf8)
        try outsideBytes.write(to: outsideFile)
        var sentinel: URL?
        switch entry {
        case .globalDirectory, .soulDirectory, .dailyDirectory:
            let path = entry == .globalDirectory ? "GLOBAL.md"
                : entry == .soulDirectory ? "SOUL.md" : "daily/2026-08-22.md"
            expected.removeValue(forKey: path)
            let target = store.memoryDirectory.appendingPathComponent(path)
            try manager.removeItem(at: target)
            try manager.createDirectory(at: target, withIntermediateDirectories: false)
            let protectedChild = target.appendingPathComponent("sentinel")
            try Data("目录子文件保持".utf8).write(to: protectedChild)
            sentinel = protectedChild
        case .outsideFileLink:
            try manager.createSymbolicLink(
                at: store.dailyDirectory.appendingPathComponent("foreign.md"),
                withDestinationURL: outsideFile
            )
        case .outsideDailyLink:
            expected.removeValue(forKey: "daily/2026-08-22.md")
            try manager.moveItem(at: store.dailyDirectory,
                                 to: directory.appendingPathComponent("preserved-daily"))
            try manager.createSymbolicLink(at: store.dailyDirectory, withDestinationURL: outside)
        case .insideFileLink:
            let path = "daily/inside.md"
            expected[path] = expected["GLOBAL.md"]
            try manager.createSymbolicLink(
                at: store.memoryDirectory.appendingPathComponent(path),
                withDestinationURL: store.globalURL
            )
        }

        for consumer in [store, MemoryFileStore(directory: directory)] {
            let files = consumer.listFiles()
            #expect(Set(files.map(\.relativePath)) == Set(expected.keys))
            for file in files {
                let content = try #require(expected[file.relativePath])
                #expect(file.id == file.relativePath)
                #expect(file.name == URL(fileURLWithPath: file.relativePath).lastPathComponent)
                let expectedKind: MemoryFileKind = file.relativePath == "GLOBAL.md" ? .global
                    : file.relativePath == "SOUL.md" ? .soul : .daily
                #expect(file.kind == expectedKind)
                #expect(file.byteCount == Data(content.utf8).count)
                #expect(file.preview == content.components(separatedBy: "\n").first)
                #expect(consumer.readDocument(named: file.relativePath) == content)
                #expect(try Data(contentsOf: consumer.memoryDirectory.appendingPathComponent(file.relativePath))
                        == Data(content.utf8))
            }
        }
        #expect(try Data(contentsOf: outsideFile) == outsideBytes)
        if let sentinel {
            #expect(try Data(contentsOf: sentinel) == Data("目录子文件保持".utf8))
        }
    }

    @Test func dailyLogCreatesAppendsUnicodeAndReopens() throws {
        let directory = try makeMemoryFileStoreTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let date = Date(timeIntervalSinceReferenceDate: 0)
        let store = MemoryFileStore(directory: directory)

        let url = try store.appendToDailyLog("第一条记忆", date: date)
        try store.appendToDailyLog("第二条记忆", date: date)
        let expected = "# 每日记忆 2001-01-01\n\n- 第一条记忆\n- 第二条记忆\n"
        #expect(url == store.dailyURL(for: date))
        #expect(store.readDaily(for: date) == expected)

        let reopened = MemoryFileStore(directory: directory)
        #expect(reopened.readDaily(for: date) == expected)
        try reopened.appendToDailyLog("重开后追加", date: date)
        #expect(reopened.readDaily(for: date) == expected + "- 重开后追加\n")
    }

    @Test func dailyLogSerializesConcurrentAppendsOnOneStore() async throws {
        let directory = try makeMemoryFileStoreTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let date = Date(timeIntervalSinceReferenceDate: 86_400)
        let store = MemoryFileStore(directory: directory)

        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<20 {
                group.addTask {
                    try store.appendToDailyLog("并发-\(index)", date: date)
                }
            }
            try await group.waitForAll()
        }

        let content = store.readDaily(for: date)
        #expect(content.hasPrefix("# 每日记忆 2001-01-02\n\n"))
        #expect(content.hasSuffix("\n"))
        // split omits empty lines; the blank separator is checked above.
        let lines = content.split(whereSeparator: \.isNewline)
        #expect(lines.first == "# 每日记忆 2001-01-02")
        #expect(lines.count == 21)
        let entries = lines.dropFirst().map(String.init)
        #expect(entries.count == 20)
        #expect(Set(entries) == Set((0..<20).map { "- 并发-\($0)" }))
        #expect(MemoryFileStore(directory: directory).readDaily(for: date) == content)
    }

    @Test func dailyLogRejectsExistingInvalidUTF8WithoutOverwritingAcrossReopen() throws {
        let directory = try makeMemoryFileStoreTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let date = Date(timeIntervalSinceReferenceDate: 2 * 86_400)
        let store = MemoryFileStore(directory: directory)
        let url = try store.ensureDailyLog(for: date)
        let invalidBytes = Data([0x23, 0x20, 0xc3, 0x28, 0x0a])
        try invalidBytes.write(to: url, options: .atomic)

        #expect(throws: (any Error).self) {
            try store.appendToDailyLog("不得覆盖", date: date)
        }
        #expect(try Data(contentsOf: url) == invalidBytes)

        let reopened = MemoryFileStore(directory: directory)
        #expect(throws: (any Error).self) {
            try reopened.appendToDailyLog("重开也不得覆盖", date: date)
        }
        #expect(try Data(contentsOf: url) == invalidBytes)
    }

    @Test func dailyLogRejectsExistingReadFailureWithoutReplacingDirectoryAcrossReopen() throws {
        let directory = try makeMemoryFileStoreTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let date = Date(timeIntervalSinceReferenceDate: 3 * 86_400)
        let store = MemoryFileStore(directory: directory)
        let url = try store.ensureDailyLog(for: date)
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)

        #expect(throws: (any Error).self) {
            try store.appendToDailyLog("不得替换目录", date: date)
        }
        var info = stat()
        #expect(Darwin.lstat(url.path, &info) == 0)
        #expect((info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR))

        let reopened = MemoryFileStore(directory: directory)
        #expect(throws: (any Error).self) {
            try reopened.appendToDailyLog("重开也不得替换目录", date: date)
        }
        var reopenedInfo = stat()
        #expect(Darwin.lstat(url.path, &reopenedInfo) == 0)
        #expect((reopenedInfo.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR))
    }

    @Test func validDocumentsReadWriteAndDelete() throws {
        let directory = try makeMemoryFileStoreTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MemoryFileStore(directory: directory)

        #expect(try store.writeDocument(named: "GLOBAL.md", content: "global") == true)
        #expect(store.readDocument(named: "GLOBAL.md") == "global")
        #expect(try store.writeDocument(named: "2026-08-22.md", content: "daily") == true)
        #expect(store.readDocument(named: "daily/2026-08-22.md") == "daily")
        #expect(try store.deleteDocument(named: "daily/2026-08-22.md") == true)
        #expect(store.readDocument(named: "2026-08-22.md") == nil)
    }

    @Test(arguments: ["GLOBAL.md", "SOUL.md"])
    func firstDocumentCreationKeepsContainmentAcrossDarwinAliasReopen(basename: String) throws {
        let directory = try makeMemoryFileStoreTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        // Match the profile's explicit `/private` spelling independently of
        // the store's guard; do not precreate the missing memory directory.
        let path = directory.path
        let physicalPath = path.hasPrefix("/var/") || path.hasPrefix("/tmp/")
            ? "/private" + path : path
        let optionalAliasPath = physicalPath.hasPrefix("/private/var/") || physicalPath.hasPrefix("/private/tmp/")
            ? String(physicalPath.dropFirst("/private".count)) : nil
        let aliasPath = try #require(optionalAliasPath)
        let physicalDirectory = URL(fileURLWithPath: physicalPath, isDirectory: true)
        let aliasDirectory = URL(fileURLWithPath: aliasPath, isDirectory: true)
        let store = MemoryFileStore(directory: physicalDirectory)
        #expect(!FileManager.default.fileExists(atPath: store.memoryDirectory.path))
        #expect(!FileManager.default.fileExists(atPath: store.dailyDirectory.path))
        let original = "首次创建🧠 " + basename
        #expect(try store.writeDocument(named: basename, content: original))
        let rootBytes = try Data(contentsOf: store.memoryDirectory.appendingPathComponent(basename))
        #expect(rootBytes == Data(original.utf8))

        let reopened = MemoryFileStore(directory: aliasDirectory)
        #expect(reopened.readDocument(named: basename) == original)
        let dailyPath = "daily/" + basename
        #expect(try reopened.writeDocument(named: dailyPath, content: "同名日志🌱"))
        #expect(try Data(contentsOf: store.memoryDirectory.appendingPathComponent(basename)) == rootBytes)
        let fresh = MemoryFileStore(directory: physicalDirectory)
        #expect(fresh.readDocument(named: dailyPath) == "同名日志🌱")
        #expect(Set(fresh.listFiles().map(\.relativePath)) == [basename, dailyPath])
        #expect(try fresh.deleteDocument(named: dailyPath))
        #expect(MemoryFileStore(directory: aliasDirectory).readDocument(named: dailyPath) == nil)
        #expect(try Data(contentsOf: store.memoryDirectory.appendingPathComponent(basename)) == rootBytes)
    }

    @Test func listFilesIncludesGlobalSoulAndDailyDocuments() throws {
        let directory = try makeMemoryFileStoreTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MemoryFileStore(directory: directory)

        try store.writeGlobal("global")
        try store.writeSoul("soul")
        #expect(try store.writeDocument(named: "2026-08-22.md", content: "daily") == true)

        #expect(Set(store.listFiles().map(\.relativePath)) == [
            "GLOBAL.md",
            "SOUL.md",
            "daily/2026-08-22.md"
        ])
    }

    @Test(arguments: [
        "../outside.md",
        "daily/../outside.md",
        "daily/./outside.md",
        "daily/nested/outside.md",
        "/tmp/outside.md",
        "daily\\outside.md"
    ])
    func rejectsTraversalAbsoluteAndExtraSeparators(_ name: String) throws {
        let directory = try makeMemoryFileStoreTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MemoryFileStore(directory: directory)

        #expect(store.readDocument(named: name) == nil)
        #expect(try store.writeDocument(named: name, content: "outside") == false)
        #expect(try store.deleteDocument(named: name) == false)
        #expect(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("outside.md").path
        ) == false)
    }

    @Test func rejectsSymlinkFileEscapeForReadWriteAndDelete() throws {
        let directory = try makeMemoryFileStoreTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileManager = FileManager.default
        let outside = fileManager.temporaryDirectory
            .appendingPathComponent("MinisCore-MemoryFileStore-outside-\(UUID().uuidString).md")
        try Data("outside".utf8).write(to: outside)
        defer { try? fileManager.removeItem(at: outside) }

        let store = MemoryFileStore(directory: directory)
        try fileManager.createDirectory(at: store.dailyDirectory, withIntermediateDirectories: true)
        let escaped = store.dailyDirectory.appendingPathComponent("escape.md")
        try fileManager.createSymbolicLink(at: escaped, withDestinationURL: outside)

        #expect(store.readDocument(named: "daily/escape.md") == nil)
        #expect(try store.writeDocument(named: "daily/escape.md", content: "overwrite") == false)
        #expect(try store.deleteDocument(named: "daily/escape.md") == false)
        #expect(String(data: try Data(contentsOf: outside), encoding: .utf8) == "outside")
    }

    @Test func rejectsSymlinkedDailyDirectoryEscape() throws {
        let directory = try makeMemoryFileStoreTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileManager = FileManager.default
        let outside = fileManager.temporaryDirectory
            .appendingPathComponent("MinisCore-MemoryFileStore-daily-outside-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: outside) }

        let store = MemoryFileStore(directory: directory)
        try fileManager.createDirectory(at: store.memoryDirectory, withIntermediateDirectories: true)
        try fileManager.createSymbolicLink(at: store.dailyDirectory, withDestinationURL: outside)

        #expect(store.readDocument(named: "daily/2026-08-22.md") == nil)
        #expect(try store.writeDocument(named: "daily/2026-08-22.md", content: "outside") == false)
        #expect(try store.deleteDocument(named: "daily/2026-08-22.md") == false)
        #expect(!fileManager.fileExists(
            atPath: outside.appendingPathComponent("2026-08-22.md").path
        ))
    }
}
