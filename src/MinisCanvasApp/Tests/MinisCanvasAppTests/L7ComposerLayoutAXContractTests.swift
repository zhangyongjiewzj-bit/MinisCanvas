import Foundation
import Testing

@Suite("L7 Composer layout and AX contracts")
struct L7ComposerLayoutAXContractTests {
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

    @Test("Companion and global composers use one layout contract")
    func composersUseSharedLayoutMetricsAndStableAXIdentity() throws {
        let global = try source(
            "src/MinisCanvasApp/Sources/MinisCanvasApp/GlobalComposerView.swift"
        )
        let companion = try source(
            "src/MinisCanvasApp/Sources/MinisCanvasApp/ChatSidebarView.swift"
        )
        let metrics = try source(
            "src/MinisCanvasApp/Sources/MinisCanvasApp/TypographyTokenProvider.swift"
        )

        for contract in [
            "static let stackSpacing",
            "static let controlSpacing",
            "static let outerPadding",
            "static let iconButtonHitSize"
        ] {
            #expect(metrics.contains(contract), "Missing shared layout token: \(contract)")
        }
        for contract in [
            "ComposerLayoutMetrics.stackSpacing",
            "ComposerLayoutMetrics.controlSpacing",
            "ComposerLayoutMetrics.outerPadding",
            "ComposerLayoutMetrics.iconButtonHitSize"
        ] {
            #expect(global.contains(contract), "Global Composer does not consume: \(contract)")
            #expect(companion.contains(contract), "Companion Composer does not consume: \(contract)")
        }

        #expect(global.contains(".accessibilityIdentifier(\"composer.global\")"))
        #expect(companion.contains(".accessibilityIdentifier(\"composer.companion\")"))
        #expect(global.contains(".accessibilityLabel(\"全局对话输入区\")"))
        #expect(companion.contains(".accessibilityLabel(\"伴随对话输入区\")"))
    }

    @Test("Companion width control has an adjustable keyboard and AX path")
    func companionWidthControlIsAdjustableWithoutPointerDrag() throws {
        let content = try source(
            "src/MinisCanvasApp/Sources/MinisCanvasApp/ContentView.swift"
        )

        for contract in [
            ".accessibilityIdentifier(\"companion.width\")",
            ".accessibilityLabel(\"调整伴随栏宽度\")",
            ".accessibilityValue(\"宽度",
            ".accessibilityAdjustableAction",
            "case .increment",
            "case .decrement"
        ] {
            #expect(content.contains(contract), "Missing companion width AX contract: \(contract)")
        }
    }
}
