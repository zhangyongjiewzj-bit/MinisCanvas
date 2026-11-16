import Foundation
import Testing
@testable import MinisCore

@Suite("Markdown importer security boundary")
struct MarkdownImporterSecurityTests {
    @Test("validated import bounds frontmatter, fences, headings, and resources")
    func validatedImportKeepsSafeStructure() throws {
        let markdown = """
        ---
        title: Fixture document
        source: local
        ---
        # Document

        ## Body
        A [safe link](https://example.test/docs) and ![image](assets/image.png).

        ```markdown
        ## Heading inside code
        [not a resource](javascript:ignored)
        ```
        """

        let content = try MarkdownImporter.importMarkdownValidated(markdown)
        #expect(content.title == "Document")
        #expect(content.sections.count == 1)
        #expect(content.sections[0].contains("## Body"))
        #expect(content.sections[0].contains("## Heading inside code"))
        #expect(content.fullText.contains("title: Fixture document"))
    }

    @Test("unsafe resources, malformed fences, and controls fail closed")
    func unsafeMarkdownIsRejected() {
        let unsafeDestinations = [
            "[x](javascript:alert(1))",
            "![x](file:///private/secret.txt)",
            "[x](/absolute/private.txt)",
            "[x](../outside.txt)",
            "[x](https://user:password@example.test/private)"
        ]
        for markdown in unsafeDestinations {
            #expect((try? MarkdownImporter.importMarkdownValidated(markdown)) == nil)
        }

        #expect((try? MarkdownImporter.importMarkdownValidated("```\nunterminated")) == nil)
        #expect((try? MarkdownImporter.importMarkdownValidated("---\ntitle: missing close\n# body")) == nil)
        #expect((try? MarkdownImporter.importMarkdownValidated("# unsafe\u{0000}text")) == nil)
    }

    @Test("limits reject oversized lines, sections, and resource counts")
    func importBudgetsAreBounded() {
        let limits = MarkdownImportLimits(
            maxBytes: 32,
            maxLines: 3,
            maxLineBytes: 16,
            maxSections: 1,
            maxHeadingCharacters: 8,
            maxHeadingDepth: 2,
            maxResourceReferences: 1
        )

        #expect((try? MarkdownImporter.importMarkdownValidated("# This heading is too long", limits: limits)) == nil)
        #expect((try? MarkdownImporter.importMarkdownValidated("# A\n\n## B\n\n## C", limits: limits)) == nil)
        #expect((try? MarkdownImporter.importMarkdownValidated("[a](a) [b](b)", limits: limits)) == nil)
        #expect((try? MarkdownImporter.importMarkdownValidated("ok", limits: MarkdownImportLimits(maxBytes: 0))) == nil)
    }

    @Test("import errors do not expose path, reason, or resource text")
    func importErrorsAreSecretSafe() {
        let path = "/private/fixture/provider-secret.md"
        let reason = "Authorization: Bearer fixture-secret"
        let errors: [MarkdownImportError] = [
            .notUTF8(URL(fileURLWithPath: path)),
            .unreadable(URL(fileURLWithPath: path), reason),
            .unsafeResource,
            .malformedStructure
        ]

        for error in errors {
            let message = error.localizedDescription
            #expect(!message.contains(path))
            #expect(!message.contains(reason))
            #expect(!message.contains("fixture-secret"))
            #expect(message.count < 160)
        }
    }
}
