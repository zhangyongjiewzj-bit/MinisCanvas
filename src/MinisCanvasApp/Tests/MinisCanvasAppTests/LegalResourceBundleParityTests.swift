import Foundation
import Testing

/// DEV-322 (tree-change batch, GPL legal materials):
/// asserts the packaged `Resources/Legal` LICENSE and NOTICE are
/// byte-for-byte identical to the repository-root files of the same name,
/// that the root LICENSE is the unmodified FSF GPL-3.0 text, that the root
/// NOTICE carries the four required declarations (GPL-3.0-only release,
/// Copyright (C) 2026 zang, OpenMinis derivation notice, Keyline MIT
/// third-party pointer), and that `Package.swift` ships the Legal directory
/// via the same `.copy` mechanism used for Keyline resources.
@Suite("Legal resources ship in-package byte-identical to repo root")
struct LegalResourceBundleParityTests {
    private static let repoRoot: URL = {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // MinisCanvasAppTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // MinisCanvasApp
            .deletingLastPathComponent()   // src
            .deletingLastPathComponent()   // repository root
    }()

    private static let legalNames = ["LICENSE", "NOTICE"]

    private func read(_ url: URL) throws -> Data {
        try Data(contentsOf: url)
    }

    @Test("Packaged LICENSE and NOTICE exist and match repo root byte-for-byte")
    func packagedLegalMatchesRepoRoot() throws {
        let packagedDir = Self.repoRoot
            .appendingPathComponent("src/MinisCanvasApp/Sources/MinisCanvasApp/Resources/Legal")
        for name in Self.legalNames {
            let rootFile = Self.repoRoot.appendingPathComponent(name)
            let packagedFile = packagedDir.appendingPathComponent(name)
            #expect(FileManager.default.fileExists(atPath: rootFile.path),
                    "repo-root \(name) must exist (GPL-3.0-only release materials)")
            #expect(FileManager.default.fileExists(atPath: packagedFile.path),
                    "in-package Resources/Legal/\(name) must exist")
            let rootData = try read(rootFile)
            let packagedData = try read(packagedFile)
            #expect(!rootData.isEmpty, "repo-root \(name) must not be empty")
            #expect(rootData == packagedData,
                    "Resources/Legal/\(name) differs byte-for-byte from repo-root \(name)")
        }
    }

    @Test("Root LICENSE is the official FSF GPL-3.0 full text, unmodified")
    func rootLicenseIsOfficialGPLv3Text() throws {
        let data = try read(Self.repoRoot.appendingPathComponent("LICENSE"))
        #expect(data.count == 35_149,
                "FSF GPL-3.0 plain-text canonical size is 35149 bytes, got \(data.count)")
        let text = String(decoding: data, as: UTF8.self)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        let nonEmpty = lines.filter { !$0.isEmpty }
        #expect(nonEmpty.first == "GNU GENERAL PUBLIC LICENSE",
                "root LICENSE must open with the FSF GPL-3.0 title block")
        #expect(nonEmpty.count > 1 && nonEmpty[1] == "Version 3, 29 June 2007",
                "root LICENSE must declare GPL version 3, 29 June 2007")
        #expect(text.contains("\n                       TERMS AND CONDITIONS\n"),
                "root LICENSE must contain the GPL-3.0 terms heading")
        #expect(text.contains("\n                     END OF TERMS AND CONDITIONS\n"),
                "root LICENSE must contain the GPL-3.0 end-of-terms marker")
        #expect(text.contains("  0. Definitions."),
                "root LICENSE must contain the numbered GPLv3 sections")
        #expect(text.contains("How to Apply These Terms to Your New Programs"))
        #expect(text.contains("You should have received a copy of the GNU General Public License"))
        #expect(nonEmpty.last == "<https://www.gnu.org/licenses/why-not-lgpl.html>.",
                "root LICENSE must end with the canonical FSF closing paragraph (https variant)")
    }

    @Test("Root NOTICE carries the four required declarations and no email address")
    func rootNoticeContentContract() throws {
        let text = try String(contentsOf: Self.repoRoot.appendingPathComponent("NOTICE"), encoding: .utf8)
        #expect(text.contains("Copyright (C) 2026 zang"))
        #expect(text.contains("GPL-3.0-only"))
        #expect(text.contains("LICENSE"))
        #expect(text.contains("https://github.com/OpenMinis/OpenMinis"))
        #expect(text.contains("Ported from OpenMinis"))
        #expect(text.contains("修改时间为 2026 年 7 月至 11 月"))
        #expect(text.contains("Keyline Icons"))
        #expect(text.contains("MIT"))
        #expect(text.contains("KeylineIcons/LICENSE"))
        #expect(text.contains("KeylineIcons/THIRD_PARTY_NOTICES"))
        #expect(!text.contains("@"), "NOTICE must not contain any email address")
    }

    @Test("Package.swift declares the Legal resources directory like Keyline")
    func packageSwiftDeclaresLegalCopy() throws {
        let manifest = try String(
            contentsOf: Self.repoRoot.appendingPathComponent("src/MinisCanvasApp/Package.swift"),
            encoding: .utf8)
        #expect(manifest.contains(#".copy("Resources/Legal")"#),
                "Package.swift resources must include .copy(\"Resources/Legal\")")
    }
}
