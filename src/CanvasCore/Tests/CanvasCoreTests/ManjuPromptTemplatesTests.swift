import Testing
@testable import CanvasCore

// MARK: - ManjuPromptTemplates 测试

struct ManjuPromptTemplatesTests {

    // MARK: - 槽位名称与顺序

    @Test func imageSlotsEightSlotsInOrder() {
        let names = ManjuPromptTemplates.imageSlots.map(\.name)
        #expect(names == ["TYPE", "REFERENCE", "LAYOUT", "STRUCTURE",
                          "MATERIAL", "COLOR", "LIGHT", "FORBID"],
                "图片提示词应为 8 槽且顺序固定")
        #expect(ManjuPromptTemplates.imageSlots.count == 8)
    }

    @Test func videoSlotsNineSlotsInOrder() {
        let names = ManjuPromptTemplates.videoSlots.map(\.name)
        #expect(names == ["MODE", "REFERENCE MAP", "STYLE LOCK", "SHOT", "ACTION",
                          "COLOR", "SOUND", "FORBID", "QC"],
                "视频提示词应为 9 槽且顺序固定")
        #expect(ManjuPromptTemplates.videoSlots.count == 9)
    }

    // MARK: - 必填

    @Test func allSlotsRequired() {
        let all = ManjuPromptTemplates.imageSlots + ManjuPromptTemplates.videoSlots
        for slot in all {
            #expect(slot.isRequired, "槽位 \(slot.name) 应为必填（铁律7：缺字段 = BLOCKED）")
        }
    }

    // MARK: - QC 检查

    @Test func qcCheckContainsStatusPass() {
        let prompt = ManjuPromptTemplates.qcCheckSystemPrompt
        #expect(prompt.contains("status=PASS"), "QC 系统提示词应允许输出 status=PASS")
        #expect(prompt.contains("skill_check=PASS"), "QC 系统提示词应允许输出 skill_check=PASS")

        // 视频 9 槽的 QC 槽说明同样带 status=PASS
        let qcSlot = ManjuPromptTemplates.videoSlots.first { $0.name == "QC" }
        #expect(qcSlot?.detail.contains("status=PASS") == true)
    }

    // MARK: - 铁律关键词命中 systemPrompt

    @Test func ironRulesPresentInSystemPrompts() {
        let image = ManjuPromptTemplates.imageSystemPrompt
        #expect(image.contains("铁律"), "图片系统提示词应内嵌 manju-core 铁律")
        #expect(image.contains("BLOCKED"), "缺字段 = BLOCKED 语义应在系统提示词中")
        #expect(image.contains("8 槽"), "图片系统提示词应声明 8 槽模板")

        let video = ManjuPromptTemplates.videoSystemPrompt
        #expect(video.contains("铁律"))
        #expect(video.contains("BLOCKED"))
        #expect(video.contains("9 槽"), "视频系统提示词应声明 9 槽模板")
        #expect(video.contains("observed_end_state"), "续接语义（铁律8）应在视频系统提示词中")

        #expect(ManjuPromptTemplates.storyboardSystemPrompt.contains("observed_end_state"))
    }

    // MARK: - 模板注册表

    @Test func templateRegistryCoversAllNodeTypes() {
        for type in ManjuNodeType.allCases {
            #expect(ManjuPromptTemplates.template(for: type) != nil,
                    "节点类型 \(type.rawValue) 应注册模板")
        }
        #expect(ManjuPromptTemplates.allTemplates.count == ManjuNodeType.allCases.count,
                "模板注册表应覆盖全部 11 类节点")
    }
}
