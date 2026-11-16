import Foundation
import Testing
@testable import MinisCore

private func importerSecurityDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("MinisCore-FileImporterSecurity-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

struct FileImporterSecurityTests {

    @Test func importsOnlyAnExistingRegularFile() throws {
        let root = try importerSecurityDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.txt")
        let destination = root.appendingPathComponent("staged", isDirectory: true)
        let data = Data("safe import".utf8)
        try data.write(to: source)

        let staged = try FileImporter.importFile(from: source, to: destination)
        #expect(FileManager.default.fileExists(atPath: staged.path))
        #expect(try Data(contentsOf: staged) == data)
    }

    @Test func rejectsDirectorySourceBeforeCopy() throws {
        let root = try importerSecurityDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceDirectory = root.appendingPathComponent("source-directory", isDirectory: true)
        let destination = root.appendingPathComponent("staged", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)

        #expect(throws: FileImportError.notARegularFile(sourceDirectory)) {
            try FileImporter.importFile(from: sourceDirectory, to: destination)
        }
    }

    @Test func rejectsSymbolicLinkSourceBeforeCopy() throws {
        let root = try importerSecurityDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("target.txt")
        let sourceLink = root.appendingPathComponent("source-link.txt")
        let destination = root.appendingPathComponent("staged", isDirectory: true)
        try Data("target".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: sourceLink, withDestinationURL: target)

        #expect(throws: FileImportError.notARegularFile(sourceLink)) {
            try FileImporter.importFile(from: sourceLink, to: destination)
        }
    }
}
