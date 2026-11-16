import AppKit
import SwiftUI

/// Shared validated numeric input for Settings values.
///
/// The control owns only transient draft text. The supplied commit closure is
/// the single write boundary, so invalid text never reaches SettingsCenter.
struct ValidatedNumericSettingField: View {
    @Environment(\.themeTokens) private var theme

    /// Shared by the actual validation caption and nonnative consumer regression.
    /// Keep the danger semantic role but resolve this caption as readable text,
    /// rather than using the unadjusted native graphical red.
    static func validationErrorColor(theme: ThemeTokenProvider?) -> Color {
        guard let theme else { return .red }
        return theme.readableStatusText(theme.tokens.statusDanger).swiftUIColor
    }

    private let title: String
    private let identifier: String
    private let boundsDescription: String
    private let readText: () -> String
    private let commitText: (String) -> String?
    private let writeText: ((String) -> Void)?
    private let stepperAdjustment: (String, Int) -> String?
    private let resetToken: Int
    private let externalFocus: FocusState<Bool>.Binding?

    @State private var draft = ""
    @State private var validationMessage: String?
    @State private var editingControlID: ObjectIdentifier?
    @FocusState private var localFocus: Bool

    init(
        _ title: String,
        value: Binding<Int>,
        in range: ClosedRange<Int>,
        step: Int = 1,
        accessibilityIdentifier: String,
        resetToken: Int = 0,
        unit: String? = nil
    ) {
        self.init(
            title,
            identifier: accessibilityIdentifier,
            boundsDescription: "\(range.lowerBound)...\(range.upperBound)，步长 \(step)",
            readText: { String(value.wrappedValue) },
            writeText: nil,
            commitText: { raw in
                guard let parsed = Self.integerValue(raw, in: range, step: step) else {
                    return Self.integerError(for: raw, in: range, step: step)
                }
                value.wrappedValue = parsed
                return nil
            },
            stepperAdjustment: { raw, direction in
                guard let current = Self.integerValue(raw, in: range, step: step) else { return nil }
                let (candidate, overflow) = current.addingReportingOverflow(direction * step)
                guard !overflow else { return nil }
                guard range.contains(candidate) else { return nil }
                return String(candidate)
            },
            resetToken: resetToken,
            unit: unit
        )
    }

    init(
        _ title: String,
        value: Binding<Double>,
        in range: ClosedRange<Double>,
        step: Double = 1,
        accessibilityIdentifier: String,
        unit: String? = nil,
        externalFocus: FocusState<Bool>.Binding? = nil
    ) {
        self.init(
            title,
            identifier: accessibilityIdentifier,
            boundsDescription: "\(range.lowerBound)...\(range.upperBound)，步长 \(step)",
            readText: { String(value.wrappedValue) },
            writeText: nil,
            commitText: { raw in
                guard let parsed = Self.doubleValue(raw, in: range, step: step) else {
                    return Self.doubleError(for: raw, in: range, step: step)
                }
                value.wrappedValue = parsed
                return nil
            },
            stepperAdjustment: { raw, direction in
                guard let current = Self.doubleValue(raw, in: range, step: step) else { return nil }
                let candidate = current + Double(direction) * step
                guard range.contains(candidate) else { return nil }
                return String(candidate)
            },
            resetToken: 0,
            unit: unit,
            externalFocus: externalFocus
        )
    }

    init(
        _ title: String,
        text: Binding<String>,
        accessibilityIdentifier: String,
        boundsDescription: String,
        commit: @escaping (String) -> String?
    ) {
        self.init(
            title,
            identifier: accessibilityIdentifier,
            boundsDescription: boundsDescription,
            readText: { text.wrappedValue },
            writeText: { text.wrappedValue = $0 },
            commitText: commit,
            stepperAdjustment: Self.nonnegativeTextStep,
            resetToken: 0,
            unit: nil
        )
    }

    private init(
        _ title: String,
        identifier: String,
        boundsDescription: String,
        readText: @escaping () -> String,
        writeText: ((String) -> Void)?,
        commitText: @escaping (String) -> String?,
        stepperAdjustment: @escaping (String, Int) -> String?,
        resetToken: Int,
        unit: String?,
        externalFocus: FocusState<Bool>.Binding? = nil
    ) {
        self.title = title
        self.identifier = identifier
        self.boundsDescription = unit.map { "\(boundsDescription) \($0)" } ?? boundsDescription
        self.readText = readText
        self.writeText = writeText
        self.commitText = commitText
        self.stepperAdjustment = stepperAdjustment
        self.resetToken = resetToken
        self.externalFocus = externalFocus
    }

    private var isFocused: Bool { externalFocus?.wrappedValue ?? localFocus }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField(title, text: $draft)
                .textFieldStyle(.roundedBorder)
                .focused(externalFocus ?? $localFocus)
                .accessibilityIdentifier(identifier)
                .accessibilityLabel(title)
                .accessibilityHint("范围 \(boundsDescription)；按 Enter 或离开后提交，按 Esc 恢复")
                .onSubmit { commit() }
                .onExitCommand { revert() }
                .onChange(of: isFocused) { _, focused in
                    if !focused { commit() }
                }
                .onReceive(
                    NotificationCenter.default.publisher(
                        for: NSControl.textDidBeginEditingNotification
                    )
                ) { notification in
                    guard let control = notification.object as? NSTextField,
                          control.accessibilityIdentifier() == identifier
                            || control.placeholderString == title else { return }
                    editingControlID = ObjectIdentifier(control)
                }
                .onReceive(
                    NotificationCenter.default.publisher(
                        for: NSControl.textDidEndEditingNotification
                    )
                ) { notification in
                    guard let control = notification.object as? NSControl,
                          editingControlID == ObjectIdentifier(control) else { return }
                    editingControlID = nil
                    // AppKit can end an NSTextField's field-editor session on
                    // Tab before SwiftUI propagates the matching FocusState
                    // change. Only this field's editor may trigger the fallback.
                    // The normal FocusState callback remains idempotent.
                    commit()
                }
                .onAppear {
                    draft = readText()
                }
                .onDisappear {
                    // A Settings page switch can remove its only text field
                    // before native focus or editing-end callbacks arrive.
                    commit()
                }

            Stepper(
                "微调",
                onIncrement: { adjustStepper(by: 1) },
                onDecrement: { adjustStepper(by: -1) }
            )
            .labelsHidden()
            .accessibilityIdentifier("\(identifier).stepper")
            .accessibilityLabel("\(title)微调")
            .accessibilityHint("按设置步长调整；输入框仍支持粘贴、Enter 或失焦提交")

            if let validationMessage {
                Text(validationMessage)
                    .font(.caption)
                    .foregroundStyle(Self.validationErrorColor(theme: theme))
                    .accessibilityIdentifier("\(identifier).error")
            }
        }
        // Keep paired custom viewport fields usable when their HStack is width-constrained.
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("\(identifier).container")
        .onChange(of: resetToken) { _, _ in
            // An explicit reset discards a draft even when the durable value
            // was already at its default, so readText() itself did not change.
            validationMessage = nil
            draft = readText()
        }
        .onChange(of: readText()) { _, newValue in
            guard !isFocused else { return }
            guard newValue != draft || validationMessage != nil else { return }
            // A successful persistence/reopen can change the bound value while
            // this field remains mounted. Clear an old draft error and adopt
            // the durable value so recovery never leaves stale UI behind.
            validationMessage = nil
            draft = newValue
        }
    }

    static func integerValue(
        _ raw: String,
        in range: ClosedRange<Int>,
        step: Int = 1
    ) -> Int? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsed = Int(trimmed),
              range.contains(parsed),
              step > 0,
              (parsed - range.lowerBound) % step == 0 else {
            return nil
        }
        return parsed
    }

    static func integerError(
        for raw: String,
        in range: ClosedRange<Int>,
        step: Int = 1
    ) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsed = Int(trimmed) else { return "请输入整数" }
        guard range.contains(parsed) else {
            return "请输入 \(range.lowerBound) 到 \(range.upperBound) 的整数"
        }
        return step > 1 && (parsed - range.lowerBound) % step != 0
            ? "请输入符合步长 \(step) 的整数"
            : "请输入整数"
    }

    static func doubleValue(
        _ raw: String,
        in range: ClosedRange<Double>,
        step: Double = 1
    ) -> Double? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsed = Double(trimmed), range.contains(parsed), step > 0 else { return nil }
        let offset = (parsed - range.lowerBound) / step
        guard abs(offset - offset.rounded()) < 0.000_001 else { return nil }
        return parsed
    }

    static func doubleError(
        for raw: String,
        in range: ClosedRange<Double>,
        step: Double = 1
    ) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsed = Double(trimmed) else { return "请输入数字" }
        guard range.contains(parsed) else {
            return "请输入 \(range.lowerBound) 到 \(range.upperBound) 的数字"
        }
        return step != 1
            ? "请输入符合步长 \(step) 的数字"
            : "请输入数字"
    }

    /// Staged text settings can be integral or fractional. Their commit
    /// closure remains the authority for each setting's final bounds.
    static func nonnegativeTextStep(_ raw: String, by direction: Int) -> String? {
        guard direction == 1 || direction == -1 else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let current = Int(trimmed) {
            guard current >= 0 else { return nil }
            let (candidate, overflow) = current.addingReportingOverflow(direction)
            guard !overflow else { return nil }
            guard candidate >= 0 else { return nil }
            return String(candidate)
        }
        guard let current = Double(trimmed), current.isFinite, current >= 0 else { return nil }
        let candidate = current + Double(direction)
        guard candidate.isFinite, candidate >= 0, candidate != current else { return nil }
        return String(candidate)
    }

    private func commit() {
        guard draft != readText() || validationMessage != nil else { return }
        validationMessage = commitText(draft)
        if validationMessage == nil {
            writeText?(draft)
            draft = readText()
        }
    }

    private func adjustStepper(by direction: Int) {
        let current = isFocused ? draft : readText()
        guard let next = stepperAdjustment(current, direction) else { return }
        validationMessage = commitText(next)
        if validationMessage == nil {
            writeText?(next)
            draft = readText()
        }
    }

    private func revert() {
        validationMessage = nil
        draft = readText()
        writeText?(draft)
    }
}
