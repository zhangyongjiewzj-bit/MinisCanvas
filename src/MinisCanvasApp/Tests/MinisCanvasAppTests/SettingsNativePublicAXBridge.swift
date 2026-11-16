import AppKit
import ApplicationServices
import Foundation

// Pure admission/type predicates, also consumed by the real mapping below.
// BEGIN_PURE_PREDICATES
struct SettingsNativePublicAXFacts {
    var ownPID: Int32
    var windowPID: Int32
    var targetPID: Int32
    var requestedID: String
    var actualID: String
    var expectedWindowID: String
    var actualWindowID: String
    var windowMatches: Int
    var targetMatches: Int
    var sameAXWindow: Bool
    var complete: Bool
    var withinBudget: Bool
}
enum SettingsNativePublicAXGate {
    static func admits(_ f: SettingsNativePublicAXFacts) -> Bool {
        f.ownPID > 0 && f.windowPID == f.ownPID && f.targetPID == f.ownPID
            && !f.requestedID.isEmpty && f.actualID == f.requestedID
            && !f.expectedWindowID.isEmpty && f.actualWindowID == f.expectedWindowID
            && f.windowMatches == 1 && f.targetMatches == 1 && f.sameAXWindow
            && f.complete && f.withinBudget
    }
    static func admitsIdentifier(_ identifier: String, refreshRoleOnly: Bool) -> Bool {
        if refreshRoleOnly {
            return identifier == "mcp.server.6e-61-74-69-76-65-2d-6d-63-70-33-30-31-33.tools.refresh"
        }
        return identifier.hasPrefix("mcp.server.") && identifier.hasSuffix(".tools.disclosure")
    }
    static func strictString(status: Int32, value: CFTypeRef?) -> String? {
        guard status == 0, let value, CFGetTypeID(value) == CFStringGetTypeID(),
              let text = value as? String, !text.isEmpty else { return nil }
        return text
    }
    static func disclosureState(valueStatus: Int32, value: CFTypeRef?,
                                descriptionStatus: Int32, valueDescription: CFTypeRef?) -> String? {
        let observed: String?
        if valueStatus == 0 {
            observed = strictString(status: valueStatus, value: value)
        } else if valueStatus == -25212 {
            observed = strictString(status: descriptionStatus, value: valueDescription)
        } else {
            return nil
        }
        guard let observed, ["已收起", "已展开"].contains(observed) else { return nil }
        return observed
    }
    static func admitsStateRead(sameWindow: Bool, sameID: Bool,
                               sameElement: Bool, withinBudget: Bool) -> Bool {
        sameWindow && sameID && sameElement && withinBudget
    }
    static func distinctCF(_ values: [CFTypeRef]) -> [CFTypeRef] {
        var result: [CFTypeRef] = []
        for value in values where !result.contains(where: { CFEqual($0, value) }) {
            result.append(value)
        }
        return result
    }
}
// END_PURE_PREDICATES

/// One test-only read channel for the observed MCP disclosure proxy. It does
/// not implement actions, synthesize a value, accept Bool as String or search
/// another window. The original test continues to assert the real AX reads.
@MainActor
enum SettingsNativePublicAXBridge {
    // An ephemeral same-call observation admission, not a state cache. Its
    // reader re-reads the real attributes; a receipt is consumed once, and
    // cannot be reused after a press/new finder lookup/window change.
    private struct Admission {
        weak var window: NSWindow?
        let windowID: String
        let identifier: String
        let target: AXUIElement
        let deadline: TimeInterval
        let readState: @MainActor () -> String?
    }
    private static var admission: Admission?
    private final class WeakWindowReference {
        weak var window: NSWindow?
        init(_ window: NSWindow) { self.window = window }
    }
    static func invalidate() { admission = nil }

    static func stateValue(_ object: AnyObject, in window: NSWindow, identifier: String) -> String? {
        let receipt = admission
        admission = nil
        guard let receipt,
              SettingsNativePublicAXGate.admitsStateRead(
                sameWindow: receipt.window === window && window.accessibilityIdentifier() == receipt.windowID,
                sameID: receipt.identifier == identifier,
                sameElement: CFGetTypeID(object) == AXUIElementGetTypeID() && CFEqual(object, receipt.target),
                withinBudget: ProcessInfo.processInfo.systemUptime < receipt.deadline) else { return nil }
        return receipt.readState()
    }

    static func disclosure(in window: NSWindow, identifier: String) -> AnyObject? {
        mappedElement(in: window, identifier: identifier, refreshRoleOnly: false)
    }

    // Only the observed native-mcp3013 refresh proxy; no state/action adapter.
    static func refresh(in window: NSWindow, identifier: String) -> AnyObject? {
        mappedElement(in: window, identifier: identifier, refreshRoleOnly: true)
    }

    // Exact Shortcut search only. Mapping performs no action or state write;
    // original replaceSettingsText consumes the actual role/settable/value.
    static func shortcutSearch(in window: NSWindow, identifier: String) -> AnyObject? {
        mappedElement(in: window, identifier: identifier, refreshRoleOnly: false, shortcutSearchOnly: true)
    }

    private static func mappedElement(in window: NSWindow, identifier: String,
                                      refreshRoleOnly: Bool, shortcutSearchOnly: Bool = false) -> AnyObject? {
        admission = nil
        let ownPID = getpid()
        let expectedWindowID = window.accessibilityIdentifier()
        guard window.windowNumber > 0, window.contentView != nil,
              NSApplication.shared.windows.contains(where: { $0 === window }),
              !expectedWindowID.isEmpty, window.sheets.isEmpty,
              (shortcutSearchOnly ? identifier == "settings.shortcuts.search"
                : SettingsNativePublicAXGate.admitsIdentifier(identifier, refreshRoleOnly: refreshRoleOnly)) else { return nil }
        let end = ProcessInfo.processInfo.systemUptime + 2
        var complete = true
        func inBudget() -> Bool { ProcessInfo.processInfo.systemUptime < end }
        func pid(_ e: AXUIElement) -> pid_t? {
            guard inBudget() else { complete = false; return nil }
            var observed: pid_t = -1
            let status = AXUIElementGetPid(e, &observed)
            guard status == .success else {
                print("SETTINGS_PUBLIC_AX_PID status=\(status.rawValue)")
                complete = false; return nil
            }
            return observed
        }
        var lastCopyCalled = false
        func read(_ e: AXUIElement, _ name: CFString) -> (AXError, CFTypeRef?) {
            lastCopyCalled = false
            guard inBudget() else {
                complete = false
                print("SETTINGS_PUBLIC_AX_BUDGET_REFUSED noRPC=true")
                return (.cannotComplete, nil)
            }
            let timeoutStatus = AXUIElementSetMessagingTimeout(e, 0.05)
            guard timeoutStatus == .success else {
                complete = false
                print("SETTINGS_PUBLIC_AX_TIMEOUT_SETUP status=\(timeoutStatus.rawValue)")
                return (timeoutStatus, nil)
            }
            // Exact SDK ABI: borrowed CFString input and retained CFTypeRef? out.
            var raw: CFTypeRef?
            lastCopyCalled = true
            let status = AXUIElementCopyAttributeValue(e, name, &raw)
            print("SETTINGS_PUBLIC_AX_READ attribute=\(name) status=\(status.rawValue) cfType=\(raw.map { CFGetTypeID($0) } ?? 0)")
            return (status, raw)
        }
        func text(_ e: AXUIElement, _ name: CFString) -> String? {
            let (status, raw) = read(e, name)
            return SettingsNativePublicAXGate.strictString(status: status.rawValue, value: raw)
        }
        func elements(_ raw: CFTypeRef?) -> [AXUIElement]? {
            guard let raw, CFGetTypeID(raw) == CFArrayGetTypeID(),
                  let values = raw as? [AnyObject],
                  values.allSatisfy({ CFGetTypeID($0) == AXUIElementGetTypeID() }) else { return nil }
            return values.map { unsafeDowncast($0, to: AXUIElement.self) }
        }
        let application = AXUIElementCreateApplication(ownPID)
        guard pid(application) == ownPID else { return nil }
        let (windowsStatus, windowsRaw) = read(application, kAXWindowsAttribute as CFString)
        guard windowsStatus == .success, let windows = elements(windowsRaw), windows.count <= 16 else { return nil }
        var owners: [AXUIElement] = []
        for candidate in windows {
            guard pid(candidate) == ownPID else { return nil }
            let (idStatus, rawID) = read(candidate, kAXIdentifierAttribute as CFString)
            if idStatus == .attributeUnsupported || idStatus == .noValue { continue }
            guard idStatus == .success,
                  let candidateID = SettingsNativePublicAXGate.strictString(status: idStatus.rawValue, value: rawID) else { return nil }
            if candidateID == expectedWindowID { owners.append(candidate) }
        }
        // Distinct CFEqual identity, never hash-only or first-match selection.
        let uniqueOwners = SettingsNativePublicAXGate.distinctCF(owners.map { $0 as CFTypeRef })
        guard uniqueOwners.count == 1,
              let owner = uniqueOwners.first.map({ unsafeDowncast($0, to: AXUIElement.self) }),
              text(owner, kAXRoleAttribute as CFString) == (kAXWindowRole as String) else { return nil }
        var queue: [(AXUIElement, Int)] = [(owner, 0)]
        var visited: [AXUIElement] = []
        var hits: [AXUIElement] = []
        var index = 0
        while index < queue.count {
            guard inBudget(), visited.count < 2048 else { complete = false; break }
            let (node, depth) = queue[index]; index += 1
            if visited.contains(where: { CFEqual($0, node) }) { continue }
            visited.append(node)
            guard pid(node) == ownPID else { complete = false; break }
            let (idStatus, rawID) = read(node, kAXIdentifierAttribute as CFString)
            if idStatus == .success {
                guard let rawID, CFGetTypeID(rawID) == CFStringGetTypeID() else { complete = false; break }
                if (rawID as? String) == identifier { hits.append(node) }
            } else if idStatus != .attributeUnsupported && idStatus != .noValue {
                complete = false; break
            }
            let (status, raw) = read(node, kAXChildrenAttribute as CFString)
            // Explicit provider NONE codes follow the accepted B0519 exporter
            // convention; unexpected errors/type mismatch are never empty tree.
            if status == .attributeUnsupported || status == .noValue { continue }
            guard status == .success, let children = elements(raw), children.count <= 2048,
                  depth < 24 || children.isEmpty,
                  queue.count + children.count <= 4096 else { complete = false; break }
            queue.append(contentsOf: children.map { ($0, depth + 1) })
        }
        complete = complete && index == queue.count
        guard hits.count == 1, let target = hits.first else { return nil }
        let (targetWindowStatus, targetWindowRaw) = read(target, kAXWindowAttribute as CFString)
        guard targetWindowStatus == .success, let targetWindowRaw,
              CFGetTypeID(targetWindowRaw) == AXUIElementGetTypeID() else { return nil }
        let actualID = text(target, kAXIdentifierAttribute as CFString) ?? ""
        let actualWindowID = text(owner, kAXIdentifierAttribute as CFString) ?? ""
        let facts = SettingsNativePublicAXFacts(ownPID: ownPID,
            windowPID: pid(owner) ?? -1, targetPID: pid(target) ?? -1,
            requestedID: identifier, actualID: actualID,
            expectedWindowID: expectedWindowID, actualWindowID: actualWindowID,
            windowMatches: uniqueOwners.count, targetMatches: hits.count,
            sameAXWindow: CFEqual(targetWindowRaw, owner),
            complete: complete, withinBudget: inBudget())
        guard SettingsNativePublicAXGate.admits(facts) else { return nil }
        if refreshRoleOnly || shortcutSearchOnly {
            // Same complete/unique own-window target; preserve the actual role.
            // AXUnknown or another nonempty CFString is returned as-is to the
            // unchanged original role getter/assertion, never mapped to AXButton.
            let (roleStatus, roleRaw) = read(target, kAXRoleAttribute as CFString)
            let roleCopyCalled = lastCopyCalled
            let role = SettingsNativePublicAXGate.strictString(status: roleStatus.rawValue, value: roleRaw)
            let record: [String: Any] = ["identifier": identifier, "pid": ownPID,
                "windowNumber": window.windowNumber, "copyAttributeValueCalled": roleCopyCalled,
                "status": roleCopyCalled ? roleStatus.rawValue as Any : NSNull(),
                "readRefusalStatus": roleCopyCalled ? NSNull() : roleStatus.rawValue as Any,
                "roleCFType": roleRaw.map { CFGetTypeID($0) } ?? 0,
                "actualRole": role.map { $0 as Any } ?? NSNull()]
            if let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]),
               let line = String(data: data, encoding: .utf8) {
                print((shortcutSearchOnly ? "SETTINGS_SHORTCUT_SEARCH_PUBLIC_AX_ROLE=" : "SETTINGS_REFRESH_PUBLIC_AX_ROLE=") + line)
            }
            guard role != nil, complete, inBudget() else { return nil }
            return target as AnyObject
        }
        func literal(_ raw: CFTypeRef?) -> Any {
            guard let raw else { return NSNull() }
            if CFGetTypeID(raw) == CFStringGetTypeID(), let string = raw as? String { return string }
            if CFGetTypeID(raw) == CFBooleanGetTypeID(), let bool = raw as? Bool { return bool }
            if CFGetTypeID(raw) == CFNumberGetTypeID(), let number = raw as? NSNumber { return number }
            return String(reflecting: raw)
        }
        let observedWindow = WeakWindowReference(window)
        func observeState() -> String? {
            guard let window = observedWindow.window else { return nil }
            // Revalidate the same admitted element/window before each real read.
            guard inBudget(), pid(owner) == ownPID, pid(target) == ownPID,
                  window.accessibilityIdentifier() == expectedWindowID,
                  text(target, kAXIdentifierAttribute as CFString) == identifier,
                  text(owner, kAXIdentifierAttribute as CFString) == expectedWindowID else { return nil }
            let (windowStatus, windowRaw) = read(target, kAXWindowAttribute as CFString)
            guard windowStatus == .success, let windowRaw,
                  CFGetTypeID(windowRaw) == AXUIElementGetTypeID(), CFEqual(windowRaw, owner) else { return nil }
            let (roleStatus, roleRaw) = read(target, kAXRoleAttribute as CFString)
            let roleCopyCalled = lastCopyCalled
            guard inBudget() else { return nil }
            var namesRaw: CFArray?
            let namesStatus = AXUIElementCopyAttributeNames(target, &namesRaw)
            var records: [[String: Any]] = []
            var valueRead: (AXError, CFTypeRef?) = (.noValue, nil)
            var descriptionRead: (AXError, CFTypeRef?) = (.noValue, nil)
            // Description/Title/Help are observation only, never state sources.
            for name in [kAXValueAttribute, kAXValueDescriptionAttribute,
                         kAXDescriptionAttribute, kAXTitleAttribute, kAXHelpAttribute] {
                let result = read(target, name as CFString)
                let copyCalled = lastCopyCalled
                records.append(["attribute": name,
                    "copyAttributeValueCalled": copyCalled,
                    "status": copyCalled ? result.0.rawValue as Any : NSNull(),
                    "readRefusalStatus": copyCalled ? NSNull() : result.0.rawValue as Any,
                    "cfType": result.1.map { CFGetTypeID($0) } ?? 0, "actualValue": literal(result.1)])
                if name == kAXValueAttribute { valueRead = result }
                if name == kAXValueDescriptionAttribute { descriptionRead = result }
            }
            let record: [String: Any] = ["identifier": identifier, "pid": ownPID,
                "windowNumber": window.windowNumber, "windowIdentifier": expectedWindowID,
                "roleCopyCalled": roleCopyCalled,
                "roleStatus": roleCopyCalled ? roleStatus.rawValue as Any : NSNull(),
                "roleReadRefusalStatus": roleCopyCalled ? NSNull() : roleStatus.rawValue as Any,
                "roleCFType": roleRaw.map { CFGetTypeID($0) } ?? 0,
                "roleActualValue": literal(roleRaw), "attributeNamesStatus": namesStatus.rawValue,
                "attributeNamesCFType": namesRaw.map { CFGetTypeID($0) } ?? 0,
                "attributeNames": (namesRaw as? [String]).map { $0 as Any } ?? NSNull(),
                "attributes": records, "observationalOnlyNoActions": true]
            if let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]),
               let encoded = String(data: data, encoding: .utf8) {
                print("SETTINGS_PUBLIC_AX_SEMANTICS=" + encoded)
            }
            guard complete, inBudget(),
                  SettingsNativePublicAXGate.strictString(status: roleStatus.rawValue, value: roleRaw) != nil else { return nil }
            return SettingsNativePublicAXGate.disclosureState(
                valueStatus: valueRead.0.rawValue, value: valueRead.1,
                descriptionStatus: descriptionRead.0.rawValue, valueDescription: descriptionRead.1)
        }
        // Actual successful CFString from AXValue, or only NoValue(-25212)
        // permits AXValueDescription. No label/Bool/empty/default synthesis.
        guard observeState() != nil, inBudget() else { return nil }
        admission = Admission(window: window, windowID: expectedWindowID, identifier: identifier,
                              target: target, deadline: end, readState: observeState)
        print("SETTINGS_PUBLIC_AX_MAP pid=\(ownPID) windowNumber=\(window.windowNumber) identifier=\(identifier) unique=true complete=\(complete) sameWindow=true")
        return target as AnyObject
    }
}
