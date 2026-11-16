import Foundation
import MinisCore

enum BL6SettingsTransactionState: Equatable {
    case ready
    case unknown
}

extension SettingsCenter {
    /// Sendable entry for the later tool executor. It serializes the already
    /// frozen JSON input before crossing to this MainActor settings owner.
    func dispatchApprovedBL6Settings(
        inputData: Data,
        approvedCall: BL6SettingsApprovedCallContext,
        currentAuthorizationFacts: ApprovalAuthorizationContext,
        currentPolicyRevision: @MainActor @Sendable () -> String,
        currentGrantEpoch: @MainActor @Sendable () -> String,
        currentProfileDirectory: URL,
        shortcutStore: ShortcutStore? = nil,
        skillsStore: SkillsStore? = nil,
        sidebarWidthSetting: SessionSidebarWidthSetting? = nil,
        sessionOwner: ChatStore? = nil,
        schedulerStore: SchedulerTaskStore? = nil
    ) async -> Result<BL6SettingsReceipt, BL6SettingsDispatchError> {
        guard let rawInput = (try? JSONSerialization.jsonObject(with: inputData)) as? [String: Any] else {
            return .failure(.invalidIntent("invalid settings JSON input"))
        }
        return await dispatchApprovedBL6Settings(
            input: rawInput, approvedCall: approvedCall,
            currentAuthorizationFacts: currentAuthorizationFacts,
            currentPolicyRevision: currentPolicyRevision,
            currentGrantEpoch: currentGrantEpoch,
            currentProfileDirectory: currentProfileDirectory,
            shortcutStore: shortcutStore,
            skillsStore: skillsStore,
            sidebarWidthSetting: sidebarWidthSetting,
            sessionOwner: sessionOwner,
            schedulerStore: schedulerStore
        )
    }

    /// Stage B owner for a single gate-approved, non-provider conversation
    /// settings call. Stage C supplies the frozen raw tool input and current
    /// trusted gate facts; model fields are never approval or undo authority.
    func dispatchApprovedBL6Settings(
        input rawInput: [String: Any],
        approvedCall: BL6SettingsApprovedCallContext,
        currentAuthorizationFacts: ApprovalAuthorizationContext,
        currentPolicyRevision: @MainActor @Sendable () -> String,
        currentGrantEpoch: @MainActor @Sendable () -> String,
        currentProfileDirectory: URL,
        shortcutStore: ShortcutStore? = nil,
        skillsStore: SkillsStore? = nil,
        sidebarWidthSetting: SessionSidebarWidthSetting? = nil,
        sessionOwner: ChatStore? = nil,
        schedulerStore: SchedulerTaskStore? = nil
    ) async -> Result<BL6SettingsReceipt, BL6SettingsDispatchError> {
        guard bl6SettingsTransactionState == .ready,
              settingsStore.lastPersistenceError != .transactionRecoveryRequired else {
            return .failure(.transactionUnknown)
        }
        guard BL6SettingsToolApproval.current === approvedCall else {
            return .failure(.approvalRequired)
        }
        let profileID = settingsStore.directory.standardizedFileURL.path
        guard currentProfileDirectory.standardizedFileURL.path == profileID,
              currentAuthorizationFacts.isValid,
              currentAuthorizationFacts.toolName == BL6SettingsToolApproval.toolName,
              let payloadDigest = ApprovalAuthorizationContext.payloadDigest(for: rawInput),
              payloadDigest == currentAuthorizationFacts.payloadDigest else {
            return .failure(.approvalRequired)
        }
        let parsed: BL6SettingsApprovedInput
        var shortcutApply = false
        var sidebarApply = false
        var mcpNameApply = false
        var mcpEnablementApply = false
        var mcpServerApply = false
        var sessionApply = false
        var memoryApply = false
        var skillsApply = false
        var schedulerApply = false
        var preferencesApply = false
        var hooksApply = false
        do {
            let approvedFields: Set<String> = ["operation", "changes", "expectedRevision", "undoReceiptID"]
            var decodeInput = rawInput
            if let operation = rawInput["operation"] as? String,
               operation == "rollback" || operation == "reset",
               rawInput["changes"] == nil {
                decodeInput["changes"] = [String: Any]()
            }
            guard Set(rawInput.keys).isSubset(of: approvedFields),
                  let encoded = try? JSONSerialization.data(withJSONObject: decodeInput, options: [.sortedKeys]) else {
                throw BL6SettingsDispatchError.invalidIntent("unsupported input fields")
            }
            parsed = try JSONDecoder().decode(BL6SettingsApprovedInput.self, from: encoded)
            let canonical = try JSONSerialization.jsonObject(with: JSONEncoder().encode(parsed))
            guard let canonicalInput = canonical as? [String: Any] else {
                throw BL6SettingsDispatchError.invalidIntent("noncanonical typed settings input")
            }
            let canonicalData = try JSONSerialization.data(
                withJSONObject: canonicalInput, options: [.sortedKeys, .withoutEscapingSlashes]
            )
            let rawData = try JSONSerialization.data(
                withJSONObject: decodeInput, options: [.sortedKeys, .withoutEscapingSlashes]
            )
            guard canonicalData == rawData else {
                throw BL6SettingsDispatchError.invalidIntent("noncanonical typed settings input")
            }
            try parsed.validateForApprovedEffect()
            shortcutApply = parsed.operation == .apply
                && parsed.changes.keys.allSatisfy { $0.hasPrefix("shortcuts.") }
            sidebarApply = parsed.operation == .apply
                && parsed.changes.count == 1
                && parsed.changes[SessionSidebarWidthContract.typedCatalogID] != nil
            mcpNameApply = parsed.operation == .apply
                && parsed.changes.count == 1
                && parsed.changes.keys.allSatisfy {
                    $0.hasPrefix("mcp.") && $0.hasSuffix(".name")
                }
            mcpEnablementApply = parsed.operation == .apply
                && parsed.changes.count == 1
                && parsed.changes.keys.allSatisfy {
                    $0.hasPrefix("mcp.") && $0.hasSuffix(".enabled")
                }
            mcpServerApply = parsed.operation == .apply
                && parsed.changes.count == 1
                && parsed.changes.keys.allSatisfy { $0 == "mcp.servers.add" || $0 == "mcp.servers.remove" }
            sessionApply = parsed.operation == .apply
                && parsed.changes.count == 1
                && parsed.changes.keys.allSatisfy { $0.hasPrefix("session.") }
            memoryApply = parsed.operation == .apply
                && parsed.changes.count == 1
                && parsed.changes.keys.allSatisfy { $0.hasPrefix("memory.fact.") }
            skillsApply = parsed.operation == .apply
                && parsed.changes.count == 1
                && parsed.changes.keys.allSatisfy {
                    $0.hasPrefix("skills.app:") && $0.hasSuffix(".enabled")
                }
            schedulerApply = parsed.operation == .apply
                && parsed.changes.count == 1
                && parsed.changes.keys.allSatisfy {
                    $0 == "scheduler.tasks.add" || $0 == "scheduler.tasks.remove"
                        || ($0.hasPrefix("scheduler.") && $0.hasSuffix(".enabled"))
                }
            preferencesApply = parsed.operation == .apply
                && parsed.changes.count == 1
                && parsed.changes.keys.allSatisfy {
                    $0.hasPrefix("notifications.") || $0 == "resident.keep-awake"
                }
            hooksApply = parsed.operation == .apply && parsed.changes.count == 1
                && parsed.changes.keys.allSatisfy { $0 == "hooks.entries.add" || $0 == "hooks.entries.remove" }
            if sidebarApply {
                guard sidebarWidthSetting != nil else {
                    throw BL6SettingsDispatchError.invalidIntent("sidebar width owner unavailable")
                }
            } else if shortcutApply {
                guard shortcutStore != nil,
                      parsed.changes.keys.allSatisfy({ id in
                          ShortcutAction(rawValue: String(id.dropFirst("shortcuts.".count))) != nil
                      }) else {
                    throw BL6SettingsDispatchError.invalidIntent("unknown shortcut setting")
                }
            } else if !mcpNameApply && !mcpEnablementApply && !mcpServerApply && !sessionApply && !memoryApply && !skillsApply
                        && !schedulerApply && !preferencesApply && !hooksApply {
                try BL6SettingsCatalog.production.validateApprovedMutation(
                    changedKeys: Array(parsed.changes.keys)
                )
            }
        } catch let error as BL6SettingsDispatchError {
            return .failure(error)
        } catch {
            return .failure(.invalidIntent("invalid typed settings input"))
        }

        let authorized: BL6SettingsAuthorizedCall
        do {
            authorized = try await approvedCall.consume(expected: currentAuthorizationFacts)
        } catch {
            return .failure(.approvalRequired)
        }
        let requestID = authorized.requestID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !requestID.isEmpty, authorized.binding == currentAuthorizationFacts else {
            return .failure(.approvalRequired)
        }
        // Read live gate revisions after the actor hop. A UI/policy change
        // during approval consumption must not validate stale captured values.
        let livePolicyRevision = currentPolicyRevision()
        let liveGrantEpoch = currentGrantEpoch()
        guard authorized.binding.policyRevision == livePolicyRevision,
              authorized.binding.grantEpoch == liveGrantEpoch else {
            return .failure(.approvalRequired)
        }
        if mcpServerApply {
            return dispatchApprovedMCPServerManagement(parsed: parsed)
        }
        if schedulerApply {
            guard let sessionOwner, let schedulerStore else { return .failure(.transactionUnknown) }
            return dispatchApprovedSchedulerManagement(
                parsed: parsed, currentSessionID: authorized.binding.sessionID,
                owner: sessionOwner, store: schedulerStore)
        }
        if hooksApply {
            return dispatchApprovedHookManagement(parsed: parsed, requestID: requestID)
        }
        if preferencesApply {
            return dispatchApprovedPreferences(parsed: parsed)
        }
        if sessionApply {
            guard let sessionOwner else { return .failure(.transactionUnknown) }
            return dispatchApprovedSessionManagement(
                parsed: parsed, currentSessionID: authorized.binding.sessionID, owner: sessionOwner)
        }
        let memoryUndo: BL6MemoryReplayRecord?
        do {
            if parsed.operation == .rollback, let receiptID = parsed.undoReceiptID {
                memoryUndo = try memoryStore.bl6MemoryReplayRecord(receiptID: receiptID, profileID: profileID)
            } else { memoryUndo = nil }
            let skillUndo: BL6SettingsReplayRecord?
            if parsed.operation == .rollback, let receiptID = parsed.undoReceiptID {
                skillUndo = try skillStore.bl6SkillEnablementReplayRecord(receiptID: receiptID, profileID: profileID)
            } else { skillUndo = nil }
            let skillRequest = try skillStore.bl6SkillEnablementReplayRecord(for: requestID, profileID: profileID)
            guard memoryUndo == nil || skillUndo == nil else {
                return .failure(.invalidIntent("undo receipt identity conflict"))
            }
            if memoryApply || memoryUndo != nil {
                guard skillRequest == nil else { return .failure(.invalidIntent("request identity conflict")) }
                return dispatchApprovedMemorySettings(parsed: parsed, payloadDigest: payloadDigest,
                    authorized: authorized, profileID: profileID, policyRevision: livePolicyRevision,
                    grantEpoch: liveGrantEpoch, shortcutStore: shortcutStore,
                    sidebarWidthSetting: sidebarWidthSetting, undo: memoryUndo)
            }
            guard try memoryStore.bl6MemoryReplayRecord(for: requestID, profileID: profileID) == nil else {
                return .failure(.invalidIntent("request identity conflict"))
            }
            if skillsApply || skillUndo != nil {
                return dispatchApprovedSkillEnablement(parsed: parsed, payloadDigest: payloadDigest,
                    authorized: authorized, profileID: profileID, policyRevision: livePolicyRevision,
                    grantEpoch: liveGrantEpoch, skillsStore: skillsStore,
                    shortcutStore: shortcutStore, sidebarWidthSetting: sidebarWidthSetting, undo: skillUndo)
            }
            guard skillRequest == nil else { return .failure(.invalidIntent("request identity conflict")) }
        } catch { return .failure(.transactionUnknown) }

        var shortcutRollback = false
        var sidebarRollback = false
        if parsed.operation == .rollback, let sidebarWidthSetting,
           let receiptID = parsed.undoReceiptID {
            switch sidebarWidthSetting.bl6ReplayRecord(receiptID: receiptID, profileID: profileID) {
            case .failure: return .failure(.transactionUnknown)
            case .success(let record?): sidebarRollback = record.receipt.receiptID == receiptID
            case .success(nil): break
            }
        }
        if parsed.operation == .rollback, let shortcutStore,
           let receiptID = parsed.undoReceiptID {
            switch shortcutStore.bl6ReplayRecord(receiptID: receiptID, profileID: profileID) {
            case .failure: return .failure(.transactionUnknown)
            case .success(let record?): shortcutRollback = record.receipt.receiptID == receiptID
            case .success(nil): break
            }
        }
        var mcpNameRollback = false
        if parsed.operation == .rollback, let receiptID = parsed.undoReceiptID {
            switch mcpManager.bl6NameReplayRecord(receiptID: receiptID, profileID: profileID) {
            case .failure: return .failure(.transactionUnknown)
            case .success(let record?): mcpNameRollback = record.receipt.receiptID == receiptID
            case .success(nil): break
            }
        }
        var mcpEnablementRollback = false
        if parsed.operation == .rollback, let receiptID = parsed.undoReceiptID {
            switch mcpManager.bl6EnablementReplayRecord(receiptID: receiptID, profileID: profileID) {
            case .failure: return .failure(.transactionUnknown)
            case .success(let record?): mcpEnablementRollback = record.receipt.receiptID == receiptID
            case .success(nil): break
            }
        }
        if !sidebarApply && !sidebarRollback, let sidebarWidthSetting {
            switch sidebarWidthSetting.bl6ReplayRecord(for: requestID, profileID: profileID) {
            case .failure: return .failure(.transactionUnknown)
            case .success(.some): return .failure(.invalidIntent("request identity conflict"))
            case .success(nil): break
            }
        }
        if sidebarApply || sidebarRollback {
            guard let sidebarWidthSetting else { return .failure(.transactionUnknown) }
            return dispatchApprovedSidebarWidth(
                parsed: parsed, setting: sidebarWidthSetting,
                payloadDigest: payloadDigest, authorized: authorized,
                profileID: profileID, policyRevision: livePolicyRevision,
                grantEpoch: liveGrantEpoch, shortcutStore: shortcutStore
            )
        }
        if shortcutApply || shortcutRollback {
            guard let shortcutStore else { return .failure(.transactionUnknown) }
            return dispatchApprovedShortcutSettings(
                parsed: parsed, shortcutStore: shortcutStore,
                payloadDigest: payloadDigest, authorized: authorized,
                profileID: profileID, policyRevision: livePolicyRevision,
                grantEpoch: liveGrantEpoch
            )
        }
        if mcpNameApply || mcpNameRollback {
            return dispatchApprovedMCPSettings(
                parsed: parsed, payloadDigest: payloadDigest,
                authorized: authorized, profileID: profileID,
                policyRevision: livePolicyRevision, grantEpoch: liveGrantEpoch,
                shortcutStore: shortcutStore, enablement: false
            )
        }
        if mcpEnablementApply || mcpEnablementRollback {
            return dispatchApprovedMCPSettings(
                parsed: parsed, payloadDigest: payloadDigest,
                authorized: authorized, profileID: profileID,
                policyRevision: livePolicyRevision, grantEpoch: liveGrantEpoch,
                shortcutStore: shortcutStore, enablement: true
            )
        }
        switch mcpManager.bl6NameReplayRecord(for: requestID, profileID: profileID) {
        case .failure: return .failure(.transactionUnknown)
        case .success(.some): return .failure(.invalidIntent("request identity conflict"))
        case .success(nil): break
        }
        switch mcpManager.bl6EnablementReplayRecord(for: requestID, profileID: profileID) {
        case .failure: return .failure(.transactionUnknown)
        case .success(.some): return .failure(.invalidIntent("request identity conflict"))
        case .success(nil): break
        }
        if let shortcutStore {
            switch shortcutStore.bl6ReplayRecord(for: requestID, profileID: profileID) {
            case .failure: return .failure(.transactionUnknown)
            case .success(.some): return .failure(.invalidIntent("request identity conflict"))
            case .success(nil): break
            }
        }
        switch settingsStore.bl6ReplayRecord(for: requestID) {
        case .failure: return .failure(.transactionUnknown)
        case .success(let existing?):
            guard existing.payloadDigest == payloadDigest,
                  existing.frozenInput == parsed,
                  existing.approvalBindingDigest == authorized.binding.identityDigest,
                  existing.profileID == profileID,
                  existing.scope == authorized.binding.scope,
                  existing.sessionID == authorized.binding.sessionID,
                  existing.policyRevision == livePolicyRevision,
                  existing.grantEpoch == liveGrantEpoch,
                  existing.operation == parsed.operation else {
                return .failure(.invalidIntent("request identity conflict"))
            }
            guard Date() < existing.approvalExpiresAt else { return .failure(.approvalRequired) }
            return .success(existing.receipt)
        case .success(nil): break
        }

        guard let current = bl6EffectiveSettingsSnapshot else {
            return .failure(.transactionUnknown)
        }
        guard parsed.expectedRevision == current.catalogRevision else {
            return .failure(.staleRevision(expected: parsed.expectedRevision, actual: current.catalogRevision))
        }
        var changes = parsed.changes
        if parsed.operation == .rollback {
            guard let receiptID = parsed.undoReceiptID else {
                return .failure(.invalidIntent("undo receipt reference required"))
            }
            switch settingsStore.bl6ReplayRecord(receiptID: receiptID) {
            case .failure: return .failure(.transactionUnknown)
            case .success(let original?):
                guard original.profileID == profileID,
                      original.receipt.effectiveRevision == current.catalogRevision else {
                    return .failure(.staleRevision(
                        expected: original.receipt.effectiveRevision,
                        actual: current.catalogRevision
                    ))
                }
                changes = original.rollbackValues
            case .success(nil): return .failure(.invalidIntent("unknown undo receipt"))
            }
        }

        let intent = BL6SettingsIntent(
            requestID: requestID,
            operation: parsed.operation,
            changes: changes,
            expectedRevision: parsed.expectedRevision,
            approval: .approved(receiptID: authorized.binding.identityDigest)
        )
        let executor = BL6SettingsExecutor()
        let plan: BL6SettingsPlan
        let execution: (snapshot: BL6EffectiveSettingsSnapshot, receipt: BL6SettingsReceipt)
        do {
            plan = try executor.plan(
                intent, against: current,
                defaults: bl6Values(from: .defaults, credentialPresent: false)
            )
            if plan.changedKeys.contains(BL6SettingsApprovedInput.approvalPolicyKey),
               parsed.operation != .apply {
                throw BL6SettingsDispatchError.invalidIntent(BL6SettingsApprovedInput.unsupportedApprovalPolicyMessage)
            }
            try BL6SettingsCatalog.production.validateApprovedMutation(changedKeys: plan.changedKeys)
            execution = try executor.execute(plan, against: current)
        } catch let error as BL6SettingsDispatchError {
            return .failure(error)
        } catch {
            return .failure(.invalidIntent("settings plan rejected"))
        }
        var candidate = settingsMirror
        do {
            if case .text(let rawPolicy)? = parsed.changes[BL6SettingsApprovedInput.approvalPolicyKey],
               let policy = ApprovalPolicy(rawValue: rawPolicy) {
                candidate.agent.approvalPolicy = policy
                candidate.agent.legacyAutomaticApprovalCompatibilityActive = false
            } else {
                try applyBL6Values(plan.targetValues, to: &candidate)
            }
        } catch let error as BL6SettingsDispatchError {
            return .failure(error)
        } catch {
            return .failure(.invalidIntent("typed value rejected"))
        }
        let redactedReceipt = BL6SettingsReceipt(
            receiptID: execution.receipt.receiptID,
            requestID: requestID,
            operation: parsed.operation,
            previousRevision: execution.receipt.previousRevision,
            effectiveRevision: execution.receipt.effectiveRevision,
            changedKeys: execution.receipt.changedKeys,
            rollbackValues: [:]
        )
        let record = BL6SettingsReplayRecord(
            requestID: requestID,
            payloadDigest: payloadDigest,
            frozenInput: parsed,
            approvalBindingDigest: authorized.binding.identityDigest,
            profileID: profileID,
            scope: authorized.binding.scope,
            sessionID: authorized.binding.sessionID,
            policyRevision: livePolicyRevision,
            grantEpoch: liveGrantEpoch,
            approvalExpiresAt: authorized.binding.expiresAt,
            operation: parsed.operation,
            receipt: redactedReceipt,
            rollbackValues: execution.receipt.rollbackValues
        )
        switch settingsStore.commitBL6Replay(
            expectedSettings: settingsMirror, candidate: candidate, record: record
        ) {
        case .success(let receipt):
            let childConcurrencyChanged = candidate.agent.childConcurrencyUserSelected
                != settingsMirror.agent.childConcurrencyUserSelected
                || candidate.agent.childConcurrencyEnabledSessionCount
                    != settingsMirror.agent.childConcurrencyEnabledSessionCount
            let composerPolicyChanged = candidate.agent.composerPolicy != settingsMirror.agent.composerPolicy
                || parsed.operation == .reset
            _ = persistSettings({ .success(.persisted) }) {
                self.logManager.minimumLevel = LogLevel(candidate.privacy.logLevel)
                self.onApprovalPolicyChanged?(candidate.agent.approvalPolicy)
                if composerPolicyChanged { self.onComposerPolicyChanged?(candidate.agent.composerPolicy) }
                if childConcurrencyChanged || parsed.operation == .reset {
                    self.publishChildConcurrencySelectionAfterCommit()
                }
                self.reloadAll()
            }
            return .success(receipt)
        case .failure(.staleRevision):
            return .failure(.staleRevision(expected: parsed.expectedRevision, actual: bl6EffectiveSettingsSnapshot?.catalogRevision ?? "<unavailable>"))
        case .failure(.conflict):
            return .failure(.invalidIntent("request identity conflict"))
        case .failure(.persistence(let error)):
            _ = persistSettings({ .failure(error) })
            return .failure(.transactionUnknown)
        }
    }

    /// The live sidebar gateway is also ContentView's drag writer. This branch
    /// borrows the ordinary one-use approval and profile fences above.
    private func dispatchApprovedSidebarWidth(
        parsed: BL6SettingsApprovedInput,
        setting: SessionSidebarWidthSetting,
        payloadDigest: String,
        authorized: BL6SettingsAuthorizedCall,
        profileID: String,
        policyRevision: String,
        grantEpoch: String,
        shortcutStore: ShortcutStore?
    ) -> Result<BL6SettingsReceipt, BL6SettingsDispatchError> {
        let requestID = authorized.requestID.trimmingCharacters(in: .whitespacesAndNewlines)
        switch setting.bl6ReplayRecord(for: requestID, profileID: profileID) {
        case .failure: return .failure(.transactionUnknown)
        case .success(let existing?):
            guard existing.payloadDigest == payloadDigest,
                  existing.frozenInput == parsed,
                  existing.approvalBindingDigest == authorized.binding.identityDigest,
                  existing.profileID == profileID,
                  existing.scope == authorized.binding.scope,
                  existing.sessionID == authorized.binding.sessionID,
                  existing.policyRevision == policyRevision,
                  existing.grantEpoch == grantEpoch,
                  existing.operation == parsed.operation else {
                return .failure(.invalidIntent("request identity conflict"))
            }
            guard Date() < existing.approvalExpiresAt else { return .failure(.approvalRequired) }
            return .success(existing.receipt)
        case .success(nil): break
        }
        switch settingsStore.bl6ReplayRecord(for: requestID) {
        case .failure: return .failure(.transactionUnknown)
        case .success(.some): return .failure(.invalidIntent("request identity conflict"))
        case .success(nil): break
        }
        if let shortcutStore {
            switch shortcutStore.bl6ReplayRecord(for: requestID, profileID: profileID) {
            case .failure: return .failure(.transactionUnknown)
            case .success(.some): return .failure(.invalidIntent("request identity conflict"))
            case .success(nil): break
            }
        }
        for existing in [
            mcpManager.bl6NameReplayRecord(for: requestID, profileID: profileID),
            mcpManager.bl6EnablementReplayRecord(for: requestID, profileID: profileID)
        ] {
            switch existing {
            case .failure: return .failure(.transactionUnknown)
            case .success(.some): return .failure(.invalidIntent("request identity conflict"))
            case .success(nil): break
            }
        }
        let preparation: (previousRevision: String, effectiveRevision: String,
                          changedKeys: [String], rollbackValues: [String: BL6SettingValue])
        switch setting.prepareBL6Replay(parsed, profileID: profileID) {
        case .failure(.staleRevision):
            let actual: String
            switch setting.bl6Snapshot(profileID: profileID) {
            case .success(let snapshot): actual = snapshot.revision
            case .failure: actual = "<unavailable>"
            }
            return .failure(.staleRevision(expected: parsed.expectedRevision, actual: actual))
        case .failure(.conflict):
            return .failure(.invalidIntent(SessionSidebarWidthContract.typedCatalogID))
        case .failure(.persistence): return .failure(.transactionUnknown)
        case .success(let ready): preparation = ready
        }
        let receipt = BL6SettingsReceipt(
            requestID: requestID, operation: parsed.operation,
            previousRevision: preparation.previousRevision,
            effectiveRevision: preparation.effectiveRevision,
            changedKeys: preparation.changedKeys, rollbackValues: [:]
        )
        let record = BL6SettingsReplayRecord(
            requestID: requestID, payloadDigest: payloadDigest,
            frozenInput: parsed, approvalBindingDigest: authorized.binding.identityDigest,
            profileID: profileID, scope: authorized.binding.scope,
            sessionID: authorized.binding.sessionID,
            policyRevision: policyRevision, grantEpoch: grantEpoch,
            approvalExpiresAt: authorized.binding.expiresAt,
            operation: parsed.operation, receipt: receipt,
            rollbackValues: preparation.rollbackValues
        )
        switch setting.commitBL6Replay(record, profileID: profileID) {
        case .success(let committed): return .success(committed)
        case .failure(.staleRevision):
            let actual: String
            switch setting.bl6Snapshot(profileID: profileID) {
            case .success(let snapshot): actual = snapshot.revision
            case .failure: actual = "<unavailable>"
            }
            return .failure(.staleRevision(expected: parsed.expectedRevision, actual: actual))
        case .failure(.conflict): return .failure(.invalidIntent(SessionSidebarWidthContract.typedCatalogID))
        case .failure(.persistence): return .failure(.transactionUnknown)
        }
    }

    /// ShortcutStore is the sole writer for this domain. The caller reaches
    /// this branch only after the same one-use approved call and live
    /// policy/grant fences as ordinary AppSettings.
    private func dispatchApprovedShortcutSettings(
        parsed: BL6SettingsApprovedInput,
        shortcutStore: ShortcutStore,
        payloadDigest: String,
        authorized: BL6SettingsAuthorizedCall,
        profileID: String,
        policyRevision: String,
        grantEpoch: String
    ) -> Result<BL6SettingsReceipt, BL6SettingsDispatchError> {
        let requestID = authorized.requestID.trimmingCharacters(in: .whitespacesAndNewlines)
        switch shortcutStore.bl6ReplayRecord(for: requestID, profileID: profileID) {
        case .failure: return .failure(.transactionUnknown)
        case .success(let existing?):
            guard existing.payloadDigest == payloadDigest,
                  existing.frozenInput == parsed,
                  existing.approvalBindingDigest == authorized.binding.identityDigest,
                  existing.profileID == profileID,
                  existing.scope == authorized.binding.scope,
                  existing.sessionID == authorized.binding.sessionID,
                  existing.policyRevision == policyRevision,
                  existing.grantEpoch == grantEpoch,
                  existing.operation == parsed.operation else {
                return .failure(.invalidIntent("request identity conflict"))
            }
            guard Date() < existing.approvalExpiresAt else { return .failure(.approvalRequired) }
            return .success(existing.receipt)
        case .success(nil): break
        }
        switch settingsStore.bl6ReplayRecord(for: requestID) {
        case .failure: return .failure(.transactionUnknown)
        case .success(.some): return .failure(.invalidIntent("request identity conflict"))
        case .success(nil): break
        }
        switch mcpManager.bl6NameReplayRecord(for: requestID, profileID: profileID) {
        case .failure: return .failure(.transactionUnknown)
        case .success(.some): return .failure(.invalidIntent("request identity conflict"))
        case .success(nil): break
        }
        if parsed.operation == .rollback, let receiptID = parsed.undoReceiptID {
            switch settingsStore.bl6ReplayRecord(receiptID: receiptID) {
            case .failure: return .failure(.transactionUnknown)
            case .success(.some): return .failure(.invalidIntent("undo receipt identity conflict"))
            case .success(nil): break
            }
            switch mcpManager.bl6NameReplayRecord(receiptID: receiptID, profileID: profileID) {
            case .failure: return .failure(.transactionUnknown)
            case .success(.some): return .failure(.invalidIntent("undo receipt identity conflict"))
            case .success(nil): break
            }
        }
        let preparation: ShortcutStore.BL6Preparation
        switch shortcutStore.prepareBL6Replay(parsed, profileID: profileID) {
        case .failure(.staleRevision):
            let actual: String
            switch shortcutStore.bl6Snapshot(profileID: profileID) {
            case .success(let current): actual = current.revision
            case .failure: actual = "<unavailable>"
            }
            return .failure(.staleRevision(expected: parsed.expectedRevision, actual: actual))
        case .failure(.conflict):
            return .failure(.invalidIntent("shortcut proposal rejected"))
        case .failure(.persistence):
            return .failure(.transactionUnknown)
        case .success(let ready):
            preparation = ready
        }
        let receipt = BL6SettingsReceipt(
            requestID: requestID,
            operation: parsed.operation,
            previousRevision: preparation.previousRevision,
            effectiveRevision: UUID().uuidString,
            changedKeys: preparation.changedKeys,
            rollbackValues: [:]
        )
        let record = BL6SettingsReplayRecord(
            requestID: requestID,
            payloadDigest: payloadDigest,
            frozenInput: parsed,
            approvalBindingDigest: authorized.binding.identityDigest,
            profileID: profileID,
            scope: authorized.binding.scope,
            sessionID: authorized.binding.sessionID,
            policyRevision: policyRevision,
            grantEpoch: grantEpoch,
            approvalExpiresAt: authorized.binding.expiresAt,
            operation: parsed.operation,
            receipt: receipt,
            rollbackValues: preparation.rollbackValues
        )
        switch shortcutStore.commitBL6Replay(record, profileID: profileID) {
        case .success(let committed): return .success(committed)
        case .failure(.staleRevision):
            let actual: String
            switch shortcutStore.bl6Snapshot(profileID: profileID) {
            case .success(let current): actual = current.revision
            case .failure: actual = "<unavailable>"
            }
            return .failure(.staleRevision(expected: parsed.expectedRevision, actual: actual))
        case .failure(.conflict): return .failure(.invalidIntent("shortcut commit rejected"))
        case .failure(.persistence): return .failure(.transactionUnknown)
        }
    }

    /// MCPServerManager owns the canonical server setting and its replay
    /// receipt. Enablement can retire a grant but cannot create or restore one;
    /// neither branch edits transport targets or secrets.
    private func dispatchApprovedMCPSettings(
        parsed: BL6SettingsApprovedInput,
        payloadDigest: String,
        authorized: BL6SettingsAuthorizedCall,
        profileID: String,
        policyRevision: String,
        grantEpoch: String,
        shortcutStore: ShortcutStore?,
        enablement: Bool
    ) -> Result<BL6SettingsReceipt, BL6SettingsDispatchError> {
        let requestID = authorized.requestID.trimmingCharacters(in: .whitespacesAndNewlines)
        let existingResult = enablement
            ? mcpManager.bl6EnablementReplayRecord(for: requestID, profileID: profileID)
            : mcpManager.bl6NameReplayRecord(for: requestID, profileID: profileID)
        switch existingResult {
        case .failure: return .failure(.transactionUnknown)
        case .success(let existing?):
            guard existing.payloadDigest == payloadDigest,
                  existing.frozenInput == parsed,
                  existing.approvalBindingDigest == authorized.binding.identityDigest,
                  existing.profileID == profileID,
                  existing.scope == authorized.binding.scope,
                  existing.sessionID == authorized.binding.sessionID,
                  existing.policyRevision == policyRevision,
                  existing.grantEpoch == grantEpoch,
                  existing.operation == parsed.operation else {
                return .failure(.invalidIntent("request identity conflict"))
            }
            guard Date() < existing.approvalExpiresAt else { return .failure(.approvalRequired) }
            return .success(existing.receipt)
        case .success(nil): break
        }
        switch settingsStore.bl6ReplayRecord(for: requestID) {
        case .failure: return .failure(.transactionUnknown)
        case .success(.some): return .failure(.invalidIntent("request identity conflict"))
        case .success(nil): break
        }
        if let shortcutStore {
            switch shortcutStore.bl6ReplayRecord(for: requestID, profileID: profileID) {
            case .failure: return .failure(.transactionUnknown)
            case .success(.some): return .failure(.invalidIntent("request identity conflict"))
            case .success(nil): break
            }
        }
        if parsed.operation == .rollback, let receiptID = parsed.undoReceiptID {
            switch settingsStore.bl6ReplayRecord(receiptID: receiptID) {
            case .failure: return .failure(.transactionUnknown)
            case .success(.some): return .failure(.invalidIntent("undo receipt identity conflict"))
            case .success(nil): break
            }
            if let shortcutStore {
                switch shortcutStore.bl6ReplayRecord(receiptID: receiptID, profileID: profileID) {
                case .failure: return .failure(.transactionUnknown)
                case .success(.some): return .failure(.invalidIntent("undo receipt identity conflict"))
                case .success(nil): break
                }
            }
        }
        let preparationResult = enablement
            ? mcpManager.prepareBL6EnablementReplay(parsed, profileID: profileID)
            : mcpManager.prepareBL6NameReplay(parsed, profileID: profileID)
        let preparation: MCPServerManager.BL6NamePreparation
        switch preparationResult {
        case .failure(.staleRevision):
            return .failure(.staleRevision(
                expected: parsed.expectedRevision,
                actual: mcpManager.bl6NameRevision() ?? "<unavailable>"
            ))
        case .failure(.conflict): return .failure(.invalidIntent("MCP name proposal rejected"))
        case .failure(.persistence): return .failure(.transactionUnknown)
        case .success(let ready): preparation = ready
        }
        let receipt = BL6SettingsReceipt(
            requestID: requestID,
            operation: parsed.operation,
            previousRevision: preparation.previousRevision,
            effectiveRevision: preparation.effectiveRevision,
            changedKeys: preparation.changedKeys,
            rollbackValues: [:]
        )
        let record = BL6SettingsReplayRecord(
            requestID: requestID, payloadDigest: payloadDigest,
            frozenInput: parsed, approvalBindingDigest: authorized.binding.identityDigest,
            profileID: profileID, scope: authorized.binding.scope,
            sessionID: authorized.binding.sessionID,
            policyRevision: policyRevision, grantEpoch: grantEpoch,
            approvalExpiresAt: authorized.binding.expiresAt,
            operation: parsed.operation, receipt: receipt,
            rollbackValues: preparation.rollbackValues
        )
        let commitResult = enablement
            ? mcpManager.commitBL6EnablementReplay(record, profileID: profileID)
            : mcpManager.commitBL6NameReplay(record, profileID: profileID)
        switch commitResult {
        case .success(let committed):
            reloadMCP()
            return .success(committed)
        case .failure(.staleRevision):
            return .failure(.staleRevision(
                expected: parsed.expectedRevision,
                actual: mcpManager.bl6NameRevision() ?? "<unavailable>"
            ))
        case .failure(.conflict): return .failure(.invalidIntent("MCP name commit rejected"))
        case .failure(.persistence): return .failure(.transactionUnknown)
        }
    }

    /// Model-initiated add/remove of an MCP server reuses the Settings page
    /// writers. A new server is unauthorized, exactly like a manual add.
    private func dispatchApprovedSessionManagement(
        parsed: BL6SettingsApprovedInput, currentSessionID: String, owner: ChatStore
    ) -> Result<BL6SettingsReceipt, BL6SettingsDispatchError> {
        let previous = owner.conversationSessionRevision(currentSessionID: currentSessionID)
        guard parsed.expectedRevision == previous else {
            return .failure(.staleRevision(expected: parsed.expectedRevision, actual: previous))
        }
        guard let (key, value) = parsed.changes.first else {
            return .failure(.invalidIntent("session change required"))
        }
        switch owner.applyConversationSessionChange(
            key: key, value: value, currentSessionID: currentSessionID
        ) {
        case .failure(let error):
            return .failure(error)
        case .success(let rollback):
            return .success(BL6SettingsReceipt(
                requestID: UUID().uuidString, operation: parsed.operation,
                previousRevision: previous,
                effectiveRevision: owner.conversationSessionRevision(currentSessionID: currentSessionID),
                changedKeys: [key], rollbackValues: [key: rollback]
            ))
        }
    }

    /// Notification category and keep-awake switches: the same controllers as the Settings page.
    /// Only the in-app switch changes; no system permission is requested.
    private func dispatchApprovedPreferences(
        parsed: BL6SettingsApprovedInput
    ) -> Result<BL6SettingsReceipt, BL6SettingsDispatchError> {
        guard let previous = conversationPreferencesRevision() else { return .failure(.transactionUnknown) }
        guard parsed.expectedRevision == previous else {
            return .failure(.staleRevision(expected: parsed.expectedRevision, actual: previous))
        }
        guard let (key, value) = parsed.changes.first else {
            return .failure(.invalidIntent("preference change required"))
        }
        switch applyConversationPreference(key: key, value: value) {
        case .failure(let error): return .failure(error)
        case .success(let rollback):
            return .success(BL6SettingsReceipt(
                requestID: UUID().uuidString, operation: parsed.operation,
                previousRevision: previous,
                effectiveRevision: conversationPreferencesRevision() ?? previous,
                changedKeys: [key], rollbackValues: [key: rollback]
            ))
        }
    }

    /// Scheduled-task enable/disable, create and delete from the conversation. Same store writers as the
    /// Settings page; a created task is never authorized and only tasks of this session/project are touched.
    private func dispatchApprovedHookManagement(
        parsed: BL6SettingsApprovedInput, requestID: String
    ) -> Result<BL6SettingsReceipt, BL6SettingsDispatchError> {
        let revision = parsed.expectedRevision
        guard let store = conversationHookStore, let (key, value) = parsed.changes.first, case .object(let fields) = value,
              case .text(let id)? = fields["id"], !id.isEmpty,
              id.utf8.count <= 128, id.allSatisfy({
                  $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_")
              }) else {
            return .failure(.invalidIntent("invalid user Hook change"))
        }
        do {
            let effective: String
            if key == "hooks.entries.add" {
                guard Set(fields.keys).isSubset(of: ["id", "event", "command", "enabled"]),
                      fields["enabled"] == nil || fields["enabled"] == .toggle(false),
                      case .text(let eventName)? = fields["event"], let event = HookEvent(rawValue: eventName),
                      case .text(let command)? = fields["command"] else {
                    return .failure(.invalidIntent("new user Hooks must be disabled"))
                }
                effective = try store.addDisabledUserHook(
                    HookDefinition(id: id, event: event, command: command, enabled: false),
                    expectedRevision: revision)
            } else {
                guard Set(fields.keys) == ["id"] else {
                    return .failure(.invalidIntent("remove requires the exact disabled user Hook id"))
                }
                effective = try store.removeDisabledUserHook(id: id, expectedRevision: revision)
            }
            return .success(BL6SettingsReceipt(
                requestID: requestID, operation: parsed.operation, previousRevision: revision,
                effectiveRevision: effective, changedKeys: [key], rollbackValues: [:]))
        } catch HookConfigStoreError.contentChangedSinceReview {
            guard let actual = store.conversationUserHooksRevision() else { return .failure(.transactionUnknown) }
            return .failure(.staleRevision(expected: revision, actual: actual))
        } catch {
            return .failure(.invalidIntent("user Hook change rejected"))
        }
    }

    private func dispatchApprovedSchedulerManagement(
        parsed: BL6SettingsApprovedInput, currentSessionID: String,
        owner: ChatStore, store: SchedulerTaskStore
    ) -> Result<BL6SettingsReceipt, BL6SettingsDispatchError> {
        let scope = owner.activeMemoryScope.flatMap {
            $0.isValid && $0.sessionID == currentSessionID ? $0 : nil
        }
        let previous = SchedulerStoreTypedCatalogAdapter.revision(visibleTo: scope, in: store)
        guard parsed.expectedRevision == previous else {
            return .failure(.staleRevision(expected: parsed.expectedRevision, actual: previous))
        }
        guard let (key, value) = parsed.changes.first else {
            return .failure(.invalidIntent("scheduler change required"))
        }
        func visibleTask(_ idText: String) -> SchedulerTask? {
            guard let scope, let id = UUID(uuidString: idText),
                  let task = store.task(id: id), !task.isDeleted,
                  SchedulerStoreTypedCatalogAdapter.isVisible(task, to: scope) else { return nil }
            return task
        }
        var rollback: [String: BL6SettingValue] = [:]
        if key == "scheduler.tasks.add" {
            guard case .object(let fields) = value,
                  Set(fields.keys) == ["name", "cron-expression", "command"],
                  case .text(let rawName)? = fields["name"],
                  case .text(let rawCron)? = fields["cron-expression"],
                  case .text(let rawCommand)? = fields["command"] else {
                return .failure(.invalidIntent("scheduler task needs name, cron-expression, command"))
            }
            let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            let cron = rawCron.trimmingCharacters(in: .whitespacesAndNewlines)
            let command = rawCommand.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, !command.isEmpty else {
                return .failure(.invalidIntent("任务名称和命令不能为空"))
            }
            guard let sessionID = UUID(uuidString: currentSessionID),
                  let prefill = owner.schedulerTaskTargetPrefill(forSessionID: sessionID) else {
                return .failure(.invalidIntent("当前会话没有项目或还没有用户回合，不能创建定时任务"))
            }
            if let error = store.add(
                name: name, cronExpression: cron, command: command, isEnabled: true,
                targetSessionID: prefill.sessionID, targetProjectID: prefill.projectID,
                targetTurnID: prefill.turnID
            ) { return .failure(.invalidIntent(error)) }
        } else if key == "scheduler.tasks.remove" {
            guard case .object(let fields) = value, Set(fields.keys) == ["id"],
                  case .text(let idText)? = fields["id"],
                  let task = visibleTask(idText),
                  let request = SchedulerTaskDeletionConsumer.request(for: task),
                  SchedulerTaskDeletionConsumer.confirm(
                    request, selectedTaskID: task.id, store: store) == .deleted else {
                return .failure(.invalidIntent("定时任务不存在、不属于当前会话，或删除失败"))
            }
        } else {
            let parts = key.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 3, let scope, let task = visibleTask(parts[1]),
                  case .success(let preview) = SchedulerStoreTypedCatalogAdapter.preview(
                    settingID: key, value: value, expectedVersion: task.version,
                    expectedEnablementRevision: task.enablementRevision,
                    visibleTo: { SchedulerStoreTypedCatalogAdapter.isVisible($0, to: scope) },
                    in: store),
                  case .toggle(let enabled) = preview.proposed,
                  store.setEnabled(task.id, enabled: enabled, expectedVersion: task.version,
                                   expectedEnablementRevision: task.enablementRevision) else {
                return .failure(.invalidIntent("定时任务启停被拒绝：任务不存在、不属于当前会话或已变化"))
            }
            rollback[key] = .toggle(task.isEnabled)
        }
        return .success(BL6SettingsReceipt(
            requestID: UUID().uuidString, operation: parsed.operation,
            previousRevision: previous,
            effectiveRevision: SchedulerStoreTypedCatalogAdapter.revision(visibleTo: scope, in: store),
            changedKeys: [key], rollbackValues: rollback
        ))
    }

    private func dispatchApprovedMCPServerManagement(
        parsed: BL6SettingsApprovedInput
    ) -> Result<BL6SettingsReceipt, BL6SettingsDispatchError> {
        let previous = mcpManager.bl6NameRevision() ?? "<unavailable>"
        guard parsed.expectedRevision == previous else {
            return .failure(.staleRevision(expected: parsed.expectedRevision, actual: previous))
        }
        guard let (key, value) = parsed.changes.first, case .object(let fields) = value else {
            return .failure(.invalidIntent("MCP server change must be an object"))
        }
        func text(_ name: String) -> String? {
            guard case .text(let raw)? = fields[name] else { return nil }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        guard let id = text("id") else { return .failure(.invalidIntent("MCP server id required")) }
        if key == "mcp.servers.add" {
            guard Set(fields.keys).isSubset(of: ["id", "name", "command", "args", "env"]),
                  let name = text("name"), let command = text("command"),
                  case .list(let args)? = fields["args"],
                  case .object(let envFields)? = fields["env"] else {
                return .failure(.invalidIntent("MCP server needs id, name, command, args, env"))
            }
            var env: [String: String] = [:]
            for (envName, envValue) in envFields {
                guard case .text(let raw) = envValue else {
                    return .failure(.invalidIntent("MCP env values must be text"))
                }
                env[envName] = raw
            }
            guard mcpManager.server(id: id) == nil else {
                return .failure(.invalidIntent("MCP server id already exists"))
            }
            guard addMCPServer(MCPServer(
                id: id, name: name, type: .stdio, enabled: true,
                command: command, args: args, env: env
            )) else { return .failure(.invalidIntent("MCP server add rejected")) }
        } else {
            guard Set(fields.keys) == ["id"], mcpManager.server(id: id) != nil,
                  removeMCPServer(id: id) else {
                return .failure(.invalidIntent("MCP server remove rejected"))
            }
        }
        return .success(BL6SettingsReceipt(
            requestID: UUID().uuidString, operation: parsed.operation,
            previousRevision: previous,
            effectiveRevision: mcpManager.bl6NameRevision() ?? "<unavailable>",
            changedKeys: [key], rollbackValues: [:]
        ))
    }

    private func dispatchApprovedSkillEnablement(
        parsed: BL6SettingsApprovedInput, payloadDigest: String,
        authorized: BL6SettingsAuthorizedCall, profileID: String,
        policyRevision: String, grantEpoch: String, skillsStore: SkillsStore?,
        shortcutStore: ShortcutStore?, sidebarWidthSetting: SessionSidebarWidthSetting?,
        undo: BL6SettingsReplayRecord?
    ) -> Result<BL6SettingsReceipt, BL6SettingsDispatchError> {
        do {
            guard let skillsStore, skillsStore.hasCanonicalBL6EnablementOwner(skillStore),
                  let scope = memoryScopeProvider?(), scope.isValid,
                  scope.sessionID == authorized.binding.sessionID else {
                return .failure(.approvalRequired)
            }
            let requestID = authorized.requestID
            if let old = try skillStore.bl6SkillEnablementReplayRecord(for: requestID, profileID: profileID) {
                guard old.payloadDigest == payloadDigest, old.frozenInput == parsed,
                      old.approvalBindingDigest == authorized.binding.identityDigest,
                      old.profileID == profileID, old.scope == authorized.binding.scope,
                      old.sessionID == authorized.binding.sessionID,
                      old.policyRevision == policyRevision, old.grantEpoch == grantEpoch,
                      old.operation == parsed.operation else {
                    return .failure(.invalidIntent("request identity conflict"))
                }
                guard Date() < old.approvalExpiresAt else { return .failure(.approvalRequired) }
                return .success(try skillStore.replayBL6SkillEnablementRecord(old, profileID: profileID))
            }
            switch settingsStore.bl6ReplayRecord(for: requestID) {
            case .failure: return .failure(.transactionUnknown)
            case .success(.some): return .failure(.invalidIntent("request identity conflict"))
            case .success(nil): break
            }
            switch mcpManager.bl6NameReplayRecord(for: requestID, profileID: profileID) {
            case .failure: return .failure(.transactionUnknown)
            case .success(.some): return .failure(.invalidIntent("request identity conflict"))
            case .success(nil): break
            }
            switch mcpManager.bl6EnablementReplayRecord(for: requestID, profileID: profileID) {
            case .failure: return .failure(.transactionUnknown)
            case .success(.some): return .failure(.invalidIntent("request identity conflict"))
            case .success(nil): break
            }
            if let shortcutStore {
                switch shortcutStore.bl6ReplayRecord(for: requestID, profileID: profileID) {
                case .failure: return .failure(.transactionUnknown)
                case .success(.some): return .failure(.invalidIntent("request identity conflict"))
                case .success(nil): break
                }
            }
            if let sidebarWidthSetting {
                switch sidebarWidthSetting.bl6ReplayRecord(for: requestID, profileID: profileID) {
                case .failure: return .failure(.transactionUnknown)
                case .success(.some): return .failure(.invalidIntent("request identity conflict"))
                case .success(nil): break
                }
            }
            let snapshot = try SkillsStoreTypedCatalogAdapter.approvedSnapshot(
                from: skillsStore, boundTo: skillStore, visibleTo: scope)
            guard snapshot.revision == parsed.expectedRevision else {
                return .failure(.staleRevision(expected: parsed.expectedRevision, actual: snapshot.revision))
            }
            let key: String
            let enabled: Bool
            if let undo {
                guard undo.operation == .apply, undo.profileID == profileID,
                      undo.sessionID == scope.sessionID, undo.receipt.changedKeys.count == 1,
                      let id = undo.receipt.changedKeys.first,
                      case .toggle(let before)? = undo.rollbackValues[id] else {
                    return .failure(.invalidIntent("skill undo receipt mismatch"))
                }
                key = id
                enabled = before
            } else {
                guard parsed.operation == .apply, parsed.changes.count == 1,
                      let (id, value) = parsed.changes.first, case .toggle(let proposed) = value else {
                    return .failure(.invalidIntent("skill enablement mutation shape"))
                }
                key = id
                enabled = proposed
            }
            let prefix = "skills.app:"
            let suffix = ".enabled"
            guard key.hasPrefix(prefix), key.hasSuffix(suffix),
                  key.count > prefix.count + suffix.count,
                  let previousEnabled = snapshot.values[key] else {
                return .failure(.approvalRequired)
            }
            let skillID = String(key.dropFirst(prefix.count).dropLast(suffix.count))
            let makeRecord: @Sendable (String, String) throws -> BL6SettingsReplayRecord = { previous, effective in
                guard previous == parsed.expectedRevision else {
                    throw BL6SettingsDispatchError.staleRevision(expected: parsed.expectedRevision, actual: previous)
                }
                guard Date() < authorized.binding.expiresAt else { throw BL6SettingsDispatchError.approvalRequired }
                let rollbackValues: [String: BL6SettingValue] = [key: .toggle(previousEnabled)]
                let receipt = BL6SettingsReceipt(requestID: requestID, operation: parsed.operation,
                    previousRevision: previous, effectiveRevision: effective,
                    changedKeys: [key], rollbackValues: [:])
                return BL6SettingsReplayRecord(requestID: requestID, payloadDigest: payloadDigest,
                    frozenInput: parsed, approvalBindingDigest: authorized.binding.identityDigest,
                    profileID: profileID, scope: authorized.binding.scope, sessionID: scope.sessionID,
                    policyRevision: policyRevision, grantEpoch: grantEpoch,
                    approvalExpiresAt: authorized.binding.expiresAt, operation: parsed.operation,
                    receipt: receipt, rollbackValues: rollbackValues)
            }
            let committed = try skillsStore.commitApprovedBL6Enablement(
                skillID: skillID, enabled: enabled, visibleTo: scope,
                profileID: profileID, expectedRevision: parsed.expectedRevision,
                undo: undo, boundTo: skillStore, makeReplayRecord: makeRecord)
            return .success(committed.receipt)
        } catch let error as BL6SettingsDispatchError {
            return .failure(error)
        } catch SkillsStoreTypedCatalogAdapter.ProjectionError.stalePreview {
            let actual: String
            if let scope = memoryScopeProvider?(), let snapshot = try? skillStore.bl6SkillEnablementSnapshot(visibleTo: scope) {
                actual = snapshot.revision
            } else { actual = "<unavailable>" }
            return .failure(.staleRevision(expected: parsed.expectedRevision, actual: actual))
        } catch { return .failure(.transactionUnknown) }
    }

    private func dispatchApprovedMemorySettings(
        parsed: BL6SettingsApprovedInput, payloadDigest: String,
        authorized: BL6SettingsAuthorizedCall, profileID: String,
        policyRevision: String, grantEpoch: String, shortcutStore: ShortcutStore?,
        sidebarWidthSetting: SessionSidebarWidthSetting?, undo: BL6MemoryReplayRecord?
    ) -> Result<BL6SettingsReceipt, BL6SettingsDispatchError> {
        do {
            guard let scope = memoryScopeProvider?(), scope.isValid,
                  scope.sessionID == authorized.binding.sessionID else {
                return .failure(.approvalRequired)
            }
            let requestID = authorized.requestID
            if let existing = try memoryStore.bl6MemoryReplayRecord(for: requestID, profileID: profileID) {
                let record = existing.settings
                guard record.payloadDigest == payloadDigest, record.frozenInput == parsed,
                      record.approvalBindingDigest == authorized.binding.identityDigest,
                      record.profileID == profileID, record.scope == authorized.binding.scope,
                      record.sessionID == authorized.binding.sessionID, record.policyRevision == policyRevision,
                      record.grantEpoch == grantEpoch, record.operation == parsed.operation,
                      existing.before.memoryScope == scope, existing.after.memoryScope == scope else {
                    return .failure(.invalidIntent("request identity conflict"))
                }
                guard Date() < record.approvalExpiresAt else { return .failure(.approvalRequired) }
                return .success(try memoryStore.replayBL6MemoryRecord(existing, profileID: profileID))
            }
            // Preserve the original cross-Store identity boundary.
            switch settingsStore.bl6ReplayRecord(for: requestID) {
            case .failure: return .failure(.transactionUnknown)
            case .success(.some): return .failure(.invalidIntent("request identity conflict"))
            case .success(nil): break
            }
            switch mcpManager.bl6NameReplayRecord(for: requestID, profileID: profileID) {
            case .failure: return .failure(.transactionUnknown)
            case .success(.some): return .failure(.invalidIntent("request identity conflict"))
            case .success(nil): break
            }
            switch mcpManager.bl6EnablementReplayRecord(for: requestID, profileID: profileID) {
            case .failure: return .failure(.transactionUnknown)
            case .success(.some): return .failure(.invalidIntent("request identity conflict"))
            case .success(nil): break
            }
            if let shortcutStore {
                switch shortcutStore.bl6ReplayRecord(for: requestID, profileID: profileID) {
                case .failure: return .failure(.transactionUnknown)
                case .success(.some): return .failure(.invalidIntent("request identity conflict"))
                case .success(nil): break
                }
            }
            if let sidebarWidthSetting {
                switch sidebarWidthSetting.bl6ReplayRecord(for: requestID, profileID: profileID) {
                case .failure: return .failure(.transactionUnknown)
                case .success(.some): return .failure(.invalidIntent("request identity conflict"))
                case .success(nil): break
                }
            }
            let revision = try memoryStore.bl6MemoryRevision(within: scope)
            guard revision == parsed.expectedRevision else {
                return .failure(.staleRevision(expected: parsed.expectedRevision, actual: revision))
            }
            let key: String
            let expectedBefore: MemoryFact
            let edit: MemoryStoreTypedCatalogAdapter.Preview?
            let rollback: MemoryStoreTypedCatalogAdapter.UndoPreview?
            if let undo {
                guard undo.settings.operation == .apply, undo.before.memoryScope == scope,
                      undo.after.memoryScope == scope, undo.settings.sessionID == scope.sessionID else {
                    return .failure(.approvalRequired)
                }
                key = try Self.singleMemoryChangedKey(undo.settings.receipt)
                let effect = MemoryStoreTypedCatalogAdapter.Effect(settingID: key,
                    before: undo.before, after: undo.after, lifecycleReceipt: nil)
                let preview = try MemoryStoreTypedCatalogAdapter.previewUndo(effect, in: self)
                expectedBefore = preview.effect.after
                rollback = preview
                edit = nil
            } else {
                guard parsed.operation == .apply, let (id, value) = parsed.changes.first else {
                    return .failure(.invalidIntent("memory mutation shape"))
                }
                let preview = try MemoryStoreTypedCatalogAdapter.preview(settingID: id, value: value, in: self)
                key = id
                expectedBefore = preview.before
                edit = preview
                rollback = nil
            }
            let makeRecord: BL6MemoryReplayRecordFactory = { before, _, beforeFacts, afterFacts in
                guard before == expectedBefore, Date() < authorized.binding.expiresAt else {
                    throw MemoryStoreError.concurrentMutation
                }
                let previous = try MemoryStore.bl6MemoryRevision(facts: beforeFacts, within: scope)
                guard previous == parsed.expectedRevision else { throw MemoryStoreError.concurrentMutation }
                let effective = try MemoryStore.bl6MemoryRevision(facts: afterFacts, within: scope)
                let receipt = BL6SettingsReceipt(requestID: requestID, operation: parsed.operation,
                    previousRevision: previous, effectiveRevision: effective, changedKeys: [key], rollbackValues: [:])
                return BL6SettingsReplayRecord(requestID: requestID, payloadDigest: payloadDigest,
                    frozenInput: parsed, approvalBindingDigest: authorized.binding.identityDigest,
                    profileID: profileID, scope: authorized.binding.scope, sessionID: scope.sessionID,
                    policyRevision: policyRevision, grantEpoch: grantEpoch,
                    approvalExpiresAt: authorized.binding.expiresAt, operation: parsed.operation,
                    receipt: receipt, rollbackValues: [:])
            }
            if let edit { _ = try MemoryStoreTypedCatalogAdapter.apply(edit, in: self, makeSettingsReplayRecord: makeRecord) }
            else if let rollback { _ = try MemoryStoreTypedCatalogAdapter.undo(rollback, in: self, makeSettingsReplayRecord: makeRecord) }
            guard let committed = try memoryStore.bl6MemoryReplayRecord(for: requestID, profileID: profileID) else {
                return .failure(.transactionUnknown)
            }
            return .success(committed.settings.receipt)
        } catch MemoryStoreTypedCatalogAdapter.Failure.undoUnsupported {
            // The original Store has no ordinary inverse for a tombstone.
            return .failure(.invalidIntent("memory tombstone undo is not an ordinary revision rollback"))
        } catch MemoryStoreError.concurrentMutation {
            let actual: String
            if let scope = memoryScopeProvider?(), let revision = try? memoryStore.bl6MemoryRevision(within: scope) {
                actual = revision
            } else { actual = "<unavailable>" }
            return .failure(.staleRevision(expected: parsed.expectedRevision, actual: actual))
        } catch { return .failure(.transactionUnknown) }
    }

    private static func singleMemoryChangedKey(_ receipt: BL6SettingsReceipt) throws -> String {
        guard receipt.changedKeys.count == 1, let key = receipt.changedKeys.first, key.hasPrefix("memory.fact.") else {
            throw MemoryStoreError.concurrentMutation
        }
        return key
    }

    /// Confirm one previously reviewed provider preview. The only credential
    /// crossing this boundary is the opaque BL6 handle; resolution remains in
    /// the existing post-CAS dispatch path and is never performed for a
    /// rejected preview.
    func confirmChatProviderSettings(
        _ preview: ChatProviderSettingsPreview,
        approvalReceiptID: String
    ) -> Result<BL6SettingsReceipt, BL6SettingsDispatchError> {
        if let expectedProviderRevision = preview.expectedProviderRevision {
            let actualProviderRevision = chatProviderSettingsProjection(providerID: preview.providerID)?.metadataRevision
            guard actualProviderRevision == expectedProviderRevision else {
                return .failure(.staleRevision(
                    expected: expectedProviderRevision,
                    actual: actualProviderRevision ?? "<missing>"
                ))
            }
        }
        let approvalReceiptID = approvalReceiptID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !approvalReceiptID.isEmpty else { return .failure(.approvalRequired) }
        return dispatchBL6Settings(BL6SettingsIntent(
            requestID: preview.requestID,
            operation: .configureProvider,
            expectedRevision: preview.expectedRevision,
            approval: .approved(receiptID: approvalReceiptID),
            providerConfiguration: BL6ProviderConfigurationPlan(
                providerID: preview.providerID,
                baseURL: preview.baseURL,
                modelIDs: preview.modelIDs,
                protocolType: preview.protocolType.rawValue,
                credential: preview.credential
            )
        ))
    }

    /// Build a typed preview from the live settings center. This is intended
    /// for the chat configuration surface, so its revision fences are bound
    /// to the same live snapshots used by `dispatchBL6Settings`.
    func makeChatProviderSettingsPreview(
        requestID: String = UUID().uuidString,
        providerID: String,
        baseURL: String,
        modelIDs: [String],
        protocolType: ProviderWireProtocol,
        credential: BL6ProviderCredentialMutation = .keepExisting
    ) -> Result<ChatProviderSettingsPreview, ChatProviderSettingsValidationError> {
        guard let snapshot = bl6EffectiveSettingsSnapshot else {
            return .failure(.emptyRevision)
        }
        do {
            return .success(try ChatProviderSettingsPreview(
                requestID: requestID,
                providerID: providerID,
                baseURL: baseURL,
                modelIDs: modelIDs,
                protocolType: protocolType,
                credential: credential,
                expectedRevision: snapshot.catalogRevision,
                expectedProviderRevision: chatProviderSettingsProjection(providerID: providerID)?.metadataRevision
            ))
        } catch let error as ChatProviderSettingsValidationError {
            return .failure(error)
        } catch {
            return .failure(.invalidBaseURL)
        }
    }

    /// Roll back provider metadata only. If the credential presence changed
    /// since the token was captured, fail closed rather than pretending that
    /// an unavailable previous secret can be restored.
    func rollbackChatProviderSettings(
        _ token: ChatProviderSettingsRollbackToken,
        approvalReceiptID: String,
        expectedCurrentProviderRevision: String? = nil
    ) -> Result<BL6SettingsReceipt, ChatProviderSettingsRollbackError> {
        let approvalReceiptID = approvalReceiptID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !approvalReceiptID.isEmpty else {
            return .failure(.dispatch(.approvalRequired))
        }
        let current = chatProviderSettingsProjection(providerID: token.providerID)
        // A provider that did not exist before the edit can be safely removed
        // even when the forward edit added a credential. For an existing
        // provider, however, a changed presence bit means its old credential
        // cannot be reconstructed without reading a secret.
        guard token.previous == nil || current?.credentialPresent == token.previous?.credentialPresent else {
            return .failure(.credentialStateChanged)
        }
        // The token retains the pre-edit metadata; rollback callers provide
        // the post-edit revision as a second CAS fence. Without that fence a
        // concurrent metadata edit cannot be distinguished from our forward
        // edit, so fail closed.
        let expectedCurrent = expectedCurrentProviderRevision ?? token.expectedProviderRevision
        if let expectedCurrent,
           current?.metadataRevision != expectedCurrent {
            return .failure(.metadataChanged)
        }
        guard let currentSettings = bl6EffectiveSettingsSnapshot else {
            return .failure(.dispatch(.invalidIntent("effective settings unavailable")))
        }
        guard currentSettings.catalogRevision == token.expectedSettingsRevision else {
            return .failure(.dispatch(.staleRevision(
                expected: token.expectedSettingsRevision,
                actual: currentSettings.catalogRevision
            )))
        }
        let provider: BL6ProviderConfigurationPlan
        if let previous = token.previous {
            provider = BL6ProviderConfigurationPlan(
                providerID: previous.providerID,
                baseURL: previous.baseURL,
                modelIDs: previous.modelIDs,
                protocolType: previous.protocolType.rawValue,
                credential: .keepExisting
            )
        } else {
            // The clear operation ignores metadata fields, but valid typed
            // placeholders keep the core contract explicit and deterministic.
            provider = BL6ProviderConfigurationPlan(
                providerID: token.providerID,
                baseURL: "https://invalid.local",
                modelIDs: ["rollback-placeholder"],
                protocolType: ProviderWireProtocol.openaiCompatible.rawValue,
                credential: .clear
            )
        }
        let result = dispatchBL6Settings(BL6SettingsIntent(
            requestID: "rollback-" + token.providerID + "-" + UUID().uuidString,
            operation: .configureProvider,
            expectedRevision: token.expectedSettingsRevision,
            approval: .approved(receiptID: approvalReceiptID),
            providerConfiguration: provider
        ))
        return result.mapError(ChatProviderSettingsRollbackError.dispatch)
    }

    /// Keep UI recovery finite and secret-free. The original error is not
    /// serialized into chat-facing state or logs by this mapper.
    static func chatProviderSettingsRecoveryState(
        for error: BL6SettingsDispatchError
    ) -> ChatProviderSettingsRecoveryState {
        switch error {
        case .transactionUnknown:
            return .blockedTransactionUnknown
        case .staleRevision:
            return .reopenRequired
        case .approvalRequired, .invalidIntent, .catalog,
             .providerConfigurationRequired, .providerMutationFailed:
            return .retryable
        }
    }

    /// Execute the canonical intent → plan → policy/approval → SettingsStore
    /// transaction. The returned receipt is the only state exposed to Chat;
    /// effective values are re-read from this SettingsCenter on the next turn.
    @discardableResult
    func dispatchBL6Settings(_ intent: BL6SettingsIntent) -> Result<BL6SettingsReceipt, BL6SettingsDispatchError> {
        guard bl6SettingsTransactionState == .ready else {
            return .failure(.transactionUnknown)
        }
        guard let current = bl6EffectiveSettingsSnapshot else {
            return .failure(.invalidIntent("effective settings unavailable"))
        }
        let executor = BL6SettingsExecutor()
        let defaults = bl6Values(from: .defaults, credentialPresent: false)
        let plan: BL6SettingsPlan
        do {
            plan = try executor.plan(intent, against: current, defaults: defaults)
        } catch let error as BL6SettingsDispatchError {
            return .failure(error)
        } catch {
            return .failure(.invalidIntent("plan rejected"))
        }

        var candidate = settingsMirror
        do {
            try applyBL6Values(plan.targetValues, to: &candidate)
        } catch let error as BL6SettingsDispatchError {
            return .failure(error)
        } catch {
            return .failure(.invalidIntent("typed value rejected"))
        }

        // Build the receipt before any provider side effect. The executor is a
        // pure CAS reducer; doing this first means a receipt failure cannot
        // strand a credential mutation without an observable receipt.
        let execution: (snapshot: BL6EffectiveSettingsSnapshot, receipt: BL6SettingsReceipt)
        do {
            execution = try executor.execute(plan, against: current)
        } catch let error as BL6SettingsDispatchError {
            return .failure(error)
        } catch {
            return .failure(.invalidIntent("receipt unavailable"))
        }

        let previousSettings = settingsMirror
        let composerPolicyChanged = candidate.agent.composerPolicy != previousSettings.agent.composerPolicy
            || intent.operation == .reset
        let persisted = persistSettings({ settingsStore.replace(with: candidate) }) {
            self.logManager.minimumLevel = LogLevel(candidate.privacy.logLevel)
            self.onApprovalPolicyChanged?(candidate.agent.approvalPolicy)
            if composerPolicyChanged { self.onComposerPolicyChanged?(candidate.agent.composerPolicy) }
            if candidate.agent.childConcurrencyUserSelected != previousSettings.agent.childConcurrencyUserSelected
                || candidate.agent.childConcurrencyEnabledSessionCount != previousSettings.agent.childConcurrencyEnabledSessionCount
                || intent.operation == .reset {
                self.publishChildConcurrencySelectionAfterCommit()
            }
            self.reloadAll()
        }
        guard persisted else { return .failure(.invalidIntent("settings transaction rejected")) }

        // Provider credentials are consumed exactly once and only after the
        // typed plan has passed policy/revision checks. Empty input keeps the
        // existing key; the model can only submit the opaque handle.
        if let provider = plan.providerConfiguration {
            guard let protocolType = ProviderWireProtocol(rawValue: provider.protocolType) else {
                return compensateSettingsAfterProviderFailure(
                    previousSettings,
                    failure: .providerMutationFailed,
                    providerStateUnknown: false
                )
            }
            let credential: String
            var shouldSaveProvider = true
            switch provider.credential {
            case .keepExisting:
                credential = ""
            case .clear:
                guard envStore.deleteEnvVar(name: provider.providerID) else {
                    return compensateSettingsAfterProviderFailure(
                        previousSettings,
                        failure: .providerMutationFailed,
                        providerStateUnknown: projectProviderPersistenceFailure()
                    )
                }
                credential = ""
                shouldSaveProvider = false
            case .opaqueHandle(let handle):
                guard let resolver = bl6CredentialResolver, let resolved = resolver(handle), !resolved.isEmpty else {
                    return compensateSettingsAfterProviderFailure(
                        previousSettings,
                        failure: .providerMutationFailed,
                        providerStateUnknown: false
                    )
                }
                credential = resolved
            }
            if shouldSaveProvider {
                guard saveProvider(
                    name: provider.providerID,
                    apiKey: credential,
                    baseURL: provider.baseURL,
                    modelNames: provider.modelIDs,
                    protocolType: protocolType
                ) else {
                    return compensateSettingsAfterProviderFailure(
                        previousSettings,
                        failure: .providerMutationFailed,
                        providerStateUnknown: projectProviderPersistenceFailure()
                    )
                }
            }
        }
        return .success(execution.receipt)
    }

    private func compensateSettingsAfterProviderFailure(
        _ previousSettings: AppSettings,
        failure: BL6SettingsDispatchError,
        providerStateUnknown: Bool
    ) -> Result<BL6SettingsReceipt, BL6SettingsDispatchError> {
        let childConcurrencyChanged = settingsMirror.agent.childConcurrencyUserSelected
            != previousSettings.agent.childConcurrencyUserSelected
            || settingsMirror.agent.childConcurrencyEnabledSessionCount
                != previousSettings.agent.childConcurrencyEnabledSessionCount
        let composerPolicyChanged = settingsMirror.agent.composerPolicy != previousSettings.agent.composerPolicy
        let compensated = persistSettings({ settingsStore.replace(with: previousSettings) }) {
            self.logManager.minimumLevel = LogLevel(previousSettings.privacy.logLevel)
            self.onApprovalPolicyChanged?(previousSettings.agent.approvalPolicy)
            if composerPolicyChanged { self.onComposerPolicyChanged?(previousSettings.agent.composerPolicy) }
            if childConcurrencyChanged {
                self.publishChildConcurrencySelectionAfterCommit()
            }
            self.reloadAll()
        }
        guard compensated, !providerStateUnknown else {
            // Keep the user-visible provider diagnostic aligned with the
            // durable fence. A Keychain rollback failure is not an ordinary
            // provider mutation error and must remain explicitly projected
            // while the effective settings snapshot is withheld.
            if providerStateUnknown {
                projectProviderSaveFailure(.keychainRollbackFailed)
            }
            markBL6SettingsTransactionUnknown()
            return .failure(.transactionUnknown)
        }
        return .failure(failure)
    }

    /// Project the typed persistence failure before compensation. This is
    /// needed for provider clears, where `saveProvider` is never reached and
    /// therefore cannot populate `providerSaveFailure` itself.
    private func projectProviderPersistenceFailure() -> Bool {
        guard let persistenceError = envStore.lastPersistenceError else {
            return false
        }
        projectProviderSaveFailure(ProviderSaveFailureCategory(
            persistenceError: persistenceError
        ))
        return persistenceError == .keychainRollbackFailed
    }

    private func applyBL6Values(
        _ values: [String: BL6SettingValue],
        to candidate: inout AppSettings
    ) throws {
        func text(_ id: String) throws -> String {
            guard case let .text(value) = values[id] else { throw BL6SettingsDispatchError.invalidIntent(id) }
            return value
        }
        func toggle(_ id: String) throws -> Bool {
            guard case let .toggle(value) = values[id] else { throw BL6SettingsDispatchError.invalidIntent(id) }
            return value
        }
        func integer(_ id: String) throws -> Int {
            guard case let .integer(value) = values[id], value >= 0 else { throw BL6SettingsDispatchError.invalidIntent(id) }
            return value
        }
        func decimal(_ id: String) throws -> Double {
            guard case let .decimal(value) = values[id], value.isFinite, value >= 0 else { throw BL6SettingsDispatchError.invalidIntent(id) }
            return value
        }
        func list(_ id: String) throws -> [String] {
            guard case let .list(value) = values[id] else { throw BL6SettingsDispatchError.invalidIntent(id) }
            return value
        }
        func object(_ id: String) throws -> [String: BL6SettingValue] {
            guard case let .object(value) = values[id] else { throw BL6SettingsDispatchError.invalidIntent(id) }
            return value
        }
        func enumValue<T: RawRepresentable>(_ id: String, _: T.Type) throws -> T where T.RawValue == String {
            guard let value = T(rawValue: try text(id)) else { throw BL6SettingsDispatchError.invalidIntent(id) }
            return value
        }

        candidate.general.appearance = try enumValue("general.appearance", Appearance.self)
        candidate.general.accentTheme = try enumValue("general.accent-theme", AccentTheme.self)
        // SETTINGS-27/THEME-05 + P3-UI-02（N-UI02-WIRE）：收敛后的预设键
        // 经 MinisCore 主题预设目录 v1 的迁移全函数（ThemePresetCatalogMigration）
        // 收敛，语义逐输入保持原 converging/nearest 双腿：
        // - 键存在且被目录识别（旧外观值、旧 18 组合串）→ 按中性明暗分支
        //   成为真值（dark/System 豁免仍 .pending，只还原外观轴，不推暗侧色）；
        // - 键存在但 rejected/未验收/目录规范词（无明暗轴信息）→ 回落到
        //   旧组合的 nearest 映射，绝不落进不可读组合；
        // - 键缺失 → 由旧组合确定性映射。
        // 各情形最后都走 setThemePreset，把旧字段重投影成预设的派生值，
        // 因此经这条路径也存不下 3×6 任意组合，且写回的值可跨重启解码。
        var storedPresetRaw: String?
        if case .text(let presetText)? = values["general.theme-preset"], !presetText.isEmpty {
            storedPresetRaw = presetText
        }
        candidate.general.setThemePreset(BL6ThemePresetCatalogConsumer.convergedAppearancePreset(
            storedRawValue: storedPresetRaw,
            legacyAppearance: candidate.general.appearance,
            legacyAccentTheme: candidate.general.accentTheme
        ))
        let provider = try text("general.default-provider-id")
        candidate.general.defaultProviderID = provider.isEmpty ? nil : provider
        let model = try text("general.default-model-id")
        candidate.general.defaultModelID = model.isEmpty ? nil : model
        let reference = try text("general.sub-model-reference")
        if reference.isEmpty {
            candidate.general.subModelReference = nil
        } else {
            let pieces = reference.split(separator: "/", maxSplits: 1).map(String.init)
            guard pieces.count == 2 else { throw BL6SettingsDispatchError.invalidIntent("general.sub-model-reference") }
            candidate.general.subModelReference = ProviderModelReference(providerID: pieces[0], modelID: pieces[1])
        }
        candidate.general.modelSpeedTier = try enumValue("general.model-speed-tier", ModelSpeedTier.self)
        candidate.general.chatOutputMode = try enumValue("general.chat-output-mode", ChatOutputMode.self)
        candidate.general.language = try text("general.language")

        candidate.agent.maxLoopIterations = try integer("agent.max-loop-iterations")
        candidate.agent.toolTimeoutSeconds = try integer("agent.tool-timeout-seconds")
        candidate.agent.concurrentToolLimit = try integer("agent.concurrent-tool-limit")
        let childConcurrency = try integer("agent.child-concurrency-user-selected")
        guard (1...ChildConcurrencySelection.hardMaximum).contains(childConcurrency) else {
            throw BL6SettingsDispatchError.invalidIntent("agent.child-concurrency-user-selected")
        }
        candidate.agent.childConcurrencyUserSelected = childConcurrency
        let enabledSessions = try integer("agent.child-concurrency-enabled-session-count")
        guard (1...ChildConcurrencySelection.hardMaximum).contains(enabledSessions) else {
            throw BL6SettingsDispatchError.invalidIntent("agent.child-concurrency-enabled-session-count")
        }
        candidate.agent.childConcurrencyEnabledSessionCount = enabledSessions
        let compactThreshold = try decimal("agent.auto-compact-threshold")
        guard (0...1).contains(compactThreshold) else {
            throw BL6SettingsDispatchError.invalidIntent("agent.auto-compact-threshold")
        }
        candidate.agent.autoCompactThreshold = compactThreshold
        candidate.agent.fallbackEnabled = try toggle("agent.fallback-enabled")
        candidate.agent.personaEnabled = try toggle("agent.persona-enabled")
        candidate.agent.personaPreset = try enumValue("agent.persona-preset", PersonaPreset.self)
        let persona = try object("agent.persona")
        guard case let .text(personaName) = persona["name"],
              case let .text(personaSummary) = persona["summary"],
              case let .text(personaTone) = persona["tone"],
              case let .text(personaAbilities) = persona["abilities"] else {
            throw BL6SettingsDispatchError.invalidIntent("agent.persona")
        }
        candidate.agent.persona = Persona(name: personaName, summary: personaSummary, tone: personaTone, abilities: personaAbilities)
        candidate.agent.memoryEnabled = try toggle("agent.memory-enabled")
        candidate.agent.approvalPolicy = try enumValue("agent.approval-policy", ApprovalPolicy.self)
        candidate.agent.availableModelWhitelist = try list("agent.available-model-whitelist")
        candidate.agent.newMessageInterruptsGeneration = try toggle("agent.new-message-interrupts-generation")
        let composer = try object("agent.composer-policy")
        guard case let .text(mode) = composer["mode"], let taskMode = ComposerTaskMode(rawValue: mode),
              case let .text(scope) = composer["approvalScope"], let approvalScope = ComposerApprovalScope(rawValue: scope),
              case let .text(effort) = composer["effort"], let composerEffort = ComposerEffort(rawValue: effort),
              case let .toggle(bypass) = composer["bypassModeConfirmed"] else {
            throw BL6SettingsDispatchError.invalidIntent("agent.composer-policy")
        }
        // 「禁用绕过」与「凭据路径保护」不进模型可改的设置投影：沿用现值，
        // 模型无法借设置工具关闭保护或重新打开绕过。
        let existingComposer = candidate.agent.composerPolicy
        candidate.agent.composerPolicy = ComposerPolicySettings(
            mode: taskMode, approvalScope: approvalScope, effort: composerEffort,
            bypassModeConfirmed: bypass,
            disableBypass: existingComposer.disableBypass,
            protectCredentialPaths: existingComposer.protectCredentialPaths)
        let runtime = try object("agent.policy-runtime-defaults")
        guard case let .integer(budget) = runtime["budget"], budget >= 0,
              case let .decimal(horizon) = runtime["deadlineHorizon"], horizon.isFinite, horizon >= 0,
              case let .integer(autonomy) = runtime["autonomyLevel"], let autonomyLevel = AutonomyLevel(rawValue: autonomy),
              case let .list(domains) = runtime["networkDomains"] else {
            throw BL6SettingsDispatchError.invalidIntent("agent.policy-runtime-defaults")
        }
        candidate.agent.policyRuntimeDefaults = ProductionPolicyDefaults(budget: budget, deadlineHorizon: horizon, autonomyLevel: autonomyLevel, networkDomains: Set(domains))

        let terminal = try object("agent.terminal-policy")
        let legacyKeys: Set<String> = ["automaticAllowCommands", "confirmationCommands", "userDeniedCommands"]
        let provenanceKeys = legacyKeys.union(["explicitConfirmationCommands", "confirmationProvenanceVersion"])
        guard Set(terminal.keys) == legacyKeys || Set(terminal.keys) == provenanceKeys else {
            throw BL6SettingsDispatchError.invalidIntent("agent.terminal-policy")
        }
        guard
              case let .list(allowed) = terminal["automaticAllowCommands"],
              case let .list(confirmation) = terminal["confirmationCommands"],
              case let .list(denied) = terminal["userDeniedCommands"] else {
            throw BL6SettingsDispatchError.invalidIntent("agent.terminal-policy")
        }
        let hardDenied = TerminalPolicySnapshot.productHardDeniedCommands
        let allCommands = allowed + confirmation + denied
        let allowedSet = Set(allowed)
        let confirmationSet = Set(confirmation)
        let deniedSet = Set(denied)
        guard allCommands.allSatisfy({ command in
                  TerminalPolicySnapshot.normalizeCommandName(command) == command && !hardDenied.contains(command)
              }),
              allCommands.count == Set(allCommands).count,
              allowedSet.isDisjoint(with: confirmationSet),
              allowedSet.isDisjoint(with: deniedSet),
              confirmationSet.isDisjoint(with: deniedSet) else {
            throw BL6SettingsDispatchError.invalidIntent("agent.terminal-policy")
        }
        var explicit: [String] = []
        var version: Int? = nil
        if terminal.count == 5 {
            guard case let .list(names) = terminal["explicitConfirmationCommands"],
                  case let .integer(rawVersion) = terminal["confirmationProvenanceVersion"],
                  rawVersion == 0 || rawVersion == 1,
                  names.count == Set(names).count,
                  Set(names).isSubset(of: confirmationSet) else {
                throw BL6SettingsDispatchError.invalidIntent("agent.terminal-policy")
            }
            explicit = names
            version = rawVersion == 1 ? 1 : nil
        }
        candidate.agent.terminalPolicy = TerminalPolicySettings(
            automaticAllowCommands: allowed,
            confirmationCommands: confirmation,
            userDeniedCommands: denied,
            explicitConfirmationCommands: explicit,
            confirmationProvenanceVersion: version
        ).normalized()

        candidate.privacy.redactEnvValues = try toggle("privacy.redact-env-values")
        candidate.privacy.logLevel = try enumValue("privacy.log-level", SettingsLogLevel.self)
        candidate.privacy.collectAnalytics = try toggle("privacy.collect-analytics")
        let allowedRootPath = try text("privacy.allowed-root-path")
        candidate.privacy.allowedRootPath = allowedRootPath.isEmpty ? nil : allowedRootPath
        candidate.privacy.deniedRootPaths = try list("privacy.denied-root-paths")
        candidate.privacy.mountedFolderPaths = try list("privacy.mounted-folder-paths")

        candidate.storage.sessionRetentionDays = try integer("storage.session-retention-days")
        let memory = try integer("storage.memory-limit-mb")
        candidate.storage.memoryLimitMB = memory == 0 ? nil : memory
        candidate.storage.autoDeleteOldSessions = try toggle("storage.auto-delete-old-sessions")
        candidate.browser.userAgentPreset = try enumValue("browser.user-agent-preset", UserAgentPreset.self)
        candidate.browser.customUserAgent = try text("browser.custom-user-agent")
        candidate.browser.viewportMode = try enumValue("browser.viewport-mode", BrowserViewportMode.self)
        let viewportWidth = try integer("browser.custom-viewport-width")
        let viewportHeight = try integer("browser.custom-viewport-height")
        guard viewportWidth > 0, viewportHeight > 0 else {
            throw BL6SettingsDispatchError.invalidIntent("browser.custom-viewport")
        }
        candidate.browser.customViewportWidth = viewportWidth
        candidate.browser.customViewportHeight = viewportHeight
        let idleTimeout = try integer("browser.idle-tab-timeout-minutes")
        guard BrowserSettings.idleTimeoutRange.contains(idleTimeout) else {
            throw BL6SettingsDispatchError.invalidIntent("browser.idle-tab-timeout-minutes")
        }
        candidate.browser.idleTabTimeoutMinutes = idleTimeout
        let fontSize = try integer("typography.ui-base-font-size")
        guard TypographySettings.uiBaseFontSizeRange.contains(fontSize) else {
            throw BL6SettingsDispatchError.invalidIntent("typography.ui-base-font-size")
        }
        candidate.typography.uiBaseFontSize = fontSize
    }
}
