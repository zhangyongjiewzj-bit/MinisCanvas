import Foundation
import Testing
@testable import MinisCore

struct MCPBoundedDocumentReaderTests {
    @Test("bounded MCP document reader accepts an exact byte limit")
    func acceptsExactLimit() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MCPBoundedDocumentReader-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appendingPathComponent("document.json")
        let expected = Data("1234".utf8)
        try expected.write(to: url)

        #expect(MCPBoundedDocumentReader.read(from: url, maxBytes: 4) == .data(expected))
    }

    @Test("bounded MCP document reader stops after the over-limit sentinel byte")
    func rejectsOneByteOverLimit() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MCPBoundedDocumentReader-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appendingPathComponent("document.json")
        try Data("12345".utf8).write(to: url)

        #expect(MCPBoundedDocumentReader.read(from: url, maxBytes: 4) == .tooLarge)
    }

    @Test("bounded MCP document reader reports a missing file as unavailable")
    func reportsUnavailableFile() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MCPBoundedDocumentReader-missing-\(UUID().uuidString).json")

        #expect(MCPBoundedDocumentReader.read(from: url, maxBytes: 4) == .unavailable)
    }
}
