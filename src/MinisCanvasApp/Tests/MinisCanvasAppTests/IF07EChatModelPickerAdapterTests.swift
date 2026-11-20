import Testing
import Foundation
import CanvasCore
import MinisCore
@testable import MinisCanvasApp

@Suite("IF-07E ChatStore readiness model picker adapter")
@MainActor
struct IF07EChatModelPickerAdapterTests {
    @Test("runtime fallback candidates require selectable readiness receipts")
    func runtimeFallbackCandidatesRequireReadinessReceipts() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = ProviderReadinessStore(directory: directory)
        let blockedOpenAI = try #require(ProviderType.openAI.builtInModels.first)
        let selectableOpenAI = try #require(ProviderType.openAI.builtInModels.dropFirst().first)
        let openAI = builtinOpenAIRecord(models: [selectableOpenAI.id])
        let credentialRevision = "fixture-revision"
        store.upsert(record(
            providerID: ProviderType.openAI.rawValue,
            modelID: blockedOpenAI.id,
            status: .unavailable,
            readinessState: .blocked,
            evidenceID: nil,
            isApplied: true
        ))
        store.upsert(record(
            providerID: ProviderType.openAI.rawValue,
            modelID: selectableOpenAI.id,
            status: .passed,
            readinessState: .mock,
            evidenceID: "openai-selectable",
            isApplied: true,
            configurationFingerprint: ChatStore.BuiltinReadinessBinding.fingerprint(
                record: openAI,
                credentialRevision: credentialRevision
            )
        ))
        let luna = providerRecord(name: "LUNA", models: ["luna-model"])
        store.upsert(record(
            providerID: luna.name,
            modelID: "luna-model",
            status: .passed,
            readinessState: .mock,
            evidenceID: "luna-selectable",
            isApplied: true
        ))

        let chat = ChatStore(providerReadinessStore: store)
        chat.providerRecordsSource = { [luna, openAI] }
        chat.schedulerCredentialVersionSource = { providerID in
            providerID.caseInsensitiveCompare(openAI.name) == .orderedSame
                ? credentialRevision : nil
        }

        #expect(!chat.canSelectChatModel(providerID: "OpenAI", modelID: blockedOpenAI.id))
        #expect(!chat.canSelectChatModel(providerID: "openai", modelID: blockedOpenAI.id))
        #expect(chat.canSelectChatModel(providerID: "OpenAI", modelID: selectableOpenAI.id))
        #expect(chat.canSelectChatModel(providerID: "openai", modelID: selectableOpenAI.id))
        #expect(!chat.canSelectChatModel(providerID: "unconfigured", modelID: selectableOpenAI.id))

        let candidates = chat.providerRuntimeFallbackCandidates(
            excludingProviderID: "Anthropic"
        )

        #expect(candidates.map(\.providerID) == ["LUNA", ProviderType.openAI.runtimeProviderID])
        #expect(candidates.map(\.model.id) == ["luna-model", selectableOpenAI.id])
        #expect(candidates.allSatisfy { $0.receipt.isApplied })
        #expect(candidates.map(\.receipt.evidenceID) == [
            "luna-selectable",
            "openai-selectable"
        ])
    }

    @Test("applied but never-checked models are selectable in the picker but never fallback candidates")
    func uncheckedAppliedModelIsSelectableButNotReady() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ProviderReadinessStore(directory: directory)
        let luna = providerRecord(name: "LUNA", models: ["luna-model", "luna-failed"])
        store.upsert(record(
            providerID: luna.name, modelID: "luna-model",
            status: .discovered, readinessState: .unverified, evidenceID: nil, isApplied: true))
        store.upsert(record(
            providerID: luna.name, modelID: "luna-failed",
            status: .unavailable, readinessState: .blocked, evidenceID: nil, isApplied: true))
        let chat = ChatStore(providerReadinessStore: store)
        chat.providerRecordsSource = { [luna] }

        #expect(chat.isUncheckedChatModel(providerID: "LUNA", modelID: "luna-model"))
        #expect(!chat.isUncheckedChatModel(providerID: "LUNA", modelID: "luna-failed"))
        let models = chat.chatModelPickerModels(forProviderID: "LUNA")
        #expect(models.map(\.id) == ["luna-model"])
        #expect(models.first?.displayName.hasSuffix("未检查") == true)
        // 未检查不是就绪证据：运行时门与回退候选仍然拒绝。
        #expect(!chat.canSelectChatModel(providerID: "LUNA", modelID: "luna-model"))
        #expect(chat.providerRuntimeFallbackCandidates(excludingProviderID: "Anthropic").isEmpty)
        #expect(chat.applyChatModel(providerID: "LUNA", modelID: "luna-model"))
        #expect(chat.selectedModelID == "luna-model")
        #expect(!chat.applyChatModel(providerID: "LUNA", modelID: "luna-failed"))
    }

    @Test("repair card points at the provider whose check failed, not the first one")
    func repairTargetIsTheFailedProvider() throws {
        let healthy = providerRecord(name: "ALPHA", models: ["a"])
        let broken = providerRecord(name: "BETA", models: ["b"])
        let records = [
            record(providerID: "ALPHA", modelID: "a", status: .passed, readinessState: .mock,
                   evidenceID: "ok", isApplied: true),
            ProviderReadinessPersistenceRecord(
                providerID: "BETA", modelID: "b", status: .unavailable, readinessState: .blocked,
                checkedAt: Date(timeIntervalSince1970: 1_787_200_000), errorCategory: .unauthorized,
                isApplied: true)
        ]
        let target = ChatStore.providerRecordNeedingRepair(records: [healthy, broken], readiness: records)
        #expect(target?.name == broken.name)
        #expect(ChatStore.providerRecordNeedingRepair(records: [healthy, broken], readiness: [])?.name == healthy.name)
    }

    @Test("repair card prefers the user's default provider when it has not passed")
    func repairTargetPrefersUncheckedOrFailedDefault() throws {
        let other = providerRecord(name: "OTHER", models: ["o"])
        let mine = providerRecord(name: "MINE", models: ["m"])
        let otherFailed = ProviderReadinessPersistenceRecord(
            providerID: "OTHER", modelID: "o", status: .unavailable, readinessState: .blocked,
            checkedAt: Date(timeIntervalSince1970: 1_787_200_000), errorCategory: .unauthorized,
            isApplied: true)
        // 用户 11/20 旅程：别家检查失败、自己的默认还没检查 → 指向默认这家，而不是失败的别家。
        #expect(ChatStore.providerRecordNeedingRepair(
            records: [other, mine], readiness: [otherFailed], defaultProviderID: "custom.mine")?.name == "MINE")
        // 默认已通过：仍指向真正失败的那家。
        let minePassed = record(providerID: "MINE", modelID: "m", status: .passed, readinessState: .mock,
                                evidenceID: "ok", isApplied: true)
        #expect(ChatStore.providerRecordNeedingRepair(
            records: [other, mine], readiness: [otherFailed, minePassed], defaultProviderID: "custom.MINE")?.name == "OTHER")
        // 默认是内置服务商：不改原有挑法。
        #expect(ChatStore.providerRecordNeedingRepair(
            records: [other, mine], readiness: [otherFailed], defaultProviderID: "deepseek")?.name == "OTHER")
    }

    @Test("default custom provider with no check result at all asks for an in-place connection check")
    func defaultProviderAwaitingFirstCheck() throws {
        let mine = providerRecord(name: "MINE", models: ["m"])
        #expect(ChatStore.defaultProviderAwaitingFirstCheck(
            defaultProviderID: "custom.mine", records: [mine], readiness: [])?.name == "MINE")
        let failed = ProviderReadinessPersistenceRecord(
            providerID: "MINE", modelID: "m", status: .unavailable, readinessState: .blocked,
            checkedAt: Date(timeIntervalSince1970: 1_787_200_000), errorCategory: .unauthorized,
            isApplied: true)
        // 检查过（哪怕失败）就交给“去修复”卡，不再显示“检查连接”。
        #expect(ChatStore.defaultProviderAwaitingFirstCheck(
            defaultProviderID: "custom.mine", records: [mine], readiness: [failed]) == nil)
        #expect(ChatStore.defaultProviderAwaitingFirstCheck(
            defaultProviderID: "deepseek", records: [mine], readiness: []) == nil)
        #expect(ChatStore.defaultProviderAwaitingFirstCheck(
            defaultProviderID: nil, records: [mine], readiness: []) == nil)
    }

    @Test("model picker 'go to settings' maps built-in providers without a record to their own preset")
    func unreadyBuiltInProviderOpensItsPreset() {
        let presetIDs = Set(ProviderPreset.all.map(\.id))
        for type in [ProviderType.openAI, .anthropic, .gemini, .openRouter, .deepSeek, .dashScope, .local] {
            let id = ChatStore.providerPresetID(for: type)
            #expect(id != nil && presetIDs.contains(id!), "\(type) 没有对应预设")
        }
        #expect(ChatStore.providerPresetID(for: .deepSeek) == DeepSeekProviderContract.providerID)
        #expect(ChatStore.providerPresetID(for: .openAIResponses) == nil)
    }

    @Test("transient check failure keeps earlier result and says so; send-time feedback uses typed message")
    func transientFailureGuidance() {
        let failed = ProviderModelReadiness(
            modelID: "m", status: .failed, redactedResult: "最小请求失败（HTTP 429）",
            readiness: nil, errorCategory: .rateLimited)
        let kept = SettingsCenter.readinessStateWithFailureGuidance(failed, hasPriorPassed: true)
        #expect(kept.redactedResult.hasPrefix("最近一次检查失败："))
        let noEvidence = SettingsCenter.readinessStateWithFailureGuidance(failed, hasPriorPassed: false)
        #expect(!noEvidence.redactedResult.contains("HTTP"))
        #expect(!noEvidence.redactedResult.isEmpty)
        let feedback = ChatStore.readinessFailureFeedback(category: .unauthorized)
        #expect(feedback.contains("API Key"))
        #expect(feedback.contains("草稿已保留"))
    }

    @Test("ChatGPT 账号的检查失败提示指向重新登录与套餐，不提 API Key")
    func chatGPTAccountFailureGuidance() {
        for category in [ProviderReadinessFailureCategory.unauthorized, .permissionDenied, .rateLimited, .missingCredential] {
            let feedback = ChatStore.readinessFailureFeedback(category: category, isChatGPTAccount: true)
            #expect(!feedback.contains("API Key"))
            #expect(feedback.contains("ChatGPT"))
            #expect(feedback.contains("草稿已保留"))
        }
    }

    @Test("restarted readiness store feeds only applied selectable models")
    func restartedStoreFeedsAppliedSelectableModels() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let firstStore = ProviderReadinessStore(directory: directory)
        firstStore.upsert(record(
            providerID: "LUNA",
            modelID: "gpt-5.6-luna",
            status: .passed,
            readinessState: .live,
            evidenceID: "live-settings:" + String(repeating: "a", count: 64),
            isApplied: true
        ))
        firstStore.upsert(record(
            providerID: "LUNA",
            modelID: "gpt-5.6-luna-mini",
            status: .discovered,
            readinessState: .unverified,
            evidenceID: nil,
            isApplied: false
        ))

        let restartedStore = ProviderReadinessStore(directory: directory)
        let chat = ChatStore(providerReadinessStore: restartedStore)
        let luna = providerRecord(name: "LUNA", models: [
            "gpt-5.6-luna",
            "gpt-5.6-luna-mini"
        ])
        chat.providerRecordsSource = { [luna] }

        #expect(chat.chatModelPickerItems.map(\.id) == ["luna/gpt-5.6-luna"])
        #expect(chat.chatModelPickerItems[0].isLiveVerified)
        #expect(chat.chatModelPickerModels(forProviderID: "LUNA").map(\.id) == [
            "gpt-5.6-luna"
        ])
        #expect(chat.chatProviderOptions.contains {
            if case .custom(let record) = $0 {
                return record.name == "LUNA" && record.modelNames == ["gpt-5.6-luna"]
            }
            return false
        })
    }

    @Test("persisted passed model enters the chat picker after explicit application")
    func persistedPassedModelBecomesSelectableAfterApply() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let firstStore = ProviderReadinessStore(directory: directory)
        firstStore.upsert(record(
            providerID: "LUNA",
            modelID: "gpt-5.6-luna",
            status: .passed,
            readinessState: .mock,
            evidenceID: "mock-evidence",
            isApplied: false
        ))

        let restartedStore = ProviderReadinessStore(directory: directory)
        _ = restartedStore.applyDiscoveredModels(
            providerID: "LUNA",
            modelIDs: ["gpt-5.6-luna"]
        )
        let chat = ChatStore(providerReadinessStore: restartedStore)
        let luna = providerRecord(name: "LUNA", models: ["gpt-5.6-luna"])
        chat.providerRecordsSource = { [luna] }

        #expect(chat.chatModelPickerItems.map(\.id) == ["luna/gpt-5.6-luna"])
        #expect(chat.chatModelPickerItems.first?.isSelectable == true)
        #expect(chat.chatModelPickerModels(forProviderID: "LUNA").map(\.id) == [
            "gpt-5.6-luna"
        ])
    }

    @Test("mock is selectable but non-live while unverified and unavailable are blocked")
    func failedModelsAreBlockedAndMockIsNonLive() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ProviderReadinessStore(directory: directory)
        store.upsert(record(
            providerID: "LUNA",
            modelID: "mock-model",
            status: .passed,
            readinessState: .mock,
            evidenceID: "fixture-evidence",
            isApplied: true
        ))
        store.upsert(record(
            providerID: "LUNA",
            modelID: "unverified-model",
            status: .unverified,
            readinessState: .unverified,
            evidenceID: nil,
            isApplied: true
        ))
        store.upsert(record(
            providerID: "LUNA",
            modelID: "failed-model",
            status: .unavailable,
            readinessState: .blocked,
            evidenceID: nil,
            isApplied: true
        ))

        let chat = ChatStore(providerReadinessStore: store)
        let luna = providerRecord(name: "LUNA", models: [
            "mock-model",
            "unverified-model",
            "failed-model"
        ])
        chat.providerRecordsSource = { [luna] }

        #expect(chat.chatModelPickerItems.map(\.modelID) == ["mock-model"])
        #expect(chat.chatModelPickerItems[0].isSelectable)
        #expect(!chat.chatModelPickerItems[0].isLiveVerified)
        #expect(chat.chatModelPickerModels(forProviderID: "LUNA").map(\.id) == ["mock-model"])

        #expect(!chat.canSelectChatModel(providerID: "LUNA", modelID: "unverified-model"))
        #expect(!chat.canSelectChatModel(providerID: "LUNA", modelID: "failed-model"))
        #expect(!chat.applyChatModel(providerID: "LUNA", modelID: "failed-model"))
        #expect(chat.selectedModelID == nil)
    }

    @Test("unbacked built-in OpenAI stays hidden and unselectable")
    func readinessHidesUnbackedBuiltInOpenAI() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ProviderReadinessStore(directory: directory)
        store.upsert(record(
            providerID: "LUNA",
            modelID: "blocked-model",
            status: .unverified,
            readinessState: .unverified,
            evidenceID: nil,
            isApplied: true
        ))

        let chat = ChatStore(providerReadinessStore: store)
        let luna = providerRecord(name: "LUNA", models: ["blocked-model"])
        chat.providerRecordsSource = { [luna] }

        #expect(!chat.chatProviderOptions.contains(.builtIn(.openAI)))
        #expect(!chat.chatProviderOptions.contains(.custom(luna)))
        #expect(chat.chatModelPickerModels(forProviderID: ProviderType.openAI.rawValue).isEmpty)
        #expect(!chat.canSelectChatModel(
            providerID: ProviderType.openAI.rawValue,
            modelID: ProviderType.openAI.builtInModels[0].id
        ))
        #expect(!chat.applyChatModel(
            providerID: ProviderType.openAI.rawValue,
            modelID: ProviderType.openAI.builtInModels[0].id
        ))
    }

    @Test("unavailable readiness only removes the matching built-in model")
    func unavailableReadinessOnlyRemovesMatchingBuiltInModel() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ProviderReadinessStore(directory: directory)
        let blockedModel = try #require(ProviderType.openAI.builtInModels.first)
        let fallbackModel = try #require(ProviderType.openAI.builtInModels.dropFirst().first)
        let openAI = builtinOpenAIRecord(models: [fallbackModel.id])
        let credentialRevision = "fixture-revision"
        store.upsert(record(
            providerID: ProviderType.openAI.rawValue,
            modelID: blockedModel.id,
            status: .unavailable,
            readinessState: .blocked,
            evidenceID: nil,
            isApplied: true
        ))
        store.upsert(record(
            providerID: ProviderType.openAI.rawValue,
            modelID: fallbackModel.id,
            status: .passed,
            readinessState: .mock,
            evidenceID: "openai-fallback",
            isApplied: true,
            configurationFingerprint: ChatStore.BuiltinReadinessBinding.fingerprint(
                record: openAI,
                credentialRevision: credentialRevision
            )
        ))

        let chat = ChatStore(providerReadinessStore: store)
        chat.providerRecordsSource = { [openAI] }
        chat.schedulerCredentialVersionSource = { _ in credentialRevision }
        let modelIDs = chat.chatModelPickerModels(
            forProviderID: ProviderType.openAI.rawValue
        ).map(\.id)

        #expect(chat.chatProviderOptions.contains(.builtIn(.openAI)))
        #expect(!modelIDs.contains(blockedModel.id))
        #expect(modelIDs.contains(fallbackModel.id))
        #expect(!chat.canSelectChatModel(
            providerID: ProviderType.openAI.rawValue,
            modelID: blockedModel.id
        ))
        #expect(chat.canSelectChatModel(
            providerID: ProviderType.openAI.rawValue,
            modelID: fallbackModel.id
        ))

        chat.setProvider(.openAI)
        #expect(chat.selectedProviderType == .openAI)
        #expect(chat.selectedModelID == fallbackModel.id)
    }

    @Test("provider and model identity stay independent and Canvas selection is untouched")
    func providerModelIdentityAndCanvasIsolation() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ProviderReadinessStore(directory: directory)
        store.upsert(record(
            providerID: "LUNA",
            modelID: "shared-model",
            status: .passed,
            readinessState: .mock,
            evidenceID: "luna-fixture",
            isApplied: true
        ))
        store.upsert(record(
            providerID: "SOL",
            modelID: "shared-model",
            status: .passed,
            readinessState: .live,
            evidenceID: "live-settings:" + String(repeating: "b", count: 64),
            isApplied: true
        ))

        let chat = ChatStore(providerReadinessStore: store)
        let luna = providerRecord(name: "LUNA", models: ["shared-model"])
        let sol = providerRecord(name: "SOL", models: ["shared-model"])
        chat.providerRecordsSource = { [luna, sol] }

        #expect(chat.chatModelPickerItems.map(\.id) == [
            "luna/shared-model",
            "sol/shared-model"
        ])
        #expect(chat.chatModelPickerItems.map(\.providerID) == ["luna", "sol"])
        #expect(chat.applyChatModel(providerID: "LUNA", modelID: "shared-model"))
        #expect(chat.selectedCustomProvider?.name == "LUNA")
        #expect(chat.selectedModelID == "shared-model")

        let canvas = CanvasStore()
        let node = try #require(canvas.addNode(ofType: ManjuNodeType.imageGen.rawValue))
        let before = try #require(canvas.canvasModelSelection(for: node.id))

        #expect(chat.applyChatModel(providerID: "SOL", modelID: "shared-model"))
        #expect(chat.selectedCustomProvider?.name == "SOL")
        #expect(chat.selectedModelID == "shared-model")
        #expect(canvas.canvasModelSelection(for: node.id) == before)
    }

    @Test("explicit Apply emits a receipt consumed by the picker and active provider")
    func explicitApplyEmitsReceiptForActiveProvider() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = ProviderReadinessStore(directory: directory)
        store.upsert(record(
            providerID: "LUNA",
            modelID: "gpt-5.6-luna",
            status: .passed,
            readinessState: .mock,
            evidenceID: "mock-readiness-evidence",
            isApplied: false
        ))
        _ = store.applyDiscoveredModels(
            providerID: "LUNA",
            modelIDs: ["gpt-5.6-luna"]
        )

        let chat = ChatStore(providerReadinessStore: store)
        let luna = providerRecord(name: "LUNA", models: ["gpt-5.6-luna"])
        chat.providerRecordsSource = { [luna] }

        #expect(chat.chatModelPickerProjection.items.map(\.id) == [
            "luna/gpt-5.6-luna"
        ])
        #expect(chat.applyChatModel(
            providerID: "LUNA",
            modelID: "gpt-5.6-luna"
        ))

        let receipt = try #require(chat.lastChatModelApplyReceipt)
        #expect(receipt.providerID == "luna")
        #expect(receipt.modelID == "gpt-5.6-luna")
        #expect(receipt.evidenceID == "mock-readiness-evidence")
        #expect(receipt.isApplied)
        #expect(chat.chatModelPickerReceipt(
            providerID: "LUNA",
            modelID: "gpt-5.6-luna"
        ) == receipt)

        let provider = try chat.activeProvider()
        #expect(provider.model.id == "gpt-5.6-luna")
        #expect(chat.activeProviderEvidenceID == "mock-readiness-evidence")
    }

    @Test("failed Apply is atomic and unsupported provider errors fail closed")
    func failedApplyDoesNotMutateActiveProvider() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = ProviderReadinessStore(directory: directory)
        store.upsert(record(
            providerID: "LUNA",
            modelID: "shared-model",
            status: .passed,
            readinessState: .mock,
            evidenceID: "luna-evidence",
            isApplied: true
        ))
        store.upsert(record(
            providerID: "BROKEN",
            modelID: "shared-model",
            status: .passed,
            readinessState: .mock,
            evidenceID: "broken-evidence",
            isApplied: true
        ))

        let chat = ChatStore(providerReadinessStore: store)
        let luna = providerRecord(name: "LUNA", models: ["shared-model"])
        let broken = providerRecord(
            name: "BROKEN",
            models: ["shared-model"],
            protocolType: .other
        )
        chat.providerRecordsSource = { [luna, broken] }
        #expect(chat.applyChatModel(
            providerID: "LUNA",
            modelID: "shared-model"
        ))
        let priorReceipt = try #require(chat.lastChatModelApplyReceipt)

        #expect(!chat.applyChatModel(
            providerID: "BROKEN",
            modelID: "shared-model"
        ))
        #expect(chat.selectedCustomProvider?.name == "LUNA")
        #expect(chat.selectedModelID == "shared-model")
        #expect(chat.lastChatModelApplyReceipt == priorReceipt)
        #expect(try chat.activeProvider().model.id == "shared-model")
    }

    @Test("cancelled or incomplete Apply has no live receipt or active selection")
    func cancelledApplyFailsClosed() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = ProviderReadinessStore(directory: directory)
        store.upsert(record(
            providerID: "LUNA",
            modelID: "gpt-5.6-luna",
            status: .passed,
            readinessState: .mock,
            evidenceID: "mock-readiness-evidence",
            isApplied: false
        ))
        let chat = ChatStore(providerReadinessStore: store)
        let luna = providerRecord(name: "LUNA", models: ["gpt-5.6-luna"])
        chat.providerRecordsSource = { [luna] }

        #expect(!chat.applyPickedModel(modelID: "gpt-5.6-luna"))
        #expect(chat.selectedProvider == nil)
        #expect(chat.lastChatModelApplyReceipt == nil)
        #expect(chat.chatModelPickerReceipt(
            providerID: "LUNA",
            modelID: "gpt-5.6-luna"
        ) == nil)
    }

    @Test("child model authorization off never resolves credentials")
    func childModelAuthorizationOffSkipsCredentialResolution() async throws {
        let chat = ChatStore()
        var reads = 0
        chat.providerRecordsSource = { reads += 1; return [] }
        let priorReads = reads
        let models = chat.childModelMetadata(settings: .default, parent: nil)
        #expect(reads == priorReads)
        #expect(models.isEmpty)
    }

    @Test("child models exclude unverified entries even when configured")
    func childModelCatalogRejectsUnverifiedEntries() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ProviderReadinessStore(directory: directory)
        store.upsert(record(providerID: "LUNA", modelID: "pending", status: .discovered,
            readinessState: .unverified, evidenceID: nil, isApplied: false))
        let chat = ChatStore(providerReadinessStore: store)
        let configured = providerRecord(name: "LUNA", models: ["pending"])
        chat.providerRecordsSource = { [configured] }
        chat.schedulerCredentialVersionSource = { _ in "fixture-revision" }
        let models = chat.childModelMetadata(settings: AgentSettings(childModelOverridesEnabled: true), parent: nil)
        #expect(models.isEmpty)
    }

    @Test("child selector resolves the actual frozen ready provider identity")
    func childModelReadyIdentityIsResolvedWithoutChangingParentPicker() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ProviderReadinessStore(directory: directory)
        store.upsert(record(providerID: "LUNA", modelID: "ready", status: .passed,
            readinessState: .mock, evidenceID: "child-ready", isApplied: true))
        let chat = ChatStore(providerReadinessStore: store)
        let configured = providerRecord(name: "LUNA", models: ["ready"])
        chat.providerRecordsSource = { [configured] }
        var versionReads = 0
        chat.schedulerCredentialVersionSource = { _ in versionReads += 1; return "fixture-revision" }
        let originalSelection = chat.selectedModelID
        let settings = AgentSettings(childModelOverridesEnabled: true)
        let models = chat.childModelMetadata(settings: settings, parent: nil)
        #expect(versionReads == 0)
        let item = try #require(chat.chatModelPickerItems.first)
        let runtime = ChildModelRuntimeBinding(policy: .init(settings: settings, readyModels: models), construct: { id in
            try await chat.prepareSelectedChildProvider(stableID: id, expectedItem: item)
        })
        let ready = try #require(runtime.policy.readyModels.first)
        let parent = ParentContextSnapshotV1(providerID: "parent", modelID: "parent", configurationFingerprint: "parent")
        let selected = try runtime.policy.resolve(modelID: ready.stableID, thinkingLevel: "high", parent: parent)
        let task = SubAgentTask(id: "child", title: "read", instructions: "read",
            providerID: selected.binding.providerID, modelID: selected.binding.modelID,
            configurationFingerprint: selected.binding.configurationFingerprint,
            reasoningConfiguration: selected.binding.reasoningConfiguration, bindingSource: .explicit)
        try await runtime.prepare(task, inherited: MockProvider.shared)
        let afterFirstPreparation = versionReads
        try await runtime.prepare(task, inherited: MockProvider.shared)
        #expect(versionReads == afterFirstPreparation)
        let provider = try runtime.resolve(task, inherited: MockProvider.shared)
        #expect(provider.name == ready.binding.providerID)
        #expect(provider.model.id == "ready")
        #expect(chat.selectedModelID == originalSelection)
    }

    @Test("thinking-only selection reuses the exact parent fingerprint and provider")
    func thinkingOnlySelectionPreservesParentRuntimeIdentity() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ProviderReadinessStore(directory: directory)
        store.upsert(record(providerID: "LUNA", modelID: "ready", status: .passed,
            readinessState: .mock, evidenceID: "thinking-parent", isApplied: true))
        let chat = ChatStore(providerReadinessStore: store)
        let configured = providerRecord(name: "LUNA", models: ["ready"])
        chat.providerRecordsSource = { [configured] }
        var versionReads = 0
        chat.schedulerCredentialVersionSource = { _ in versionReads += 1; return "fixture" }
        let parent = ParentContextSnapshotV1(providerID: "LUNA", modelID: "ready",
            configurationFingerprint: "actual-parent-runtime-fingerprint", reasoningConfiguration: "medium")
        let settings = AgentSettings(childModelOverridesEnabled: true)
        let models = chat.childModelMetadata(settings: settings, parent: parent)
        let runtime = ChildModelRuntimeBinding(policy: .init(settings: settings, readyModels: models), parentBinding: parent, construct: { id in
            throw ChildModelBindingError.notReady(id)
        })
        let selected = try runtime.policy.resolve(modelID: nil, thinkingLevel: "high", parent: parent)
        let task = SubAgentTask(id: "level", title: "level", instructions: "read",
            providerID: selected.binding.providerID, modelID: selected.binding.modelID,
            configurationFingerprint: selected.binding.configurationFingerprint,
            reasoningConfiguration: selected.binding.reasoningConfiguration, bindingSource: .explicit)
        let provider = OpenAICompatibleProvider(apiKey: "fixture", model: LLMModel(id: "ready", displayName: "Ready", provider: "LUNA"),
            customBaseURL: "https://luna.example.test/v1", providerName: "LUNA")
        try await runtime.prepare(task, inherited: provider)
        let resolved = try runtime.resolve(task, inherited: provider)
        #expect((resolved as? OpenAICompatibleProvider) === provider)
        #expect(selected.binding.configurationFingerprint == parent.configurationFingerprint)
        #expect(selected.binding.modelID == parent.modelID)
        #expect(selected.binding.reasoningConfiguration == "high")
        #expect(versionReads == 0)
    }

    @Test("retry rejects a changed live provider configuration before accepting its child identity")
    func retryFrozenProviderRejectsChangedConfiguration() async throws {
        let model = LLMModel(id: "ready", displayName: "Ready", provider: "LUNA")
        var original = ProviderConfig(label: "LUNA", providerType: .openAI, runtimeProviderID: "LUNA")
        original.customBaseURL = "https://original.example.test/v1"
        let originalFingerprint = try #require(ProviderFactory.shared.configurationFingerprintMetadata(for: original, modelID: model.id))
        let binding = ParentContextSnapshotV1(providerID: "LUNA", modelID: model.id,
            configurationFingerprint: originalFingerprint)
        let ready = ReadyChildModel(stableID: "luna/ready", displayName: "Ready", binding: binding,
            maximumThinkingLevel: .xhigh)
        var changed = original
        changed.customBaseURL = "https://changed.example.test/v1"
        let changedProvider = OpenAICompatibleProvider(apiKey: "fixture", model: model,
            customBaseURL: changed.customBaseURL, providerName: "LUNA")
        changedProvider.runtimeConfigurationMaterial = changed.runtimeConfigurationMaterial
        #expect(providerRuntimeConfigurationFingerprint(changedProvider) != originalFingerprint)
        let runtime = ChildModelRuntimeBinding(policy: .init(settings: AgentSettings(childModelOverridesEnabled: true), readyModels: [ready]),
            construct: { _ in LLMProviderBox(value: changedProvider) })
        let frozenRetry = SubAgentTask(id: "failed-child", title: "retry", instructions: "read",
            providerID: binding.providerID, modelID: binding.modelID,
            configurationFingerprint: binding.configurationFingerprint, bindingSource: .explicit)
            .withExecutionID("retry:frozen-child")
        do {
            try await runtime.prepare(frozenRetry, inherited: MockProvider.shared)
            Issue.record("changed provider configuration must reject the frozen retry")
        } catch let error as ChildModelBindingError {
            #expect(error == .notReady(ready.stableID))
        }
        #expect(runtime.cache.provider(for: ready.stableID) == nil)
        #expect(frozenRetry.configurationFingerprint == originalFingerprint)
    }

    private func providerRecord(name: String, models: [String]) -> EnvVarEntry {
        providerRecord(
            name: name,
            models: models,
            protocolType: .openaiCompatible
        )
    }

    private func providerRecord(
        name: String,
        models: [String],
        protocolType: ProviderWireProtocol
    ) -> EnvVarEntry {
        EnvVarEntry(
            name: name,
            value: "fixture",
            isSecret: true,
            baseURL: "https://\(name.lowercased()).example.test/v1",
            modelNames: models,
            protocolType: protocolType
        )
    }

    private func builtinOpenAIRecord(models: [String]) -> EnvVarEntry {
        EnvVarEntry(
            name: ProviderType.openAI.rawValue,
            value: "fixture-key",
            isSecret: true,
            baseURL: "https://api.openai.com/v1",
            modelNames: models,
            protocolType: .openaiCompatible
        )
    }

    private func record(
        providerID: String,
        modelID: String,
        status: ProviderReadinessPersistenceStatus,
        readinessState: ProviderReadinessState,
        evidenceID: String?,
        isApplied: Bool,
        configurationFingerprint: String? = nil
    ) -> ProviderReadinessPersistenceRecord {
        ProviderReadinessPersistenceRecord(
            providerID: providerID,
            modelID: modelID,
            status: status,
            readinessState: readinessState,
            checkedAt: Date(timeIntervalSince1970: 1_787_200_000),
            evidenceID: evidenceID,
            isApplied: isApplied,
            configurationFingerprint: configurationFingerprint
        )
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("if-07e-chat-picker-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }
}
