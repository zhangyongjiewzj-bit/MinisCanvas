import Foundation
import Testing
@testable import MinisCanvasApp

@Suite("MM01 factory actual-process audit requirement", .serialized)
@MainActor struct MM01FactoryAuditRequirementTests {
    @Test(arguments: [false, true])
    func nonMMProcessKeepsLegacyNilAudit(hasTestConfiguration: Bool) {
        // A synthetic factory argv containing MM flags cannot turn the actual
        // non-MM SDK process into an owned live window, or borrow its budget.
        for windowPresent in [false, true] {
            #expect(DeepSeekMM01FieldLane.factoryAuditRequirement(actualProcessRequiresPlan: false,
                hasTestConfiguration: hasTestConfiguration, installedWindowPresent: windowPresent) == .legacyNonMM)
        }
    }
    @Test(arguments: [false, true], [false, true])
    func realMMProcessCannotDisableAudit(hasTestConfiguration: Bool, installedWindowPresent: Bool) {
        let actual = DeepSeekMM01FieldLane.factoryAuditRequirement(actualProcessRequiresPlan: true,
            hasTestConfiguration: hasTestConfiguration, installedWindowPresent: installedWindowPresent)
        if !hasTestConfiguration && installedWindowPresent {
            #expect(actual == .ownedMM)
        } else {
            #expect(actual == nil)
        }
    }
}
