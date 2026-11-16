import Foundation
import MinisCore
import Testing
@testable import MinisCanvasApp

@Suite("APP09 menu argument routing")
@MainActor
struct APP09MenuArgumentRoutingTests {
    @Test
    func requiredArgumentRowsOpenTheRegisteredCommandInTheExistingEditor() throws {
        let bridge = BridgeStore()
        for id in ["env.set", "env.delete", "log.level", "memory.add"] {
            let definition = try #require(bridge.commandRegistry.command(id: id))
            #expect(definition.argumentSpecs.contains(where: { $0.required }))

            bridge.activateCommandRow(id: id)
            #expect(bridge.isCommandPalettePresented)
            #expect(bridge.takeCommandPaletteDraft() == "/\(id) ")
            #expect(bridge.takeCommandPaletteDraft() == nil)
            bridge.isCommandPalettePresented = false
        }
    }

    @Test
    func filledRowUsesParserArgumentsAndArgumentFreeRowsStillExecuteDirectly() throws {
        let bridge = BridgeStore()
        let filled = try #require(CommandPaletteView.filledSubmissionForRow(
            query: "/env.set APP09_KEY=sample value",
            registry: bridge.commandRegistry,
            selectedID: "env.set"
        ))
        #expect(filled.id == "env.set")
        #expect(filled.args == ["name": "APP09_KEY", "value": "sample value"])
        #expect(CommandPaletteView.filledSubmissionForRow(
            query: "/env.set APP09_KEY=sample value",
            registry: bridge.commandRegistry,
            selectedID: "env.delete"
        ) == nil)

        bridge.activateCommandRow(id: "session.new")
        #expect(!bridge.isCommandPalettePresented)
        #expect(bridge.takeCommandPaletteDraft() == nil)
    }
}
