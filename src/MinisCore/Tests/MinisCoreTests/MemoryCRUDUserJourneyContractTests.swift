import Foundation
import Testing
@testable import MinisCore

// D-MEMORY-05（现场缺陷 F04）/ 验收清单 MEMORY-05：
//   「可以新增、编辑和删除长期记忆。」
// MinisCore 侧合同：新增(addFact)/编辑(appendRevision 现行版本链)/删除
// (removeFact) 的用户级 CRUD 旅程作为「一次连续旅程 + 落盘重开恢复」的可执行
// 合同被钉住；被拒绝的编辑必须 fail-closed 且不改写字节。
// 去重边界（C0 派工单 note + wave2/QODER_C0_ACCEPTANCE_SESSION-DELETE-017）：
// MemoryStore facts 在会话删除前后的字节稳定性已由 lane 017 的
// D-SESSION-18 隔离测试钉住，本文件不触碰 SessionStore、不重复该场景；
// 单点持久化/版本链行为亦不重写 MemoryStoreTests 既有断言，
// 只补「端到端旅程 + 重开后各生命周期态」这一段差额。
// 设置中心「编辑」入口（SettingsView/SettingsCenter）在 lane 011 独占写集内，
// 属被阻塞的 settings lane；其应调用的边界即本文件演示的 appendRevision。

/// Unique temp directory per test (tests run in parallel; never share paths).
private func makeTempDir(_ label: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("MinisCore-MemoryCRUD-\(label)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// 用户显式编辑时设置中心应合成的 provenance 三元组（唯一可过
/// `validateVersionedFields` 的形状：三项皆非空且 digest 匹配新文本）。
private func userEditProvenance(for factID: String, newText: String, revision: Int)
    -> (sourceProposalID: String, sourceRef: String, contentDigest: String)
{
    return (
        sourceProposalID: "user-edit:\(factID):r\(revision)",
        sourceRef: "settings://memory/\(factID)/revision-\(revision)",
        contentDigest: MemoryStore.contentDigest(for: newText)
    )
}

struct MemoryCRUDUserJourneyContractTests {

    // MARK: - 新增 → 编辑 → 删除 连续旅程 + 重开恢复

    @Test func userCRUDJourneySurvivesStoreRelaunch() throws {
        let dir = try makeTempDir("journey")
        defer { try? FileManager.default.removeItem(at: dir) }

        // 1) 新增两条长期记忆（用户显式动作，非 proposal）。
        let store = MemoryStore(directory: dir)
        let kept = try store.addFact("用户偏好深色主题", sourceSessionID: "user")
        let doomed = try store.addFact("用户临时喜欢奶茶", sourceSessionID: "user")

        // 2) 编辑：appendRevision 现行版本链（同一 id 边界，非 proposal 消费者）。
        let editedText = "用户偏好深色主题与 14pt 字号"
        let provenance = userEditProvenance(for: kept.id, newText: editedText, revision: 2)
        let edited = try store.appendRevision(
            to: kept.id,
            text: editedText,
            sourceProposalID: provenance.sourceProposalID,
            sourceRef: provenance.sourceRef,
            contentDigest: provenance.contentDigest
        )
        #expect(edited.revision == 2)
        #expect(edited.supersedesFactID == kept.id)

        // 3) 删除第三条（用户在设置中心点删除）。
        try store.removeFact(id: doomed.id)

        // 4) 重开（全新实例 = 模拟 App 重启）后旅程结果必须整体恢复。
        let relaunched = MemoryStore(directory: dir)
        let active = try relaunched.activeFacts()
        #expect(active.map(\.id) == [edited.id])
        #expect(active.first?.text == editedText)
        #expect(active.first?.revision == 2)

        let all = try relaunched.facts()
        #expect(all.count == 2) // 编辑保留历史版本，删除是真删除
        #expect(all.first(where: { $0.id == kept.id })?.lifecycleState == .superseded)
        #expect(all.first(where: { $0.id == doomed.id }) == nil)

        // 检索/注入面只见新值：旧文本与已删文本都不再命中。
        #expect(try relaunched.searchFacts(keyword: "深色").map(\.id) == [edited.id])
        #expect(try relaunched.searchFacts(keyword: "奶茶").isEmpty)
        #expect(try relaunched.searchFacts(keyword: "14pt").map(\.id) == [edited.id])
    }

    @Test func chainedEditsPersistOnlyLatestActiveRevision() throws {
        let dir = try makeTempDir("chain")
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = MemoryStore(directory: dir)
        let v1 = try store.addFact("第一阶段：只用中文回复", sourceSessionID: "user")

        let t2 = "第二阶段：只用中文和日文回复"
        let p2 = userEditProvenance(for: v1.id, newText: t2, revision: 2)
        let v2 = try store.appendRevision(
            to: v1.id, text: t2,
            sourceProposalID: p2.sourceProposalID,
            sourceRef: p2.sourceRef, contentDigest: p2.contentDigest
        )
        let t3 = "第三阶段：只用中文回复并附拼音"
        let p3 = userEditProvenance(for: v2.id, newText: t3, revision: 3)
        let v3 = try store.appendRevision(
            to: v2.id, text: t3,
            sourceProposalID: p3.sourceProposalID,
            sourceRef: p3.sourceRef, contentDigest: p3.contentDigest
        )
        #expect(v3.revision == 3)

        let relaunched = MemoryStore(directory: dir)
        #expect(try relaunched.activeFacts().map(\.id) == [v3.id])
        let all = try relaunched.facts()
        #expect(all.count == 3)
        #expect(Set(all.filter { $0.lifecycleState == .superseded }.map(\.id)) == [v1.id, v2.id])
        #expect(all.map(\.id).count == Set(all.map(\.id)).count)
    }

    // MARK: - 被拒绝的编辑 fail-closed，不改写字节

    @Test func rejectedEditsFailClosedAndLeaveFactsBytesUnchanged() throws {
        let dir = try makeTempDir("reject")
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = MemoryStore(directory: dir)
        let fact = try store.addFact("唯一基线记忆", sourceSessionID: "user")
        let p = userEditProvenance(for: fact.id, newText: "合法新值", revision: 2)
        let edited = try store.appendRevision(
            to: fact.id, text: "合法新值",
            sourceProposalID: p.sourceProposalID,
            sourceRef: p.sourceRef, contentDigest: p.contentDigest
        )
        let bytesBefore = try Data(contentsOf: store.fileURL)

        // (a) digest 与新文本不匹配 → invalidProvenance
        #expect(throws: MemoryStoreError.invalidProvenance) {
            try store.appendRevision(
                to: edited.id, text: "篡改文本",
                sourceProposalID: "user-edit:x",
                sourceRef: "settings://memory/x",
                contentDigest: MemoryStore.contentDigest(for: "另一个文本")
            )
        }
        // (b) 编辑已被 superseded 的旧版本 → invalidRevision
        #expect(throws: MemoryStoreError.invalidRevision) {
            try store.appendRevision(
                to: fact.id, text: "复活旧版本",
                sourceProposalID: "user-edit:y",
                sourceRef: "settings://memory/y",
                contentDigest: MemoryStore.contentDigest(for: "复活旧版本")
            )
        }
        // (c) 编辑不存在的 id → unknownSupersededFact
        #expect(throws: MemoryStoreError.unknownSupersededFact) {
            try store.appendRevision(
                to: "missing-fact-id", text: "幽灵",
                sourceProposalID: "user-edit:z",
                sourceRef: "settings://memory/z",
                contentDigest: MemoryStore.contentDigest(for: "幽灵")
            )
        }
        // (d) 空文本编辑 → emptyFact
        #expect(throws: MemoryStoreError.emptyFact) {
            try store.appendRevision(
                to: edited.id, text: "   ",
                sourceProposalID: "user-edit:w",
                sourceRef: "settings://memory/w",
                contentDigest: MemoryStore.contentDigest(for: "x")
            )
        }
        // (e) 编辑自身指向自己 → invalidRevision（supersedes == factID）
        #expect(throws: MemoryStoreError.invalidRevision) {
            try store.appendRevision(
                to: edited.id, id: edited.id, text: "自我替换",
                sourceProposalID: "user-edit:self",
                sourceRef: "settings://memory/self",
                contentDigest: MemoryStore.contentDigest(for: "自我替换")
            )
        }

        #expect(try Data(contentsOf: store.fileURL) == bytesBefore)
        #expect(try MemoryStore(directory: dir).activeFacts().map(\.id) == [edited.id])
    }

    @Test func deletedFactCannotBeEditedAfterRelaunch() throws {
        let dir = try makeTempDir("delete-edit")
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = MemoryStore(directory: dir)
        let fact = try store.addFact("待删除记忆", sourceSessionID: "user")
        try store.removeFact(id: fact.id)

        let relaunched = MemoryStore(directory: dir)
        #expect(try relaunched.facts().isEmpty)
        let text = "删除后再编辑"
        #expect(throws: MemoryStoreError.unknownSupersededFact) {
            try relaunched.appendRevision(
                to: fact.id, text: text,
                sourceProposalID: "user-edit:after-delete",
                sourceRef: "settings://memory/after-delete",
                contentDigest: MemoryStore.contentDigest(for: text)
            )
        }
        // 删除是持久的：重开不会复活，也不留下可被注入的活跃事实。
        #expect(try MemoryStore(directory: dir).activeFacts().isEmpty)
    }

    @Test func userAddedFactsWithoutProvenanceRemainEditableAndInjectable() throws {
        // 新增入口（无 proposal 来源）与编辑入口（补 provenance）在重启后
        // 必须共存：旧事实解码为 revision-1 active，编辑链不破坏其可读性。
        let dir = try makeTempDir("mixed")
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = MemoryStore(directory: dir)
        let plain = try store.addFact("用户常驻上海", sourceSessionID: "user")
        let newText = "用户常驻杭州"
        let p = userEditProvenance(for: plain.id, newText: newText, revision: 2)
        _ = try store.appendRevision(
            to: plain.id, text: newText,
            sourceProposalID: p.sourceProposalID,
            sourceRef: p.sourceRef, contentDigest: p.contentDigest
        )

        let relaunched = MemoryStore(directory: dir)
        let active = try relaunched.activeFacts()
        #expect(active.count == 1)
        #expect(active.first?.text == newText)
        // 注入面（MemoryInjector 消费 activeFacts）不因编辑链产生重复注入：
        // 新文本可被注入，已被 superseded 的旧文本不再进入 systemPrompt。
        let injector = MemoryInjector(store: relaunched)
        let prompt = try injector.systemPrompt(base: "BASE", userMessage: "用户常驻情况如何？")
        #expect(prompt.contains(newText))
        #expect(!prompt.contains("上海"))
    }
}
