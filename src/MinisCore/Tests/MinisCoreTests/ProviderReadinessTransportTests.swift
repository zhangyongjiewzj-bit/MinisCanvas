import Foundation
import Testing
@testable import MinisCore

@Suite("Provider readiness mock transport contract")
struct ProviderReadinessTransportTests {
    private let checkedAt = Date(timeIntervalSince1970: 1_787_100_000)

    @Test func happyPathRunsOrderedChecksAndTestsEveryDiscoveredModel() async {
        let request = makeRequest()
        let transport = MockProviderReadinessTransport(
            script: .init(
                modelCatalog: .success([
                    ProviderReadinessModel(
                        id: "gpt-5.6-luna",
                        capabilities: [.streaming, .tools]
                    ),
                    ProviderReadinessModel(id: "gpt-5.6-luna-mini", capabilities: [.streaming])
                ])
            )
        )

        let report = await ProviderReadinessContractProbe(
            request: request,
            transport: transport
        ).check()

        #expect(report.readiness.state == .mock)
        #expect(report.readiness.modelID == "gpt-5.6-luna")
        #expect(report.readiness.capabilities == [.streaming, .tools])
        #expect(report.discoveredModels.map(\.id) == ["gpt-5.6-luna", "gpt-5.6-luna-mini"])
        #expect(report.modelResults["gpt-5.6-luna"]?.status == .passed)
        #expect(report.modelResults["gpt-5.6-luna-mini"]?.status == .passed)
        #expect(
            report.stageResults.map(\.stage) == [
                .configuration,
                .reachability,
                .authentication,
                .modelCatalog,
                .modelRequest
            ]
        )
        #expect(await transport.recordedCalls() == [
            .reachability,
            .authentication,
            .modelCatalog,
            .modelRequest(modelID: "gpt-5.6-luna"),
            .modelRequest(modelID: "gpt-5.6-luna-mini")
        ])
    }

    @Test func invalidConfigurationStopsBeforeTransportAndDoesNotExposeEvidence() async {
        var request = makeRequest()
        request.baseURL = "not a URL"
        let transport = MockProviderReadinessTransport(
            script: .init(modelCatalog: .success([]))
        )

        let report = await ProviderReadinessContractProbe(
            request: request,
            transport: transport
        ).check()

        #expect(report.readiness.state == .blocked)
        #expect(report.readiness.evidenceID == nil)
        #expect(report.stageResults.count == 1)
        #expect(report.stageResults[0].stage == .configuration)
        #expect(report.stageResults[0].failureCategory == .invalidConfiguration)
        #expect(await transport.recordedCalls().isEmpty)
    }

    @Test func missingCredentialFailsAuthenticationBeforeReachability() async {
        var request = makeRequest()
        request.credential = .missing(source: "TEST_PROVIDER_KEY")
        let transport = MockProviderReadinessTransport(
            script: .init(modelCatalog: .success([]))
        )

        let report = await ProviderReadinessContractProbe(
            request: request,
            transport: transport
        ).check()

        #expect(report.readiness.state == .blocked)
        #expect(report.stageResults.count == 2)
        #expect(report.stageResults[1].stage == .authentication)
        #expect(report.stageResults[1].failureCategory == .missingCredential)
        #expect(await transport.recordedCalls().isEmpty)
    }

    @Test func reachabilityTimeoutStopsLaterStagesAndPreservesErrorCategory() async {
        let transport = MockProviderReadinessTransport(
            script: .init(
                reachability: .failure(.timeout),
                modelCatalog: .success([])
            )
        )

        let report = await ProviderReadinessContractProbe(
            request: makeRequest(),
            transport: transport
        ).check()

        #expect(report.readiness.state == .blocked)
        #expect(report.stageResults.last?.stage == .reachability)
        #expect(report.stageResults.last?.failureCategory == .timeout)
        #expect(await transport.recordedCalls() == [.reachability])
    }

    @Test func authenticationRateLimitIsDistinctFromPermissionDenied() async {
        let transport = MockProviderReadinessTransport(
            script: .init(
                authentication: .failure(.rateLimited(retryAfterSeconds: 4)),
                modelCatalog: .success([])
            )
        )

        let report = await ProviderReadinessContractProbe(
            request: makeRequest(),
            transport: transport
        ).check()

        #expect(report.stageResults.last?.stage == .authentication)
        #expect(report.stageResults.last?.failureCategory == .rateLimited)
        #expect(report.stageResults.last?.retryAfterSeconds == 4)
        #expect(report.stageResults.last?.failureCategory != .permissionDenied)
        #expect(await transport.recordedCalls() == [.reachability, .authentication])
    }

    @Test func catalogPermissionDeniedDoesNotRunModelRequests() async {
        let transport = MockProviderReadinessTransport(
            script: .init(
                modelCatalog: .failure(.permissionDenied)
            )
        )

        let report = await ProviderReadinessContractProbe(
            request: makeRequest(),
            transport: transport
        ).check()

        #expect(report.readiness.state == .blocked)
        #expect(report.stageResults.last?.stage == .modelCatalog)
        #expect(report.stageResults.last?.failureCategory == .permissionDenied)
        #expect(report.modelResults.isEmpty)
        #expect(await transport.recordedCalls() == [
            .reachability,
            .authentication,
            .modelCatalog
        ])
    }

    @Test func perModelFailureIsRecordedWithoutHidingOtherModelResults() async {
        let transport = MockProviderReadinessTransport(
            script: .init(
                modelCatalog: .success([
                    ProviderReadinessModel(id: "gpt-5.6-luna", capabilities: [.streaming]),
                    ProviderReadinessModel(id: "gpt-5.6-luna-mini", capabilities: [.tools])
                ]),
                minimumRequests: [
                    "gpt-5.6-luna-mini": .failure(.permissionDenied)
                ]
            )
        )

        let report = await ProviderReadinessContractProbe(
            request: makeRequest(),
            transport: transport
        ).check()

        #expect(report.readiness.state == .mock)
        #expect(report.modelResults["gpt-5.6-luna"]?.status == .passed)
        #expect(report.modelResults["gpt-5.6-luna-mini"]?.status == .failed)
        #expect(report.modelResults["gpt-5.6-luna-mini"]?.failureCategory == .permissionDenied)
        #expect(await transport.recordedCalls().contains(
            .modelRequest(modelID: "gpt-5.6-luna-mini")
        ))
    }

    @Test func modelRequestTimeoutAndServerFailureKeepDistinctCategories() async {
        let transport = MockProviderReadinessTransport(
            script: .init(
                modelCatalog: .success([
                    ProviderReadinessModel(id: "gpt-5.6-luna", capabilities: [.streaming]),
                    ProviderReadinessModel(id: "gpt-5.6-luna-mini", capabilities: [.tools])
                ]),
                minimumRequests: [
                    "gpt-5.6-luna": .failure(.timeout),
                    "gpt-5.6-luna-mini": .failure(.server(statusCode: 503))
                ]
            )
        )

        let report = await ProviderReadinessContractProbe(
            request: makeRequest(),
            transport: transport
        ).check()

        #expect(report.readiness.state == .blocked)
        #expect(report.stageResults.last?.stage == .modelRequest)
        #expect(report.stageResults.last?.failureCategory == .timeout)
        #expect(report.modelResults["gpt-5.6-luna"]?.failureCategory == .timeout)
        #expect(report.modelResults["gpt-5.6-luna-mini"]?.failureCategory == .server)
    }

    @Test func emptyCatalogIsMalformedAndTargetAbsentIsNotReady() async {
        let transport = MockProviderReadinessTransport(
            script: .init(modelCatalog: .success([]))
        )

        let report = await ProviderReadinessContractProbe(
            request: makeRequest(),
            transport: transport
        ).check()

        #expect(report.readiness.state == .blocked)
        #expect(report.stageResults.last?.stage == .modelCatalog)
        #expect(report.stageResults.last?.failureCategory == .malformedResponse)
        #expect(await transport.recordedCalls() == [
            .reachability,
            .authentication,
            .modelCatalog
        ])
    }

    @Test func probeAdapterReturnsTheSameCoreReadinessConsumedByTheRegistry() async {
        let transport = MockProviderReadinessTransport(
            script: .init(
                modelCatalog: .success([
                    ProviderReadinessModel(
                        id: "gpt-5.6-luna",
                        capabilities: [.streaming]
                    )
                ])
            )
        )
        let probe = ProviderReadinessContractProbe(
            request: makeRequest(),
            transport: transport
        )

        let report = await probe.check()
        let probedReadiness = await probe.probe()

        #expect(probedReadiness == report.readiness)
        #expect(probedReadiness.state == .mock)
    }

    @Test("transport fence rejects rebound and restarted attempt tokens")
    func transportFenceRejectsStaleCompositeIdentity() async {
        let fence = ProviderReadinessTransportAttemptFence()
        let firstRequest = ProviderReadinessCheckRequest(
            providerID: "Luna",
            modelID: "gpt-5.6-luna",
            deployment: .remote,
            baseURL: "https://provider.example/v1",
            credential: .present(source: "fixture"),
            checkedAt: checkedAt,
            configurationGeneration: "generation-1",
            configurationFingerprint: "fingerprint-1"
        )
        let reboundRequest = ProviderReadinessCheckRequest(
            providerID: "luna",
            modelID: "gpt-5.6-luna",
            deployment: .remote,
            baseURL: "https://provider.example/v1",
            credential: .present(source: "fixture"),
            checkedAt: checkedAt,
            configurationGeneration: "generation-2",
            configurationFingerprint: "fingerprint-2"
        )

        let first = await fence.begin(request: firstRequest)
        let rebound = await fence.begin(request: reboundRequest)
        #expect(first.identity.providerID == "luna")
        #expect(first.identity != rebound.identity)
        #expect(await fence.accepts(first) == false)
        #expect(await fence.accepts(rebound))

        await fence.invalidate()
        #expect(await fence.accepts(rebound) == false)
    }

    private func makeRequest() -> ProviderReadinessCheckRequest {
        ProviderReadinessCheckRequest(
            providerID: "luna",
            modelID: "gpt-5.6-luna",
            deployment: .mock,
            baseURL: "https://mock.invalid/v1",
            credential: .present(source: "test-fixture"),
            evidenceID: "mock-readiness-contract",
            checkedAt: checkedAt
        )
    }
}
