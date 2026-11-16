import Foundation
import Testing
@testable import MinisCanvasApp

@Suite("A7-A UI00 interactive model entry contract")
struct A7AModelEntryContractTests {
    @Test("top and companion headers are read-only while Composer owns model selection")
    func modelSelectionHasOneComposerEntry() throws {
        let root = repositoryRoot()
        let contentView = try String(
            contentsOf: root.appendingPathComponent(
                "src/MinisCanvasApp/Sources/MinisCanvasApp/ContentView.swift"
            ),
            encoding: .utf8
        )
        let sidebarView = try String(
            contentsOf: root.appendingPathComponent(
                "src/MinisCanvasApp/Sources/MinisCanvasApp/ChatSidebarView.swift"
            ),
            encoding: .utf8
        )
        let composerView = try String(
            contentsOf: root.appendingPathComponent(
                "src/MinisCanvasApp/Sources/MinisCanvasApp/GlobalComposerView.swift"
            ),
            encoding: .utf8
        )

        let toolbarStart = try #require(contentView.range(of: "private func toolbar(decision:"))
        let toolbar = contentView[toolbarStart.lowerBound...]
        #expect(!toolbar.contains("Text(\"MinisCanvas\")"))
        let headerStart = try #require(sidebarView.range(of: "private var header: some View"))
        let headerEnd = try #require(sidebarView.range(of: "guard let redactor = transcriptRedactor", range: headerStart.upperBound..<sidebarView.endIndex))
        let header = sidebarView[headerStart.lowerBound..<headerEnd.lowerBound]
        #expect(!header.contains("Text(\"Minis 助手\")"))
        #expect(!header.contains("provider.status.readonly"))

        #expect(!contentView.contains("ChatModelMenu("))
        #expect(contentView.contains("provider.status.readonly"))
        #expect(!sidebarView.contains("ChatModelMenu("))
        #expect(!sidebarView.contains("localModelRow"))
        #expect(!sidebarView.contains("localModelBinding"))
        #expect(!sidebarView.contains("本地模型名（如 qwen2.5）"))
        #expect(sidebarView.contains("ModelMenuButton(chat: chat)"))
        #expect(sidebarView.contains("provider.status.readonly"))
        #expect(composerView.contains("ModelMenuButton(chat: chat)"))
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
