import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

@Suite("Session-derived file root")
struct SessionFileRootPolicyTests {
    @Test func projectRootReplacesAmbientHomeAndFollowsSelectedSession() {
        let storage = URL(fileURLWithPath: "/synthetic/profile/sessions")
        let a = SessionFileRootPolicy.root(explicit: nil, workingDirectory: "/synthetic/projects/a",
            sessionDirectory: storage, sessionID: UUID())
        let b = SessionFileRootPolicy.root(explicit: nil, workingDirectory: "/synthetic/projects/b",
            sessionDirectory: storage, sessionID: UUID())
        #expect(a.path == "/synthetic/projects/a")
        #expect(b.path == "/synthetic/projects/b")
    }

    @Test func explicitRootAndProjectlessIdentityRemainDistinct() {
        let id = UUID()
        let storage = URL(fileURLWithPath: "/synthetic/profile/sessions")
        let explicit = URL(fileURLWithPath: "/synthetic/explicit")
        #expect(SessionFileRootPolicy.root(explicit: explicit, workingDirectory: "/synthetic/project",
            sessionDirectory: storage, sessionID: id) == explicit)
        #expect(SessionFileRootPolicy.root(explicit: nil, workingDirectory: nil,
            sessionDirectory: storage, sessionID: id).path == storage.path + "/workspaces/" + id.uuidString)
    }

    @Test func legacySchemaRetainsExplicitSettingsAndRecordsVersion() throws {
        let decoder = JSONDecoder()
        let implicit = try decoder.decode(PrivacySettings.self, from: Data("{}".utf8))
        #expect(implicit.allowedRootPath == nil)
        #expect(implicit.fileRootPolicyVersion == 1)
        let legacy = Data(#"{"allowedRootPath":"/synthetic/home","mountedFolderPaths":["/synthetic/mount"]}"#.utf8)
        let explicit = try decoder.decode(PrivacySettings.self, from: legacy)
        #expect(explicit.allowedRootPath == "/synthetic/home")
        #expect(explicit.mountedFolderPaths == ["/synthetic/mount"])
        let once = try JSONEncoder().encode(explicit)
        let reloaded = try decoder.decode(PrivacySettings.self, from: once)
        #expect(reloaded == explicit)
        #expect(reloaded.fileRootPolicyVersion == 1)
    }

}
