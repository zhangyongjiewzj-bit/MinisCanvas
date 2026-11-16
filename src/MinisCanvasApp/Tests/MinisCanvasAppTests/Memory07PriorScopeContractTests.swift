import Foundation
import Testing
@testable import MinisCore

/// Contract tests for the minimal `MemoryScope` identity DTO (A5 local slice).
///
/// Scope semantics are fail-closed:
/// - an invalid scope (empty / whitespace-only identifier) never matches and is
///   always isolated from every other scope;
/// - matching requires both identifiers to be non-empty and exactly equal;
/// - isolation only dissolves when two scopes are valid and identical.
struct MemoryScopeContractTests {

    // MARK: - Codable

    @Test func codableRoundTripPreservesSessionAndProject() throws {
        let scope = MemoryScope(sessionID: "session-1", projectID: "project-2")
        let data = try JSONEncoder().encode(scope)
        let decoded = try JSONDecoder().decode(MemoryScope.self, from: data)
        #expect(decoded == scope)
        #expect(decoded.sessionID == "session-1")
        #expect(decoded.projectID == "project-2")
    }

    @Test func codableDecodesStableWireShape() throws {
        let json = #"{"sessionID":"s","projectID":"p"}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(MemoryScope.self, from: json)
        #expect(decoded.sessionID == "s")
        #expect(decoded.projectID == "p")
    }

    @Test func codableDecodesIgnoringUnknownFields() throws {
        let json = #"{"sessionID":"s","projectID":"p","futureField":1}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(MemoryScope.self, from: json)
        #expect(decoded == MemoryScope(sessionID: "s", projectID: "p"))
    }

    // MARK: - Equatable / Hashable

    @Test func equalityRequiresBothIdentifiers() {
        let a = MemoryScope(sessionID: "s1", projectID: "p1")
        let b = MemoryScope(sessionID: "s1", projectID: "p1")
        let differentProject = MemoryScope(sessionID: "s1", projectID: "p2")
        let differentSession = MemoryScope(sessionID: "s2", projectID: "p1")
        #expect(a == b)
        #expect(a != differentProject)
        #expect(a != differentSession)
        #expect(Set([a, b, differentProject]).count == 2)
    }

    // MARK: - Fail-closed validity

    @Test func invalidWhenEitherIdentifierIsEmpty() {
        #expect(MemoryScope(sessionID: "", projectID: "p").isValid == false)
        #expect(MemoryScope(sessionID: "s", projectID: "").isValid == false)
        #expect(MemoryScope(sessionID: "", projectID: "").isValid == false)
        #expect(MemoryScope(sessionID: "s", projectID: "p").isValid == true)
    }

    @Test func whitespaceOnlyIdentifiersAreInvalid() {
        #expect(MemoryScope(sessionID: "   ", projectID: "p").isValid == false)
        #expect(MemoryScope(sessionID: "s", projectID: " \t\n").isValid == false)
    }

    // MARK: - Fail-closed matches

    @Test func matchesRequiresBothNonEmptyAndExactEquality() {
        let scope = MemoryScope(sessionID: "session-9", projectID: "project-9")
        #expect(scope.matches(sessionID: "session-9", projectID: "project-9"))
        #expect(scope.matches(sessionID: "session-9", projectID: "project-8") == false)
        #expect(scope.matches(sessionID: "session-8", projectID: "project-9") == false)
    }

    @Test func matchesFailsClosedOnEmptyRequestIdentifiers() {
        let scope = MemoryScope(sessionID: "session-9", projectID: "project-9")
        #expect(scope.matches(sessionID: "", projectID: "project-9") == false)
        #expect(scope.matches(sessionID: "session-9", projectID: "") == false)
    }

    @Test func matchesFailsClosedForInvalidScope() {
        let blankSession = MemoryScope(sessionID: "", projectID: "project-9")
        #expect(blankSession.matches(sessionID: "", projectID: "project-9") == false)
        let blankProject = MemoryScope(sessionID: "session-9", projectID: "")
        #expect(blankProject.matches(sessionID: "session-9", projectID: "") == false)
    }

    // MARK: - Fail-closed isolation

    @Test func isolationSeparatesScopesOnEitherIdentifier() {
        let a = MemoryScope(sessionID: "s1", projectID: "p1")
        let identical = MemoryScope(sessionID: "s1", projectID: "p1")
        let differentSession = MemoryScope(sessionID: "s2", projectID: "p1")
        let differentProject = MemoryScope(sessionID: "s1", projectID: "p2")
        #expect(a.isIsolated(from: identical) == false)
        #expect(a.isIsolated(from: differentSession))
        #expect(a.isIsolated(from: differentProject))
    }

    @Test func isolationFailsClosedForInvalidScopes() {
        let valid = MemoryScope(sessionID: "s1", projectID: "p1")
        let invalid = MemoryScope(sessionID: "", projectID: "p1")
        let otherInvalid = MemoryScope(sessionID: "", projectID: "p1")
        #expect(valid.isIsolated(from: invalid))
        #expect(invalid.isIsolated(from: otherInvalid))
    }

    // MARK: - Sendable conformance (compile-time guarantee)

    @Test func scopeIsSendable() {
        let scope = MemoryScope(sessionID: "s", projectID: "p")
        let box = SendableBox(value: scope)
        #expect(box.value == scope)
    }
}

/// Compile-time proof that `MemoryScope` is `Sendable`.
private struct SendableBox: Sendable {
    let value: MemoryScope
}
