import Foundation
import Testing

@Suite("Provider secret field submit contract")
struct SettingsProviderSubmitContractTests {
    @Test("ProviderSecretField uses the SwiftUI-compatible submit closure")
    func providerSecretFieldSubmitClosureIsUnlabelled() throws {
        let source = try settingsSource()
        let fieldStart = try #require(source.range(of: "private struct ProviderSecretField"))
        let formStart = try #require(source.range(of: "private struct ProviderEditSheet"))
        let field = String(source[fieldStart.lowerBound..<formStart.lowerBound])

        #expect(field.contains(".onSubmit { onSubmit() }"))
        #expect(!field.contains(".onSubmit(perform: onSubmit)"))
        #expect(field.components(separatedBy: ".onSubmit").count - 1 == 1)
    }

    private func settingsSource() throws -> String {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // MinisCanvasAppTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // MinisCanvasApp
            .deletingLastPathComponent() // src
            .deletingLastPathComponent() // repository
        return try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "src/MinisCanvasApp/Sources/MinisCanvasApp/SettingsView.swift"
            ),
            encoding: .utf8
        )
    }
}
