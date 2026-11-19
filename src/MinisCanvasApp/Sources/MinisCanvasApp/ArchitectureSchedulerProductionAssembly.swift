import Foundation

extension ProductionDomainAssembly {
    /// The App's scheduler runtime wiring, shared with its non-UI assembly
    /// consumers. AppMain remains the single ordinary caller and starts the
    /// returned runtime at the original bootstrap point.
    static func makeSchedulerRuntime(
        store schedulerStore: SchedulerTaskStore,
        bridge: BridgeStore,
        settings: SettingsCenter,
        now: @escaping @MainActor @Sendable () -> Date = Date.init
    ) -> SchedulerTaskRuntime {
        let schedulerProviderPreflightResolver: SchedulerTaskStore.ProviderPreflightResolver = { [weak bridge] task, now in
            guard let bridge else { return .unavailable("调度目标当前不可用") }
            return bridge.chat.schedulerProviderPreflight(for: task, now: now)
        }
        schedulerStore.providerPreflightResolver = schedulerProviderPreflightResolver
        // 定时任务的锚点会话不参与自动归档。
        bridge.chat.scheduledAnchorSessionIDs = { [weak schedulerStore] in
            Set(schedulerStore?.allTasks().compactMap(\.targetSessionID) ?? [])
        }
        return SchedulerTaskRuntime(
            store: schedulerStore,
            now: now,
            sourceAnchorResolver: { [weak bridge] sessionID, projectID, ordinal in
                bridge?.chat.schedulerSourceAnchorDigest(sessionID: sessionID, projectID: projectID, ordinal: ordinal)
            },
            policyRevisionResolver: { [weak bridge] in bridge?.chat.schedulerPolicyRevision() },
            providerPreflightResolver: schedulerProviderPreflightResolver,
            targetDeliveryResolver: { [weak bridge] occurrence in
                bridge?.chat.scheduledTargetDelivery(for: occurrence)
            },
            submitEffect: { [weak bridge, weak settings] context in
                guard let bridge else { throw ChatStore.ScheduledSubmissionError.targetUnavailable }
                return try await bridge.chat.submitScheduledRequest(
                    context, memoryProposalConsumer: settings?.memoryProposalConsumer
                )
            }
        )
    }
}
