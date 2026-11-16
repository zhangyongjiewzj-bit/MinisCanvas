import Foundation
import Testing
@testable import MinisCore

@Suite("SKILL-21 manifest JSON budget")
struct SKILL21ManifestJSONBudgetTests {
    private let content = "---\nname: Demo\nversion: 1.0.0\n---\nbody"

    private func manifestData(extra: String) throws -> Data {
        let manifest = SkillSourceManifest(
            skillID: "demo",
            source: .file,
            skillVersion: "1.0.0",
            content: content
        )
        var json = String(decoding: try JSONEncoder().encode(manifest), as: UTF8.self)
        try #require(json.last == "}")
        json.removeLast()
        return Data((json + "," + extra + "}").utf8)
    }

    private func nestedObject(depth: Int) -> String {
        guard depth > 0 else { return "0" }
        return "{\"next\":\(nestedObject(depth: depth - 1))}"
    }

    @Test func deeplyNestedUnknownManifestIsRejectedBeforeDecode() throws {
        let data = try manifestData(extra: "\"noise\":\(nestedObject(depth: SkillManifestIdentity.maxManifestJSONDepth + 1))")
        #expect(SkillManifestIdentity.rejection(
            skillID: "demo",
            skillVersion: "1.0.0",
            content: content,
            manifestData: data
        ) == .malformedManifest)
    }

    @Test func oversizedUnknownCollectionIsRejectedBeforeDecode() throws {
        let values = Array(repeating: "0", count: SkillManifestIdentity.maxManifestCollectionEntries + 1)
            .joined(separator: ",")
        let data = try manifestData(extra: "\"noise\":[\(values)]")
        #expect(SkillManifestIdentity.rejection(
            skillID: "demo",
            skillVersion: "1.0.0",
            content: content,
            manifestData: data
        ) == .malformedManifest)
    }

    @Test func overlongUnknownStringIsRejectedBeforeDecode() throws {
        let value = String(repeating: "x", count: SkillManifestIdentity.maxManifestJSONStringBytes + 1)
        let data = try manifestData(extra: "\"noise\":\"\(value)\"")
        #expect(SkillManifestIdentity.rejection(
            skillID: "demo",
            skillVersion: "1.0.0",
            content: content,
            manifestData: data
        ) == .malformedManifest)
    }
}
