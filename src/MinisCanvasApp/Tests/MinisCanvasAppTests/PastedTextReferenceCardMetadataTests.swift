import Testing
import Foundation
@testable import MinisCanvasApp

// MARK: - D-COMPOSER-10 / F17 长粘贴资料卡元数据合同
//
// 验收锚点：清单 L199 `COMPOSER-10`（胶囊化、不失控膨胀）与 L208 `COMPOSER-19`
// （发送后资料卡保留字符数、行数、预览、完整查看）。F17 现场缺陷是"引用卡
// metadata 跨重启丢失"；候选源码已在解码时从持久化 material 重建派生字段
// （PastedTextReferenceCard.init(from:)）。本组测试把该重建合同锁在源码层：
// 过期/伪造/缺失的派生字段 JSON 都不能改变重启后的卡片事实。

@Suite("Pasted reference card metadata rebuild on decode (F17)")
struct PastedTextReferenceCardMetadataTests {

    private let material = "第一行\n" + String(repeating: "资料", count: 3_000) + "\n尾行"
    private let sessionID = UUID()

    private func roundTripJSON(of card: PastedTextReferenceCard) throws -> [String: Any] {
        let data = try JSONEncoder().encode(card)
        return try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
    }

    @Test("derived fields are not trusted from the persisted payload")
    func encodeOmitsDerivedFields() throws {
        let card = PastedTextReferenceCard(
            id: UUID(), sessionID: sessionID, instruction: "解释材料", material: material
        )
        let json = try roundTripJSON(of: card)
        // 派生展示字段（preview/characterCount/lineCount）不落盘：
        // 重启后唯一事实源是 material，过期计数没有生存空间。
        #expect(json["preview"] == nil)
        #expect(json["characterCount"] == nil)
        #expect(json["lineCount"] == nil)
        #expect(json["material"] != nil)
    }

    @Test("stale derived keys in hand-edited JSON cannot change a restored card")
    func staleDerivedKeysAreRebuiltFromMaterial() throws {
        let card = PastedTextReferenceCard(
            id: UUID(), sessionID: sessionID, instruction: "解释材料", material: material
        )
        var json = try roundTripJSON(of: card)
        json["preview"] = "伪造预览"
        json["characterCount"] = 7
        json["lineCount"] = 99
        let tamperedData = try JSONSerialization.data(withJSONObject: json)

        let restored = try JSONDecoder().decode(PastedTextReferenceCard.self, from: tamperedData)
        #expect(restored.material == material)
        #expect(restored.characterCount == material.unicodeScalars.count)
        #expect(restored.lineCount == 3)
        #expect(restored.preview ==
                String(String.UnicodeScalarView(material.unicodeScalars.prefix(PastedTextReferenceCard.previewScalarLimit))))
        #expect(restored.preview != "伪造预览")
    }

    @Test("legacy payloads without kind/instruction still rebuild counts and defaults")
    func legacyPayloadRebuild() throws {
        let card = PastedTextReferenceCard(
            id: UUID(), sessionID: sessionID, material: material
        )
        var json = try roundTripJSON(of: card)
        json.removeValue(forKey: "kind")
        json.removeValue(forKey: "instruction")
        let legacyData = try JSONSerialization.data(withJSONObject: json)

        let restored = try JSONDecoder().decode(PastedTextReferenceCard.self, from: legacyData)
        #expect(restored.kind == .reference)
        #expect(restored.instruction.isEmpty)
        #expect(restored.characterCount == material.unicodeScalars.count)
        #expect(restored.isExpanded == false)
        // 收起态渲染只走 bounded preview，转录不失控膨胀（COMPOSER-10）。
        #expect(restored.renderedMaterial == restored.preview)
        #expect(restored.renderedMaterial.unicodeScalars.count
                <= PastedTextReferenceCard.previewScalarLimit)
    }

    @Test("collapse policy separates pasteboard paste from typing")
    func capsuleVersusTypingSemantics() {
        let longPaste = String(repeating: "长", count: PastedTextPolicy.scalarThreshold + 1)
        #expect(PastedTextPolicy.shouldCollapse(longPaste, source: .pasteboard))
        // 手输同样长度不折叠：胶囊只属于粘贴通道。
        #expect(!PastedTextPolicy.shouldCollapse(longPaste, source: .typing))
        let shortPaste = String(repeating: "长", count: 10)
        #expect(!PastedTextPolicy.shouldCollapse(shortPaste, source: .pasteboard))
        // 参考材料的斜杠/指令入口不参与命令分类（COMPOSER-18 分离合同，
        // 仅回归本 lane 的粘贴投影，不改意图路由实现）。
        let draft = PastedTextDraft(id: UUID(), text: longPaste, source: .pasteboard, kind: .reference)
        #expect(PastedTextPolicy.commandInput(body: "总结", pastedText: draft) == "总结")
        #expect(PastedTextPolicy.commandInput(body: "", pastedText: draft).isEmpty)
    }
}
