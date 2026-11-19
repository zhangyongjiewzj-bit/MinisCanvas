import Foundation
import Testing
@testable import MinisCore

@Suite("Provider readiness fail-closed contract")
struct ProviderReadinessTests {
    @Test func readinessFailureMessagesAreTypedActionableAndPayloadFree() {
        let secretLikeText = "Authorization: Bearer fixture-secret"
        let cases: [(ProviderReadinessFailureCategory, String, String)] = [
            (.unauthorized, "认证", "Authentication"),
            // S1-07：403 可能是权限，也可能是余额/额度不足，文案合并说明。
            (.permissionDenied, "访问权限", "permission"),
            (.notFound, "端点", "endpoint"),
            (.timeout, "超时", "timed out"),
            (.rateLimited, "限流", "rate limited"),
            (.server, "服务端", "Provider server")
        ]

        for (category, zhNeedle, enNeedle) in cases {
            let message = HTTPStatusMessages.providerReadinessMessage(for: category)
            #expect(message.zh.contains(zhNeedle))
            #expect(message.en.contains(enNeedle))
            #expect(!message.zh.contains(secretLikeText))
            #expect(!message.en.contains(secretLikeText))
            #expect(!message.suggestionZH.isEmpty)
            #expect(!message.suggestionEN.isEmpty)
        }
    }

    @Test func remoteProviderWithoutCredentialIsBlockedBeforeProbeEvidenceIsTrusted() {
        let checkedAt = Date(timeIntervalSince1970: 1_787_000_000)

        let readiness = ProviderReadiness.evaluate(
            providerID: "openai",
            modelID: "gpt-5.4",
            deployment: .remote,
            probe: .reachable,
            credential: .missing(source: "OPENAI_API_KEY"),
            capabilities: [.streaming, .tools],
            checkedAt: checkedAt,
            evidenceID: "must-not-be-trusted"
        )

        #expect(readiness.state == .blocked)
        #expect(readiness.capabilities.isEmpty)
        #expect(readiness.credentialSource == "OPENAI_API_KEY")
        #expect(readiness.checkedAt == checkedAt)
        #expect(readiness.evidenceID == nil)
    }

    @Test func deploymentAndProbeStatusCapTheReadinessClaim() {
        let checkedAt = Date(timeIntervalSince1970: 1_787_000_100)

        let notProbed = evaluate(.remote, .notRun, evidenceID: nil, checkedAt: checkedAt)
        let undeployedLocal = evaluate(.local, .unavailable, evidenceID: "stale", checkedAt: checkedAt)
        let local = evaluate(.local, .reachable, evidenceID: "local-probe", checkedAt: checkedAt)
        let mock = evaluate(.mock, .reachable, evidenceID: "mock-probe", checkedAt: checkedAt)
        let beta = evaluate(.beta, .reachable, evidenceID: "beta-probe", checkedAt: checkedAt)
        let remoteWithoutEvidence = evaluate(.remote, .reachable, evidenceID: "  ", checkedAt: checkedAt)
        let live = evaluate(.remote, .reachable, evidenceID: "live-e2e-42", checkedAt: checkedAt)

        #expect(notProbed.state == .unverified)
        #expect(notProbed.capabilities.isEmpty)
        #expect(undeployedLocal.state == .blocked)
        #expect(undeployedLocal.evidenceID == nil)
        #expect(local.state == .local)
        #expect(mock.state == .mock)
        #expect(beta.state == .beta)
        #expect(remoteWithoutEvidence.state == .unverified)
        #expect(remoteWithoutEvidence.capabilities.isEmpty)
        #expect(live.state == .live)
        #expect(live.capabilities == [.streaming, .tools])
        #expect(live.evidenceID == "live-e2e-42")
        #expect(notProbed.isReadyForSelection == false)
        #expect(live.isReadyForSelection)
    }

    @Test("non-finite timestamps and empty identities cannot become selectable")
    func readinessRejectsInvalidTypedStateInputs() {
        let invalidTimestamp = ProviderReadiness.evaluate(
            providerID: "provider",
            modelID: "model",
            deployment: .remote,
            probe: .reachable,
            credential: .available(source: "fixture"),
            capabilities: [.streaming],
            checkedAt: Date(timeIntervalSinceReferenceDate: .infinity),
            evidenceID: "must-not-be-trusted"
        )
        let emptyIdentity = ProviderReadiness.evaluate(
            providerID: "  ",
            modelID: "model",
            deployment: .remote,
            probe: .reachable,
            credential: .available(source: "fixture"),
            capabilities: [.streaming],
            checkedAt: Date(timeIntervalSinceReferenceDate: 1_787_000_150),
            evidenceID: "must-not-be-trusted"
        )

        #expect(invalidTimestamp.state == .unverified)
        #expect(invalidTimestamp.errorCategory == .invalidConfiguration)
        #expect(invalidTimestamp.evidenceID == nil)
        #expect(invalidTimestamp.capabilities.isEmpty)
        #expect(invalidTimestamp.isReadyForSelection == false)
        #expect(emptyIdentity.state == .unverified)
        #expect(emptyIdentity.errorCategory == .invalidConfiguration)
        #expect(emptyIdentity.isReadyForSelection == false)
    }

    @Test func registryKeepsMockOutOfLiveEvidenceAndIgnoresStaleProbeResults() async {
        let registry = ProviderReadinessRegistry()
        let older = Date(timeIntervalSince1970: 1_787_000_200)
        let newer = Date(timeIntervalSince1970: 1_787_000_300)
        let mock = evaluate(.mock, .reachable, evidenceID: "mock-probe", checkedAt: older)
        let live = evaluate(.remote, .reachable, evidenceID: "live-e2e", checkedAt: newer)

        #expect(await registry.readiness(providerID: "provider", modelID: "model") == nil)

        _ = await registry.refresh(using: FixedProviderReadinessProbe(result: mock))
        #expect(await registry.readiness(providerID: "provider", modelID: "model") == mock)
        #expect(await registry.liveE2EReadiness(providerID: "provider", modelID: "model") == nil)

        _ = await registry.refresh(using: FixedProviderReadinessProbe(result: live))
        _ = await registry.refresh(using: FixedProviderReadinessProbe(result: mock))
        #expect(await registry.readiness(providerID: "provider", modelID: "model") == live)
        #expect(await registry.liveE2EReadiness(providerID: "provider", modelID: "model") == live)

        let sameTimestamp = evaluate(
            .remote,
            .reachable,
            evidenceID: "same-timestamp-retry",
            checkedAt: newer
        )
        _ = await registry.refresh(using: FixedProviderReadinessProbe(result: sameTimestamp))
        #expect(await registry.readiness(providerID: "provider", modelID: "model") == sameTimestamp)
    }

    @Test("registry merges duplicate provider identities into one readiness fact")
    func registryCanonicalizesDuplicateProviderIDs() async {
        let registry = ProviderReadinessRegistry()
        let checkedAt = Date(timeIntervalSince1970: 1_787_000_320)
        let first = ProviderReadiness.evaluate(
            providerID: " Provider ",
            modelID: " model",
            deployment: .remote,
            probe: .reachable,
            credential: .available(source: "fixture"),
            capabilities: [],
            checkedAt: checkedAt,
            evidenceID: "first"
        )
        let second = ProviderReadiness.evaluate(
            providerID: "provider",
            modelID: "model",
            deployment: .remote,
            probe: .reachable,
            credential: .available(source: "fixture"),
            capabilities: [],
            checkedAt: checkedAt,
            evidenceID: "second"
        )

        _ = await registry.refresh(using: FixedProviderReadinessProbe(result: first))
        _ = await registry.refresh(using: FixedProviderReadinessProbe(result: second))
        #expect(await registry.readiness(providerID: "PROVIDER", modelID: "model") == second)
    }

    @Test("revision ordering rejects non-finite candidates and repairs invalid current state")
    func revisionOrderingRejectsInvalidTimestamps() {
        let finite = Date(timeIntervalSinceReferenceDate: 1_787_000_320)
        let invalid = Date(timeIntervalSinceReferenceDate: .nan)

        #expect(ProviderReadinessRevision.accepts(candidateAt: invalid, replacing: nil) == false)
        #expect(ProviderReadinessRevision.accepts(candidateAt: finite, replacing: invalid))
        #expect(ProviderReadinessRevision.accepts(candidateAt: finite, replacing: finite))
    }

    @Test("restart invalidation removes all pre-restart readiness facts")
    func registryInvalidatesForRestart() async {
        let registry = ProviderReadinessRegistry()
        let readiness = evaluate(
            .remote,
            .reachable,
            evidenceID: "live-e2e-restart",
            checkedAt: Date(timeIntervalSince1970: 1_787_000_350)
        )

        _ = await registry.refresh(using: FixedProviderReadinessProbe(result: readiness))
        #expect(await registry.readiness(providerID: "provider", modelID: "model") != nil)
        #expect(await registry.invalidateForRestart() == 1)
        #expect(await registry.readiness(providerID: "provider", modelID: "model") == nil)
        #expect(await registry.liveE2EReadiness(providerID: "provider", modelID: "model") == nil)
    }

    @Test("production consumer clears durable readiness before restart re-entry")
    func productionConsumerInvalidatesForRestart() async {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("P3Readiness-restart-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = ProviderReadinessStore(directory: directory)
        let consumer = ProviderReadinessProductionConsumer(store: store)
        store.upsert(
            ProviderReadinessPersistenceRecord(
                providerID: "provider",
                modelID: "model",
                status: .passed,
                readinessState: .live,
                checkedAt: Date(timeIntervalSince1970: 1_787_000_360),
                evidenceID: "live-e2e-restart",
                isApplied: true
            )
        )

        #expect(await consumer.currentRecords().count == 1)
        #expect(await consumer.invalidateForRestart() == 1)
        #expect(await consumer.currentRecords().isEmpty)
        #expect(ProviderReadinessStore(directory: directory).records.isEmpty)
    }

    @Test func readinessCarriesRedactedFailureTelemetryAndImmutableLineage() {
        let checkedAt = Date(timeIntervalSince1970: 1_787_000_400)
        let lineage = ProviderReadinessLineage(
            discoveryReceiptID: "discover:fixture",
            discoveredAt: checkedAt,
            applyReceiptID: "apply:fixture",
            appliedAt: checkedAt.addingTimeInterval(2)
        )

        let readiness = ProviderReadiness.evaluate(
            providerID: "provider",
            modelID: "model",
            deployment: .remote,
            probe: .unavailable,
            credential: .available(source: "API_KEY"),
            capabilities: [.streaming],
            checkedAt: checkedAt,
            evidenceID: nil,
            errorCategory: .timeout,
            latency: 42,
            lineage: lineage
        )

        #expect(readiness.errorCategory == .timeout)
        #expect(readiness.latency == 42)
        #expect(readiness.lineage == lineage)
        #expect(readiness.state == .blocked)
    }

    @Test func readinessRejectsLineageBoundToAnotherProviderOrModel() {
        let checkedAt = Date(timeIntervalSince1970: 1_787_000_500)
        let mismatchedLineage = ProviderReadinessLineage.derived(
            providerID: "other-provider",
            modelID: "other-model",
            checkedAt: checkedAt
        )

        let readiness = ProviderReadiness.evaluate(
            providerID: "provider",
            modelID: "model",
            deployment: .remote,
            probe: .reachable,
            credential: .available(source: "fixture"),
            capabilities: [.streaming],
            checkedAt: checkedAt,
            evidenceID: "live-evidence",
            lineage: mismatchedLineage
        )

        #expect(
            readiness.lineage
                == ProviderReadinessLineage.derived(
                    providerID: "provider",
                    modelID: "model",
                    checkedAt: checkedAt
                )
        )
    }

    private func evaluate(
        _ deployment: ProviderDeployment,
        _ probe: ProviderProbeStatus,
        evidenceID: String?,
        checkedAt: Date
    ) -> ProviderReadiness {
        ProviderReadiness.evaluate(
            providerID: "provider",
            modelID: "model",
            deployment: deployment,
            probe: probe,
            credential: .notRequired,
            capabilities: [.streaming, .tools],
            checkedAt: checkedAt,
            evidenceID: evidenceID
        )
    }
}

private struct FixedProviderReadinessProbe: ProviderReadinessProbe {
    let result: ProviderReadiness

    func probe() async -> ProviderReadiness {
        result
    }
}
