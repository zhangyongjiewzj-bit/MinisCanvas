import Foundation
import Testing
@testable import MinisCanvasApp

@Suite("A7A NON_CANVAS semantic icon contract")
struct A7ANonCanvasIconContractTests {
    private static let scopedSourceFiles = [
        "src/MinisCanvasApp/Sources/MinisCanvasApp/SettingsView.swift",
        "src/MinisCanvasApp/Sources/MinisCanvasApp/ChatSidebarView.swift",
    ]

    private static let typedFragments = [
        "presentation.systemImageName",
        "Image(systemName: icon)",
        "Image(systemName: attachment.iconName)",
        "Image(systemName: att.iconName)",
        "systemImage: actionIcon",
        "modelStatusIcon(state?.status)",
        "Image(systemName: stateIcon)",
    ]

    // ContentUnavailableView, the shared BubbleActionButton, and the locked
    // Phase4 canvas-facing boundary still expose String SF Symbol APIs. Keep
    // those boundaries explicit until their owning components gain semantic
    // icon overloads.
    private static let reviewedStaticFragments = [
        "systemImage: \"books.vertical\"",
        "systemImage: \"clock\"",
        "systemImage: \"brain\"",
        "systemImage: \"terminal\"",
        "systemImage: \"doc.text\"",
        "BubbleActionButton(title: \"编辑\", systemImage: \"pencil\"",
        "Image(systemName: \"scope\")",
        "Label(context.statusLabel, systemImage: \"circle.fill\")",
        // ROOT #79: skipped-row status hint, not an action icon.
        "Image(systemName: \"circle.slash\")",
    ]

    @Test("settings and chat sidebar migrate non-canvas actions to semantic icons")
    func migratedNonCanvasActionsUseSemanticIcons() throws {
        let settings = try source("src/MinisCanvasApp/Sources/MinisCanvasApp/SettingsView.swift")
        let chat = try source("src/MinisCanvasApp/Sources/MinisCanvasApp/ChatSidebarView.swift")

        #expect(settings.contains("MinisIconView(.warning, size: 14"))
        #expect(!settings.contains("Image(systemName: \"exclamationmark.triangle\")"))
        #expect(chat.contains("let icon: MinisIcon"))
        #expect(chat.contains("MinisIconView(icon, size: 12"))
        #expect(chat.contains("MinisIconView(.download, size: 14"))
        #expect(chat.contains("MinisIconView(.folderAdd, size: 12)"))
        #expect(!chat.contains("Image(systemName: \"folder.badge.plus\")"))
        #expect(MinisIcon.folderAdd.fallbackSystemName == "folder.badge.plus")
        #expect(!chat.contains("systemImage: \"arrow.down\""))
        #expect(!chat.contains("Image(systemName: \"folder.fill\")"))
    }

    @Test("scoped direct SF symbols are typed, reviewed, or explicitly deferred")
    func directSFUsageIsAllowlisted() throws {
        let lines = try scopedSource()
            .split(separator: "\n")
            .map(String.init)
        let direct = lines.filter {
            $0.contains("Image(systemName:") || $0.contains("systemImage:")
        }
        #expect(!direct.isEmpty)
        for line in direct {
            let allowed = Self.typedFragments.contains { line.contains($0) }
                || Self.reviewedStaticFragments.contains { line.contains($0) }
            #expect(allowed, "unallowlisted NON_CANVAS SF symbol: \(line.trimmingCharacters(in: .whitespaces))")
        }
    }

    private func scopedSource() throws -> String {
        try Self.scopedSourceFiles
            .map { try source($0) }
            .joined(separator: "\n")
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
