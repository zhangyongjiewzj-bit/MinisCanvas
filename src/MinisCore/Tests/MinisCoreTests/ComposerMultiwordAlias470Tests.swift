import Foundation
import Testing
@testable import MinisCore

struct Alias470Argument: Sendable {
    let input: String
    let id: String
    let args: [String: String]
}

@Suite("D-COMMAND-07 complete English slash aliases")
struct ComposerMultiwordAlias470Tests {
    private func registry() -> CommandRegistry {
        let registry = CommandRegistry()
        registry.registerComposerCommands()
        return registry
    }

    @Test(arguments: ["/boundary set", "/boundary.set", "/设置安全边界",
                      "/BOUNDARY SET", "/boundary\tset", "/boundary   set"])
    func boundaryAliasCannotFallThroughToReadonlyPrefix(input: String) {
        let registry = registry()
        let parsed = CommandParser().parse(input, registry: registry)
        #expect(parsed.command?.id == "boundary.set")
        #expect(parsed.args.isEmpty)
        #expect(parsed.intentDisposition == .authorizationRequired)
        #expect(parsed.exactIntent?.requiresAuthorization == true)
        #expect(CommandRegistry.composerMetadata(for: "boundary.set")?.risk == .high)
        switch registry.validatedComposerPendingRequest(for: parsed) {
        case .failure(let error):
            #expect(error == .missingArgument(commandID: "boundary.set", argument: "profile"))
        case .success:
            Issue.record("Missing profile must fail before policy/pending, including the English alias")
        }
    }

    @Test(arguments: [
        Alias470Argument(input: "/boundary set profile=strict", id: "boundary.set", args: ["profile": "strict"]),
        Alias470Argument(input: "/boundary set \"strict profile\"", id: "boundary.set", args: ["profile": "strict profile"]),
        Alias470Argument(input: "/provider use synthetic/model", id: "provider.use", args: ["provider_model": "synthetic/model"]),
        Alias470Argument(input: "/memory propose \"local synthetic fact\"", id: "memory.propose", args: ["text": "local synthetic fact"]),
    ])
    func completeAliasConsumesOnlyItsOwnTokens(input: Alias470Argument) throws {
        let registry = registry()
        let parsed = CommandParser().parse(input.input, registry: registry)
        #expect(parsed.command?.id == input.id)
        #expect(parsed.args == input.args)
        let pending = try registry.validatedComposerPendingRequest(for: parsed).get()
        #expect(pending.commandID == input.id && pending.args == input.args)
        #expect(pending.requiresPolicyApproval) // Parsing never approves or executes.
    }

    @Test func choiceValidationAndLocalizedNormalizationAreUnchanged() throws {
        let registry = registry()
        let parser = CommandParser()
        let invalid = parser.parse("/canvas minimap mode=sideways", registry: registry)
        #expect(invalid.command?.id == "canvas.minimap")
        switch registry.validatedComposerPendingRequest(for: invalid) {
        case .failure(.invalidArgument(let id, let argument, let reason)):
            #expect(id == "canvas.minimap" && argument == "mode")
            #expect(reason.contains("on") && reason.contains("off"))
        case .failure, .success:
            Issue.record("Multiword alias must retain the exact enum validation boundary")
        }
        let localized = parser.parse("/canvas minimap mode=开启", registry: registry)
        let pending = try registry.validatedComposerPendingRequest(for: localized).get()
        #expect(pending.commandID == "canvas.minimap" && pending.args == ["mode": "on"])
        // Core registration here is parse-only; it does not enable App Canvas.
    }

    @Test func shortPrefixesAndOrdinaryProseRetainTheirOwnSemantics() {
        let registry = registry()
        let parser = CommandParser()
        for id in ["boundary", "provider", "memory"] {
            let parsed = parser.parse("/\(id)", registry: registry)
            #expect(parsed.command?.id == id && parsed.args.isEmpty)
        }
        for prose in ["boundary set", "provider use synthetic/model", "memory propose local fact",
                      "请显示当前状态", "please boundary set strict", "https://example.invalid/boundary set",
                      "```/boundary set```"] {
            let parsed = parser.parse(prose, registry: registry)
            #expect(parsed.command == nil && parsed.exactIntent == nil)
            #expect(parsed.disposition == .message)
        }
    }
}
