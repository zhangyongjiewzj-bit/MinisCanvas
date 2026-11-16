import Testing
import MinisCore
@testable import MinisCanvasApp

@Suite("模型速度档位展示契约")
struct ModelSpeedTierPresentationTests {
    @Test("四档使用稳定 Keyline 图标和中文标签")
    func mapsEveryTierToSemanticIcon() {
        #expect(ModelSpeedTierPresentation(.ultraFast).icon == .activity)
        #expect(ModelSpeedTierPresentation(.fast).icon == .next)
        #expect(ModelSpeedTierPresentation(.balanced).icon == .settings)
        #expect(ModelSpeedTierPresentation(.quality).icon == .target)
        #expect(ModelSpeedTierPresentation(.ultraFast).label == "极快")
        #expect(ModelSpeedTierPresentation(.fast).label == "快")
        #expect(ModelSpeedTierPresentation(.balanced).label == "均衡")
        #expect(ModelSpeedTierPresentation(.quality).label == "质量")
    }

    @Test("辅助标签始终使用用户可读档位名称")
    func accessibilityLabelsUseTierNames() {
        for tier in ModelSpeedTier.allCases {
            #expect(ModelSpeedTierPresentation(tier).accessibilityLabel == tier.displayName)
        }
    }

    @Test("选中与普通状态映射到对应图标状态")
    func selectedAndNormalStatesRemainExplicit() {
        let normal = ModelSpeedTierPresentation(.balanced).iconState(selected: false)
        let selected = ModelSpeedTierPresentation(.balanced).iconState(selected: true)
        let isNormal: Bool
        let isActive: Bool
        switch normal {
        case .normal: isNormal = true
        default: isNormal = false
        }
        switch selected {
        case .active: isActive = true
        default: isActive = false
        }
        #expect(isNormal)
        #expect(isActive)
    }

    @Test("静态 helpers 与实例展示保持一致")
    func staticHelpersUseSameMapping() {
        for tier in ModelSpeedTier.allCases {
            let presentation = ModelSpeedTierPresentation(tier)
            #expect(ModelSpeedTierPresentation.icon(for: tier) == presentation.icon)
            #expect(ModelSpeedTierPresentation.label(for: tier) == presentation.label)
        }
    }
}
