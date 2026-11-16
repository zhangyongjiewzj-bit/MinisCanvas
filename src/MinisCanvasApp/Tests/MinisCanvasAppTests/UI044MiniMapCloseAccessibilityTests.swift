import Foundation
import Testing

@testable import MinisCanvasApp

@Suite("UI-044 迷你地图关闭按钮 AX 合同")
struct UI044MiniMapCloseAccessibilityTests {
    private func miniMapSource() throws -> String {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // MinisCanvasAppTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // MinisCanvasApp
            .deletingLastPathComponent() // src
            .deletingLastPathComponent() // repository
        return try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "src/MinisCanvasApp/Sources/MinisCanvasApp/MiniMapView.swift"
            ),
            encoding: .utf8
        )
    }

    private func headerBody() throws -> String {
        let source = try miniMapSource()
        let start = try #require(source.range(of: "    private var header: some View"))
        let end = try #require(source.range(
            of: "    /// 缩略画布",
            range: start.upperBound..<source.endIndex
        ))
        return String(source[start.lowerBound..<end.lowerBound])
    }

    @Test("关闭按钮暴露稳定名称和标识")
    func closeButtonExposesAccessibilityContract() throws {
        let body = try headerBody()

        #expect(body.contains("Button(action: onClose)"))
        #expect(body.contains("Image(systemName: \"xmark\")"))
        #expect(body.contains(".accessibilityLabel(\"关闭迷你地图\")"))
        #expect(body.contains(".accessibilityIdentifier(\"canvas.minimap.close\")"))
        #expect(body.contains(".help(\"关闭迷你地图（⌘M 重新打开）\")"))
    }

    @Test("AX 修复保留关闭动作、图标样式和键盘提示")
    func closeButtonPreservesInteractionContract() throws {
        let body = try headerBody()

        #expect(body.contains("Button(action: onClose)"))
        #expect(body.contains(".buttonStyle(.plain)"))
        #expect(body.contains(".foregroundStyle(.tertiary)"))
        #expect(body.contains("关闭迷你地图（⌘M 重新打开）"))
    }
}
