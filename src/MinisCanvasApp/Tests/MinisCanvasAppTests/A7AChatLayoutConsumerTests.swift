import Foundation
import Testing

@testable import MinisCanvasApp

@Suite("A7-A 主聊天布局 production consumer")
struct A7AChatLayoutConsumerTests {
    private func source(_ relativePath: String) throws -> String {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // MinisCanvasAppTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // MinisCanvasApp
            .deletingLastPathComponent() // src
            .deletingLastPathComponent() // repository
        return try String(
            contentsOf: repositoryRoot.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    @Test("600–1600pt 主聊天外圈留白随宽度类稳定变化")
    func surfaceMetricsMatrix() {
        let compact = ChatSurfaceLayoutMetrics.forWidth(600)
        #expect(compact.widthClass == .compact)
        #expect(compact.surfaceGutter == 0)
        #expect(compact.minimumContentWidth == 600)

        let medium = ChatSurfaceLayoutMetrics.forWidth(800)
        #expect(medium.widthClass == .medium)
        #expect(medium.surfaceGutter == 4)

        let regular = ChatSurfaceLayoutMetrics.forWidth(1_100)
        #expect(regular.widthClass == .regular)
        #expect(regular.surfaceGutter == 8)

        let wide = ChatSurfaceLayoutMetrics.forWidth(1_600)
        #expect(wide.widthClass == .wide)
        #expect(wide.surfaceGutter == 12)
    }

    @Test("主聊天 surface 保留状态消费者和稳定 AX 层级")
    func productionConsumersKeepStableHierarchy() throws {
        let content = try source(
            "src/MinisCanvasApp/Sources/MinisCanvasApp/ContentView.swift"
        )
        let composer = try source(
            "src/MinisCanvasApp/Sources/MinisCanvasApp/GlobalComposerView.swift"
        )
        let empty = try source(
            "src/MinisCanvasApp/Sources/MinisCanvasApp/ChatEmptyStateView.swift"
        )

        for contract in [
            "struct ChatSurfaceLayoutMetrics",
            "ChatSurfaceLayoutMetrics.forWidth(geometry.size.width)",
            ".accessibilityIdentifier(\"chat.surface\")",
            ".accessibilityIdentifier(\"chat.composer\")"
        ] {
            #expect(content.contains(contract), "Missing chat surface contract: \(contract)")
        }
        for contract in [
            ".accessibilityIdentifier(\"composer.model\")",
            ".accessibilityIdentifier(\"composer.attachments\")",
            ".accessibilityIdentifier(\"composer.plugins\")",
            ".modifier(ComposerDraftAccessibilityValue(chat: chat) { composerAccessibilityValue })",
            "return content.accessibilityValue(value())"
        ] {
            #expect(composer.contains(contract), "Missing composer contract: \(contract)")
        }
        for contract in [
            "GeometryReader { geometry in",
            ".accessibilityIdentifier(\"chat.emptyState.title\")",
            ".accessibilityIdentifier(\"chat.emptyState.prompt\")",
            ".lineLimit(metrics.promptLineLimit)"
        ] {
            #expect(empty.contains(contract), "Missing empty-state contract: \(contract)")
        }
    }

    @Test("用户布局意图使用同一 preferences store 持久化并恢复")
    func layoutPersistenceAndRecoveryContracts() throws {
        let content = try source(
            "src/MinisCanvasApp/Sources/MinisCanvasApp/ContentView.swift"
        )

        for contract in [
            "@AppStorage(\"minisCanvas.mainPane\")",
            "@AppStorage(\"minisCanvas.sessionSidebarCollapsed\")",
            "@AppStorage(\"minisCanvas.contextPanelCollapsed\")",
            "_storedMainPaneRawValue = AppStorage(",
            "let restoredPane = CanvasViewAdmission.pane(",
            "MainPane(rawValue: storedMainPaneRawValue) ?? .chat,",
            "canvasAvailable: canvasAvailable",
            "navStack = [restoredPane]",
            "storedSessionSidebarCollapsed = true",
            "storedContextPanelCollapsed = true",
            "storedMainPaneRawValue = pane.rawValue"
        ] {
            #expect(content.contains(contract), "Missing layout persistence contract: \(contract)")
        }
        #expect(CanvasViewAdmission.pane(.canvas, canvasAvailable: false) == .chat)
        #expect(CanvasViewAdmission.pane(.canvas, canvasAvailable: true) == .canvas)
    }

    @Test("动态分隔策略保留请求宽度并由当前空间决定 effective 宽度")
    func dynamicDividerConsumerUsesEffectivePolicy() {
        let narrow = AdaptiveLayoutPolicy.decision(
            for: 1_280,
            preferredLeftWidth: 500,
            preferredRightWidth: 900
        )
        let wide = AdaptiveLayoutPolicy.decision(
            for: 1_600,
            preferredLeftWidth: 500,
            preferredRightWidth: 900
        )

        #expect(wide.leftWidth > narrow.leftWidth)
        #expect(wide.rightWidth > narrow.rightWidth)
        #expect(wide.leftWidth > 320)
        #expect(wide.rightWidth > 320)
        #expect(wide.leftWidth + wide.rightWidth + wide.mainMinimumWidth <= 1_600)
    }
}
