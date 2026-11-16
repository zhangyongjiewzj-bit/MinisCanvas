import Foundation
import Testing
@testable import MinisCore

private let protectionTestPassword = "correct horse battery staple"

private func protectionTestDirectory(_ name: String) throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("MinisCore-Protection-\(name)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func protectionTestManager(_ directory: URL) -> SyncManager {
    SyncManager(
        sessionStore: SessionStore(directory: directory),
        memoryStore: MemoryStore(directory: directory),
        skillStore: SkillStore(skillsRoot: directory.appendingPathComponent("skills", isDirectory: true)),
        settingsStore: SettingsStore(directory: directory),
        deviceName: "ProtectionTestMac"
    )
}

struct SyncProtectionTests {
    @Test func protectedEnvelopeRoundTripsWithoutPlaintextManifest() throws {
        let sourceDirectory = try protectionTestDirectory("round-trip-source")
        let destinationDirectory = try protectionTestDirectory("round-trip-destination")
        defer {
            try? FileManager.default.removeItem(at: sourceDirectory)
            try? FileManager.default.removeItem(at: destinationDirectory)
        }

        let source = protectionTestManager(sourceDirectory)
        let memoryScope = MemoryScope(sessionID: "protected-session", projectID: "project-1")
        try source.sessionStore.createSession(id: "protected-session", title: "private title")
        try source.memoryStore.addFact(
            "private memory",
            sourceSessionID: "protected-session",
            memoryScope: memoryScope
        )
        let file = sourceDirectory.appendingPathComponent("protected.minissync")
        try source.exportSnapshotFile(to: file, protection: .password(protectionTestPassword))

        let bytes = try Data(contentsOf: file)
        let object = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        #expect(object["manifest"] == nil)
        #expect(object["sessions"] == nil)
        #expect(object["memories"] == nil)
        #expect(try source.snapshotProtectionKind(from: file) == .passwordProtected)

        let destination = protectionTestManager(destinationDirectory)
        _ = try destination.importSnapshotFile(
            from: file,
            memoryScope: memoryScope,
            protection: .password(protectionTestPassword)
        )
        #expect(destination.sessionStore.loadSession(id: "protected-session")?.title == "private title")
        #expect(try destination.memoryStore.facts().map(\.text) == ["private memory"])
    }

    @Test func wrongPasswordAndTamperDoNotWriteTarget() throws {
        let sourceDirectory = try protectionTestDirectory("failure-source")
        let destinationDirectory = try protectionTestDirectory("failure-destination")
        defer {
            try? FileManager.default.removeItem(at: sourceDirectory)
            try? FileManager.default.removeItem(at: destinationDirectory)
        }

        let source = protectionTestManager(sourceDirectory)
        try source.sessionStore.createSession(id: "incoming", title: "incoming")
        let file = sourceDirectory.appendingPathComponent("protected.minissync")
        try source.exportSnapshotFile(to: file, protection: .password(protectionTestPassword))

        let destination = protectionTestManager(destinationDirectory)
        try destination.sessionStore.createSession(id: "keep", title: "keep")
        #expect(throws: SyncProtectionError.wrongPasswordOrCorrupt) {
            try destination.importSnapshotFile(from: file, protection: .password("wrong password value"))
        }
        #expect(destination.sessionStore.listSessions().map(\.id) == ["keep"])

        var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        var protection = try #require(object["protection"] as? [String: Any])
        let sealedBase64 = try #require(protection["sealedPayload"] as? String)
        var sealed = try #require(Data(base64Encoded: sealedBase64))
        sealed[0] = sealed[0] ^ 1
        protection["sealedPayload"] = sealed.base64EncodedString()
        object["protection"] = protection
        let tampered = sourceDirectory.appendingPathComponent("tampered.minissync")
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: tampered)
        #expect(throws: SyncProtectionError.wrongPasswordOrCorrupt) {
            try destination.importSnapshotFile(from: tampered, protection: .password(protectionTestPassword))
        }
        #expect(destination.sessionStore.listSessions().map(\.id) == ["keep"])
    }

    @Test func protectedMarkerRequiresPasswordAndLegacyRemainsExplicit() throws {
        let directory = try protectionTestDirectory("legacy")
        defer { try? FileManager.default.removeItem(at: directory) }
        let manager = protectionTestManager(directory)
        let legacy = directory.appendingPathComponent("legacy.minissync")
        try manager.exportSnapshotFile(scopes: [.settings], to: legacy)
        #expect(try manager.snapshotProtectionKind(from: legacy) == .legacyPlaintext)
        _ = try manager.importSnapshotFile(from: legacy)

        let protected = directory.appendingPathComponent("protected.minissync")
        try manager.exportSnapshotFile(scopes: [.settings], to: protected, protection: .password(protectionTestPassword))
        #expect(throws: SyncProtectionError.protectionRequired) {
            try manager.importSnapshotFile(from: protected)
        }
    }

    @Test func passwordAndProtectionParametersFailBeforePayloadWork() throws {
        let payload = Data(#"{"manifest":{"version":1,"exportedAt":0,"deviceName":"T","scopes":["settings"]},"settings":{}}"#.utf8)
        #expect(throws: SyncProtectionError.invalidParameters) {
            try SyncProtectionCodec.seal(payload, password: "short")
        }

        let invalid = SyncProtectedEnvelope(
            format: SyncProtectionCodec.format,
            containerVersion: SyncManifest.protectedContainerVersion,
            protection: SyncProtectedPayload(
                scheme: SyncProtectionCodec.scheme,
                schemeVersion: SyncProtectionCodec.schemeVersion,
                iterations: SyncProtectionCodec.maximumRounds + 1,
                salt: Data(repeating: 0, count: SyncProtectionCodec.saltLength),
                nonce: Data(repeating: 0, count: SyncProtectionCodec.nonceLength),
                aadVersion: SyncProtectionCodec.aadVersion,
                sealedPayload: Data(repeating: 0, count: SyncProtectionCodec.tagLength)
            )
        )
        let encoder = JSONEncoder()
        #expect(throws: SyncProtectionError.invalidParameters) {
            try SyncProtectionCodec.open(encoder.encode(invalid), password: protectionTestPassword)
        }
    }
}
