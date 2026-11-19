import AppKit
import ApplicationServices
import Foundation
import SwiftUI
import Testing
import MinisCore

@testable import MinisCanvasApp

@Suite("UI-043 模型选择行 AX 合同")
struct UI043ModelPickerRowAccessibilityTests {
    private func modelMenuSource() throws -> String {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // MinisCanvasAppTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // MinisCanvasApp
            .deletingLastPathComponent() // src
            .deletingLastPathComponent() // repository
        return try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "src/MinisCanvasApp/Sources/MinisCanvasApp/ModelMenuButton.swift"
            ),
            encoding: .utf8
        )
    }

    private func rowBody() throws -> String {
        let source = try modelMenuSource()
        let start = try #require(source.range(of: "    private func row("))
        let end = try #require(source.range(
            of: "    private func providerIcon",
            range: start.upperBound..<source.endIndex
        ))
        return String(source[start.lowerBound..<end.lowerBound])
    }

    @Test("选择行暴露稳定名称、选中状态和值提示")
    func rowExposesAccessibilityContract() throws {
        let body = try rowBody()

        #expect(body.contains("let guardedAction = { if isEnabled { action() } }"))
        #expect(body.contains("Button(action: guardedAction)"))
        #expect(body.contains(".disabled(!isEnabled)"))
        #expect(body.contains(".accessibilityAction(.default, guardedAction)"))
        #expect(body.contains(".accessibilityElement(children: .ignore)"))
        #expect(body.contains(".accessibilityLabel(subtitle.map { \"\\(title)，\\($0)\" } ?? title)"))
        #expect(body.contains(".accessibilityValue(isSelected ? \"已选中\" : \"未选中\")"))
        #expect(body.contains(".accessibilityHint(isEnabled ? \"选择此项\" : \"不可选择，请到设置检查模型连接\")"))
    }

    @Test("未就绪服务商合并为一行可点条目，不再有独立的“去设置 ·”链接行")
    func unreadyProviderIsSingleClickableRow() throws {
        let source = try modelMenuSource()
        #expect(!source.contains("Button(\"去设置 · "))
        let start = try #require(source.range(of: "private func unreadyProviderRow("))
        let end = try #require(source.range(of: "/// ① 点内置 Provider", range: start.upperBound..<source.endIndex))
        let body = String(source[start.lowerBound..<end.lowerBound])
        #expect(body.contains("Text(\"去设置\")"))
        #expect(body.contains("openSettingsPage(ProviderConnectionRoute.id)"))
        #expect(body.contains(".accessibilityAction(.default, open)"))
        #expect(body.contains(".accessibilityLabel(\"\\(name)，\\(reason)\")"))
    }

    @Test("AX 修复不改变原选择动作与可见行布局")
    func rowPreservesActionAndVisualContract() throws {
        let source = try modelMenuSource()
        let body = try rowBody()

        #expect(body.contains(".buttonStyle(.plain)"))
        #expect(body.contains(".padding(.horizontal, 6)"))
        #expect(body.contains(".padding(.vertical, 4)"))
        #expect(body.contains(".contentShape(Rectangle())"))
        #expect(source.contains("state.selectModel"))
        #expect(source.contains("pickProvider"))
        #expect(source.contains("finalize(with: tier)"))
    }
}

/// A rendered AppKit accessibility check, separate from the source-contract
/// checks above. It must run only in the formal isolated App test profile.
@Suite("UI-043 模型选择行原生 AX Press")
@MainActor
struct UI043ModelPickerNativeAXPressTests {
    @Test("Provider、模型、档位行的 Press 到达各自选择动作")
    func pressAdvancesTheActualPickerAndAppliesOnlyAtTier() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ui043-model-picker-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suite = "ui043-model-picker-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let chat = ChatStore(
            preferencesDefaults: defaults,
            logManager: LogManager(directory: root.appendingPathComponent("logs"))
        )
        #expect(chat.selectedProviderType == nil)
        #expect(chat.chatProviderOptions.contains(.builtIn(.deepSeek)))
        var dismissals = 0
        // Keep the test host mounted so it can also exercise a separate tier press.
        let presentation = Binding(get: { true }, set: { if !$0 { dismissals += 1 } })
        let host = modelPicker043MakeHost(
            ModelPickerPanel(chat: chat, isPresented: presentation)
        )
        defer { modelPicker043CloseHost(host) }
        try #require(
            host.window.frame.width > 0 && host.window.frame.height > 0,
            "native host must keep a nonzero window frame before AX lookup"
        )

        let provider = try #require(modelPicker043PublicAX(
            host.window, label: "DeepSeek", value: "未选中"
        ))
        #expect(modelPicker043PublicRole(provider) == kAXButtonRole as String)
        #expect(modelPicker043PublicEnabled(provider))
        #expect(modelPicker043PublicHasPress(provider))
        #expect(modelPicker043PublicPress(provider))
        modelPicker043Pump(host)
        #expect(modelPicker043PublicAX(host.window, label: "DeepSeek", value: "已选中") != nil)
        #expect(chat.selectedProviderType == nil, "Provider 行只改变面板预选")

        let model = try #require(modelPicker043PublicAX(
            host.window, label: "DeepSeek Chat (V3)，deepseek-chat", value: "未选中"
        ))
        #expect(modelPicker043PublicRole(model) == kAXButtonRole as String)
        #expect(modelPicker043PublicHasPress(model))
        #expect(modelPicker043PublicPress(model))
        modelPicker043Pump(host)
        #expect(modelPicker043PublicAX(
            host.window, label: "DeepSeek Chat (V3)，deepseek-chat", value: "已选中"
        ) != nil)
        #expect(chat.selectedProviderType == .deepSeek)
        #expect(chat.selectedModelID == "deepseek-chat")
        #expect(chat.modelSpeedTier == .balanced)
        #expect(dismissals == 1)

        let tier = try #require(modelPicker043PublicAX(host.window, label: "快", value: "未选中"))
        #expect(modelPicker043PublicRole(tier) == kAXButtonRole as String)
        #expect(modelPicker043PublicHasPress(tier))
        #expect(modelPicker043PublicPress(tier))
        modelPicker043Pump(host)
        try #require(chat.selectedProviderType == .deepSeek)
        try #require(chat.selectedModelID == "deepseek-chat")
        try #require(chat.modelSpeedTier == .fast)
        #expect(dismissals == 2)
        FileHandle.standardError.write(Data(
            "UI043_NATIVE_BODY_COMPLETE provider=deepSeek model=deepseek-chat tier=fast\n".utf8
        ))
    }
}

@MainActor
private func modelPicker043MakeHost<V: View>(_ view: V) -> (window: NSWindow, view: NSView) {
    let lease = NativeTestHostLifecycle.begin("ModelPickerAX043")
    let controller = NSHostingController(rootView: AnyView(view.frame(width: 300, height: 430)))
    controller.sizingOptions = []
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 300, height: 430),
        styleMask: [.titled, .closable], backing: .buffered, defer: false
    )
    NativeTestHostLifecycle.bind(lease, to: window)
    window.isReleasedWhenClosed = false
    window.contentViewController = controller
    let hosted = controller.view
    hosted.frame = NSRect(x: 0, y: 0, width: 300, height: 430)
    window.makeKeyAndOrderFront(nil)
    window.orderFrontRegardless()
    window.setContentSize(NSSize(width: 300, height: 430))
    let ownerIdentifier = "ui043-model-picker-host-" + UUID().uuidString
    window.setAccessibilityIdentifier(ownerIdentifier)
    modelPicker043Pump((window, hosted))
    let exposure = modelPicker043ExposeOwnedWindow(ownerIdentifier: ownerIdentifier)
    print("UI043_NATIVE_HOST_EXPOSURE \(exposure) frame=\(window.frame) content=\(String(describing: window.contentView?.frame))")
    NativeTestHostLifecycle.observe(window, phase: "sampled")
    return (window, hosted)
}

@MainActor
private func modelPicker043ExposeOwnedWindow(ownerIdentifier: String) -> String {
    let application = AXUIElementCreateApplication(getpid())
    guard AXUIElementSetMessagingTimeout(application, 0.05) == .success else {
        return "APP_MESSAGING_TIMEOUT_UNSET"
    }
    var count = 0
    guard AXUIElementGetAttributeValueCount(
        application, kAXWindowsAttribute as CFString, &count
    ) == .success, (1...16).contains(count) else {
        return "OWN_WINDOWS_UNREADABLE count=\(count)"
    }
    var rawWindows: CFArray?
    guard AXUIElementCopyAttributeValues(
        application, kAXWindowsAttribute as CFString, 0, count, &rawWindows
    ) == .success, let windows = rawWindows as? [AXUIElement] else {
        return "OWN_WINDOWS_COPY_FAILED"
    }
    var matches = 0
    for window in windows {
        _ = AXUIElementSetMessagingTimeout(window, 0.05)
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(
            window, kAXIdentifierAttribute as CFString, &value
        ) == .success, (value as? String) == ownerIdentifier {
            matches += 1
            var children = 0
            _ = AXUIElementGetAttributeValueCount(
                window, kAXChildrenAttribute as CFString, &children
            )
            if children > 0 {
                var first: CFArray?
                _ = AXUIElementCopyAttributeValues(
                    window, kAXChildrenAttribute as CFString, 0, min(children, 4), &first
                )
            }
        }
    }
    return "OWN_WINDOW matches=\(matches) total=\(count)"
}

@MainActor
private func modelPicker043CloseHost(_ host: (window: NSWindow, view: NSView)) {
    host.window.orderOut(nil)
    host.window.contentViewController = nil
    host.window.close()
    NativeTestHostLifecycle.end(host.window)
}

@MainActor
private func modelPicker043Pump(_ host: (window: NSWindow, view: NSView)) {
    for _ in 0..<6 {
        host.window.layoutIfNeeded()
        host.view.layoutSubtreeIfNeeded()
        _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.02))
    }
}

@MainActor
private func modelPicker043FindAX(
    _ object: AnyObject, label: String, value: String
) -> AnyObject? {
    var visited = Set<ObjectIdentifier>()
    var samples: [String] = []
    let found = modelPicker043FindAX(
        object, label: label, value: value, visited: &visited, samples: &samples
    )
    if found == nil {
        print("UI043_NATIVE_AX_MISSING label=\(label) value=\(value) visited=\(visited.count) samples=\(samples.joined(separator: " | "))")
    }
    return found
}

@MainActor
private func modelPicker043FindAX(
    _ object: AnyObject, label: String, value: String,
    visited: inout Set<ObjectIdentifier>, samples: inout [String]
) -> AnyObject? {
    guard visited.insert(ObjectIdentifier(object)).inserted, visited.count <= 800 else { return nil }
    if modelPicker043Label(object) == label, modelPicker043Value(object) == value {
        return object
    }
    var children = NSAccessibility.unignoredChildrenForOnlyChild(from: object)
    if let raw = modelPicker043RawChildren(object) {
        children += raw
        children += NSAccessibility.unignoredChildren(from: raw)
    }
    if let view = object as? NSView { children += view.subviews }
    if let window = object as? NSWindow, let content = window.contentView {
        children.append(content.superview ?? content)
    }
    if samples.count < 24 {
        samples.append("\(String(reflecting: type(of: object))):\(String((modelPicker043Label(object) ?? "<nil>").prefix(60))):\(modelPicker043Value(object) ?? "<nil>"):\(modelPicker043Role(object)?.rawValue ?? "<nil>"):children=\(children.count)")
    }
    for child in children {
        let child = child as AnyObject
        if let found = modelPicker043FindAX(
            child, label: label, value: value, visited: &visited, samples: &samples
        ) {
            return found
        }
    }
    return nil
}

@MainActor
private func modelPicker043RawChildren(_ object: AnyObject) -> [Any]? {
    guard let result = modelPicker043RawGetter(object, "accessibilityChildren") else { return nil }
    return (result as? NSArray)?.map { $0 }
}

@MainActor
private func modelPicker043RawGetter(_ object: AnyObject, _ selectorName: String) -> Any? {
    guard let object = object as? NSObject else { return nil }
    let selector = NSSelectorFromString(selectorName)
    guard object.responds(to: selector),
          let result = object.perform(selector) else { return nil }
    return result.takeUnretainedValue()
}

@MainActor
private func modelPicker043Role(_ object: AnyObject) -> NSAccessibility.Role? {
    (modelPicker043RawGetter(object, "accessibilityRole") as? String)
        .map(NSAccessibility.Role.init(rawValue:))
        ?? (object as? NSAccessibilityProtocol)?.accessibilityRole()
        ?? UF03LegacyAttribute(object as? NSObject, .role) as? NSAccessibility.Role
}

@MainActor
private func modelPicker043Label(_ object: AnyObject) -> String? {
    modelPicker043RawGetter(object, "accessibilityLabel") as? String
        ?? (object as? NSAccessibilityProtocol)?.accessibilityLabel()
        ?? UF03LegacyAttribute(object as? NSObject, .description) as? String
}

@MainActor
private func modelPicker043Value(_ object: AnyObject) -> String? {
    modelPicker043RawGetter(object, "accessibilityValue") as? String
        ?? (object as? NSAccessibilityProtocol)?.accessibilityValue() as? String
        ?? UF03LegacyAttribute(object as? NSObject, .value) as? String
}

/// The local SwiftUI.AccessibilityNode can report its role through selectors
/// while omitting NSAccessibilityProtocol and legacy actionNames. Exercise the
/// public AX channel used by an external client, scoped to this owned window.
@MainActor
private func modelPicker043PublicAX(
    _ window: NSWindow, label: String, value: String
) -> AXUIElement? {
    guard let ownerIdentifier = modelPicker043RawGetter(window, "accessibilityIdentifier") as? String,
          !ownerIdentifier.isEmpty else { return nil }
    let application = AXUIElementCreateApplication(getpid())
    _ = AXUIElementSetMessagingTimeout(application, 0.05)
    var rawWindows: CFTypeRef?
    guard AXUIElementCopyAttributeValue(
        application, kAXWindowsAttribute as CFString, &rawWindows
    ) == .success, let windows = rawWindows as? [AXUIElement] else { return nil }
    var visited = Set<CFHashCode>()
    var budget = 2048
    var samples: [String] = []
    func walk(_ element: AXUIElement, depth: Int) -> AXUIElement? {
        guard budget > 0, depth <= 24 else { return nil }
        budget -= 1
        guard visited.insert(CFHash(element)).inserted else { return nil }
        _ = AXUIElementSetMessagingTimeout(element, 0.05)
        let actualLabel = modelPicker043PublicString(element, kAXDescriptionAttribute as CFString)
            ?? modelPicker043PublicString(element, kAXTitleAttribute as CFString)
        let actualValue = modelPicker043PublicString(element, kAXValueAttribute as CFString)
        if samples.count < 24 {
            samples.append("\(actualLabel ?? "<nil>"):\(actualValue ?? "<nil>"):\(modelPicker043PublicRole(element) ?? "<nil>")")
        }
        if actualLabel == label, actualValue == value { return element }
        var rawChildren: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, kAXChildrenAttribute as CFString, &rawChildren
        ) == .success, let children = rawChildren as? [AXUIElement] else { return nil }
        for child in children {
            if let found = walk(child, depth: depth + 1) { return found }
        }
        return nil
    }
    for candidate in windows.prefix(16) {
        guard modelPicker043PublicString(candidate, kAXIdentifierAttribute as CFString)
                == ownerIdentifier else { continue }
        if let found = walk(candidate, depth: 0) { return found }
    }
    print("UI043_PUBLIC_AX_MISSING label=\(label) value=\(value) visited=\(visited.count) samples=\(samples.joined(separator: " | "))")
    let local = modelPicker043FindAX(window, label: label, value: value)
    print("UI043_LOCAL_AX_MATCH \(local != nil) role=\(local.flatMap(modelPicker043Role)?.rawValue ?? "<nil>")")
    return nil
}

@MainActor
private func modelPicker043PublicString(_ element: AXUIElement, _ attribute: CFString) -> String? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else { return nil }
    return value as? String
}

@MainActor
private func modelPicker043PublicRole(_ element: AXUIElement) -> String? {
    modelPicker043PublicString(element, kAXRoleAttribute as CFString)
}

@MainActor
private func modelPicker043PublicEnabled(_ element: AXUIElement) -> Bool {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(
        element, kAXEnabledAttribute as CFString, &value
    ) == .success else { return false }
    if let number = value as? NSNumber { return number.boolValue }
    return value as? Bool ?? false
}

@MainActor
private func modelPicker043PublicHasPress(_ element: AXUIElement) -> Bool {
    var actions: CFArray?
    return AXUIElementCopyActionNames(element, &actions) == .success
        && (actions as? [String])?.contains(kAXPressAction as String) == true
}

@MainActor
private func modelPicker043PublicPress(_ element: AXUIElement) -> Bool {
    let result = AXUIElementPerformAction(element, kAXPressAction as CFString)
    print("UI043_PUBLIC_AX_PRESS result=\(result.rawValue)")
    return result == .success
}
