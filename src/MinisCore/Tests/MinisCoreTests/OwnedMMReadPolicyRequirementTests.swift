import Foundation
import Testing
@testable import MinisCore

struct OwnedMMReadPolicyRequirementTests {
    @Test func realProcessRequirementIsImmutableAndMetadataReadsDoNotConsumeBudget() {
        let ordinary = OwnedMMCredentialReadPolicy(requiresPlan: false)
        #expect(!ordinary.requiresOwnedWindow)
        #expect(!ordinary.arm())
        #expect(!ordinary.requiresOwnedWindow)
        let owned = OwnedMMCredentialReadPolicy(requiresPlan: true)
        #expect(owned.requiresOwnedWindow && owned.arm())
        #expect(owned.install(nonce: String(repeating: "a", count: 32), limit: 1, deadline: .distantFuture))
        let before = owned.snapshot
        for _ in 0..<3 { #expect(owned.requiresOwnedWindow && owned.activeWindow != nil) }
        #expect(owned.snapshot.reserved == before.reserved && owned.snapshot.refused == before.refused)
        #expect(!owned.install(nonce: String(repeating: "b", count: 32), limit: 100, deadline: .distantFuture))
        #expect(owned.requiresOwnedWindow)
        owned.rejectPlan()
        #expect(owned.requiresOwnedWindow && owned.snapshot.limit == 1)
        let blocked = OwnedMMCredentialReadPolicy(requiresPlan: true)
        #expect(blocked.arm())
        #expect(!blocked.install(nonce: "invalid", limit: 1, deadline: .distantPast))
        #expect(blocked.requiresOwnedWindow && blocked.activeWindow == nil)
    }
}
