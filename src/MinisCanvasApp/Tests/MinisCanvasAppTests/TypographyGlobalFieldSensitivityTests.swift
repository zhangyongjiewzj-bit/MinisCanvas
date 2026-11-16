import AppKit
import Foundation
import SwiftUI
import Testing
@testable import MinisCanvasApp

/// Deterministic contract for the package-bound executable field journey.
/// Real field measurements are produced only by the packaged App's WindowGroup;
/// ordinary `swift test` must never promote synthetic NSHosting output.
@Suite("UX-01 executable global typography sensitivity")
@MainActor
struct TypographyGlobalFieldSensitivityTests {
    @Test("Composer NSTextView responds at 12pt and 20pt in both widths")
    func composerNSTextViewResponds() {
        let measurements = TypographyGlobalFieldSensitivitySupport.composerMeasurements()
        #expect(measurements.count == 4)
        #expect(measurements.filter { $0.fontPointSize == 12 }.count == 2)
        #expect(measurements.filter { $0.fontPointSize == 20 }.count == 2)
        #expect(measurements.allSatisfy { $0.bounds.width > 0 && !$0.isClipped })
    }

    @Test("Session row requires four title and four metadata package observations")
    func sessionRowPackageContract() {
        let steps = contractSteps()
        let titles = steps.filter { $0.semanticField == "sessionTitle" }
        let metadata = steps.filter { $0.semanticField == "sessionMetadata" }
        #expect(titles.count == 4)
        #expect(metadata.count == 4)
        #expect(Set(titles.map(\.expectedPointSize)) == Set<CGFloat>([12, 20]))
        #expect(Set(metadata.map(\.expectedPointSize)) == Set<CGFloat>([11, 18]))
        #expect((titles + metadata).allSatisfy { $0.surface == .session })
    }

    @Test("Task card requires four package observations")
    func taskCardPackageContract() {
        let steps = contractSteps().filter { $0.semanticField == "taskGoalHeadline" }
        #expect(steps.count == 4)
        #expect(Set(steps.map(\.expectedPointSize)) == Set<CGFloat>([14, 22]))
        #expect(steps.allSatisfy { $0.surface == .task })
    }

    @Test("MCP surface requires four package observations")
    func mcpPackageContract() {
        let steps = contractSteps().filter { $0.semanticField == "mcpServerCount" }
        #expect(steps.count == 4)
        #expect(Set(steps.map(\.expectedPointSize)) == Set<CGFloat>([11, 18]))
        #expect(steps.allSatisfy { $0.surface == .mcp })
    }

    @Test("Settings body requires four package observations")
    func settingsPackageContract() {
        let steps = contractSteps().filter { $0.semanticField == "settingsBody" }
        #expect(steps.count == 4)
        #expect(Set(steps.map(\.expectedPointSize)) == Set<CGFloat>([12, 20]))
        #expect(steps.allSatisfy { $0.surface == .settings })
    }

    private func contractSteps() -> [TypographyPackageFieldJourneyContract.Step] {
        TypographyPackageFieldJourneyContract.steps(
            sessionID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        )
    }
}
