import Foundation
import Testing
@testable import MinisCore

private func makeMemoryVisibilityTestDirectory() throws -> URL {
    let paths = try #require(try FormalTestIsolationPaths.resolveCurrentProcess())
    let directory = paths.rootDirectory
        .appendingPathComponent("MinisCore-MemoryVisibility-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

struct MemoryVisibilityIsolationTests {
    @Test func unscopedLegacyFactReportsPendingWithoutRewritingOrInjecting() throws {
        let directory = try makeMemoryVisibilityTestDirectory()

        let scope = MemoryScope(sessionID: "session-a", projectID: "project-a")
        let writer = MemoryStore(directory: directory)
        let legacy = try writer.addFact("晴天 legacy", sourceSessionID: scope.sessionID)
        let before = try writer.facts()
        let reader = MemoryStore(directory: directory)
        let result = try MemoryInjector(store: reader).injection(
            base: "base", userMessage: "晴天",
            context: MemoryInjectionContext(scope: scope)
        )

        #expect(result.prompt == "base")
        #expect(result.injectedFactIDs.isEmpty)
        #expect(result.holds == [.legacyAuthorizationPending])
        #expect(try reader.facts() == before)
        #expect(try reader.facts().first?.id == legacy.id)
        #expect(try reader.facts().first?.visibility == nil)
    }

    @Test func missingOrWrongLifetimeNeverFallsBackToSessionOrProject() throws {
        let directory = try makeMemoryVisibilityTestDirectory()

        let scope = MemoryScope(sessionID: "session-a", projectID: "project-a")
        let store = MemoryStore(directory: directory)
        let fact = try store.addFact(
            "晴天 temporary", memoryScope: scope, visibility: .temporary,
            temporaryLifetimeID: "lifetime-a"
        )
        let injector = MemoryInjector(store: store)
        let noLifetime = try injector.injection(
            base: "base", userMessage: "晴天",
            context: MemoryInjectionContext(scope: scope)
        )
        #expect(noLifetime.prompt == "base")
        #expect(noLifetime.holds == [.temporaryLifetimeUnavailable])

        let wrongLifetime = try injector.injection(
            base: "base", userMessage: "晴天",
            context: MemoryInjectionContext(
                scope: scope,
                temporaryLifetime: MemoryTemporaryLifetime(id: "lifetime-b")
            )
        )
        #expect(wrongLifetime.prompt == "base")
        #expect(wrongLifetime.injectedFactIDs.isEmpty)
        #expect(wrongLifetime.holds.isEmpty)

        let matching = try injector.injection(
            base: "base", userMessage: "晴天",
            context: MemoryInjectionContext(
                scope: scope,
                temporaryLifetime: MemoryTemporaryLifetime(id: "lifetime-a")
            )
        )
        #expect(matching.injectedFactIDs == [fact.id])
        #expect(try store.facts().first?.id == fact.id)
    }

    @Test func unverifiedPersonalOwnerAndInvalidRuntimeScopeAreUnavailable() throws {
        let directory = try makeMemoryVisibilityTestDirectory()

        let scope = MemoryScope(sessionID: "session-a", projectID: "project-a")
        let store = MemoryStore(directory: directory)
        #expect(MemoryTrustedPrincipal.validated(userID: "user-a", by: { _ in false }) == nil)
        #expect(throws: MemoryVisibilityError.invalidMetadata) {
            try store.addFact(
                "晴天 personal", memoryScope: scope,
                ownerUserID: "local-user", visibility: .personal
            )
        }
        let invalid = try MemoryInjector(store: store).injection(
            base: "base", userMessage: "晴天",
            context: MemoryInjectionContext(
                scope: MemoryScope(sessionID: " ", projectID: "project-a")
            )
        )
        #expect(invalid.prompt == "base")
        #expect(invalid.holds == [.invalidScope])
        #expect(try store.facts().isEmpty)
    }
}
