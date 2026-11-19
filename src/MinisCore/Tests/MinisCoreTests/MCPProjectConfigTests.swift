import Foundation
import Testing
@testable import MinisCore

@Suite struct MCPProjectConfigTests {
    private func makeRoots() throws -> (project: URL, state: URL) {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("MCPProjectConfigTests-\(UUID().uuidString)", isDirectory: true)
        let project = base.appendingPathComponent("project", isDirectory: true)
        let state = base.appendingPathComponent("state", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        return (project, state)
    }

    private func write(_ text: String, to project: URL) throws {
        try Data(text.utf8).write(to: project.appendingPathComponent(".mcp.json"))
    }

    @Test func projectFileStaysPendingUntilTheExactContentIsApproved() throws {
        let (project, state) = try makeRoots()
        try write(#"{"mcpServers":{"demo":{"command":"/bin/echo","args":["hi"]}}}"#, to: project)
        let store = MCPProjectConfigStore(directory: state)

        let first = store.snapshot(projectRoot: project)
        #expect(first.trust == .untrusted(changedSinceTrust: false))
        #expect(first.servers.map(\.id) == ["demo"])
        let hash = try #require(first.contentHash)

        #expect(throws: MCPProjectConfigError.contentChangedSinceReview) {
            try store.trust(projectRoot: project, expectedHash: "0000")
        }
        #expect(store.snapshot(projectRoot: project).trust == .untrusted(changedSinceTrust: false))

        try store.trust(projectRoot: project, expectedHash: hash)
        #expect(store.snapshot(projectRoot: project).trust == .trusted)

        // 内容一变就回到待批准，并标明“上次批准之后变了”。
        try write(#"{"mcpServers":{"demo":{"command":"/bin/echo","args":["changed"]}}}"#, to: project)
        #expect(store.snapshot(projectRoot: project).trust == .untrusted(changedSinceTrust: true))

        try store.revokeTrust(projectRoot: project)
        #expect(store.snapshot(projectRoot: project).trust == .untrusted(changedSinceTrust: false))
    }

    @Test func updateSkipsServersTheUserEditedLocally() throws {
        let (project, state) = try makeRoots()
        try write(#"{"mcpServers":{"a":{"command":"/bin/echo","env":{"K":"${TOK}"}},"b":{"command":"/bin/echo"}}}"#, to: project)
        let store = MCPProjectConfigStore(directory: state)
        let first = store.snapshot(projectRoot: project)
        try store.trust(projectRoot: project, expectedHash: try #require(first.contentHash),
                        serverIDs: first.servers.map(\.id), servers: first.allServers)

        var local = first.allServers
        local[0].env["K"] = "my-real-secret"   // 用户填了实际值
        try write(#"{"mcpServers":{"a":{"command":"/bin/echo","env":{"K":"${TOK}"},"args":["x"]},"b":{"command":"/bin/echo","args":["y"]}}}"#, to: project)
        let second = store.snapshot(projectRoot: project, existingIDs: ["a", "b"], existingServers: local)
        #expect(second.locallyModifiedIDs == ["a"])
        #expect(second.servers.map(\.id) == ["b"])
        #expect(second.locallyModifiedServers.map(\.id) == ["a"])
    }

    @Test func missingFileReportsNoFile() throws {
        let (project, state) = try makeRoots()
        #expect(MCPProjectConfigStore(directory: state).snapshot(projectRoot: project).trust == .noFile)
    }
}
