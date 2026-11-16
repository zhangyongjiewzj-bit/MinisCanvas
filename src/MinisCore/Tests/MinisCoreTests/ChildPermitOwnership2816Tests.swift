import Foundation
import Testing
@testable import MinisCore

@Suite("D-CHILDD physical request permit ownership")
struct ChildPermitOwnership2816Tests {
    @Test("late release from an old request cannot transfer a replacement permit")
    func lateOldRequestReleaseCannotAdmitOtherSession() async {
        let governor = ChildConcurrencyGovernor(policy: .init(globalHardCeiling: 1))
        let firstID = ChildLaunchRequestID(rawValue: "2816-first")
        let replacementID = ChildLaunchRequestID(rawValue: "2816-replacement")
        let otherID = ChildLaunchRequestID(rawValue: "2816-other")

        guard case .admitted = await governor.requestLaunch(
            sessionID: "A", requestID: firstID
        ) else {
            Issue.record("first request did not obtain its permit")
            return
        }
        await governor.releaseLaunch(sessionID: "A", requestID: firstID)
        guard case .admitted = await governor.requestLaunch(
            sessionID: "A", requestID: replacementID
        ) else {
            Issue.record("replacement did not obtain the returned permit")
            return
        }

        let other = Task {
            await governor.requestLaunch(sessionID: "B", requestID: otherID)
        }
        for _ in 0..<100 {
            if await governor.checkpoint().queuedSessions == ["B"] { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(await governor.checkpoint().queuedSessions == ["B"])

        // This callback has the same session key, but its exact physical
        // permit was already returned. It must not free the replacement.
        await governor.releaseLaunch(sessionID: "A", requestID: firstID)
        let afterLate = await governor.checkpoint()
        #expect(afterLate.globalActive == 1)
        #expect(afterLate.perSessionActive["A"] == 1)
        #expect(afterLate.perSessionActive["B"] == nil)
        #expect(afterLate.queuedSessions == ["B"])

        await governor.releaseLaunch(sessionID: "A", requestID: replacementID)
        guard case .admitted = await other.value else {
            Issue.record("the actual permit return did not admit B")
            return
        }
        let handedOff = await governor.checkpoint()
        #expect(handedOff.globalActive == 1)
        #expect(handedOff.perSessionActive["B"] == 1)
        await governor.releaseLaunch(sessionID: "B", requestID: otherID)
        #expect(await governor.checkpoint().globalActive == 0)
    }
}
