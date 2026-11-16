import Foundation
import Testing
@testable import MinisCore

@Suite("SKILL-07 catalog document admission")
struct SkillCatalogDocumentPolicyTests {
    @Test func duplicateFrontmatterKeysFailClosedCaseInsensitively() {
        let duplicateKnown = """
        ---
        name: Demo
        NAME: Shadow
        version: 1.0.0
        ---
        body
        """
        let duplicateUnknown = """
        ---
        name: Demo
        x-policy: one
        X-POLICY: two
        ---
        body
        """

        #expect(SkillCatalogDocumentPolicy.admit(duplicateKnown) == nil)
        #expect(SkillCatalogDocumentPolicy.admit(duplicateUnknown) == nil)
    }

    @Test func bodyTextMayContainKeyLikeLinesWithoutBecomingFrontmatter() throws {
        let content = """
        ---
        name: Demo
        version: 1.0.0
        ---
        name: body text
        description: body text
        """

        let document = try #require(SkillCatalogDocumentPolicy.admit(content))
        #expect(document.name == "Demo")
        #expect(document.body.contains("name: body text"))
        #expect(document.body.contains("description: body text"))
        #expect(document.frontmatterByteCount > 0)
    }

    @Test func documentBodyAndEveryFrontmatterValueAreBounded() {
        let oversizedDocument = String(repeating: "x", count: 33)
        #expect(SkillCatalogDocumentPolicy.admit(
            oversizedDocument,
            maxDocumentBytes: 32
        ) == nil)

        let oversizedBody = "---\nname: Demo\nversion: 1.0.0\n---\n" + String(repeating: "b", count: 17)
        #expect(SkillCatalogDocumentPolicy.admit(
            oversizedBody,
            maxBodyBytes: 16
        ) == nil)

        let oversizedUnknownField = "---\nname: Demo\nx: " + String(repeating: "v", count: 17) + "\n---\nbody"
        #expect(SkillCatalogDocumentPolicy.admit(
            oversizedUnknownField,
            maxFieldBytes: 16
        ) == nil)
    }

    @Test func blockScalarFieldLengthIsBoundedAfterResolution() {
        let content = """
        ---
        name: Demo
        description: |
          \(String(repeating: "d", count: 17))
        version: 1.0.0
        ---
        body
        """

        #expect(SkillCatalogDocumentPolicy.admit(content, maxFieldBytes: 16) == nil)
    }
}
