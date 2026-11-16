import Foundation
import Testing
@testable import MinisCore
@testable import MinisCanvasApp

@Suite("P03 trusted App runtime profile adapter")
struct P03RuntimeWorktreeProfileTests {
    @Test("blocked composition never yields a storage home")
    func blockedRejects() throws {
        let adapter = P03RuntimeWorktreeProfile(profile: .blockedProfile())
        #expect(adapter.worktreeProfileIsBlocked)
        #expect(throws: (any Error).self) { try adapter.validatedWorktreeProfileHome() }
    }

    @Test("normal composition selects system home rather than App Support")
    func productionUsesSystemHome() throws {
        let profile = RuntimeIsolationProfile.production
        let adapter = P03RuntimeWorktreeProfile(profile: profile)
        #expect(!adapter.worktreeProfileIsDisposable)
        #expect(!adapter.worktreeProfileIsBlocked)
        #expect(try adapter.validatedWorktreeProfileHome() == FileManager.default.homeDirectoryForCurrentUser)
        #expect(try adapter.validatedWorktreeProfileHome() != profile.rootDirectory)
    }

    @Test("isolated composition uses its captured root and rejects replacement")
    func isolatedIdentityRevalidated() throws {
        let profile = try RuntimeIsolationProfile.makeIsolatedTest(
            label: "P03-adapter", processEnvironment: [:],
            processArguments: ["/tmp/P03RuntimeWorktreeProfileTests.xctest"])
        defer { try? FileManager.default.removeItem(at: profile.rootDirectory) }
        let adapter = P03RuntimeWorktreeProfile(profile: profile)
        #expect(adapter.worktreeProfileIsDisposable)
        #expect(try adapter.validatedWorktreeProfileHome() == profile.rootDirectory)
        try FileManager.default.removeItem(at: profile.rootDirectory)
        #expect(throws: (any Error).self) { try adapter.validatedWorktreeProfileHome() }
    }
    @Test("field composition uses isolated home and refuses a deleted root")
    func fieldIdentityRevalidated() throws {
        let anchor = try RuntimeIsolationProfile.makeIsolatedTest(
            label: "P03-field-anchor", processEnvironment: [:],
            processArguments: ["/tmp/P03RuntimeWorktreeProfileTests.xctest"])
        defer { try? FileManager.default.removeItem(at: anchor.rootDirectory) }
        let root = anchor.rootDirectory.deletingLastPathComponent()
            .appendingPathComponent("P03-field-\(UUID().uuidString)", isDirectory: true)
        let profile = try RuntimeIsolationProfile.makePackagedField(
            processEnvironment: [RuntimeIsolationProfile.fieldActivationMarkerKey: "1",
                                 RuntimeIsolationProfile.fieldActivationRootKey: root.path],
            processArguments: ["MinisCanvas", RuntimeIsolationProfile.fieldActivationArgument])
        defer { try? FileManager.default.removeItem(at: profile.rootDirectory) }
        let adapter = P03RuntimeWorktreeProfile(profile: profile)
        #expect(try adapter.validatedWorktreeProfileHome() == profile.rootDirectory)
        #expect(try adapter.validatedWorktreeProfileHome() != FileManager.default.homeDirectoryForCurrentUser)
        try FileManager.default.removeItem(at: profile.rootDirectory)
        #expect(throws: (any Error).self) { try adapter.validatedWorktreeProfileHome() }
    }

}
