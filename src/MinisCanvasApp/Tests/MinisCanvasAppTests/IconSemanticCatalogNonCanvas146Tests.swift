import Foundation
import Testing
@testable import MinisCanvasApp

/// P3-ICON-01 lane QODER-DEV-W10-ICON-SEMANTIC-CATALOG-NONCANVAS-146.
///
/// Guards the non-canvas semantic icon catalog migration: every hard-coded
/// `Image(systemName: "literal")` in the scoped non-canvas surfaces either
/// renders through `MinisIconView` with a semantically matching `MinisIcon`
/// case, or sits on the explicit reviewed-deferral allowlist below. The
/// allowlist doubles as the ledger of sites still awaiting a design ruling
/// or a serial successor lane; reintroducing a cataloged literal fails.
/// Canvas-family sources (CanvasView, AssetPanelView, MiniMapView, Node*,
/// Storyboard*) are deferred scope and intentionally not scanned here.
@Suite("ICON-146 non-canvas semantic icon catalog contract")
struct IconSemanticCatalogNonCanvas146Tests {
    /// Scoped non-canvas app sources owned by this lane's migration.
    /// Hard-excluded files (MinisCanvasApp.swift, SettingsView.swift,
    /// ContextPanelView.swift, ExternalSession*) are not scanned here.
    private static let scopedSourceFiles = [
        "src/MinisCanvasApp/Sources/MinisCanvasApp/ChatSidebarView.swift",
        "src/MinisCanvasApp/Sources/MinisCanvasApp/ChatEmptyStateView.swift",
        "src/MinisCanvasApp/Sources/MinisCanvasApp/DiagnosticExportView.swift",
        "src/MinisCanvasApp/Sources/MinisCanvasApp/ModelMenuButton.swift",
        "src/MinisCanvasApp/Sources/MinisCanvasApp/SchedulerControlSettingsView.swift",
        "src/MinisCanvasApp/Sources/MinisCanvasApp/SessionSearchView.swift",
    ]

    /// Reviewed deferrals inside scoped files: literals that stay until an
    /// owner grants a ruling, mapped to the reason. Do not add entries just
    /// to silence a failure without a recorded decision.
    private static let reviewedDeferralLiterals: Set<String> = [
        // Canvas-facing node context card; explicitly allowlisted as a
        // reviewed static fragment by A7ANonCanvasIconContractTests.
        "ChatSidebarView.swift|Image(systemName: \"scope\")",
        // Bare menu-selection checkmark; the catalog renders circled checks
        // (circle-check asset, checkmark.circle fallback), so remapping
        // would change the glyph shape. Needs a design ruling, not a swap.
        "ModelMenuButton.swift|Image(systemName: \"checkmark\")",
    ]

    /// (file, old literal, migrated catalog rendering, semantic case) for
    /// every site this lane migrated at head 11dc4510218261b9ea7ac18b078541e6d4fa7a3b.
    private static let migratedSites: [(file: String, literal: String, render: String, icon: MinisIcon)] = [
        ("ChatSidebarView.swift", "Image(systemName: \"pencil\")", "MinisIconView(\n                .edit,", .edit),
        ("ChatEmptyStateView.swift", "Image(systemName: \"bubble.left.and.bubble.right\")", "MinisIconView(.messages, size: 28)", .messages),
        ("ChatEmptyStateView.swift", "Label(content.actionTitle, systemImage: \"arrow.clockwise\")", "MinisIconView(.refresh, size: 14)", .refresh),
        ("DiagnosticExportView.swift", "Image(systemName: \"checkmark.circle.fill\")", "MinisIconView(.check, state: .success", .check),
        ("DiagnosticExportView.swift", "Label(\"导出已取消，目标文件未改变。\", systemImage: \"xmark.circle\")", "MinisIconView(.close, size: 14)", .close),
        ("DiagnosticExportView.swift", "Label(reason.message, systemImage: \"exclamationmark.triangle.fill\")", "MinisIconView(.warning, state: .danger, size: 14)", .warning),
        ("ModelMenuButton.swift", "Image(systemName: \"chevron.down\")", "MinisIconView(.caretDown, size: 12", .caretDown),
        ("SchedulerControlSettingsView.swift", "Image(systemName: \"pencil\")", "MinisIconView(.edit, size: 14", .edit),
        ("SessionSearchView.swift", "Image(systemName: \"magnifyingglass\")", "MinisIconView(.search, size: 14", .search),
        ("SessionSearchView.swift", "Image(systemName: \"xmark.circle.fill\")", "MinisIconView(.close, size: 14", .close),
    ]

    @Test("migrated non-canvas sites render catalog cases and drop their literals")
    func migratedSitesUseCatalogRendering() throws {
        for site in Self.migratedSites {
            guard let path = Self.scopedSourceFiles.first(where: { $0.hasSuffix("/" + site.file) }) else {
                Issue.record("unknown scoped file \(site.file)")
                continue
            }
            let text = try source(path)
            #expect(
                text.contains(site.render),
                "\(site.file) must render \(site.icon.rawValue) through MinisIconView"
            )
            #expect(
                !text.contains(site.literal),
                "\(site.file) reintroduced hard-coded \(site.literal)"
            )
        }
    }

    @Test("catalog cases mapped by this lane are semantically identical to the old glyphs")
    func catalogCaseSemanticsMatchMigratedLiterals() {
        // Each migrated literal equals (or is the .fill twin of) the case's
        // allowlisted fallback SF Symbol, so the mapping is a catalog
        // adoption and never a substitution of a different-looking glyph.
        #expect(MinisIcon.edit.fallbackSystemName == "pencil")
        #expect(MinisIcon.messages.fallbackSystemName == "bubble.left.and.bubble.right")
        #expect(MinisIcon.refresh.fallbackSystemName == "arrow.clockwise")
        #expect(MinisIcon.check.fallbackSystemName == "checkmark.circle")
        #expect(MinisIcon.warning.fallbackSystemName == "exclamationmark.triangle")
        #expect(MinisIcon.caretDown.fallbackSystemName == "chevron.down")
        #expect(MinisIcon.search.fallbackSystemName == "magnifyingglass")
        #expect(MinisIcon.close.fallbackSystemName == "xmark.circle")
    }

    @Test("scoped non-canvas files keep only allowlisted literal SF symbols")
    func scopedFilesStayOnCatalogAllowlist() throws {
        for path in Self.scopedSourceFiles {
            let fileName = (path as NSString).lastPathComponent
            let lines = try source(path).split(separator: "\n").map(String.init)
            let literals = lines.filter { $0.contains("Image(systemName: \"") }
            for line in literals {
                let key = "\(fileName)|\(line.trimmingCharacters(in: .whitespaces))"
                #expect(
                    Self.reviewedDeferralLiterals.contains(key),
                    "unallowlisted literal SF symbol in \(fileName): \(line.trimmingCharacters(in: .whitespaces))"
                )
            }
        }
    }

    @Test("duotone bundle wiring of the catalog view stays intact")
    func catalogViewKeepsBundleWiring() throws {
        let view = try source("src/MinisCanvasApp/Sources/MinisCanvasApp/DesignSystem/MinisIconView.swift")
        let helper = try source("src/MinisCanvasApp/Sources/MinisCanvasApp/MinisCanvasResourceBundle.swift")
        // Source wiring clues only. The callable resolver tests establish
        // packaged priority, app fail-closed behavior, and lazy DEV fallback.
        #expect(view.contains("MinisCanvasResourceBundle.current?.bundle")
                && helper.contains("moduleBundle: { .module }"))
        #expect(helper.contains("guard mainBundleURL.pathExtension != \"app\" else { return nil }"))
        #expect(helper.contains("let bundle = Bundle(url: packagedURL)"))
        #expect(view.contains("MinisCanvasResourceBundle.resolve(")
                && helper.contains("return Resolution(bundle: moduleBundle(), origin: .swiftPackage)"))
    }

    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }
}
