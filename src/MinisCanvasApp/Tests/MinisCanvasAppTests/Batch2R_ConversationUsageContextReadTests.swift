import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

// 第二批线 R-1：对话内只读“用量与上下文占用”（RED）。对照 CC get_usage。
//
// 接口约定（不新增工具，沿用 settings_catalog 的 values/entries）：
//   usage.session.total-tokens   integer  当前会话全部调用 token（含缓存口径，= 设置页“会话 token（含子智能体）”）
//   usage.session.call-count     integer  当前会话关联的调用次数
//   usage.session.estimated-cost text     = UsageModelPricing.display(records:prices:)（设置页“估算费用”同源）
//   context.reported             toggle   最近一次模型是否已报告上下文占用（未报告时下面三项不出现）
//   context.used-tokens          integer  = ChatStore.contextOccupancy.inputTokens
//   context.window-tokens        integer  = ChatStore.contextOccupancy.windowTokens
//   context.percent              text     = ChatStore.contextOccupancy.percentage（如 "32%"）
//   以上全部 entries.agentMutable == false。
// 审批口径（事实）：settings_catalog 在 ApprovalGate.defaultPolicies 里是 .alwaysAsk（低风险卡），
// 现有 ConversationSettingsProvider2094Tests 也断言每次读取都有一条 catalogToolName 请求。
// 因此“只读项不弹卡”在此落成：读用量/上下文不产生任何 conversation_settings 写卡，
// 且整轮只有读目录本身那一张卡（不因 usage.*/context.* 额外加卡）。
// 若要把目录读取也改成零卡，是另一个策略决定（会改 2094 的既有断言），本线不做。
//
// 最小改动点：ConversationSettingsToolExecutor.swift 目录读分支（约 :146–:263）在 values/entries 后追加上述键，
// 数据来自 UsageFilteredSettingsView.sessionRecords + UsageModelPricing.display（UsageFilteredSettingsView.swift:409/:447）
// 与 chat.contextOccupancy（ChatStore.swift:3177）。

@Suite("Batch2R conversation usage and context read", .serialized)
@MainActor
struct Batch2R_ConversationUsageContextReadTests {
    private let provider = "batch2r-offline"
    private let model = "batch2r-model"

    @Test("catalog reports this session's token usage and estimated cost exactly as the Settings usage page computes them")
    func catalogReportsSessionUsage() async throws {
        let fx = try await Batch2RFixture.make()
        defer { fx.cleanup() }
        let store = fx.center.usageStore
        let sid = fx.sessionID.uuidString
        store.recordCall(provider: provider, model: model, inputTokens: 1000, outputTokens: 200, sessionID: sid)
        store.recordCall(provider: provider, model: model, inputTokens: 500, outputTokens: 100, sessionID: sid)
        store.recordCall(provider: provider, model: model, inputTokens: 9999, outputTokens: 1,
                         sessionID: UUID().uuidString)
        store.setModelPricing(
            UsageModelPricing(currency: "USD", inputPerMillion: 3, outputPerMillion: 15,
                              cacheReadPerMillion: 0.3, cacheWritePerMillion: 3.75),
            for: UsageStore.key(provider: provider, model: model))
        #expect(await store.waitForPersistence())

        let records = UsageFilteredSettingsView.sessionRecords(from: store, sessionID: sid)
        #expect(records.count == 2)
        let expectedTokens = records.reduce(0) { $0 + $1.totalTokensIncludingCache }
        #expect(expectedTokens == 1800)
        let expectedCost = UsageModelPricing.display(records: records, prices: store.modelPricing)
        #expect(expectedCost.contains("USD"))

        let catalog = try await fx.readCatalog()
        #expect(catalog.values["usage.session.total-tokens"] == .integer(expectedTokens))
        #expect(catalog.values["usage.session.call-count"] == .integer(2))
        #expect(catalog.values["usage.session.estimated-cost"] == .text(expectedCost))
        let ids = catalog.entryIDs(prefix: "usage.")
        #expect(ids.count >= 3)
        for id in ids { #expect(catalog.isAgentMutable(id) == false, "\(id) 必须只读") }
    }

    @Test("reading usage and context raises no settings write card, only the one catalog read card")
    func readingUsageAddsNoWriteCard() async throws {
        let fx = try await Batch2RFixture.make()
        defer { fx.cleanup() }
        fx.center.usageStore.recordCall(provider: provider, model: model, inputTokens: 10,
                                        outputTokens: 5, sessionID: fx.sessionID.uuidString)
        #expect(await fx.center.usageStore.waitForPersistence())

        let catalog = try await fx.readCatalog()
        #expect(catalog.values["usage.session.total-tokens"] != nil)
        #expect(await fx.approval.settingsRequests.isEmpty)
        #expect(await fx.approval.catalogReadRequests.count == 1)
    }

    @Test("catalog reports the context occupancy the model last reported, same numbers as the context panel")
    func catalogReportsContextOccupancy() async throws {
        let fx = try await Batch2RFixture.make()
        defer { fx.cleanup() }
        // 一轮纯文本回复并附带用量，走生产的上下文占用记录路径（窗口 200_000 由假模型声明）。
        let usage = LLMUsage(inputTokens: 64_000, outputTokens: 500, cacheCreationInputTokens: 0,
                             cacheReadInputTokens: 0, cacheHitInputTokens: 64_000)
        _ = try await fx.run(tool: nil, input: [:], usage: usage)
        let occupancy = try #require(fx.chat.contextOccupancy)
        #expect(occupancy.inputTokens == 64_000)
        #expect(occupancy.windowTokens == 200_000)

        let catalog = try await fx.readCatalog()
        #expect(catalog.values["context.reported"] == .toggle(true))
        #expect(catalog.values["context.used-tokens"] == .integer(occupancy.inputTokens))
        #expect(catalog.values["context.window-tokens"] == .integer(occupancy.windowTokens))
        #expect(catalog.values["context.percent"] == .text(occupancy.percentage))
        for id in catalog.entryIDs(prefix: "context.") {
            #expect(catalog.isAgentMutable(id) == false, "\(id) 必须只读")
        }
    }

    @Test("before any usage report the catalog says context is unreported instead of inventing numbers")
    func catalogContextUnreportedWhenNoReport() async throws {
        let fx = try await Batch2RFixture.make()
        defer { fx.cleanup() }
        // 2026-11-16：首个用量回报前显示带“约”的本地估算，同时仍明确标注“未回报”。
        let catalog = try await fx.readCatalog()
        #expect(catalog.values["context.reported"] == .toggle(false))
        if case .text(let percent)? = catalog.values["context.percent"] {
            #expect(percent.hasPrefix("约"), "估算值必须带“约”，不能冒充模型回报")
        } else {
            #expect(catalog.values["context.used-tokens"] == nil)
            #expect(catalog.values["context.window-tokens"] == nil)
        }
    }

    @Test("a model cannot write a usage or context row; usage records stay unchanged")
    func usageRowsAreReadOnly() async throws {
        let fx = try await Batch2RFixture.make()
        defer { fx.cleanup() }
        fx.center.usageStore.recordCall(provider: provider, model: model, inputTokens: 10,
                                        outputTokens: 5, sessionID: fx.sessionID.uuidString)
        #expect(await fx.center.usageStore.waitForPersistence())
        let before = fx.center.usageStore.callHistory
        let revision = try fx.ordinaryCatalogRevision()

        let attempt = try await fx.write(
            ["usage.session.total-tokens": Batch2RFixture.integer(0)], revision: revision)
        #expect(attempt.toolFailed)
        #expect(fx.center.usageStore.callHistory == before)
    }
}
