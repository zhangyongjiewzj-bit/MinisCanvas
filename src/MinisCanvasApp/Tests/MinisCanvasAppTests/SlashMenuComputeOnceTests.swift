import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

@Suite("斜杠菜单只在斜杠草稿时计算且结果稳定")
@MainActor
struct SlashMenuComputeOnceTests {
    private final class Counter { var registry = 0; var session = 0; var context = 0; var canvas = 0 }

    private func entries(
        for draft: String,
        dismissed: String? = nil,
        counter: Counter,
        reasons: [String: String] = [:]
    ) -> [ComposerSlashMenuEntry] {
        GlobalComposer.slashMenuEntries(
            for: draft,
            dismissedContextKey: dismissed,
            contextKey: { counter.context += 1; return "ctx\u{001F}\(draft)" },
            registry: { counter.registry += 1; return SlashRegistryExpectations.routedComposerRegistry() },
            sessionState: {
                counter.session += 1
                return ComposerSlashSessionState(unavailableReasonsByCommandID: reasons)
            },
            canvasAvailable: { counter.canvas += 1; return false }
        )
    }

    @Test("非斜杠开头的草稿不触发任何延迟输入（含就绪原因）")
    func nonSlashDraftEvaluatesNothing() {
        for draft in ["", "  ", "hello", "说明 /compact", "a/"] {
            let counter = Counter()
            let result = entries(for: draft, counter: counter)
            #expect(result.isEmpty)
            #expect(counter.registry == 0 && counter.session == 0
                    && counter.context == 0 && counter.canvas == 0)
        }
    }

    @Test("斜杠草稿每个延迟输入只求值一次")
    func slashDraftEvaluatesEachInputOnce() {
        let counter = Counter()
        _ = entries(for: "/", counter: counter)
        #expect(counter.registry == 1 && counter.session == 1
                && counter.context == 1 && counter.canvas == 1)
    }

    @Test("同一草稿多次取条目结果一致")
    func repeatedEvaluationIsStable() {
        let counter = Counter()
        let first = entries(for: "/", counter: counter)
        let second = entries(for: "/", counter: counter)
        #expect(!first.isEmpty)
        #expect(first.map(\.id) == second.map(\.id))
        #expect(first.map(\.state) == second.map(\.state))
    }

    @Test("条目与纯函数 visibleSlashEntries 一致，含禁用原因")
    func matchesPureProjection() {
        let registry = SlashRegistryExpectations.routedComposerRegistry()
        let blockedID = SlashRegistryExpectations.canonicalComposerIDs().first
        let reasons = blockedID.map { [$0: "测试阻断原因"] } ?? [:]
        let state = ComposerSlashSessionState(unavailableReasonsByCommandID: reasons)
        for draft in ["/", "/c"] {
            let viaGate = entries(for: draft, counter: Counter(), reasons: reasons)
            let direct = GlobalComposer.visibleSlashEntries(
                for: draft, registry: registry, sessionState: state, canvasAvailable: false
            )
            #expect(viaGate.map(\.id) == direct.map(\.id))
            #expect(viaGate.map(\.state) == direct.map(\.state))
        }
    }

    @Test("已关闭的上下文键返回空且不求值就绪状态")
    func dismissedContextSkipsProjection() {
        let counter = Counter()
        let result = entries(for: "/", dismissed: "ctx\u{001F}/", counter: counter)
        #expect(result.isEmpty)
        #expect(counter.session == 0 && counter.registry == 0)
    }
}
