import Foundation
import Testing
import AppKit
import MinisCore
@testable import MinisCanvasApp

@Suite("R35/D Composer Settings gap contracts")
@MainActor
struct R35DComposerSettingsGapTests {
    private func source(_ relativePath: String) throws -> String {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: repositoryRoot.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    @Test("Typography settings reach the production Composer environment")
    func typographyHasProductionInjectionAndConsumer() throws {
        let app = try source(
            "src/MinisCanvasApp/Sources/MinisCanvasApp/MinisCanvasApp.swift"
        )
        let typography = try source(
            "src/MinisCanvasApp/Sources/MinisCanvasApp/TypographyTokenProvider.swift"
        )
        let global = try source(
            "src/MinisCanvasApp/Sources/MinisCanvasApp/GlobalComposerView.swift"
        )
        let controls = try source(
            "src/MinisCanvasApp/Sources/MinisCanvasApp/ComposerPolicyControls.swift"
        )
        let sidebar = try source(
            "src/MinisCanvasApp/Sources/MinisCanvasApp/ChatSidebarView.swift"
        )

        #expect(typography.contains("var typographyTokens: TypographyTokenProvider?"))
        #expect(app.contains(".environment(\\.typographyTokens, TypographyTokenProvider(center: settingsCenter))"))
        #expect(global.contains("@Environment(\\.typographyTokens)"))
        #expect(global.contains("typography?.composerBodySize"))
        #expect(controls.contains("@Environment(\\.typographyTokens)"))
        #expect(sidebar.contains("@Environment(\\.typographyTokens)"))
        #expect(sidebar.contains("font: .systemFont(ofSize: typography?.composerBodySize ?? 13)"))
        #expect(sidebar.contains("baseSize: typography?.transcriptBodySize ?? 13"))
        #expect(sidebar.contains("typography?.transcriptBodySize(for: dynamicTypeSize)"))
        #expect(!sidebar.contains("font: .systemFont(ofSize: 12)"))
    }

    @Test("Composer controls present the active session's frozen policy snapshot")
    func composerControlsPresentFrozenSnapshot() throws {
        let controls = try source(
            "src/MinisCanvasApp/Sources/MinisCanvasApp/ComposerPolicyControls.swift"
        )
        let policyState = try source(
            "src/MinisCanvasApp/Sources/MinisCanvasApp/ComposerPolicyState.swift"
        )

        #expect(controls.contains("chat.lastComposerSubmissionSnapshot"))
        #expect(controls.contains("snapshot.sessionID == activeSessionID.uuidString"))
        #expect(controls.contains(".accessibilityIdentifier(\"composer.snapshot\")"))
        #expect(controls.contains("snapshotSummary"))
        #expect(policyState.contains("权限模式："))
        #expect(!policyState.contains("范围："))
        #expect(policyState.contains("工作量："))
    }

    @Test("Frozen snapshot presentation rejects a different active session")
    func frozenSnapshotPresentationUsesActiveSession() {
        let activeSessionID = UUID()
        let snapshot = ComposerSubmissionSnapshot(
            mode: .autoEdit,
            approvalScope: .turn,
            effort: .high,
            sessionID: activeSessionID.uuidString,
            turnID: 7,
            taskID: "task",
            workspaceID: "workspace",
            createdAt: Date(),
            policyRevision: "revision"
        )

        #expect(
            ComposerPolicyPresentation.activeSnapshot(
                snapshot,
                activeSessionID: activeSessionID
            ) == snapshot
        )
        #expect(
            ComposerPolicyPresentation.activeSnapshot(
                snapshot,
                activeSessionID: UUID()
            ) == nil
        )
        #expect(
            ComposerPolicyPresentation.snapshotSummary(snapshot)
                == "权限模式：自动编辑 · 工作量：高"
        )
    }

    @Test("Composer input resolves the live typography token at the input seam")
    func composerInputUsesTypographyTokenSize() {
        let fallback = NSFont.systemFont(ofSize: 12)

        #expect(
            ComposerScrollField.resolvedFont(
                fallback: fallback,
                composerBodySize: 18
            ).pointSize == 18
        )
        #expect(
            ComposerScrollField.resolvedFont(
                fallback: fallback,
                composerBodySize: nil
            ).pointSize == 12
        )
    }
}
