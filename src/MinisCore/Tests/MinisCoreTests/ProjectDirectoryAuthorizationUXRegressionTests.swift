import Foundation
import Testing
@testable import MinisCore

@Suite("Goal20 project directory authorization UX regression")
struct ProjectDirectoryAuthorizationUXRegressionTests {
    private func fixture() throws -> (base: URL, allowed: URL, additional: URL) {
        let formal = try #require(FormalTestIsolationPaths.currentOrFail())
        let base = formal.rootDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("goal20-project-authorization-\(UUID().uuidString)")
        let allowed = base.appendingPathComponent("allowed", isDirectory: true)
        let additional = base.appendingPathComponent("additional", isDirectory: true)
        for directory in [allowed, additional] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        // Synthetic fixtures remain inside this run's formal root for the cleanup owner.
        return (base, allowed, additional)
    }

    @Test func allowedAndAdditionalRootsReturnOriginalCanonicalDirectory() throws {
        let (_, allowed, additional) = try fixture()
        let executor = BuiltinToolExecutor(allowedRoot: allowed, deniedRoots: [],
            additionalAllowedRoots: [additional])
        for directory in [allowed, additional] {
            let original = try executor.validatedTargetWorkspaceDirectory(directory.path)
            let project = try executor.validatedProjectAuthorizationDirectory(directory.path)
            #expect(project == original)
            #expect(project.path == directory.path)
        }
    }

    @Test func outsideRootsReportsTypedBoundaryWithoutChangingOriginalError() throws {
        let (base, allowed, _) = try fixture()
        let outside = base.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        let executor = BuiltinToolExecutor(allowedRoot: allowed, deniedRoots: [])
        do {
            _ = try executor.validatedProjectAuthorizationDirectory(outside.path)
            Issue.record("An outside directory must not be authorized")
        } catch BuiltinToolExecutor.ProjectDirectoryAuthorizationError.outsideAccessibleRoots {
        } catch {
            Issue.record("Expected outsideAccessibleRoots, received \(error)")
        }
        #expect(throws: ToolExecutorError.pathViolation(outside.path)) {
            _ = try executor.validatedTargetWorkspaceDirectory(outside.path)
        }
    }

    @Test func missingAllowedDirectoryReportsTypedUnavailable() throws {
        let (_, allowed, _) = try fixture()
        let missing = allowed.appendingPathComponent("missing")
        let executor = BuiltinToolExecutor(allowedRoot: allowed, deniedRoots: [])
        do {
            _ = try executor.validatedProjectAuthorizationDirectory(missing.path)
            Issue.record("A missing directory must not be authorized")
        } catch BuiltinToolExecutor.ProjectDirectoryAuthorizationError.directoryUnavailable {
        } catch {
            Issue.record("Expected directoryUnavailable, received \(error)")
        }
        #expect(throws: ToolExecutorError.pathViolation(missing.path)) {
            _ = try executor.validatedTargetWorkspaceDirectory(missing.path)
        }
    }

    @Test func deniedAndNoncanonicalSymlinkKeepOriginalPolicyRejection() throws {
        let (_, allowed, additional) = try fixture()
        let denied = allowed.appendingPathComponent("denied", isDirectory: true)
        try FileManager.default.createDirectory(at: denied, withIntermediateDirectories: false)
        let alias = allowed.appendingPathComponent("additional-alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: additional)
        let executor = BuiltinToolExecutor(allowedRoot: allowed, deniedRoots: [denied],
            additionalAllowedRoots: [additional])
        for directory in [denied, alias] {
            #expect(throws: ToolExecutorError.pathViolation(directory.path)) {
                _ = try executor.validatedProjectAuthorizationDirectory(directory.path)
            }
            #expect(throws: ToolExecutorError.pathViolation(directory.path)) {
                _ = try executor.validatedTargetWorkspaceDirectory(directory.path)
            }
        }
    }
}
