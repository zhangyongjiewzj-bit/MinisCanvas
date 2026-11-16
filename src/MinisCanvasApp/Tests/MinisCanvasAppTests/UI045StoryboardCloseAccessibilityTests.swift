import Foundation
import Testing

@testable import MinisCanvasApp

@Suite("UI-045 分镜表关闭按钮 AX 合同")
struct UI045StoryboardCloseAccessibilityTests {
    private func storyboardSource() throws -> String {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // MinisCanvasAppTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // MinisCanvasApp
            .deletingLastPathComponent() // src
            .deletingLastPathComponent() // repository
        return try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "src/MinisCanvasApp/Sources/MinisCanvasApp/StoryboardWorkbenchView.swift"
            ),
            encoding: .utf8
        )
    }

    private func headerBody() throws -> String {
        let source = try storyboardSource()
        let start = try #require(source.range(of: "    private var header: some View"))
        let end = try #require(source.range(
            of: "    // MARK: 工具栏",
            range: start.upperBound..<source.endIndex
        ))
        return String(source[start.lowerBound..<end.lowerBound])
    }

    @Test("关闭按钮暴露稳定名称和标识")
    func closeButtonExposesAccessibilityContract() throws {
        let body = try headerBody()

        #expect(body.contains("Button(action: onClose)"))
        #expect(body.contains("Image(systemName: \"xmark\")"))
        #expect(body.contains(".accessibilityLabel(\"关闭分镜表\")"))
        #expect(body.contains(".accessibilityIdentifier(\"canvas.storyboard.close\")"))
        #expect(body.contains(".help(\"关闭分镜表\")"))
    }

    @Test("AX 修复保留关闭动作、无边框样式和原提示")
    func closeButtonPreservesInteractionContract() throws {
        let body = try headerBody()

        #expect(body.contains("Button(action: onClose)"))
        #expect(body.contains(".buttonStyle(.borderless)"))
        #expect(body.contains(".foregroundStyle(.secondary)"))
        #expect(body.contains("关闭分镜表"))
    }
}
