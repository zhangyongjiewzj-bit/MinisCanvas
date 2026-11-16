import Foundation
import Testing

@Suite("Swift interpolation production surface")
struct SwiftInterpolationContractTests {
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

    @Test("dynamic labels keep their runtime interpolation expressions")
    func dynamicLabelsRemainInterpolated() throws {
        let inspector = try source(
            "src/MinisCanvasApp/Sources/MinisCanvasApp/NodeInspectorView.swift"
        )
        let editor = try source(
            "src/MinisCanvasApp/Sources/MinisCanvasApp/NodeContentEditorView.swift"
        )
        let settings = try source(
            "src/MinisCanvasApp/Sources/MinisCanvasApp/SettingsView.swift"
        )

        #expect(inspector.contains(#"displayName: "\(provider.name) · \(entry.displayName)""#))
        #expect(editor.contains(#"Text("\(draft.count) 字符")"#))
        #expect(settings.contains(#".help("\(m.provider) · \(m.display)")"#))
        #expect(settings.contains(#"center.availableModelWhitelist.count) 个模型"#))
        #expect(settings.contains(#"showFeedback("已移除拒绝目录：\(path)")"#))
        #expect(settings.contains(#"Section("记忆（\(center.memoryFacts.count)）")"#))
    }

    @Test("target files reject accidental double-escaped interpolation")
    func targetFilesContainNoDoubleEscapedInterpolation() throws {
        let paths = [
            "src/MinisCanvasApp/Sources/MinisCanvasApp/NodeInspectorView.swift",
            "src/MinisCanvasApp/Sources/MinisCanvasApp/NodeContentEditorView.swift",
            "src/MinisCanvasApp/Sources/MinisCanvasApp/SettingsView.swift"
        ]

        for path in paths {
            let contents = try source(path)
            #expect(!contents.contains(#"\\("#), "Unexpected literal interpolation escape in \(path)")
        }
    }
}
