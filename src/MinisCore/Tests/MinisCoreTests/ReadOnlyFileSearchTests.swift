import Foundation
import Testing
@testable import MinisCore

struct ReadOnlyFileSearchTests {
    private func withRoot(_ operation: (URL) async throws -> Void) async throws {
        let temporary = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        let root = temporary.appendingPathComponent("minis-search-\(UUID().uuidString)")
        try #require(root.path.hasPrefix(temporary.path + "/minis-search-"))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        try await operation(root)
    }

    private func search(_ name: String, root: URL, path: String? = nil,
                        pattern: String, maximum: Int = 100, denied: [URL] = [],
                        extra: [String: Any] = [:],
                        budgets: ReadOnlyFileSearch.Budgets = .standard) throws -> String {
        let executor = BuiltinToolExecutor(allowedRoot: root, deniedRoots: denied)
        let validate = executor.fileArtifactTargetValidator()
        var input: [String: Any] = ["path": path ?? root.path, "pattern": pattern, "max_results": maximum]
        for (key, value) in extra { input[key] = value }
        return try ReadOnlyFileSearch.execute(name: name,
            input: input, budgets: budgets,
            validatePath: { raw in
                if PolicyRuntimePathBoundary.canonicalPath(raw) == PolicyRuntimePathBoundary.canonicalPath(root.path) {
                    return try executor.validatedTargetWorkspaceDirectory(raw)
                }
                guard let url = validate(raw, root.path) else { throw ToolExecutorError.pathViolation(raw) }
                return url
            }, isSensitive: SensitiveFilePolicy.isSensitive)
    }

    @Test func relativePathsLineNumbersSensitiveAndDeniedFiles() async throws {
        try await withRoot { root in
            let nested = root.appendingPathComponent("nested")
            try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: false)
            try "first\nneedle here\n".write(to: nested.appendingPathComponent("note.txt"), atomically: true, encoding: .utf8)
            try "synthetic-secret-needle".write(to: root.appendingPathComponent(".env"), atomically: true, encoding: .utf8)
            let denied = root.appendingPathComponent("private")
            try FileManager.default.createDirectory(at: denied, withIntermediateDirectories: false)
            try "denied-needle".write(to: denied.appendingPathComponent("hidden.txt"), atomically: true, encoding: .utf8)
            try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("linked-private").path,
                withDestinationPath: denied.path)
            let output = try search("file_grep", root: root, pattern: "needle", denied: [denied])
            #expect(output.contains("nested/note.txt:2:needle here"))
            #expect(!output.contains("synthetic-secret"))
            #expect(!output.contains("denied-needle"))
            #expect(!output.contains(".env"))
            let glob = try search("file_glob", root: root, pattern: "*.txt", denied: [denied])
            #expect(glob.contains("nested/note.txt"))
            #expect(!glob.contains("hidden.txt"))
        }
    }

    @Test func rejectsOutsideRootAndSkipsLinksAndHardlinks() async throws {
        try await withRoot { root in
            try "needle".write(to: root.appendingPathComponent("original.txt"), atomically: true, encoding: .utf8)
            try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("link.txt").path,
                withDestinationPath: root.appendingPathComponent("original.txt").path)
            try FileManager.default.linkItem(at: root.appendingPathComponent("original.txt"), to: root.appendingPathComponent("hard.txt"))
            let directory = root.appendingPathComponent("directory")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            let directoryLink = root.appendingPathComponent("directory-link")
            try FileManager.default.createSymbolicLink(atPath: directoryLink.path,
                withDestinationPath: directory.path)
            #expect(throws: ToolExecutorError.self) {
                _ = try search("file_glob", root: root, path: directoryLink.path, pattern: "*")
            }
            let output = try search("file_grep", root: root, pattern: "needle")
            #expect(!output.contains("needle"))
            #expect(throws: ToolExecutorError.self) {
                _ = try search("file_glob", root: root, path: root.deletingLastPathComponent().path, pattern: "*")
            }
        }
    }

    @Test func oversizedBinaryAndCountBudgets() async throws {
        try await withRoot { root in
            try String(repeating: "needle\n", count: 50_000).write(to: root.appendingPathComponent("large.txt"), atomically: true, encoding: .utf8)
            var smallBudgets = ReadOnlyFileSearch.Budgets()
            smallBudgets.fileBytes = 100_000
            try Data([0, 110, 101, 101, 100, 108, 101]).write(to: root.appendingPathComponent("binary.txt"))
            try "needle\nneedle\nneedle".write(to: root.appendingPathComponent("small.txt"), atomically: true, encoding: .utf8)
            let output = try search("file_grep", root: root, pattern: "needle", maximum: 2, budgets: smallBudgets)
            #expect(!output.contains("large.txt:"))
            #expect(!output.contains("binary.txt:"))
            #expect(output.contains("2 result(s)"))
            #expect(output.contains("safety budget"))
            #expect(output.contains("INCOMPLETE"))
            #expect(output.count <= MCPOutputLimiter.defaultMaximumCharacters)
        }
    }

    @Test func totalReadBudgetStopsWithoutUnboundedAccumulation() async throws {
        try await withRoot { root in
            let text = String(repeating: "x", count: 220_000)
            for index in 0..<20 {
                try text.write(to: root.appendingPathComponent("file-\(index).txt"), atomically: true, encoding: .utf8)
            }
            var tinyBudgets = ReadOnlyFileSearch.Budgets()
            tinyBudgets.readBytes = 1_000_000
            let output = try search("file_grep", root: root, pattern: "absent", budgets: tinyBudgets)
            #expect(output.contains("0 result(s)"))
            #expect(output.contains("safety budget"))
        }
    }

    @Test func nativeCatalogDispatcherAndOutputCap() async throws {
        try await withRoot { root in
            let line = "needle " + String(repeating: "字", count: 1500)
            try Array(repeating: line, count: 200).joined(separator: "\n")
                .write(to: root.appendingPathComponent("bounded.txt"), atomically: true, encoding: .utf8)
            // File-size cap applies before the output cap. Use an admissible
            // file with many large but bounded rows to exercise projection.
            let medium = "needle " + String(repeating: "字", count: 500)
            try Array(repeating: medium, count: 100).joined(separator: "\n")
                .write(to: root.appendingPathComponent("matches.txt"), atomically: true, encoding: .utf8)
            let executor = BuiltinToolExecutor(allowedRoot: root, deniedRoots: [])
            let catalog = AgentToolCatalog.makeTools()
            #expect(catalog.contains { $0.name == "file_grep" })
            #expect(catalog.contains { $0.name == "file_glob" })
            let output = try await executor.execute(name: "file_grep", input: [
                "path": root.path, "pattern": "needle", "max_results": 200])
            #expect(output.count <= MCPOutputLimiter.defaultMaximumCharacters)
            #expect(output.contains(MCPOutputLimiter.truncationMarker))
            await #expect(throws: ToolExecutorError.self) {
                _ = try await executor.execute(name: "file_glob", input: [
                    "path": root.deletingLastPathComponent().path, "pattern": "*"])
            }
        }
    }

    @Test(arguments: ["file_grep", "file_glob"])
    func approvedInt64LimitCapsNativeDispatcherResults(name: String) async throws {
        try await withRoot { root in
            for index in 0..<3 {
                try "needle".write(to: root.appendingPathComponent("match-\(index).txt"),
                    atomically: true, encoding: .utf8)
            }
            let executor = BuiltinToolExecutor(allowedRoot: root, deniedRoots: [])
            let pattern = name == "file_grep" ? "needle" : "*.txt"
            // Use the existing immutable Composer input and its production
            // execution projection, not a test copy of integer conversion.
            let frozen = ComposerToolInput(values: [
                "path": .string(root.path), "pattern": .string(pattern), "max_results": .integer(1)
            ])
            let limited = try await executor.execute(name: name, input: frozen.toolExecutionDictionary)
            #expect(limited.split(separator: "\n").filter { $0.hasPrefix("match-") }.count == 1)
            #expect(limited.contains("1 result(s)"))
            #expect(limited.contains("Search stopped at a safety budget"))

            let nativeInt = try await executor.execute(name: name, input: [
                "path": root.path, "pattern": pattern, "max_results": 1])
            #expect(nativeInt.split(separator: "\n").filter { $0.hasPrefix("match-") }.count == 1)
            let clamped = try await executor.execute(name: name, input: [
                "path": root.path, "pattern": pattern, "max_results": Int64(0)])
            #expect(clamped.split(separator: "\n").filter { $0.hasPrefix("match-") }.count == 1)
            let defaulted = try await executor.execute(name: name, input: [
                "path": root.path, "pattern": pattern])
            #expect(defaulted.split(separator: "\n").filter { $0.hasPrefix("match-") }.count == 3)
            #expect(defaulted.contains("3 result(s)"))
            let invalidType = try await executor.execute(name: name, input: [
                "path": root.path, "pattern": pattern, "max_results": "1"])
            #expect(invalidType.split(separator: "\n").filter { $0.hasPrefix("match-") }.count == 3)
            #expect(!invalidType.contains("Search stopped at a safety budget"))
        }
    }

    @Test func cancellationRejectsBeforeTraversal() async throws {
        try await withRoot { root in
            let operation = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                return try search("file_glob", root: root, pattern: "*")
            }
            await #expect(throws: CancellationError.self) { _ = try await operation.value }
        }
    }

    @Test func regexByDefaultLiteralOnRequestAndInvalidRegexExplains() async throws {
        try await withRoot { root in
            try "foo123\nbar(1)\nFOO9\n".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
            let regex = try search("file_grep", root: root, pattern: #"foo\d+"#)
            #expect(regex.contains("a.txt:1:foo123"))
            #expect(!regex.contains("a.txt:3:"))
            let folded = try search("file_grep", root: root, pattern: #"foo\d"#, extra: ["ignore_case": true])
            #expect(folded.contains("a.txt:1:") && folded.contains("a.txt:3:"))
            let literal = try search("file_grep", root: root, pattern: "bar(1)", extra: ["literal": true])
            #expect(literal.contains("a.txt:2:bar(1)"))
            #expect(throws: ToolExecutorError.self) {
                _ = try search("file_grep", root: root, pattern: "(")
            }
        }
    }

    @Test func skipsBuildDirectoriesAndGitignoreUnlessAsked() async throws {
        try await withRoot { root in
            let fm = FileManager.default
            for directory in ["node_modules", "build", "src", "out"] {
                try fm.createDirectory(at: root.appendingPathComponent(directory), withIntermediateDirectories: false)
            }
            for file in ["node_modules/dep.js", "build/gen.txt", "src/main.txt", "out/artifact.txt", "debug.log", "keep.txt"] {
                try "needle".write(to: root.appendingPathComponent(file), atomically: true, encoding: .utf8)
            }
            try "out/\n*.log\n".write(to: root.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
            let output = try search("file_grep", root: root, pattern: "needle")
            #expect(output.contains("src/main.txt:1:needle") && output.contains("keep.txt:1:needle"))
            for hidden in ["node_modules", "build/", "out/", "debug.log"] { #expect(!output.contains(hidden)) }
            let everything = try search("file_grep", root: root, pattern: "needle", extra: ["include_ignored": true])
            for shown in ["node_modules/dep.js", "build/gen.txt", "out/artifact.txt", "debug.log"] {
                #expect(everything.contains(shown))
            }
        }
    }

    @Test func globRecursesThroughDirectoriesSupportsBracesAndOrdersNewestFirst() async throws {
        try await withRoot { root in
            let fm = FileManager.default
            try fm.createDirectory(at: root.appendingPathComponent("sub/deep"), withIntermediateDirectories: true)
            let stamps: [(String, Double)] = [("a.swift", 1_000), ("sub/b.swift", 3_000), ("sub/deep/c.ts", 5_000), ("d.md", 9_000)]
            for (file, stamp) in stamps {
                let url = root.appendingPathComponent(file)
                try "x".write(to: url, atomically: true, encoding: .utf8)
                try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: stamp)], ofItemAtPath: url.path)
            }
            let output = try search("file_glob", root: root, pattern: "**/*.{swift,ts}")
            let paths = output.split(separator: "\n").filter { $0.contains(".") && !$0.contains("result(s)") }.map(String.init)
            #expect(paths == ["sub/deep/c.ts", "sub/b.swift", "a.swift"])
            let nested = try search("file_glob", root: root, pattern: "sub/**/*.ts")
            #expect(nested.contains("sub/deep/c.ts") && !nested.contains("b.swift"))
        }
    }

    @Test func contextOutputModesAndFileFilters() async throws {
        try await withRoot { root in
            try "one\ntwo\nneedle\nfour\nfive\n".write(to: root.appendingPathComponent("a.swift"), atomically: true, encoding: .utf8)
            try "needle\nneedle\n".write(to: root.appendingPathComponent("b.md"), atomically: true, encoding: .utf8)
            let context = try search("file_grep", root: root, pattern: "needle", extra: ["glob": "*.swift", "context": 1])
            #expect(context.contains("a.swift-2-two") && context.contains("a.swift:3:needle") && context.contains("a.swift-4-four"))
            #expect(!context.contains("b.md"))
            let files = try search("file_grep", root: root, pattern: "needle", extra: ["output_mode": "files_with_matches"])
            #expect(files.contains("a.swift") && files.contains("b.md") && !files.contains(":3:"))
            let counts = try search("file_grep", root: root, pattern: "needle", extra: ["output_mode": "count", "type": "md"])
            #expect(counts.contains("b.md:2") && !counts.contains("a.swift"))
        }
    }

    @Test func crlfAndGBKFilesAreSearchable() async throws {
        try await withRoot { root in
            try "first\r\nneedle line\r\n".write(to: root.appendingPathComponent("crlf.txt"), atomically: true, encoding: .utf8)
            let gb18030 = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
            let gbk = try #require("你好 针 世界".data(using: String.Encoding(rawValue: gb18030)))
            try gbk.write(to: root.appendingPathComponent("gbk.txt"))
            let output = try search("file_grep", root: root, pattern: "针", extra: ["literal": true])
            #expect(output.contains("gbk.txt:1:你好 针 世界"))
            let crlf = try search("file_grep", root: root, pattern: "^needle line$")
            #expect(crlf.contains("crlf.txt:2:needle line"))
        }
    }
}
