import AppKit
import ApplicationServices
import Foundation
import Darwin
import SwiftUI
import Testing
import MinisCore
@testable import MinisCanvasApp

/// lane QODER-DEV-255-H3REACH（Canonical H3，总表 :311）。
///
/// 子会话行可达性回归：TaskSummaryView 的 child 行从纯文本
/// （base head :117-118 实测 `InspectorValueRow("子会话", childSessionID)`）
/// 升级为原生 AX 层可操作元素。断言走与冻结的
/// TaskCenterNativeAccessibilityConsumerTests / SchedulerNativeAXExposure190Tests
/// 同款宿主与读取纪律（真实 NSHostingController 窗口 + 本地 AX 树遍历），
/// 只钉被投射元素本身：role=.button、enabled、稳定 identifier、公开导航标签、
/// 且按压真实把 head 已有的 public `TaskCenterChildSessionNavigation` 身份送达
/// 注入的 seam。行数据来自真实生产链（AgentTaskStore → settleChildResult →
/// TaskCenterControlConsumer.receiptRows），不是手造 fixture。
/// 消费者（把 seam 接到会话切换权威）按 C0 裁定 DEFERRED，本文件不复制、
/// 不放宽任何既有断言；PASS 只能来自 PKG 门轮对本文件的重测。
@Suite("TaskSummary child-session reachability (lane 255 / H3)")
@MainActor
struct TaskSummaryChildReachability255Tests {

    // MARK: - 真实生产链行投影

    private func settledChildRow(
        ownedRoot: URL,
        taskID: String,
        parentID: String,
        childExecutionID: String,
        bindTranscript: Bool = true,
        validLineage: Bool = true
    ) throws -> (row: TaskCenterReceiptRow, directory: URL) {
        let directory = ownedRoot
            .appendingPathComponent("child-reachability-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            let sessions = SessionStore(directory: directory)
            let parentSessionID = parentID
            let childSessionID = "\(parentID):child:\(childExecutionID)"
            _ = try sessions.createSession(id: parentSessionID)
            let store = AgentTaskStore()
            let task = try store.enqueue(
                taskID: taskID,
                parentID: parentID,
                providerID: "offline",
                modelID: "test",
                parentContextSnapshotID: "session-255"
            )
            let run = try store.startRun(
                taskID: task.taskID,
                parentID: task.parentID,
                runID: "\(taskID)-run"
            )
            _ = try sessions.forkSession(
                from: parentSessionID, id: childSessionID, throughMessageIndex: 0,
                createdByTaskID: task.taskID,
                createdByRunID: validLineage ? run.runID : "mismatched-255-run"
            )
            try sessions.saveMessage(
                LLMMessage(role: .assistant, content: "synthetic persisted child message"),
                sessionID: childSessionID
            )
            let attemptID = try #require(store.canonicalAttemptID(runID: run.runID))
            let locator = ChildTranscriptLocator(
                childSessionID: childSessionID, parentSessionID: parentSessionID,
                taskID: task.taskID, parentID: task.parentID, runID: run.runID,
                attemptID: attemptID, childExecutionID: childExecutionID,
                parentContextSnapshotID: task.parentContextSnapshotID
            )
            if bindTranscript { _ = try store.bindChildTranscript(locator) }
            let envelope = ChildResultEnvelope(
                taskID: task.taskID,
                runID: run.runID,
                attemptID: attemptID,
                parentContextSnapshotID: task.parentContextSnapshotID,
                childExecutionID: childExecutionID,
                outcome: .succeeded,
                outputDigest: "digest-255-\(taskID)",
                idempotencyKey: "idempotency-255-\(taskID)",
                agentType: "codex",
                childTranscriptLocator: bindTranscript ? locator : nil
            )
            _ = try store.settleChildResult(envelope)
            let consumer = TaskCenterControlConsumer(
                store: store, childTranscriptSessionStore: sessions
            )
            let row = try #require(
                consumer.receiptRows(now: Date(timeIntervalSince1970: 1_850_000_000))
                    .first { $0.taskID == taskID }
            )
            if bindTranscript && validLineage {
                #expect(row.childNavigation?.locator == locator)
                #expect(consumer.childTranscript(navigation: .init(locator: locator)) != nil)
            } else {
                #expect(row.childSessionID == nil)
                #expect(row.childNavigation == nil)
                #expect(consumer.childTranscript(navigation: .init(locator: locator)) == nil)
            }
            return (row, directory)
        } catch {
            throw error
        }
    }

    // MARK: - 曝光合同

    @Test("子会话行以原生 AX button 曝光且按压把公开导航身份送达注入 seam")
    func childSessionRowIsNativeButtonRoutedToInjectedSeam() throws {
        try taskSummary255WithOwnedRoot { ownedRoot in
        let fixture = try settledChildRow(
            ownedRoot: ownedRoot,
            taskID: "reach-255-child",
            parentID: "reach-255-parent",
            childExecutionID: "reach-255-exec"
        )
        let row = fixture.row
        let childSessionID = try #require(row.childSessionID)
        let navigation = try #require(row.childNavigation)
        // 钉住 head 既有公开语义：身份串与导航标签不由本线发明。
        #expect(childSessionID == "reach-255-parent:child:reach-255-exec")
        #expect(navigation.accessibilityLabel == "打开子会话 \(childSessionID)，返回父会话 \(navigation.parentSessionID)")

        let recorder = TaskSummary255NavigationRecorder()
        let host = taskSummary255MakeHost(TaskSummaryView(
            currentTaskID: row.parentID,
            taskSnapshots: [],
            receiptRows: [row],
            onOpenChildSession: { received in recorder.record(received) }
        ))
        defer { taskSummary255CloseHost(host) }

        let identifier = "task-summary-child-session-\(childSessionID)"
        taskSummary255RevealChildDetails(host, lookingFor: identifier)
        let button = try #require(
            taskSummary255FindAX(host.window, identifier: identifier),
            "child 行必须以稳定 identifier \(identifier) 进入 AX 树"
        )
        #expect(taskSummary255AXRole(button) == .button)
        #expect(taskSummary255AXEnabled(button))
        #expect(taskSummary255AXLabel(button) == navigation.accessibilityLabel)
        #expect(taskSummary255AXPress(button))
        taskSummary255Pump(host)

        // 按压必须真实到达注入的生产 seam，且携带的就是行上那份公开导航身份。
        #expect(recorder.received == [navigation])
        }
    }

    @Test("未注入消费者时子会话行仍是可操作元素（producer-only 边界，consumer=DEFERRED）")
    func affordanceStaysOperableWithoutConsumerInjection() throws {
        try taskSummary255WithOwnedRoot { ownedRoot in
        let fixture = try settledChildRow(
            ownedRoot: ownedRoot,
            taskID: "defer-255-child",
            parentID: "defer-255-parent",
            childExecutionID: "defer-255-exec"
        )
        let row = fixture.row
        let childSessionID = try #require(row.childSessionID)
        let navigation = try #require(row.childNavigation)
        // 与现有 ChatInspectorView 调用点同款成员序初始化：不注入 seam。
        let host = taskSummary255MakeHost(TaskSummaryView(
            currentTaskID: row.parentID,
            taskSnapshots: [],
            receiptRows: [row]
        ))
        defer { taskSummary255CloseHost(host) }

        let identifier = "task-summary-child-session-\(childSessionID)"
        taskSummary255RevealChildDetails(host, lookingFor: identifier)
        let button = try #require(
            taskSummary255FindAX(host.window, identifier: identifier),
            "无消费者注入时 affordance 也必须已曝光（declared ≠ exposed 教训的反向钉）"
        )
        #expect(taskSummary255AXRole(button) == .button)
        #expect(taskSummary255AXEnabled(button))
        #expect(taskSummary255AXLabel(button) == navigation.accessibilityLabel)
        // 动作存在且同步派发不崩溃；跳转后果属 DEFERRED 消费者线，不在本断言面。
        #expect(taskSummary255AXPress(button))
        taskSummary255Pump(host)
        }
    }

    @Test("已落子结果缺少绑定或持久化血缘错误时不能曝光跳转入口")
    func settledResultWithMissingOrIncorrectBindingIsNotReachable() throws {
        try taskSummary255WithOwnedRoot { ownedRoot in
        for bindTranscript in [false, true] {
            let fixture = try settledChildRow(
            ownedRoot: ownedRoot,
                taskID: "invalid-255-child-\(bindTranscript)",
                parentID: "invalid-255-parent",
                childExecutionID: "invalid-255-exec",
                bindTranscript: bindTranscript,
                validLineage: !bindTranscript
            )
                #expect(fixture.row.childSessionID == nil)
            #expect(fixture.row.childNavigation == nil)
            let host = taskSummary255MakeHost(TaskSummaryView(
                currentTaskID: fixture.row.parentID, taskSnapshots: [], receiptRows: [fixture.row]
            ))
            defer { taskSummary255CloseHost(host) }
            taskSummary255PressChildDetailsToggle(host)
            taskSummary255Pump(host)
            #expect(taskSummary255FindAXPrefix(
                host.window, prefix: "task-summary-child-session-"
            ) == nil)
            _ = try #require(taskSummary255FindAX(host.window, identifier: "child-agent-counts"),
                "负向观察前必须先读到真实子任务内容")
            let absent = NativeConsumerOwnedAX.hasNoIdentifier(
                in: host.window, prefix: "task-summary-child-session-"
            ) == true
            try #require(absent, "不可读取宿主 AX 树不等于入口不存在")
            #expect(absent)
        }
        }
    }

    @Test("无子会话身份的 child 行不伪造跳转入口")
    func childlessRowExposesNoAffordance() throws {
        try taskSummary255WithOwnedRoot { ownedRoot in
        // 未落子结果的排队任务：head 生产链该行 childSessionID == nil。
        let store = AgentTaskStore()
        let task = try store.enqueue(
            taskID: "plain-255-child",
            parentID: "plain-255-parent",
            providerID: "offline",
            modelID: "test",
            parentContextSnapshotID: "session-255-plain"
        )
        let row = try #require(
            TaskCenterControlConsumer(store: store)
                .receiptRows(now: Date(timeIntervalSince1970: 1_850_000_000))
                .first { $0.taskID == task.taskID }
        )
        #expect(row.childSessionID == nil)

        let host = taskSummary255MakeHost(TaskSummaryView(
            currentTaskID: row.parentID,
            taskSnapshots: [],
            receiptRows: [row]
        ))
        defer { taskSummary255CloseHost(host) }

        // 尽力展开详情区后，树内不得出现任何 child-session affordance identifier。
        taskSummary255PressChildDetailsToggle(host)
        taskSummary255Pump(host)
        #expect(
            taskSummary255FindAXPrefix(host.window, prefix: "task-summary-child-session-") == nil
        )
        _ = try #require(taskSummary255FindAX(host.window, identifier: "child-agent-counts"),
            "负向观察前必须先读到真实子任务内容")
        let absent = NativeConsumerOwnedAX.hasNoIdentifier(
            in: host.window, prefix: "task-summary-child-session-"
        ) == true
        try #require(absent, "不可读取宿主 AX 树不等于入口不存在")
        #expect(absent)
        }
    }
}

// MARK: - 注入 seam 的按压记录器

@MainActor
final class TaskSummary255NavigationRecorder {
    private(set) var received: [TaskCenterChildSessionNavigation] = []
    func record(_ navigation: TaskCenterChildSessionNavigation) {
        received.append(navigation)
    }
}

// MARK: - 宿主与原生 AX 读取（与冻结 TaskCenter / 190 纪律同款，本地私有副本）

@MainActor
private func taskSummary255MakeHost<V: View>(_ rootView: V) -> (window: NSWindow, view: NSView) {
    let hostLease = NativeTestHostLifecycle.begin("TaskSummary255")
    let controller = NSHostingController(
        rootView: AnyView(rootView.frame(width: 480, height: 640))
    )
    controller.sizingOptions = []
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 480, height: 640),
        styleMask: [.titled, .closable, .resizable],
        backing: .buffered,
        defer: false
    )
    NativeTestHostLifecycle.bind(hostLease, to: window)
    TaskSummary255OwnedHosts.windows.append(window)
    window.isReleasedWhenClosed = false
    window.contentViewController = controller
    let view = controller.view
    view.frame = NSRect(x: 0, y: 0, width: 480, height: 640)
    window.makeKeyAndOrderFront(nil)
    window.orderFrontRegardless()
    taskSummary255Pump((window, view))
    NativeTestHostLifecycle.observe(window, phase: "sampled")
    return (window, view)
}

@MainActor
private func taskSummary255CloseHost(_ host: (window: NSWindow, view: NSView)) {
    host.window.orderOut(nil)
    host.window.contentViewController = nil
    host.window.close()
    NativeTestHostLifecycle.end(host.window)
}

@MainActor
private func taskSummary255Pump(_ host: (window: NSWindow, view: NSView)) {
    for _ in 0..<6 {
        host.window.layoutIfNeeded()
        host.view.layoutSubtreeIfNeeded()
        host.view.display()
        _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.02))
    }
}

/// 「子任务详情」是 DisclosureGroup；折叠态下详情可能未进入布局。
/// 与真实用户一致：先找目标，找不到就按压详情开关，再找。
@MainActor
private func taskSummary255RevealChildDetails(
    _ host: (window: NSWindow, view: NSView),
    lookingFor identifier: String
) {
    for _ in 0..<3 {
        if taskSummary255FindAX(host.window, identifier: identifier) != nil { return }
        taskSummary255PressChildDetailsToggle(host)
        taskSummary255Pump(host)
    }
}

@MainActor
private func taskSummary255PressChildDetailsToggle(
    _ host: (window: NSWindow, view: NSView)
) {
    guard let toggle = taskSummary255FindAXLabel(host.window, label: "子任务详情") else {
        return
    }
    _ = taskSummary255AXPress(toggle)
}

@MainActor
private func taskSummary255FindAX(_ object: AnyObject, identifier: String) -> AnyObject? {
    var visited = Set<ObjectIdentifier>()
    var diagnostics: [String] = []
    let result = taskSummary255FindAX(
        object,
        identifier: identifier,
        visited: &visited,
        diagnostics: &diagnostics
    )
    let window = (object as? NSWindow) ?? (object as? NSView)?.window
    if let window, (result == nil || taskSummary255AXRole(result!) == nil),
       let publicNode = NativeConsumerOwnedAX.find(in: window, identifier: identifier) {
        return publicNode
    }
    if result == nil {
        print("TASKSUMMARY255_NATIVE_AX_MISSING identifier=\(identifier) visited=\(visited.count) samples=\(diagnostics.joined(separator: " || "))")
    }
    return result
}

@MainActor
private func taskSummary255FindAX(
    _ object: AnyObject,
    identifier: String,
    visited: inout Set<ObjectIdentifier>,
    diagnostics: inout [String]
) -> AnyObject? {
    let objectID = ObjectIdentifier(object)
    guard visited.insert(objectID).inserted else { return nil }
    if taskSummary255AXIdentifier(object) == identifier {
        return object
    }
    let ordered = taskSummary255RawAXChildren(
        of: object,
        attribute: .childrenInNavigationOrderAttribute
    )
    var children = ordered.isEmpty
        ? taskSummary255RawAXChildren(of: object, attribute: .children)
        : ordered
    if let view = object as? NSView { children += view.subviews }
    if let window = object as? NSWindow, let content = window.contentView {
        children.append(content.superview ?? content)
    }
    if diagnostics.count < 16,
       let line = taskSummary255AXDiagnosticLine(object, childCount: taskSummary255Flatten(children).count) {
        diagnostics.append(line)
    }
    for child in taskSummary255Flatten(children) {
        let childObject = child as AnyObject
        if let match = taskSummary255FindAX(
            childObject,
            identifier: identifier,
            visited: &visited,
            diagnostics: &diagnostics
        ) {
            return match
        }
    }
    return nil
}

@MainActor
private func taskSummary255FindAXPrefix(
    _ object: AnyObject,
    prefix: String
) -> AnyObject? {
    var visited = Set<ObjectIdentifier>()
    if let local = taskSummary255FindAXPrefix(object, prefix: prefix, visited: &visited) { return local }
    guard let window = (object as? NSWindow) ?? (object as? NSView)?.window else { return nil }
    return NativeConsumerOwnedAX.find(in: window, identifierPrefix: prefix)
}

@MainActor
private func taskSummary255FindAXPrefix(
    _ object: AnyObject,
    prefix: String,
    visited: inout Set<ObjectIdentifier>
) -> AnyObject? {
    let objectID = ObjectIdentifier(object)
    guard visited.insert(objectID).inserted else { return nil }
    if let identifier = taskSummary255AXIdentifier(object), identifier.hasPrefix(prefix) {
        return object
    }
    let ordered = taskSummary255RawAXChildren(
        of: object,
        attribute: .childrenInNavigationOrderAttribute
    )
    var children = ordered.isEmpty
        ? taskSummary255RawAXChildren(of: object, attribute: .children)
        : ordered
    if let view = object as? NSView { children += view.subviews }
    if let window = object as? NSWindow, let content = window.contentView {
        children.append(content.superview ?? content)
    }
    for child in taskSummary255Flatten(children) {
        let childObject = child as AnyObject
        if let match = taskSummary255FindAXPrefix(
            childObject,
            prefix: prefix,
            visited: &visited
        ) {
            return match
        }
    }
    return nil
}

@MainActor
private func taskSummary255FindAXLabel(
    _ object: AnyObject,
    label: String,
    visited: inout Set<ObjectIdentifier>
) -> AnyObject? {
    let objectID = ObjectIdentifier(object)
    guard visited.insert(objectID).inserted else { return nil }
    if taskSummary255AXLabel(object) == label { return object }
    let ordered = taskSummary255RawAXChildren(
        of: object,
        attribute: .childrenInNavigationOrderAttribute
    )
    var children = ordered.isEmpty
        ? taskSummary255RawAXChildren(of: object, attribute: .children)
        : ordered
    if let view = object as? NSView { children += view.subviews }
    if let window = object as? NSWindow, let content = window.contentView {
        children.append(content.superview ?? content)
    }
    for child in taskSummary255Flatten(children) {
        let childObject = child as AnyObject
        if let match = taskSummary255FindAXLabel(
            childObject,
            label: label,
            visited: &visited
        ) {
            return match
        }
    }
    return nil
}

@MainActor
private func taskSummary255FindAXLabel(_ object: AnyObject, label: String) -> AnyObject? {
    var visited = Set<ObjectIdentifier>()
    if let local = taskSummary255FindAXLabel(object, label: label, visited: &visited) { return local }
    guard let window = (object as? NSWindow) ?? (object as? NSView)?.window else { return nil }
    return NativeConsumerOwnedAX.find(in: window, label: label)
}

@MainActor
private func taskSummary255RawAXChildren(
    of object: AnyObject,
    attribute: NSAccessibility.Attribute
) -> [Any] {
    let unignoredFromObject = NSAccessibility.unignoredChildrenForOnlyChild(from: object)
    let selectorName = attribute == .childrenInNavigationOrderAttribute
        ? "accessibilityChildrenInNavigationOrder"
        : "accessibilityChildren"
    guard let value = taskSummary255RawAXGetter(object, selectorName: selectorName)
        ?? UF03LegacyAttribute(object as? NSObject, attribute) else {
        return unignoredFromObject
    }
    if let values = value as? NSArray {
        let raw = values.map { $0 }
        return raw + NSAccessibility.unignoredChildren(from: raw) + unignoredFromObject
    }
    return [value]
        + NSAccessibility.unignoredChildrenForOnlyChild(from: value)
        + unignoredFromObject
}

private func taskSummary255Flatten(_ children: [Any]) -> [Any] {
    children.flatMap { child in
        if let nested = child as? [Any] { return taskSummary255Flatten(nested) }
        if let nested = child as? NSArray { return taskSummary255Flatten(nested.map { $0 }) }
        return [child]
    }
}

@MainActor
private func taskSummary255RawAXGetter(_ object: AnyObject, selectorName: String) -> Any? {
    guard let object = object as? NSObject else { return nil }
    let selector = NSSelectorFromString(selectorName)
    guard object.responds(to: selector),
          let result = object.perform(selector) else { return nil }
    return result.takeUnretainedValue()
}

@MainActor
private func taskSummary255RawAXAttribute(
    _ object: AnyObject,
    _ attribute: NSAccessibility.Attribute
) -> Any? {
    UF03LegacyAttribute(object as? NSObject, attribute)
}

@MainActor
private func taskSummary255AXDiagnosticLine(_ object: AnyObject, childCount: Int) -> String? {
    let dynamicID = taskSummary255RawAXGetter(object, selectorName: "accessibilityIdentifier") as? String
    let legacyID = taskSummary255RawAXAttribute(object, .identifier) as? String
    let protocolID = (object as? NSAccessibilityProtocol)?.accessibilityIdentifier()
    let dynamicLabel = taskSummary255RawAXGetter(object, selectorName: "accessibilityLabel") as? String
    let legacyLabel = taskSummary255RawAXAttribute(object, .description) as? String
    let role = taskSummary255RawAXGetter(object, selectorName: "accessibilityRole")
        ?? taskSummary255RawAXAttribute(object, .role)
    let meaningful = [dynamicID, legacyID, protocolID, dynamicLabel, legacyLabel]
        .contains { !($0 ?? "").isEmpty }
    guard meaningful else { return nil }
    return "type=\(type(of: object)) dynamicID=\(dynamicID ?? "") legacyID=\(legacyID ?? "") protocolID=\(protocolID ?? "") dynamicLabel=\(dynamicLabel ?? "") role=\(String(describing: role)) childCount=\(childCount)"
}

@MainActor
private func taskSummary255AXIdentifier(_ object: AnyObject) -> String? {
    if let identifier = taskSummary255RawAXGetter(object, selectorName: "accessibilityIdentifier") as? String,
       !identifier.isEmpty {
        return identifier
    }
    if let identifier = taskSummary255RawAXAttribute(object, .identifier) as? String,
       !identifier.isEmpty {
        return identifier
    }
    if let identifier = (object as? NSAccessibilityProtocol)?.accessibilityIdentifier(),
       !identifier.isEmpty {
        return identifier
    }
    return nil
}

@MainActor
private func taskSummary255AXRole(_ object: AnyObject) -> NSAccessibility.Role? {
    if NativeConsumerOwnedAX.element(object) != nil { return NativeConsumerOwnedAX.role(object) }
    return (object as? NSAccessibilityProtocol)?.accessibilityRole()
        ?? taskSummary255RawAXAttribute(object, .role) as? NSAccessibility.Role
}

@MainActor
private func taskSummary255AXEnabled(_ object: AnyObject) -> Bool {
    if NativeConsumerOwnedAX.element(object) != nil { return NativeConsumerOwnedAX.enabled(object) ?? false }
    return (object as? NSAccessibilityProtocol)?.isAccessibilityEnabled()
        ?? (taskSummary255RawAXAttribute(object, .enabled) as? Bool)
        ?? false
}

@MainActor
private func taskSummary255AXLabel(_ object: AnyObject) -> String? {
    if NativeConsumerOwnedAX.element(object) != nil { return NativeConsumerOwnedAX.label(object) }
    return (object as? NSAccessibilityProtocol)?.accessibilityLabel()
        ?? taskSummary255RawAXAttribute(object, .description) as? String
}

@MainActor
private func taskSummary255AXPress(_ object: AnyObject) -> Bool {
    if NativeConsumerOwnedAX.element(object) != nil { return NativeConsumerOwnedAX.press(object) }
    if let accessibilityObject = object as? NSAccessibilityProtocol,
       accessibilityObject.accessibilityPerformPress() {
        return true
    }
    guard let object = object as? NSObject,
          (object.perform(NSSelectorFromString("accessibilityActionNames"))?.takeUnretainedValue() as? [String])?.contains(NSAccessibility.Action.press.rawValue) == true else { return false }
    _ = object.perform(NSSelectorFromString("accessibilityPerformAction:"), with: NSAccessibility.Action.press.rawValue)
    return true
}

// Tests-only fixture qualification. No production/store API changed.
@MainActor private enum TaskSummary255OwnedHosts {static var windows:[NSWindow]=[]}
@MainActor private func taskSummary255WithOwnedRoot(_ body:(URL)throws->Void)throws {
 guard let formal=try FormalTestIsolationPaths.resolveCurrentProcess() else{throw NSError(domain:"TaskSummary255FormalRootRequired",code:0)}
 let root=formal.rootDirectory.appendingPathComponent("TaskSummary255-"+UUID().uuidString,isDirectory:true)
 try FileManager.default.createDirectory(at:root,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
 var identity=stat();guard lstat(root.path,&identity)==0 && identity.st_mode & S_IFMT==S_IFDIR && identity.st_mode & 0o777==0o700 && identity.st_uid==geteuid() && identity.st_uid==formal.rootOwner && UInt64(identity.st_dev)==formal.rootDevice && UInt64(identity.st_ino) != formal.rootInode else{throw NSError(domain:"TaskSummary255OwnedRootIdentity",code:1)}
 TaskSummary255OwnedHosts.windows=[]
 print("TASKSUMMARY255_OWNED_BEGIN path=\(root.path) uid=\(identity.st_uid) dev=\(identity.st_dev) ino=\(identity.st_ino) mode700=true")
 let business=Result{try body(root)}
 let cleanup=Result<Void,Error>{
  guard TaskSummary255OwnedHosts.windows.allSatisfy({!$0.isVisible && $0.contentViewController==nil}) else{throw NSError(domain:"TaskSummary255HostNotClosed_ROOT_RETAINED",code:2)}
  var now=stat();guard lstat(root.path,&now)==0 && now.st_dev==identity.st_dev && now.st_ino==identity.st_ino && now.st_uid==identity.st_uid && now.st_mode & S_IFMT==S_IFDIR && now.st_mode & 0o777==0o700 else{throw NSError(domain:"TaskSummary255CleanupIdentity_ROOT_RETAINED",code:3)}
  try FileManager.default.removeItem(at:root)
  var missing=stat();guard lstat(root.path,&missing)<0 && errno==ENOENT else{throw NSError(domain:"TaskSummary255CleanupNotENOENT",code:4)}
  print("TASKSUMMARY255_OWNED_END hosts=\(TaskSummary255OwnedHosts.windows.count) closed=true cleanup_ENOENT=true")
  TaskSummary255OwnedHosts.windows=[]
 }
 switch (business,cleanup){case (.success,.success):return;case (.failure(let e),.success):throw e;case (.success,.failure(let e)):throw e;case (.failure(let b),.failure(let c)):throw NSError(domain:"TaskSummary255BusinessAndCleanup",code:5,userInfo:[NSLocalizedDescriptionKey:"business=\(b); cleanup=\(c)"])}
}
