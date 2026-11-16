import Foundation
import SwiftUI

struct UsageModelPricing: Codable, Equatable, Sendable {
    let currency: String
    let inputPerMillion: Double
    let outputPerMillion: Double
    let cacheReadPerMillion: Double
    let cacheWritePerMillion: Double

    var isValid: Bool {
        currency.count == 3 && currency.unicodeScalars.allSatisfy { (65...90).contains($0.value) }
            && [inputPerMillion, outputPerMillion, cacheReadPerMillion, cacheWritePerMillion]
                .allSatisfy { $0.isFinite && $0 >= 0 }
    }

    func estimate(_ record: UsageRecord) -> Double? {
        guard isValid, let fullInput = record.cacheHitInputTokens,
              let read = record.cacheReadTokens, let write = record.cacheCreationTokens,
              fullInput >= 0, read >= 0, write >= 0 else { return nil }
        let (cached, overflow) = read.addingReportingOverflow(write)
        guard !overflow, cached <= fullInput else { return nil }
        let cost = (Double(fullInput - cached) * inputPerMillion
            + Double(record.outputTokens) * outputPerMillion
            + Double(read) * cacheReadPerMillion + Double(write) * cacheWritePerMillion) / 1_000_000
        return cost.isFinite ? cost : nil
    }

    static func canPrice(provider: String, model: String) -> Bool {
        !["未确认路由", "子智能体"].contains(provider)
            && !["未确认模型", "服务路由未确认"].contains(model)
            && !provider.isEmpty && !model.isEmpty
    }

    static func display(records: [UsageRecord], prices: [String: UsageModelPricing]) -> String {
        guard !records.isEmpty else { return "未配置单价" }
        var totals: [String: Double] = [:]
        var unknown = 0
        for record in records {
            let key = UsageStore.key(provider: record.provider, model: record.model, providerRecordID: record.providerRecordID)
            guard canPrice(provider: record.provider, model: record.model),
                  let price = prices[key], let cost = price.estimate(record),
                  ((totals[price.currency] ?? 0) + cost).isFinite else {
                unknown += 1
                continue
            }
            totals[price.currency, default: 0] += cost
        }
        var parts = totals.keys.sorted().map { $0 + " " + String(format: "%.6f", totals[$0] ?? 0) }
        if unknown > 0 { parts.append("\(unknown) 次无法估算（未配置单价、路由未确认或用量字段不足）") }
        return parts.joined(separator: " · ")
    }
}

struct UsageModelPricingEditor: View {
    let usageStore: UsageStore
    let key: String
    let title: String
    @State private var currency = ""
    @State private var input = ""
    @State private var output = ""
    @State private var cacheRead = ""
    @State private var cacheWrite = ""

    private var candidate: UsageModelPricing? {
        guard let i = Double(input), let o = Double(output), let r = Double(cacheRead), let w = Double(cacheWrite) else { return nil }
        let value = UsageModelPricing(currency: currency.trimmingCharacters(in: .whitespacesAndNewlines).uppercased(),
            inputPerMillion: i, outputPerMillion: o, cacheReadPerMillion: r, cacheWritePerMillion: w)
        return value.isValid ? value : nil
    }

    var body: some View {
        DisclosureGroup(title) {
            VStack(alignment: .leading, spacing: 8) {
                TextField("币种代码（如 USD 或 CNY）", text: $currency)
                TextField("输入单价 / 百万 token", text: $input)
                TextField("输出单价 / 百万 token", text: $output)
                TextField("缓存读取单价 / 百万 token", text: $cacheRead)
                TextField("缓存写入单价 / 百万 token", text: $cacheWrite)
                HStack {
                    Button("保存单价") { if let candidate { usageStore.setModelPricing(candidate, for: key) } }
                        .disabled(candidate == nil)
                    Button("移除单价") {
                        usageStore.setModelPricing(nil, for: key)
                        currency = ""; input = ""; output = ""; cacheRead = ""; cacheWrite = ""
                    }.disabled(usageStore.modelPricing[key] == nil)
                }
            }.textFieldStyle(.roundedBorder)
        }
        .onAppear {
            guard let value = usageStore.modelPricing[key] else { return }
            currency = value.currency; input = String(value.inputPerMillion); output = String(value.outputPerMillion)
            cacheRead = String(value.cacheReadPerMillion); cacheWrite = String(value.cacheWritePerMillion)
        }
    }
}
