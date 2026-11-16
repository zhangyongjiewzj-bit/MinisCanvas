import Foundation
import Testing

@Suite("Chat deletion UI contracts")
struct ChatDeletionUIContractTests {
    private func source() throws -> String {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // MinisCanvasAppTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // MinisCanvasApp
            .deletingLastPathComponent() // src
            .deletingLastPathComponent() // repository
        return try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "src/MinisCanvasApp/Sources/MinisCanvasApp/ChatSidebarView.swift"
            ),
            encoding: .utf8
        )
    }

    @Test("session deletion UI starts an intent preview for both locations")
    func deletionEntriesStartPreview() throws {
        let content = try source()

        #expect(content.contains("beginDeletion(id: session.id, archived: false)"))
        #expect(content.contains("beginDeletion(id: item.session.id, archived: true)"))
        #expect(!content.contains("chat.deleteSession(id: session.id)"))
        #expect(!content.contains("chat.deleteArchivedSession(id: item.session.id)"))
    }

    @Test("deletion UI passes user-entered confirmations and exposes lifecycle errors")
    func deletionConfirmationUsesUserInput() throws {
        let content = try source()

        for contract in [
            "withFirstConfirmation(firstConfirmation)",
            "withSecondConfirmation(secondConfirmation)",
            "DeletionGate.cancel(request.intent)",
            "case .expired",
            "case .cancelled",
            "case .alreadyConsumed",
            "chat.deletion.firstConfirmation",
            "chat.deletion.secondConfirmation"
        ] {
            #expect(content.contains(contract), "Missing deletion UI contract: \(contract)")
        }

        #expect(!content.contains("withFirstConfirmation(\""))
        let recoverable = try #require(content.range(
            of: "if request.intent.reversible {\n                    Button(\"移入回收站\", role: .destructive)"
        ))
        let typed = try #require(content.range(
            of: "} else {\n                    switch step {",
            range: recoverable.upperBound..<content.endIndex
        ))
        let literalPrefix = "withSecondConfirmation(\""
        #expect(content.components(separatedBy: literalPrefix).count - 1 == 1)
        #expect(content[recoverable.upperBound..<typed.lowerBound]
            .contains("withSecondConfirmation(\"移入回收站\")"))
        #expect(!content[typed.upperBound...].contains(literalPrefix))
    }
}
