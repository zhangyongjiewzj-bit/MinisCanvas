import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

@Suite("IF-07B model readiness task ownership", .serialized)
@MainActor
struct IF07BProviderModelTaskOwnershipTests {
    @Test("a superseded completion cannot detach the live retry from cancellation")
    func supersededCompletionPreservesRetryCancellationHandle() async throws {
        let transport = IF07BHeldModelReadinessTransport()
        let center = try makeCenter(transport: transport)
        let provider = "IF07B_TASK_OWNERSHIP_API_KEY"
        #expect(center.saveProvider(
            name: provider,
            apiKey: "synthetic-test-only-key",
            baseURL: "https://mock.example/v1",
            modelNames: ["model-a", "model-b"],
            protocolType: .openaiCompatible
        ))

        let old = center.startProviderModelReadiness(
            forProviderName: provider, modelID: "model-a"
        )
        let oldStarted = try await waitUntil { await transport.requestCount >= 1 }
        #expect(oldStarted)

        let fresh = center.startProviderModelReadiness(
            forProviderName: provider, modelID: "model-a"
        )
        let foreign = center.startProviderModelReadiness(
            forProviderName: provider, modelID: "model-b"
        )
        let allStarted = try await waitUntil { await transport.requestCount == 3 }
        #expect(allStarted)
        #expect(center.providerModelReadiness(
            forProviderName: provider, modelID: "model-a"
        )?.status == .loading)

        // The transport deliberately holds the cancelled old request until the
        // new request is already live. This is the production start/retry path.
        await transport.releaseOld()
        await old.value
        #expect(center.providerModelReadiness(
            forProviderName: provider, modelID: "model-a"
        )?.status == .loading)

        center.cancelProviderModelReadiness(
            forProviderName: provider, modelID: "model-a"
        )
        let freshTransportCancelled = try await waitUntil {
            await transport.freshWasCancelled
        }

        // Always release held requests before assertions so a failed test
        // cannot leave an unfinished task behind in the test process.
        await transport.releaseFreshIfPending()
        await transport.releaseForeignIfPending()
        await fresh.value
        await foreign.value

        #expect(freshTransportCancelled, "the live retry must remain owned by cancelProviderModelReadiness")
        #expect(await transport.foreignWasCancelled == false)
        #expect(center.providerModelReadiness(
            forProviderName: provider, modelID: "model-a"
        )?.status == .cancelled)
        #expect(center.providerModelReadiness(
            forProviderName: provider, modelID: "model-b"
        )?.status == .passed)
    }

    private func makeCenter(
        transport: any SettingsProviderReadinessTransport
    ) throws -> SettingsCenter {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("IF07BTaskOwnership-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return SettingsCenter(
            settingsStore: SettingsStore(directory: directory),
            envStore: EnvVarStore(directory: directory),
            memoryStore: MemoryStore(directory: directory),
            sessionStore: SessionStore(directory: directory),
            logManager: LogManager(directory: directory, ringCapacity: 50),
            providerReadinessTransport: transport,
            providerReadinessDeployment: .mock
        )
    }

    private func waitUntil(
        _ condition: @escaping @Sendable () async -> Bool
    ) async throws -> Bool {
        for _ in 0..<200 {
            if await condition() { return true }
            try await Task.sleep(for: .milliseconds(5))
        }
        return false
    }
}

private actor IF07BHeldModelReadinessTransport: SettingsProviderReadinessTransport {
    private var modelACount = 0
    private var requests = 0
    private var oldContinuation: CheckedContinuation<ProviderReadinessTransportResponse, Error>?
    private var freshContinuation: CheckedContinuation<ProviderReadinessTransportResponse, Error>?
    private var foreignContinuation: CheckedContinuation<ProviderReadinessTransportResponse, Error>?
    private var cancelledFresh = false
    private var cancelledForeign = false

    nonisolated var canProduceLiveEvidence: Bool { false }
    var requestCount: Int { requests }
    var freshWasCancelled: Bool { cancelledFresh }
    var foreignWasCancelled: Bool { cancelledForeign }

    func send(
        _ request: ProviderReadinessTransportRequest
    ) async throws -> ProviderReadinessTransportResponse {
        requests += 1
        if request.modelID == "model-a" {
            modelACount += 1
            if modelACount == 1 {
                // Ignore cancellation until explicitly released, modeling a
                // transport that settles its old request after a retry starts.
                return try await withCheckedThrowingContinuation {
                    oldContinuation = $0
                }
            }
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation {
                    freshContinuation = $0
                }
            } onCancel: {
                Task { await self.cancelFresh() }
            }
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                foreignContinuation = $0
            }
        } onCancel: {
            Task { await self.cancelForeign() }
        }
    }

    func releaseOld() {
        oldContinuation?.resume(returning: .init(statusCode: 200, body: "old"))
        oldContinuation = nil
    }

    func releaseFreshIfPending() {
        freshContinuation?.resume(returning: .init(statusCode: 200, body: "fresh"))
        freshContinuation = nil
    }

    func releaseForeignIfPending() {
        foreignContinuation?.resume(returning: .init(statusCode: 200, body: "foreign"))
        foreignContinuation = nil
    }

    private func cancelFresh() {
        cancelledFresh = true
        freshContinuation?.resume(throwing: CancellationError())
        freshContinuation = nil
    }

    private func cancelForeign() {
        cancelledForeign = true
        foreignContinuation?.resume(throwing: CancellationError())
        foreignContinuation = nil
    }
}
