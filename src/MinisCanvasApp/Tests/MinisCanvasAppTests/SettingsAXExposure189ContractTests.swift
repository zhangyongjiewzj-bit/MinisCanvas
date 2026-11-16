import Foundation
import Testing

/// lane QODER-DEV-W14-SET01-AX-EXPOSURE-189（QA 行028 两条 AX 断言 / 043-residual）。
///
/// 运行时原生 AX 验收由 SettingsNativeInteractionConsumerTests 的既有通道负责
/// （本文件不复制点击链，也不得被当作该需求行的 PASS —— PASS 只能来自 PKG
/// 重测同一通道）。这里只钉住「产品侧曝光配方」这一源码合同，防止回归：两个
/// 破坏性动作入口的 accessibilityIdentifier 必须与 lane 161 / TaskCenter 已确立
/// 的单一元素配方（accessibilityElement(children:.ignore) + isButton trait）
/// 一起声明。配方缺失时的失败形态即 R21 raw :42/:56 的 local-visit +
/// public-channel 双 MISS（settings.reset.defaults / settings.logs.clear
/// hit=false）。
@Suite("Settings destructive-action AX exposure contract (lane 189)")
struct SettingsAXExposure189ContractTests {
    private func settingsSource() throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: root.appendingPathComponent(
                "src/MinisCanvasApp/Sources/MinisCanvasApp/SettingsView.swift"
            ),
            encoding: .utf8
        )
    }

    private func recipeBlock(label: String, identifier: String) -> String {
        [
            "                .accessibilityLabel(\"\(label)\")",
            "                .accessibilityElement(children: .ignore)",
            "                .accessibilityAddTraits(.isButton)",
            "                .accessibilityIdentifier(\"\(identifier)\")",
        ].joined(separator: "\n")
    }

    @Test("reset-defaults trigger declares the single-element AX button recipe")
    func resetDefaultsTriggerCarriesExposureRecipe() throws {
        let source = try settingsSource()
        #expect(
            source.contains(
                recipeBlock(label: "恢复全部默认设置", identifier: "settings.reset.defaults")
            )
        )
    }

    @Test("logs clear action declares the single-element AX button recipe")
    func logsClearActionCarriesExposureRecipe() throws {
        let source = try settingsSource()
        #expect(
            source.contains(
                recipeBlock(label: "清空", identifier: "settings.logs.clear")
            )
        )
    }
}
