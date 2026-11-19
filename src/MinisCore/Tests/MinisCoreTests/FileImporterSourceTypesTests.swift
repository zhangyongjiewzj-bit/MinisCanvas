import Foundation
import Testing
@testable import MinisCore

@Suite("FileImporter source-code, extensionless and sniffing helpers")
struct FileImporterSourceTypesTests {
    @Test("source and config extensions classify as text",
          arguments: ["go", "rs", "java", "kt", "c", "h", "cpp", "hpp", "m", "mm", "tsx", "jsx", "ts", "vue",
                      "sh", "zsh", "bash", "sql", "toml", "ini", "cfg", "conf", "gradle", "rb", "php",
                      "lua", "r", "scala", "dart", "yaml", "yml", "svg"])
    func sourceExtensionsAreText(ext: String) {
        #expect(FileImporter.type(forExtension: ext) == .text)
        #expect(FileImporter.classify(url: URL(fileURLWithPath: "/tmp/sample.\(ext)")) == .text)
    }

    @Test("svg is text but keeps its image MIME")
    func svgIsTextWithImageMIME() {
        #expect(FileImporter.type(forExtension: "svg") == .text)
        #expect(FileImporter.mimeType(forExtension: "svg") == "image/svg+xml")
    }

    @Test("source extensions get a text MIME")
    func sourceExtensionsGetTextMIME() {
        #expect(FileImporter.mimeType(forExtension: "go") == "text/plain")
        #expect(FileImporter.mimeType(forExtension: "SQL") == "text/plain")
    }

    @Test("extensionless conventional names and env.example are text",
          arguments: ["Makefile", "Dockerfile", "README", "LICENSE", "readme", "env.example", ".env.example", "prod.env.example"])
    func conventionalNamesAreText(name: String) {
        #expect(FileImporter.declaredType(forFileName: name) == .text)
        #expect(FileImporter.classify(url: URL(fileURLWithPath: "/tmp/\(name)")) == .text)
    }

    @Test("a plain .env file and unrelated names stay unknown")
    func envAndUnrelatedStayUnknown() {
        #expect(FileImporter.declaredType(forFileName: ".env") == nil)
        #expect(FileImporter.declaredType(forFileName: "secrets.env") == nil)
        #expect(FileImporter.declaredType(forFileName: "noextension") == nil)
        #expect(FileImporter.declaredType(forFileName: "ReadmeNotes") == nil)
    }

    @Test("rtf is no longer injected as plain text and never sniffed")
    func rtfIsReferenceOnly() {
        #expect(FileImporter.type(forExtension: "rtf") == nil)
        #expect(FileImporter.declaredType(forFileName: "memo.rtf") == nil)
        #expect(FileImporter.allowsTextSniffing(forExtension: "rtf") == false)
        #expect(FileImporter.allowsTextSniffing(forExtension: "RTFD") == false)
        #expect(FileImporter.allowsTextSniffing(forExtension: "weird") == true)
        #expect(FileImporter.allowsTextSniffing(forExtension: "") == true)
    }

    @Test("sniffing accepts NUL-free UTF-8 and rejects NUL, invalid bytes and empty data")
    func sniffingRules() {
        #expect(FileImporter.looksLikeUTF8Text(Data("你好 hello\n".utf8), truncated: false))
        #expect(!FileImporter.looksLikeUTF8Text(Data(), truncated: false))
        #expect(!FileImporter.looksLikeUTF8Text(Data([0x61, 0x00, 0x62]), truncated: false))
        #expect(!FileImporter.looksLikeUTF8Text(Data([0xFF, 0xFE, 0x41]), truncated: false))
    }

    @Test("a UTF-8 sequence cut by the byte limit is valid only when the data was truncated")
    func truncatedTailBoundary() {
        let whole = Data("字字字".utf8)          // 9 bytes
        let cut = whole.prefix(8)                // splits the last 3-byte character
        #expect(FileImporter.utf8DecodedAllowingTruncatedTail(cut, truncated: false) == nil)
        #expect(FileImporter.utf8DecodedAllowingTruncatedTail(cut, truncated: true) == "字字")
        #expect(FileImporter.looksLikeUTF8Text(cut, truncated: true))
        #expect(!FileImporter.looksLikeUTF8Text(cut, truncated: false))
    }
}
