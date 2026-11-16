import Foundation
import Testing
@testable import MinisCore

struct FileImporterCleanroomBehaviorTests {
    @Test func jsonDisplayKeepsAcronym() {
        #expect(FileType.json.displayName == "JSON")
    }

    @Test func syntheticMPEGAndID3PrefixesRespectCompatibilityBounds() throws {
        func sniff(_ prefix: [UInt8]) throws -> String? {
            let fixture = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: fixture) }
            try Data(prefix).write(to: fixture)
            return FileImporter.mimeType(of: fixture)
        }
        #expect(try sniff([0xFF, 0xFB, 0x90, 0x64, 0, 0, 0, 0, 0, 0, 0, 0]) == "audio/mpeg")
        #expect(try sniff([0xFF, 0xFD, 0x90, 0x64, 0, 0, 0, 0, 0, 0, 0, 0]) == nil)
        #expect(try sniff([73, 68, 51, 4, 0, 0, 0, 0, 0, 1, 0, 0]) == "audio/mpeg")
        #expect(try sniff([73, 68, 51, 4, 0, 0, 0x80, 0, 0, 1, 0, 0]) == nil)
    }
}
