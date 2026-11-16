import Foundation
import Testing
@testable import MinisCanvasApp

@Suite("Validated numeric Settings field")
@MainActor
struct ValidatedNumericSettingFieldTests {
    private func fieldSource() throws -> String {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // MinisCanvasAppTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // MinisCanvasApp
            .deletingLastPathComponent() // src
            .deletingLastPathComponent() // repository
        return try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "src/MinisCanvasApp/Sources/MinisCanvasApp/ValidatedNumericSettingField.swift"
            ),
            encoding: .utf8
        )
    }

    private func settingsSource() throws -> String {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // MinisCanvasAppTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // MinisCanvasApp
            .deletingLastPathComponent() // src
            .deletingLastPathComponent() // repository
        return try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "src/MinisCanvasApp/Sources/MinisCanvasApp/SettingsView.swift"
            ),
            encoding: .utf8
        )
    }

    @Test("editable TextField keeps native AXValue and exposes validation separately")
    func editableTextFieldKeepsNativeAXValue() throws {
        let source = try fieldSource()

        #expect(source.contains(".accessibilityIdentifier(identifier)"))
        #expect(source.contains(".accessibilityLabel(title)"))
        #expect(source.contains(".accessibilityHint("))
        #expect(!source.contains(".accessibilityValue("))
        #expect(source.contains(#".accessibilityIdentifier("\(identifier).error")"#))
    }

    @Test("shared Stepper is present for every canonical Settings consumer")
    func sharedStepperCoversAllSettingsConsumers() throws {
        let source = try fieldSource()
        let settings = try settingsSource()
        let identifiers = [
            "settings.typography.base-font-size.input",
            "settings.agent.max-tokens-per-session",
            "settings.agent.max-loop-iterations",
            "settings.agent.shell-command-timeout",
            "settings.agent.concurrent-tool-limit",
            "settings.agent.child-concurrency.selected",
            // 166-B（D-CHILDA「设置里显式选 N」）：启用并行会话数与每会话 1–40
            // 同级，共用同一共享数字字段。
            "settings.agent.child-concurrency.enabled-sessions",
            "settings.agent.auto-compact-threshold",
            "settings.agent.context-length-tokens",
            "settings.agent.history-turn-limit",
            "settings.agent.policy-runtime.budget",
            "settings.agent.policy-runtime.deadline",
            "settings.storage.session-retention-days",
            "settings.storage.memory-limit",
            "settings.browser.viewport-width",
            "settings.browser.viewport-height",
            "settings.browser.idle-tab-timeout",
        ]

        #expect(source.contains("Stepper("))
        #expect(source.contains("adjustStepper(by: 1)"))
        #expect(source.contains("adjustStepper(by: -1)"))
        #expect(source.contains(".accessibilityIdentifier(\"\\(identifier).stepper\")"))
        #expect(source.contains(".onSubmit { commit() }"))
        #expect(source.contains(".onExitCommand { revert() }"))
        #expect(source.contains("if !focused { commit() }"))
        #expect(source.contains("writeText?(draft)"))
        #expect(source.contains("writeText?(next)"))
        #expect(source.contains("范围 "))
        #expect(identifiers.count == 17)
        for identifier in identifiers {
            #expect(settings.contains("accessibilityIdentifier: \"\(identifier)\""))
        }
        #expect(settings.components(separatedBy: "ValidatedNumericSettingField(").count - 1 == identifiers.count)
    }

    @Test("PolicyRuntime staged ceilings use the shared editable numeric consumer")
    func policyRuntimeCeilingDraftsUseSharedField() throws {
        let settings = try settingsSource()
        #expect(settings.range(
            of: #"ValidatedNumericSettingField\(\s*"预算上限",\s*text:\s*\$policyBudgetDraft"#,
            options: .regularExpression
        ) != nil)
        #expect(settings.range(
            of: #"ValidatedNumericSettingField\(\s*"时限上限（分钟）",\s*text:\s*\$policyDeadlineDraft"#,
            options: .regularExpression
        ) != nil)
        #expect(settings.contains("Button(\"保存运行上限\") { savePolicyRuntimeDefaults() }"))
        #expect(settings.contains("guard center.updatePolicyRuntimeDefaults(value) else"))
    }

    @Test("staged numeric stepper preserves decimal deadlines and integral budget boundaries")
    func stagedNumericStepperBoundaries() {
        #expect(ValidatedNumericSettingField.nonnegativeTextStep("0", by: 1) == "1")
        #expect(ValidatedNumericSettingField.nonnegativeTextStep("0", by: -1) == nil)
        #expect(ValidatedNumericSettingField.nonnegativeTextStep(String(Int.max), by: 1) == nil)
        #expect(ValidatedNumericSettingField.nonnegativeTextStep("1.5", by: 1) == "2.5")
        #expect(ValidatedNumericSettingField.nonnegativeTextStep("1.5", by: -1) == "0.5")
        #expect(ValidatedNumericSettingField.nonnegativeTextStep("-1", by: 1) == nil)
        #expect(ValidatedNumericSettingField.nonnegativeTextStep("nan", by: 1) == nil)
        #expect(ValidatedNumericSettingField.nonnegativeTextStep("1e309", by: 1) == nil)
        #expect(ValidatedNumericSettingField.nonnegativeTextStep("1.5", by: 2) == nil)
    }

    @Test("shared numeric field fills constrained consumer rows without changing semantics")
    func sharedFieldFillsConstrainedRows() throws {
        let source = try fieldSource()

        #expect(source.contains(".frame(maxWidth: .infinity, alignment: .leading)"))
        #expect(source.contains("VStack(alignment: .leading, spacing: 4)"))
        #expect(source.contains("Stepper("))
        #expect(source.contains("guard !isFocused else { return }"))
        #expect(source.contains("validationMessage = nil"))
    }

    @Test("integer input accepts values inside bounds")
    func integerInputAcceptsInRange() {
        #expect(
            ValidatedNumericSettingField.integerValue("6", in: 1...10, step: 5) == 6
        )
        #expect(
            ValidatedNumericSettingField.integerValue("7", in: 1...10, step: 5) == nil
        )
        #expect(
            ValidatedNumericSettingField.integerValue("0", in: 1...10) == nil
        )
        #expect(
            ValidatedNumericSettingField.integerError(for: "oops", in: 1...10) == "请输入整数"
        )
        #expect(
            ValidatedNumericSettingField.integerError(for: "11", in: 1...10)
                == "请输入 1 到 10 的整数"
        )
    }

    @Test("context and history accept zero or positive integer drafts, never negative or overflow")
    func nonnegativeDraftBoundary() {
        #expect(ValidatedNumericSettingField.integerValue("0", in: 0...Int.max) == 0)
        #expect(ValidatedNumericSettingField.integerValue("1", in: 0...Int.max) == 1)
        #expect(ValidatedNumericSettingField.integerValue(String(Int.max), in: 0...Int.max) == Int.max)
        #expect(ValidatedNumericSettingField.integerValue("-1", in: 0...Int.max) == nil)
        #expect(ValidatedNumericSettingField.integerValue("not-a-number", in: 0...Int.max) == nil)
        #expect(ValidatedNumericSettingField.integerValue("\(Int.max)0", in: 0...Int.max) == nil)
    }

    @Test("double input accepts decimal values inside bounds")
    func doubleInputAcceptsInRange() {
        #expect(
            ValidatedNumericSettingField.doubleValue("0.75", in: 0.5...1.0, step: 0.05) == 0.75
        )
        #expect(
            ValidatedNumericSettingField.doubleValue("0.72", in: 0.5...1.0, step: 0.05) == nil
        )
        #expect(
            ValidatedNumericSettingField.doubleValue("1.5", in: 0.5...1.0) == nil
        )
        #expect(
            ValidatedNumericSettingField.doubleError(for: "oops", in: 0.5...1.0) == "请输入数字"
        )
        #expect(
            ValidatedNumericSettingField.doubleError(for: "1.5", in: 0.5...1.0)
                == "请输入 0.5 到 1.0 的数字"
        )
    }

    @Test("Stepper deltas preserve integer and double canonical steps")
    func stepperDeltaRulesRemainAlignedWithValidation() throws {
        let source = try fieldSource()

        #expect(source.contains("current.addingReportingOverflow(direction * step)"))
        #expect(source.contains("let candidate = current + Double(direction) * step"))
        #expect(source.contains("current.addingReportingOverflow(direction)"))
        #expect(source.contains("guard range.contains(candidate) else { return nil }"))
        #expect(source.contains("guard candidate >= 0 else { return nil }"))
    }
}
