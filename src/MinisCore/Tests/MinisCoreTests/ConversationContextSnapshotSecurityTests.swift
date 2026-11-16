import Testing
@testable import MinisCore

@Suite("Conversation context snapshot security boundaries")
struct ConversationContextSnapshotSecurityTests {
    private func snapshot(
        snapshotID: String? = nil,
        sessionID: String = "session-security",
        providerID: String = "provider-security",
        modelID: String = "model-security",
        configurationFingerprint: String = "fingerprint-security",
        skillIdentifiers: [String] = ["browser", "file_read"],
        conversationID: String? = "conversation-security"
    ) -> ConversationContextSnapshotV1 {
        ConversationContextSnapshotV1(
            snapshotID: snapshotID,
            sessionID: sessionID,
            providerID: providerID,
            modelID: modelID,
            configurationFingerprint: configurationFingerprint,
            skillIdentifiers: skillIdentifiers,
            conversationID: conversationID
        )
    }

    @Test("field delimiter collisions produce distinct canonical IDs")
    func delimiterCollisionIsNotAnIdentityAlias() {
        let first = snapshot(sessionID: "session:a", providerID: "provider")
        let second = snapshot(sessionID: "session", providerID: "a:provider")

        #expect(first.snapshotID != second.snapshotID)
        #expect(first.isValid)
        #expect(second.isValid)
        #expect(first.matches(second) == false)
    }

    @Test("skill delimiter collisions and duplicate skills fail closed")
    func skillCanonicalizationIsUnambiguous() {
        let commaSkill = snapshot(skillIdentifiers: ["a,b"])
        let splitSkills = snapshot(skillIdentifiers: ["a", "b"])
        #expect(commaSkill.snapshotID != splitSkills.snapshotID)
        #expect(commaSkill.isValid)
        #expect(splitSkills.isValid)
        #expect(commaSkill.matches(splitSkills) == false)

        let duplicateSkills = snapshot(skillIdentifiers: ["browser", "browser"])
        #expect(duplicateSkills.isValid == false)
        #expect(duplicateSkills.matches(duplicateSkills) == false)
    }

    @Test("unsafe and unbounded binding facts are rejected")
    func unsafeBindingFactsFailClosed() {
        let unsafe = snapshot(sessionID: "session\u{202E}forged")
        #expect(unsafe.isValid == false)
        #expect(unsafe.matches(unsafe) == false)

        let control = snapshot(providerID: "provider\u{0000}forged")
        #expect(control.isValid == false)
        #expect(control.matches(control) == false)

        let oversized = snapshot(modelID: String(repeating: "m", count: 257))
        #expect(oversized.isValid == false)
        #expect(oversized.matches(oversized) == false)

        let emptyProvider = snapshot(providerID: "")
        #expect(emptyProvider.isValid == false)
        #expect(emptyProvider.matches(emptyProvider) == false)

        let whitespace = snapshot(providerID: "provider security")
        #expect(whitespace.isValid == false)
        #expect(whitespace.matches(whitespace) == false)

        let tooManySkills = snapshot(
            skillIdentifiers: (0..<129).map { "skill-\($0)" }
        )
        #expect(tooManySkills.isValid == false)
        #expect(tooManySkills.matches(tooManySkills) == false)
    }

    @Test("legacy-safe IDs remain stable while unsafe values use framed canonical IDs")
    func legacyCompatibilityAndFraming() {
        let safe = snapshot()
        #expect(safe.snapshotID == safe.canonicalSnapshotID())
        #expect(safe.snapshotID.hasPrefix("context:"))

        let framed = snapshot(sessionID: "session/with/slash")
        #expect(framed.snapshotID.hasPrefix("context:v2:"))
        #expect(framed.snapshotID == framed.canonicalSnapshotID())
        #expect(framed.isValid)
    }

    @Test("published delimiter ID is recognized only as inert production history")
    func historicalProductionIDNeverBecomesCurrentAuthority() {
        let session = "00000000-0000-4000-8000-000000000001"
        let oldID = "context:\(session):mock:model-synthetic:chat:v1:mock:model-synthetic:1024:browser,file_read:\(session)"
        let old = snapshot(
            snapshotID: oldID,
            sessionID: session,
            providerID: "mock",
            modelID: "model-synthetic",
            configurationFingerprint: "chat:v1:mock:model-synthetic:1024",
            conversationID: session
        )
        #expect(old.isRecognizedLegacyProductionSnapshot)
        #expect(!old.isValid)
        #expect(!old.matches(old))
        #expect(old.snapshotID != old.canonicalSnapshotID())

        let changed = snapshot(
            snapshotID: oldID,
            sessionID: session,
            providerID: "mock",
            modelID: "other-model",
            configurationFingerprint: "chat:v1:mock:other-model:1024",
            conversationID: session
        )
        #expect(!changed.isRecognizedLegacyProductionSnapshot)

        let ambiguous = snapshot(
            snapshotID: "context:\(session):mock:model-synthetic:chat:v1:mock:model-synthetic:1024:a,b:\(session)",
            sessionID: session,
            providerID: "mock",
            modelID: "model-synthetic",
            configurationFingerprint: "chat:v1:mock:model-synthetic:1024",
            skillIdentifiers: ["a,b"],
            conversationID: session
        )
        #expect(ambiguous.isRecognizedLegacyProductionSnapshot)
        #expect(!ambiguous.isValid)
        #expect(!ambiguous.matches(ambiguous))
        let splitSkills = snapshot(
            snapshotID: ambiguous.snapshotID, sessionID: session,
            providerID: "mock", modelID: "model-synthetic",
            configurationFingerprint: "chat:v1:mock:model-synthetic:1024",
            skillIdentifiers: ["a", "b"], conversationID: session
        )
        #expect(splitSkills.isRecognizedLegacyProductionSnapshot)
        #expect(ambiguous != splitSkills)
        #expect(!ambiguous.matches(splitSkills))

        let current = snapshot(
            sessionID: session,
            providerID: "mock",
            modelID: "model-synthetic",
            configurationFingerprint: "chat:v1:mock:model-synthetic:1024",
            conversationID: session
        )
        #expect(current.isValid)
        #expect(!current.isRecognizedLegacyProductionSnapshot)
    }

    @Test("old provider-model aliases may be retained but never authorize a turn")
    func taggedLocalModelCannotBecomeHistoricalAuthority() {
        let session = "00000000-0000-4000-8000-000000000001"
        let fingerprint = "chat:v1:Local:qwen:7b:1024"
        let oldID = "context:\(session):Local:qwen:7b:\(fingerprint):browser:\(session)"
        let local = snapshot(
            snapshotID: oldID, sessionID: session, providerID: "Local",
            modelID: "qwen:7b", configurationFingerprint: fingerprint,
            skillIdentifiers: ["browser"], conversationID: session
        )
        let alias = snapshot(
            snapshotID: oldID, sessionID: session, providerID: "Local:qwen",
            modelID: "7b", configurationFingerprint: fingerprint,
            skillIdentifiers: ["browser"], conversationID: session
        )
        #expect(local.historicalCanonicalSnapshotID() == oldID)
        #expect(alias.historicalCanonicalSnapshotID() == oldID)
        #expect(local != alias)
        #expect(local.isRecognizedLegacyProductionSnapshot)
        #expect(alias.isRecognizedLegacyProductionSnapshot)
        #expect(!local.isValid)
        #expect(!alias.isValid)
        #expect(!local.matches(local))
        #expect(!alias.matches(alias))
        #expect(!local.matches(alias))
    }
}
