import Foundation
import Testing
@testable import MinisCore

@Suite("D-COMMAND-07 Composer argument validation")
struct P3AcceptanceM05CommandArgumentValidationTests {
    private let parser = CommandParser()

    private func registry() -> CommandRegistry {
        let registry = CommandRegistry()
        registry.registerComposerCommands()
        return registry
    }

    @Test func requiredArgumentsFailBeforeARequestCanBecomePending() {
        let registry = registry()
        for (id, argument) in [
            ("boundary.set", "profile"),
            ("provider.use", "provider_model"),
            ("memory.propose", "text"),
            ("workflow", "template"),
        ] {
            let parsed = parser.parse("/\(id)", registry: registry)
            switch registry.validatedComposerPendingRequest(for: parsed) {
            case .failure(let error):
                #expect(error == .missingArgument(commandID: id, argument: argument))
            case .success:
                Issue.record("/\(id) 缺少必填参数却形成 pending request")
            }
        }
    }

    @Test func invalidChoiceFailsAndLocalizedChoiceNormalizes() throws {
        let registry = registry()
        let invalid = parser.parse("/canvas.minimap mode=sideways", registry: registry)
        switch registry.validatedComposerPendingRequest(for: invalid) {
        case .failure(.invalidArgument(let commandID, let argument, let reason)):
            #expect(commandID == "canvas.minimap")
            #expect(argument == "mode")
            #expect(reason.contains("on"))
            #expect(reason.contains("off"))
        case .failure(let error):
            Issue.record("错误类别不符：\(error.errorDescription)")
        case .success:
            Issue.record("非法 mode 却形成 pending request")
        }

        let localized = parser.parse("/canvas.minimap mode=开启", registry: registry)
        let pending = try registry.validatedComposerPendingRequest(for: localized).get()
        #expect(pending.commandID == "canvas.minimap")
        #expect(pending.args["mode"] == "on")
    }

    @Test func workflowArgumentsReachApprovalWithoutLosingRunnerInputText() throws {
        let registry = registry()
        for (input, expected) in [
            ("/workflow 小说拆解 novel=长 文本", "novel=长 文本"),
            ("/workflow 小说拆解 novel=\"第一 章：主角=路人\" style=轻松",
             "novel=\"第一 章：主角=路人\" style=轻松"),
            ("/workflow 小说拆解 novel=甲\nnovel=乙", "novel=甲\nnovel=乙"),
            ("/ workflow 小说拆解 novel=甲\nnovel=乙", "novel=甲\nnovel=乙"),
            ("/workflow template=小说拆解 args=novel=合成文本", "novel=合成文本"),
        ] {
            let parsed = parser.parse(input, registry: registry)
            let pending = try registry.validatedComposerPendingRequest(for: parsed).get()
            #expect(pending.commandID == "workflow")
            #expect(pending.args["template"] == "小说拆解")
            #expect(pending.args["args"] == expected)
        }

        let missingTemplate = parser.parse("/workflow novel=合成文本", registry: registry)
        switch registry.validatedComposerPendingRequest(for: missingTemplate) {
        case .failure(.missingArgument(let commandID, let argument)):
            #expect(commandID == "workflow" && argument == "template")
        default:
            Issue.record("仅有输入参数时不得形成工作流审批卡")
        }
    }
}
