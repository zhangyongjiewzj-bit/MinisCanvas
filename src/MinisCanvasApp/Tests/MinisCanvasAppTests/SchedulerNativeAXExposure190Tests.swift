import AppKit
import ApplicationServices
import Foundation
import SwiftUI
import Testing
@testable import MinisCanvasApp

/// lane QODER-DEV-W14-SCHEDAX-190（scheduler-f16-baseline-028 / 缺陷族 F16）。
///
/// 本文件是行 028 原生 AX 曝光修复（SchedulerControlSettingsView.swift 的
/// 单一元素配方收敛：label/默认动作声明移到 `.accessibilityElement(children:
/// .ignore)` 之后）的附加回归覆盖：驱动同一公开入口
/// SchedulerControlSettingsView(store:)，经与 SchedulerControlSettingsTests
/// 同款的宿主与双通道读取纪律（本地 NSAccessibility 遍历优先、命中无 role 时
/// 落回有界自家 pid 公共 AXUIElement 通道），断言删除入口携带组合标签、按压
/// 真实驱动确认区出现，取消无写、确认到达原 Store 删除边界。
/// 行 028 的 PASS 只能来自 PKG 对冻结 SchedulerControlSettingsTests 的重测；
/// 本文件只钉住「被投射的单一元素同时携带标签与真实动作」这一曝光合同，
/// 不复制、不放宽任何既有断言。
@Suite("Scheduler deletion native AX single-element exposure (lane 190)")
@MainActor
struct SchedulerNativeAXExposure190Tests {
    private func make190Fixture() -> (store: SchedulerTaskStore, directory: URL, suiteName: String) {
        let suite = "scheduler-ax190-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("scheduler-ax190-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = SchedulerTaskStore(
            defaults: defaults,
            occurrenceLedgerURL: directory.appendingPathComponent("occurrences.json")
        )
        return (store, directory, suite)
    }

    private func cleanup190(directory: URL, suiteName: String) {
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: directory)
    }

    @Test("删除入口单一元素携带组合标签且按压投射确认区")
    func deletionTriggerCarriesCombinedLabelAndPressMaterializesConfirmation() throws {
        let fixture = make190Fixture()
        defer { cleanup190(directory: fixture.directory, suiteName: fixture.suiteName) }
        fixture.store.add(name: "190曝光回归任务", cronExpression: "0 9 * * *", command: "")
        let target = try #require(fixture.store.allTasks().first)
        let host = scheduler190MakeHost(SchedulerControlSettingsView(store: fixture.store))
        defer { scheduler190CloseHost(host) }

        let openDelete = try #require(scheduler190FindAX(
            host.window,
            identifier: "scheduler.task.delete.\(target.id.uuidString)"
        ))
        #expect(scheduler190AXRole(openDelete) == .button)
        #expect(scheduler190AXEnabled(openDelete))
        #expect(scheduler190AXLabel(openDelete) == "删除定时任务 190曝光回归任务")
        #expect(scheduler190AXPress(openDelete))
        scheduler190PumpAX(host)

        // 按压必须真实驱动既有 beginDeletion 路径：确认区容器随之进入 AX 树，
        // 且其标签（聚合之后声明）携带任务名。
        let confirmation = try #require(scheduler190FindAX(
            host.window,
            identifier: "scheduler.delete.confirmation"
        ))
        #expect(scheduler190AXLabel(confirmation)?.contains("190曝光回归任务") == true)
        let cancel = try #require(scheduler190FindAX(
            host.window,
            identifier: "scheduler.delete.cancel"
        ))
        #expect(scheduler190AXRole(cancel) == .button)
        #expect(scheduler190AXPress(cancel))
        scheduler190PumpAX(host)
        #expect(scheduler190FindAX(host.window, identifier: "scheduler.delete.confirmation") == nil)

        // 打开-取消全程无写：任务仍存活且未删除。
        #expect(fixture.store.task(id: target.id)?.isDeleted == false)
        #expect(fixture.store.allTasks().map(\.id) == [target.id])
    }

    @Test("a persisted disabled task opens its exact edit payload after Store reopen and cancel does not write")
    func reopenedDisabledTaskKeepsItsEditPayloadAndCancelIsReadOnly() throws {
        let fixture = make190Fixture()
        defer { cleanup190(directory: fixture.directory, suiteName: fixture.suiteName) }
        let name = "Goal22_owned_DISABLED_metadata_20261029_saved"
        let cron = "0 0 1 1 *"
        let prompt = "G22_DISABLED_METADATA_ONLY"
        try #require(fixture.store.add(name: name, cronExpression: cron,
            command: prompt, isEnabled: false) == nil)
        let original = try #require(fixture.store.allTasks().first)
        try #require(!original.isEnabled && !original.isAuthorized)
        try #require(original.targetSessionID == nil && original.targetProjectID == nil
            && original.targetTurnID == nil)
        let defaults = try #require(UserDefaults(suiteName: fixture.suiteName))
        let reopened = SchedulerTaskStore(defaults: defaults,
            occurrenceLedgerURL: fixture.directory.appendingPathComponent("occurrences.json"))
        try #require(reopened.allTasks() == [original])
        let host = scheduler190MakeHost(SchedulerControlSettingsView(store: reopened))
        defer { scheduler190CloseHost(host) }
        _ = try #require(scheduler190FindAX(host.window,
            identifier: "scheduler.task.\(original.id.uuidString)"))
        let edit = try #require(NativeConsumerOwnedAX.find(in: host.window,
            label: "编辑任务", pressable: true))
        try #require(NativeConsumerOwnedAX.press(edit))
        scheduler190PumpAX(host)
        let sheet = try #require(host.window.attachedSheet)
        try #require(host.window.sheets.count == 1 && sheet.sheetParent === host.window)
        // Preserve the original attached-sheet query's unique ownership ID.
        if sheet.accessibilityIdentifier().isEmpty {
            sheet.setAccessibilityIdentifier("native-consumer-sheet-" + UUID().uuidString)
        }
        // Reuse the complete owned AXChildren channel: this host omits AXSheets.
        let title = try #require(NativeConsumerOwnedAX.find(in: host.window, identifier: "scheduler.editor.title"))
        #expect(NativeConsumerOwnedAX.attribute(title, kAXValueAttribute as CFString) as? String == "编辑定时任务")
        for (identifier, expected) in [
            ("scheduler.editor.name", name),
            ("scheduler.editor.cron", cron),
            ("scheduler.editor.prompt", prompt)
        ] {
            let field = try #require(NativeConsumerOwnedAX.find(in: host.window, identifier: identifier))
            #expect(NativeConsumerOwnedAX.attribute(field, kAXValueAttribute as CFString) as? String == expected)
        }
        let cancel = try #require(NativeConsumerOwnedAX.find(in: host.window, identifier: "scheduler.editor.cancel"))
        try #require(NativeConsumerOwnedAX.press(cancel))
        scheduler190PumpAX(host)
        #expect(host.window.attachedSheet == nil)
        #expect(reopened.allTasks() == [original])
        let afterCancel = SchedulerTaskStore(defaults: defaults,
            occurrenceLedgerURL: fixture.directory.appendingPathComponent("occurrences.json"))
        #expect(afterCancel.allTasks() == [original])
        #expect(afterCancel.enabledTasks().isEmpty && afterCancel.occurrences.isEmpty)
    }

    @Test("确认按钮单一元素携带组合标签且按压到达原 Store 删除边界")
    func confirmTriggerReachesStoreDeletionBoundary() throws {
        let fixture = make190Fixture()
        defer { cleanup190(directory: fixture.directory, suiteName: fixture.suiteName) }
        fixture.store.add(name: "190确认边界任务", cronExpression: "0 9 * * *", command: "")
        let target = try #require(fixture.store.allTasks().first)
        let beforeVersion = target.version
        let host = scheduler190MakeHost(SchedulerControlSettingsView(store: fixture.store))
        defer { scheduler190CloseHost(host) }

        let openDelete = try #require(scheduler190FindAX(
            host.window,
            identifier: "scheduler.task.delete.\(target.id.uuidString)"
        ))
        #expect(scheduler190AXPress(openDelete))
        scheduler190PumpAX(host)

        let confirm = try #require(scheduler190FindAX(
            host.window,
            identifier: "scheduler.delete.confirm"
        ))
        #expect(scheduler190AXRole(confirm) == .button)
        #expect(scheduler190AXLabel(confirm) == "确认删除定时任务 190确认边界任务")
        #expect(scheduler190AXPress(confirm))
        scheduler190PumpAX(host)

        // 与行 028 :501-:503 同一生产边界：tombstone、版本前进、活动列表清空。
        #expect(fixture.store.task(id: target.id)?.isDeleted == true)
        #expect(fixture.store.task(id: target.id)?.version == beforeVersion + 1)
        #expect(fixture.store.allTasks().isEmpty)
    }
}

@MainActor
private func scheduler190MakeHost<V: View>(_ rootView: V) -> (window: NSWindow, view: NSView) {
    let hostLease = NativeTestHostLifecycle.begin("SchedulerAX190")
    // 与 SchedulerControlSettingsTests 的宿主合同一致：先给页面有界 proposal，
    // 再经有界自家 pid 公共曝光读取，宿主行为逐字同款（见其 :547-595 注释）。
    let controller = NSHostingController(
        rootView: AnyView(rootView.frame(width: 1_100, height: 760))
    )
    controller.sizingOptions = []
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 1_100, height: 760),
        styleMask: [.titled, .closable, .resizable],
        backing: .buffered,
        defer: false
    )
    NativeTestHostLifecycle.bind(hostLease, to: window)
    window.isReleasedWhenClosed = false
    window.contentViewController = controller
    let view = controller.view
    view.frame = NSRect(x: 0, y: 0, width: 1_100, height: 760)
    window.makeKeyAndOrderFront(nil)
    window.orderFrontRegardless()
    window.setContentSize(NSSize(width: 1_100, height: 760))
    let ownerIdentifier = "scheduler-ax190-native-host-" + UUID().uuidString
    window.setAccessibilityIdentifier(ownerIdentifier)
    scheduler190PumpAX((window, view))
    let exposureStatus = scheduler190ExposeOwnedWindowForAccessibility(
        window, ownerIdentifier: ownerIdentifier
    )
    print("SCHEDULER190_NATIVE_HOST_EXPOSURE \(exposureStatus)")
    NativeTestHostLifecycle.observe(window, phase: "sampled")
    return (window, view)
}

@MainActor
private func scheduler190CloseHost(_ host: (window: NSWindow, view: NSView)) {
    host.window.orderOut(nil)
    host.window.contentViewController = nil
    host.window.close()
    NativeTestHostLifecycle.end(host.window)
}

@MainActor
private func scheduler190PumpAX(_ host: (window: NSWindow, view: NSView)) {
    for _ in 0..<6 {
        host.window.layoutIfNeeded()
        host.view.layoutSubtreeIfNeeded()
        host.view.display()
        _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.02))
    }
}

@MainActor
private func scheduler190ExposeOwnedWindowForAccessibility(
    _ window: NSWindow, ownerIdentifier: String
) -> String {
    let application = AXUIElementCreateApplication(getpid())
    guard AXUIElementSetMessagingTimeout(application, 0.05) == .success else {
        return "status=APP_MESSAGING_TIMEOUT_UNSET"
    }
    var windowCount = 0
    guard AXUIElementGetAttributeValueCount(
        application, kAXWindowsAttribute as CFString, &windowCount
    ) == .success, (1...16).contains(windowCount) else {
        return "status=OWN_WINDOWS_UNREADABLE windowCount=\(windowCount)"
    }
    var rawWindows: CFArray?
    guard AXUIElementCopyAttributeValues(
        application, kAXWindowsAttribute as CFString, 0, windowCount, &rawWindows
    ) == .success, let windows = rawWindows as? [AXUIElement] else {
        return "status=OWN_WINDOWS_COPY_FAILED"
    }
    var owner: AXUIElement?
    var matches = 0
    for element in windows.prefix(16) {
        _ = AXUIElementSetMessagingTimeout(element, 0.05)
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(
            element, kAXIdentifierAttribute as CFString, &value
        ) == .success, (value as? String) == ownerIdentifier {
            matches += 1
            owner = element
        }
    }
    guard matches == 1, let owner else {
        return "status=OWNER_NOT_UNIQUE matches=\(matches) windows=\(windows.count)"
    }
    var childCount = 0
    guard AXUIElementGetAttributeValueCount(
        owner, kAXChildrenAttribute as CFString, &childCount
    ) == .success else {
        return "status=OWNER_CHILDREN_UNREADABLE ownerMatches=\(matches)"
    }
    if childCount > 0 {
        var children: CFArray?
        _ = AXUIElementCopyAttributeValues(
            owner, kAXChildrenAttribute as CFString, 0, min(childCount, 4), &children
        )
    }
    return "status=EXPOSED children=\(childCount) windows=\(windows.count)"
}

@MainActor
private func scheduler190FindAX(_ object: AnyObject, identifier: String) -> AnyObject? {
    // 与冻结行 028 的 schedulerFindAX 同款双通道纪律：本地遍历命中且节点有 role
    // 才采用；否则落回有界自家 pid 公共通道。不引入替代节点、不放宽匹配。
    var visited = Set<ObjectIdentifier>()
    if let local = scheduler190FindAXLocal(object, identifier: identifier, visited: &visited),
       scheduler190AXRole(local) != nil {
        return local
    }
    return scheduler190PublicFindAX(identifier)
}

@MainActor
private func scheduler190FindAXLocal(
    _ object: AnyObject,
    identifier: String,
    visited: inout Set<ObjectIdentifier>
) -> AnyObject? {
    guard visited.insert(ObjectIdentifier(object)).inserted else { return nil }
    if scheduler190AXIdentifier(object) == identifier { return object }
    let ordered = scheduler190RawAXChildren(of: object, attribute: .childrenInNavigationOrderAttribute)
    var children = ordered
    children.append(contentsOf: scheduler190RawAXChildren(of: object, attribute: .children))
    if let view = object as? NSView { children += view.subviews }
    if let window = object as? NSWindow, let content = window.contentView {
        children.append(content.superview ?? content)
    }
    for child in scheduler190Flatten(children) {
        let childObject = child as AnyObject
        if let match = scheduler190FindAXLocal(childObject, identifier: identifier, visited: &visited) {
            return match
        }
    }
    return nil
}

@MainActor
private func scheduler190RawAXChildren(
    of object: AnyObject,
    attribute: NSAccessibility.Attribute
) -> [Any] {
    let unignored = NSAccessibility.unignoredChildrenForOnlyChild(from: object)
    let selectorName = attribute == .childrenInNavigationOrderAttribute
        ? "accessibilityChildrenInNavigationOrder"
        : "accessibilityChildren"
    // lane 179 教训：responds(to:) 守卫后才发送遗留选择子。
    guard let value = scheduler190RawAXGetter(object, selectorName: selectorName)
        ?? scheduler190RawAXAttribute(object, attribute) else {
        return unignored
    }
    if let values = value as? NSArray {
        let raw = values.map { $0 }
        return raw + NSAccessibility.unignoredChildren(from: raw) + unignored
    }
    return [value] + NSAccessibility.unignoredChildrenForOnlyChild(from: value) + unignored
}

private func scheduler190Flatten(_ children: [Any]) -> [Any] {
    children.flatMap { child in
        if let nested = child as? [Any] { return scheduler190Flatten(nested) }
        if let nested = child as? NSArray { return scheduler190Flatten(nested.map { $0 }) }
        return [child]
    }
}

@MainActor
private func scheduler190RawAXGetter(_ object: AnyObject, selectorName: String) -> Any? {
    guard let object = object as? NSObject else { return nil }
    let selector = NSSelectorFromString(selectorName)
    guard object.responds(to: selector), let result = object.perform(selector) else { return nil }
    return result.takeUnretainedValue()
}

@MainActor
private func scheduler190RawAXAttribute(
    _ object: AnyObject,
    _ attribute: NSAccessibility.Attribute
) -> Any? {
    guard let object = object as? NSObject,
          object.responds(to: NSSelectorFromString("accessibilityAttributeValue:")) else {
        return nil
    }
    return UF03LegacyAttribute(object, attribute)
}

@MainActor
private func scheduler190PublicFindAX(_ identifier: String) -> AnyObject? {
    // 只读、有界、仅自家 pid：app → kAXWindowsAttribute → 深度≤24、节点≤2048，
    // 按 kAXIdentifierAttribute 精确匹配（与行 028 schedulerPublicFindAX 同纪律）。
    let application = AXUIElementCreateApplication(getpid())
    _ = AXUIElementSetMessagingTimeout(application, 0.05)
    var rawWindows: CFTypeRef?
    guard AXUIElementCopyAttributeValue(
        application, kAXWindowsAttribute as CFString, &rawWindows
    ) == .success, let windows = rawWindows as? [AXUIElement] else {
        return nil
    }
    var visited = Set<CFHashCode>()
    var budget = 2048
    func walk(_ element: AXUIElement, depth: Int) -> AXUIElement? {
        if budget <= 0 || depth > 24 { return nil }
        budget -= 1
        guard visited.insert(CFHash(element)).inserted else { return nil }
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(
            element, kAXIdentifierAttribute as CFString, &value
        ) == .success, (value as? String) == identifier {
            return element
        }
        var children: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, kAXChildrenAttribute as CFString, &children
        ) == .success, let kidList = children as? [AXUIElement] else {
            return nil
        }
        for kid in kidList {
            if let match = walk(kid, depth: depth + 1) { return match }
        }
        return nil
    }
    for window in windows.prefix(16) {
        if let match = walk(window, depth: 0) {
            return match as AnyObject
        }
    }
    return nil
}

@MainActor
private func scheduler190PublicAXElement(_ object: AnyObject) -> AXUIElement? {
    // CFGetTypeID 可失败判别 + unsafeDowncast（仓库实测唯一可用写法）。
    guard CFGetTypeID(object) == AXUIElementGetTypeID() else { return nil }
    return unsafeDowncast(object, to: AXUIElement.self)
}

@MainActor
private func scheduler190PublicAttribute(_ object: AnyObject, _ name: CFString) -> CFTypeRef? {
    guard let element = scheduler190PublicAXElement(object) else { return nil }
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name, &value) == .success else { return nil }
    return value
}

private func scheduler190PublicBool(_ value: CFTypeRef?) -> Bool? {
    guard let value else { return nil }
    if CFGetTypeID(value) == CFBooleanGetTypeID() {
        return CFBooleanGetValue((value as! CFBoolean))
    }
    if let number = value as? NSNumber { return number.boolValue }
    return value as? Bool
}

@MainActor
private func scheduler190AXIdentifier(_ object: AnyObject) -> String? {
    if let value = scheduler190PublicAttribute(object, kAXIdentifierAttribute as CFString) as? String,
       !value.isEmpty { return value }
    if let value = scheduler190RawAXGetter(object, selectorName: "accessibilityIdentifier") as? String,
       !value.isEmpty { return value }
    if let value = scheduler190RawAXAttribute(object, .identifier) as? String,
       !value.isEmpty { return value }
    return (object as? NSAccessibilityProtocol)?.accessibilityIdentifier()
}

@MainActor
private func scheduler190AXRole(_ object: AnyObject) -> NSAccessibility.Role? {
    if let value = scheduler190PublicAttribute(object, kAXRoleAttribute as CFString) as? String {
        return NSAccessibility.Role(rawValue: value)
    }
    return (object as? NSAccessibilityProtocol)?.accessibilityRole()
        ?? scheduler190RawAXAttribute(object, .role) as? NSAccessibility.Role
}

@MainActor
private func scheduler190AXEnabled(_ object: AnyObject) -> Bool {
    if let value = scheduler190PublicAttribute(object, kAXEnabledAttribute as CFString) {
        return scheduler190PublicBool(value) ?? false
    }
    return (object as? NSAccessibilityProtocol)?.isAccessibilityEnabled()
        ?? scheduler190RawAXAttribute(object, .enabled) as? Bool
        ?? false
}

@MainActor
private func scheduler190AXLabel(_ object: AnyObject) -> String? {
    if let value = scheduler190PublicAttribute(object, kAXDescriptionAttribute as CFString) as? String {
        return value
    }
    if let value = scheduler190PublicAttribute(object, kAXTitleAttribute as CFString) as? String {
        return value
    }
    return (object as? NSAccessibilityProtocol)?.accessibilityLabel()
        ?? scheduler190RawAXAttribute(object, .description) as? String
}

@MainActor
private func scheduler190AXPress(_ object: AnyObject) -> Bool {
    if let element = scheduler190PublicAXElement(object) {
        return AXUIElementPerformAction(element, kAXPressAction as CFString) == .success
    }
    if let accessibilityObject = object as? NSAccessibilityProtocol,
       accessibilityObject.accessibilityPerformPress() {
        return true
    }
    guard let object = object as? NSObject,
          (object.perform(NSSelectorFromString("accessibilityActionNames"))?.takeUnretainedValue() as? [String])?.contains(NSAccessibility.Action.press.rawValue) == true else { return false }
    _ = object.perform(NSSelectorFromString("accessibilityPerformAction:"), with: NSAccessibility.Action.press.rawValue)
    return true
}
