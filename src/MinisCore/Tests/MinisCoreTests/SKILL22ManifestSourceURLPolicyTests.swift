import Foundation
import Testing
@testable import MinisCore

@Suite("SKILL-22 manifest source URL policy")
struct SKILL22ManifestSourceURLPolicyTests {
    private let content = "---\nname: Demo\nversion: 1.0.0\n---\nbody"

    private func manifestData(source: SkillImportSource) throws -> Data {
        try JSONEncoder().encode(SkillSourceManifest(
            skillID: "demo",
            source: source,
            skillVersion: "1.0.0",
            content: content
        ))
    }

    private func rejection(for source: SkillImportSource) throws -> SkillManifestIdentity.Rejection? {
        SkillManifestIdentity.rejection(
            skillID: "demo",
            skillVersion: "1.0.0",
            content: content,
            manifestData: try manifestData(source: source)
        )
    }

    @Test func httpAndHTTPSSourcesRemainAdmitted() throws {
        for source in [
            SkillImportSource.url("https://example.com/skills/demo"),
            SkillImportSource.url("http://localhost:8080/skills/demo")
        ] {
            #expect(try rejection(for: source) == nil)
        }
    }

    @Test func localDangerousAndTraversalSourcesFailClosed() throws {
        let sources = [
            SkillImportSource.url("file:///tmp/skill"),
            SkillImportSource.url("data:text/plain,skill"),
            SkillImportSource.url("javascript:alert(1)"),
            SkillImportSource.url("/tmp/skill"),
            SkillImportSource.url("https://example.com/../secret"),
            SkillImportSource.url("https://example.com/%2e%2e/secret"),
            SkillImportSource.url("https://example.com/skill\u{7F}")
        ]
        for source in sources {
            #expect(try rejection(for: source) == .invalidSourceURL)
        }
    }

    @Test func overlongSourceURLFailsClosedWithoutChangingUnknownFieldCompatibility() throws {
        let value = "https://example.com/" + String(
            repeating: "x",
            count: SkillManifestIdentity.maxSourceURLBytes
        )
        #expect(try rejection(for: .url(value)) == .invalidSourceURL)

        let valid = try manifestData(source: .file)
        var json = String(decoding: valid, as: UTF8.self)
        try #require(json.last == "}")
        json.removeLast()
        let withUnknownField = Data((json + ",\"future\":{\"nested\":[1,2,3]}}").utf8)
        #expect(SkillManifestIdentity.rejection(
            skillID: "demo",
            skillVersion: "1.0.0",
            content: content,
            manifestData: withUnknownField
        ) == nil)
    }
}
