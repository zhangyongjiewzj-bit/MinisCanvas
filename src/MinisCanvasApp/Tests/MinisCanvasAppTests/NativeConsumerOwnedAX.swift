import AppKit
import ApplicationServices
import CryptoKit
import Darwin
@testable import MinisCanvasApp

/// Test-only extraction of SchedulerControlSettingsTests' public AX channel.
/// Reads our PID and the exact host (including its attached sheets), never an
/// arbitrary foreground window. Missing, ambiguous or truncated reads stay nil.
@MainActor
enum NativeConsumerOwnedAX {
    // Observation only: one failed row/restore query per synthetic identifier.
    private static var diagnosedRowQueries = Set<String>()
    static func element(_ object: AnyObject) -> AXUIElement? {
        guard CFGetTypeID(object) == AXUIElementGetTypeID() else { return nil }
        return unsafeDowncast(object, to: AXUIElement.self)
    }

    static func attribute(_ object: AnyObject, _ name: CFString) -> CFTypeRef? {
        guard let element = element(object) else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name, &value) == .success else { return nil }
        return value
    }

    static func role(_ object: AnyObject) -> NSAccessibility.Role? {
        guard let value = attribute(object, kAXRoleAttribute as CFString) as? String else { return nil }
        return NSAccessibility.Role(rawValue: value)
    }

    static func enabled(_ object: AnyObject) -> Bool? {
        attribute(object, kAXEnabledAttribute as CFString) as? Bool
    }

    static func label(_ object: AnyObject) -> String? {
        if let existing = labels(object).first { return existing }
        // Real Goal AXStaticText exposed its human text as AXValue with
        // success, while Description/Title were NoValue. Do not convert a
        // control's Bool/number value, or use Value for any other role.
        guard role(object) == .staticText,
              let raw = attribute(object, kAXValueAttribute as CFString),
              CFGetTypeID(raw) == CFStringGetTypeID(),
              let text = raw as? String, !text.isEmpty else { return nil }
        return text
    }

    static func press(_ object: AnyObject) -> Bool {
        guard let element = element(object) else { return false }
        let status = AXUIElementPerformAction(element, kAXPressAction as CFString)
        print("NATIVE_CONSUMER_AXPRESS action=AXPress status=\(status.rawValue) callerPID=\(getpid()) targetCFType=\(CFGetTypeID(element))")
        return status == .success
    }

    static func frame(_ object: AnyObject) -> CGRect? {
        guard let rawPosition = attribute(object, kAXPositionAttribute as CFString),
              let rawSize = attribute(object, kAXSizeAttribute as CFString),
              CFGetTypeID(rawPosition) == AXValueGetTypeID(),
              CFGetTypeID(rawSize) == AXValueGetTypeID() else { return nil }
        let position = unsafeDowncast(rawPosition, to: AXValue.self)
        let size = unsafeDowncast(rawSize, to: AXValue.self)
        var point = CGPoint.zero
        var extent = CGSize.zero
        guard AXValueGetValue(position, .cgPoint, &point),
              AXValueGetValue(size, .cgSize, &extent) else { return nil }
        return CGRect(origin: point, size: extent)
    }

    static func find(in window: NSWindow, identifier: String) -> AnyObject? {
        find(in: window, description: "identifier=\(identifier)") {
            (attribute($0, kAXIdentifierAttribute as CFString) as? String) == identifier
        }
    }

    static func find(
        in window: NSWindow, label: String, pressable: Bool = false, textField: Bool = false
    ) -> AnyObject? {
        find(in: window, description: "label=\(label)") { object in
            labels(object).contains { $0.contains(label) }
                && (!pressable || role(object) == .button)
                && (!textField || role(object) == .textField)
        }
    }

    /// Read-only body assertion. AXValue is admitted only for displayed text,
    /// never as a fallback for labels used to locate or press controls.
    static func findDisplayedText(in window: NSWindow, exactText: String) -> AnyObject? {
        find(in: window, description: "displayed-text-exact") { object in
            guard role(object) == .staticText || role(object) == .textArea,
                  let raw = attribute(object, kAXValueAttribute as CFString),
                  CFGetTypeID(raw) == CFStringGetTypeID(),
                  let text = raw as? String else { return false }
            return Data(text.utf8) == Data(exactText.utf8)
        }
    }

    static func find(in window: NSWindow, identifierPrefix: String,
                     excludingPrefix: String? = nil) -> AnyObject? {
        find(in: window, description: "prefix=\(identifierPrefix)") {
            guard let id = attribute($0, kAXIdentifierAttribute as CFString) as? String else { return false }
            return id.hasPrefix(identifierPrefix)
                && !(excludingPrefix.map { id.hasPrefix($0) } ?? false)
        }
    }

    /// Negative assertions require a complete read. nil means unobservable,
    /// never "absent"; multiple matching controls likewise cannot become PASS.
    static func hasNoIdentifier(in window: NSWindow, prefix: String) -> Bool? {
        matchingElements(in: window, description: "absence-prefix=\(prefix)") {
            (attribute($0, kAXIdentifierAttribute as CFString) as? String)?
                .hasPrefix(prefix) == true
        }?.isEmpty
    }

    /// Explicit attached-sheet channel. It never substitutes a global window
    /// for an unreadable root; a nil result remains unobservable, not absent.
    static func find(inAttachedSheet sheet: NSWindow, of parent: NSWindow,
                     identifier: String) -> AnyObject? {
        find(inAttachedSheet: sheet, of: parent, description: identifier) {
            (attribute($0, kAXIdentifierAttribute as CFString) as? String) == identifier
        }
    }

    static func find(inAttachedSheet sheet: NSWindow, of parent: NSWindow,
                     description: String, matches: (AnyObject) -> Bool) -> AnyObject? {
        let parentID = parent.accessibilityIdentifier()
        guard parent.sheets.count == 1, parent.sheets.first === sheet,
              sheet.sheetParent === parent, sheet.contentView != nil,
              !parentID.isEmpty else {
            print("NATIVE_CONSUMER_ATTACHED_AX stage=appkit status=OWNERSHIP_REFUSED")
            return nil
        }
        let existingID = sheet.accessibilityIdentifier()
        let sheetID = existingID.isEmpty
            ? "native-consumer-sheet-\(UUID().uuidString)" : existingID
        sheet.setAccessibilityIdentifier(sheetID)
        let application = AXUIElementCreateApplication(getpid())
        guard AXUIElementSetMessagingTimeout(application, 0.05) == .success else { return nil }
        var rawWindows: CFTypeRef?
        let windowsStatus = AXUIElementCopyAttributeValue(
            application, kAXWindowsAttribute as CFString, &rawWindows)
        guard windowsStatus == .success, let windows = rawWindows as? [AXUIElement],
              windows.count <= 16 else {
            print("NATIVE_CONSUMER_ATTACHED_AX stage=windows status=\(windowsStatus.rawValue) readable=false")
            return nil
        }
        let parents = windows.filter {
            _ = AXUIElementSetMessagingTimeout($0, 0.05)
            return (attribute($0, kAXIdentifierAttribute as CFString) as? String) == parentID
        }
        let sheetWindowCount = windows.filter {
            (attribute($0, kAXIdentifierAttribute as CFString) as? String) == sheetID
        }.count
        print("NATIVE_CONSUMER_ATTACHED_AX stage=windows parentMatches=\(parents.count) sheetIDMatches=\(sheetWindowCount)")
        guard parents.count == 1, let owner = parents.first else { return nil }
        var rawSheets: CFTypeRef?
        let sheetsStatus = AXUIElementCopyAttributeValue(owner, "AXSheets" as CFString, &rawSheets)
        let roots: [AXUIElement]
        if sheetsStatus == .attributeUnsupported {
            var rawChildren: CFTypeRef?
            guard AXUIElementCopyAttributeValue(owner, kAXChildrenAttribute as CFString, &rawChildren) == .success,
                  let children = rawChildren as? [AXUIElement], children.count <= 16 else {
                print("NATIVE_CONSUMER_ATTACHED_AX stage=direct-children status=UNAVAILABLE")
                return nil
            }
            var sheets: [AXUIElement] = []
            for child in children {
                guard AXUIElementSetMessagingTimeout(child, 0.05) == .success,
                      let childRole = attribute(child, kAXRoleAttribute as CFString) as? String else {
                    print("NATIVE_CONSUMER_ATTACHED_AX stage=direct-children status=ROLE_UNAVAILABLE")
                    return nil
                }
                if childRole == kAXSheetRole as String { sheets.append(child) }
            }
            guard sheets.count == 1 else {
                print("NATIVE_CONSUMER_ATTACHED_AX stage=direct-children status=NONUNIQUE_SHEET count=\(sheets.count)")
                return nil
            }
            roots = sheets
        } else {
            guard sheetsStatus == .success, let sheets = rawSheets as? [AXUIElement] else {
                print("NATIVE_CONSUMER_ATTACHED_AX stage=sheets status=\(sheetsStatus.rawValue) bound=false")
                return nil
            }
            roots = sheets
        }
        guard roots.count == 1, let root = roots.first else { return nil }
        guard AXUIElementSetMessagingTimeout(root, 0.05) == .success else { return nil }
        var rawID: CFTypeRef?
        let idStatus = AXUIElementCopyAttributeValue(root, kAXIdentifierAttribute as CFString, &rawID)
        let projectedID = rawID as? String
        let idReadable = (idStatus == .success && projectedID != nil)
            || idStatus == .attributeUnsupported || idStatus == .noValue
        let idMatches = projectedID.map { $0.isEmpty || $0 == sheetID } ?? true
        var rawRole: CFTypeRef?
        let roleStatus = AXUIElementCopyAttributeValue(root, kAXRoleAttribute as CFString, &rawRole)
        let roleMatches = roleStatus == .success && (rawRole as? String) == (kAXSheetRole as String)
        let wireFrame = frame(root)
        if wireFrame == nil {
            for name in [kAXPositionAttribute, kAXSizeAttribute] {
                var rawFrameValue: CFTypeRef?
                let status = AXUIElementCopyAttributeValue(root, name as CFString, &rawFrameValue)
                print("NATIVE_CONSUMER_ATTACHED_AX stage=frame attribute=\(name) status=\(status.rawValue) valuePresent=\(rawFrameValue != nil)")
            }
        }
        let actualFrame = wireFrame.flatMap {
            UF03AXScreenCoordinates.appKitFrame(position: $0.origin, size: $0.size,
                zeroScreenFrame: NSScreen.screens.first?.frame)
        }
        let frameMatches = actualFrame == sheet.frame
        print("NATIVE_CONSUMER_ATTACHED_AX stage=sheet-binding idStatus=\(idStatus.rawValue) idReadable=\(idReadable) idMatches=\(idMatches) roleStatus=\(roleStatus.rawValue) roleMatches=\(roleMatches) wireFrame=\(String(describing: wireFrame)) appKitFrame=\(String(describing: actualFrame)) expectedFrame=\(sheet.frame) frameMatches=\(frameMatches)")
        // A SwiftUI AXSheet may omit the NSWindow's identifier. Its direct
        // relation to the exact parent, sole AppKit/AX sheet, role and exact
        // converted frame must still bind it to this actual NSWindow. A
        // projected conflicting ID, unreadable frame or AX error is refusal.
        guard idReadable, idMatches, roleMatches, frameMatches else { return nil }

        var queue: [(AXUIElement, Int)] = [(root, 0)]
        var visited: [AXUIElement] = []
        var hits: [AXUIElement] = []
        var index = 0
        var incomplete = false
        while index < queue.count && visited.count < 2048 {
            let (node, depth) = queue[index]
            index += 1
            guard !visited.contains(where: { CFEqual($0, node) }) else { continue }
            visited.append(node)
            guard AXUIElementSetMessagingTimeout(node, 0.05) == .success else {
                incomplete = true
                continue
            }
            if matches(node) {
                hits.append(node)
            }
            var rawChildren: CFTypeRef?
            let status = AXUIElementCopyAttributeValue(node, kAXChildrenAttribute as CFString, &rawChildren)
            if status == .attributeUnsupported || status == .noValue { continue }
            guard status == .success, let children = rawChildren as? [AXUIElement] else {
                print("NATIVE_CONSUMER_ATTACHED_AX stage=children status=\(status.rawValue) depth=\(depth) readable=false")
                incomplete = true
                continue
            }
            guard depth < 24 || children.isEmpty else { incomplete = true; continue }
            queue.append(contentsOf: children.map { ($0, depth + 1) })
        }
        incomplete = incomplete || index < queue.count
        print("NATIVE_CONSUMER_ATTACHED_AX stage=target identifier=\(description) visited=\(visited.count) matches=\(hits.count) incomplete=\(incomplete)")
        guard !incomplete, hits.count == 1 else { return nil }
        return hits[0]
    }

    /// Complete text-only snapshot of one uniquely owned subtree. No AX/view
    /// object escapes; unreadable or truncated trees cannot prove absence.
    static func textSnapshot(in window: NSWindow, identifier: String) -> (texts: [String], labelsByIdentifier: [String: [String]])? {
        guard let root = find(in: window, identifier: identifier), let element = element(root) else { return nil }
        var queue: [(AXUIElement, Int)] = [(element, 0)]
        var visited: [AXUIElement] = []
        var output: [String] = []
        var labelsByIdentifier: [String: [String]] = [:]
        var index = 0
        while index < queue.count {
            guard visited.count < 2048 else { return nil }
            let (node, depth) = queue[index]
            index += 1
            guard !visited.contains(where: { CFEqual($0, node) }) else { continue }
            visited.append(node)
            guard AXUIElementSetMessagingTimeout(node, 0.05) == .success else { return nil }
            if let id = attribute(node, kAXIdentifierAttribute as CFString) as? String {
                // Keep every identified node, including missing-label nodes, so
                // duplicate IDs cannot disappear from the uniqueness check.
                labelsByIdentifier[id, default: []].append(label(node) ?? "")
            }
            for name in [kAXDescriptionAttribute, kAXTitleAttribute, kAXPlaceholderValueAttribute, kAXValueAttribute] {
                var value: CFTypeRef?
                let status = AXUIElementCopyAttributeValue(node, name as CFString, &value)
                if status == .attributeUnsupported || status == .noValue { continue }
                guard status == .success else { return nil }
                if let text = value as? String, !text.isEmpty { output.append(text) }
            }
            var rawChildren: CFTypeRef?
            let status = AXUIElementCopyAttributeValue(node, kAXChildrenAttribute as CFString, &rawChildren)
            if status == .attributeUnsupported || status == .noValue { continue }
            guard status == .success, let children = rawChildren as? [AXUIElement],
                  depth < 24 || children.isEmpty else { return nil }
            queue.append(contentsOf: children.map { ($0, depth + 1) })
        }
        return (output, labelsByIdentifier)
    }

    private static func labels(_ object: AnyObject) -> [String] {
        [kAXDescriptionAttribute, kAXTitleAttribute, kAXPlaceholderValueAttribute]
            .compactMap { attribute(object, $0 as CFString) as? String }
            .filter { !$0.isEmpty }
    }

    private static func find(
        in window: NSWindow, description: String, matches: (AnyObject) -> Bool
    ) -> AnyObject? {
        guard let hits = matchingElements(in: window, description: description, matches: matches),
              hits.count == 1 else { return nil }
        return hits[0]
    }

    private static func matchingElements(
        in window: NSWindow, description: String, matches: (AnyObject) -> Bool
    ) -> [AXUIElement]? {
        let ownerID = window.accessibilityIdentifier()
        window.setAccessibilityIdentifier(ownerID)
        let application = AXUIElementCreateApplication(getpid())
        guard AXUIElementSetMessagingTimeout(application, 0.05) == .success else { return nil }
        var rawWindows: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            application, kAXWindowsAttribute as CFString, &rawWindows
        ) == .success, let windows = rawWindows as? [AXUIElement], windows.count <= 16 else {
            print("NATIVE_CONSUMER_OWNED_AX \(description) status=WINDOWS_UNREADABLE")
            return nil
        }
        let owners = windows.filter {
            _ = AXUIElementSetMessagingTimeout($0, 0.05)
            return (attribute($0, kAXIdentifierAttribute as CFString) as? String) == ownerID
        }
        guard owners.count == 1, let owner = owners.first else {
            print("NATIVE_CONSUMER_OWNED_AX \(description) status=OWNER_NOT_UNIQUE count=\(owners.count)")
            return nil
        }
        // AppKit proves sheet ownership. Some sheets are separate AXWindows,
        // others are children of the owner; read only those explicit identities.
        let sheetIDs = window.sheets.map { sheet in
            let identifier = sheet.accessibilityIdentifier()
            sheet.setAccessibilityIdentifier(identifier)
            return identifier
        }
        var ownedSheets: [AXUIElement] = []
        for identifier in sheetIDs {
            let sheets = windows.filter {
                (attribute($0, kAXIdentifierAttribute as CFString) as? String) == identifier
            }
            guard sheets.count <= 1 else { return nil }
            ownedSheets.append(contentsOf: sheets)
        }
        var queue: [(AXUIElement, Int)] = ([owner] + ownedSheets).map { ($0, 0) }
        var visited: [AXUIElement] = []
        var hits: [AXUIElement] = []
        var index = 0
        var incomplete = false
        while index < queue.count && visited.count < 2048 {
            let (node, depth) = queue[index]
            index += 1
            // CFHash alone is not identity; distinct nodes may share a hash.
            guard !visited.contains(where: { CFEqual($0, node) }) else { continue }
            visited.append(node)
            _ = AXUIElementSetMessagingTimeout(node, 0.05)
            if matches(node) { hits.append(node) }
            for name in [kAXChildrenAttribute] {
                var rawChildren: CFTypeRef?
                let status = AXUIElementCopyAttributeValue(node, name as CFString, &rawChildren)
                if status == .attributeUnsupported || status == .noValue { continue }
                guard status == .success, let children = rawChildren as? [AXUIElement] else {
                    print("NATIVE_CONSUMER_OWNED_AX_CHILDREN_FAILURE statusRaw=\(status.rawValue) castFailed=\(status == .success)")
                    incomplete = true
                    continue
                }
                guard depth < 24 || children.isEmpty else { incomplete = true; continue }
                queue.append(contentsOf: children.map { ($0, depth + 1) })
            }
        }
        incomplete = incomplete || index < queue.count
        print("NATIVE_CONSUMER_OWNED_AX \(description) visited=\(visited.count) matches=\(hits.count) incomplete=\(incomplete)")
        let restorePrefix = "identifier=chat.sidebar.archive.restore."
        let restoreSessionID = description.hasPrefix(restorePrefix)
            ? UUID(uuidString: String(description.dropFirst(restorePrefix.count))) : nil
        let missingRestore = restoreSessionID != nil && hits.count != 1
        let ambiguousRow = hits.count > 1 && description.hasPrefix("identifier=chat.session.row.")
        if !incomplete, ambiguousRow || missingRestore,
           diagnosedRowQueries.insert(description).inserted {
            // Same observed tree only; no second traversal or node selection.
            // Attribute fingerprints distinguish inherited labels without printing text.
            func textMetadata(_ node: AXUIElement, _ name: CFString) -> [String: Any] {
                guard let value = attribute(node, name) as? String else {
                    return ["readable": false]
                }
                let fingerprint = SHA256.hash(data: Data(value.utf8))
                    .map { String(format: "%02x", $0) }.joined()
                let publicLabels = ["message", "pin", "未读", "空闲", "连接正常",
                                    "按回车或空格切换到此会话"]
                    + (missingRestore ? ["archive", "retry", "恢复会话",
                                         "显示 / 隐藏归档会话", "已展开", "已收起"] : [])
                return ["readable": true, "length": value.count, "sha256": fingerprint,
                        "publicSemantic": publicLabels.contains(value) ? value : "unclassified"]
            }
            let capturesWholeTree = visited.count <= 64
            let normalID = restoreSessionID.map { "chat.session.row.\($0.uuidString)" }
            if missingRestore {
                let toggles = visited.filter {
                    (attribute($0, kAXIdentifierAttribute as CFString) as? String)
                        == "chat.sidebar.archived.toggle"
                }
                let normalMatches = visited.filter {
                    (attribute($0, kAXIdentifierAttribute as CFString) as? String) == normalID
                }.count
                // Only fixed public state values are emitted, never unknown AXValue text.
                let toggleStates = toggles.map { node -> String in
                    guard let value = attribute(node, kAXValueAttribute as CFString) as? String else {
                        return "UNREADABLE"
                    }
                    return ["已展开", "已收起"].contains(value) ? value : "UNCLASSIFIED"
                }
                let summary: [String: Any] = [
                    "query": description, "pid": getpid(), "observedTreeNodeCount": visited.count,
                    "diagnosticTreeComplete": capturesWholeTree, "toggleMatches": toggles.count,
                    "toggleStates": toggleStates, "targetNormalMatches": normalMatches,
                    "targetRestoreMatches": hits.count
                ]
                if let data = try? JSONSerialization.data(withJSONObject: summary, options: [.sortedKeys]),
                   let encoded = String(data: data, encoding: .utf8) {
                    print("NATIVE_CONSUMER_RESTORE479_SUMMARY=" + encoded)
                }
            }
            let parentIndices: [Int?] = capturesWholeTree ? visited.map { node -> Int? in
                guard let parent = attribute(node, kAXParentAttribute as CFString)
                    .flatMap({ element($0 as AnyObject) }) else { return nil }
                return visited.firstIndex { CFEqual($0, parent) }
            } : []
            let diagnosticNodes = capturesWholeTree ? visited : hits
            for hit in diagnosticNodes {
                let nodeIndex = visited.firstIndex { CFEqual($0, hit) }
                let parent = attribute(hit, kAXParentAttribute as CFString)
                    .flatMap { element($0 as AnyObject) }
                let parentIndex = parent.flatMap { parent in
                    visited.firstIndex { CFEqual($0, parent) }
                }
                var rawActions: CFArray?
                let actionStatus = AXUIElementCopyActionNames(hit, &rawActions)
                let actionNames = actionStatus == .success ? rawActions as? [String] : nil
                let bounds = frame(hit).map {
                    ["x": $0.origin.x, "y": $0.origin.y,
                     "width": $0.width, "height": $0.height]
                }
                let metadata: [String: Any] = [
                    "query": description, "pid": getpid(),
                    "nodeIndex": nodeIndex.map { $0 as Any } ?? NSNull(),
                    "parentIndex": parentIndex.map { $0 as Any } ?? NSNull(),
                    "parentReadable": parent != nil,
                    "role": role(hit).map { $0.rawValue as Any } ?? NSNull(),
                    "actionStatus": actionStatus.rawValue,
                    "actionNames": actionNames.map { $0 as Any } ?? NSNull(),
                    "enabled": enabled(hit).map { $0 as Any } ?? NSNull(),
                    "wholeFrame": bounds.map { $0 as Any } ?? NSNull(),
                ]
                let queryHit = hits.contains { CFEqual($0, hit) }
                if queryHit,
                   let data = try? JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys]),
                   let encoded = String(data: data, encoding: .utf8) {
                    print("NATIVE_CONSUMER_ROW448_METADATA=" + encoded)
                }
                var treeMetadata = metadata
                treeMetadata["exactQueryHit"] = queryHit
                treeMetadata["diagnosticTreeComplete"] = capturesWholeTree
                treeMetadata["observedTreeNodeCount"] = visited.count
                treeMetadata["childIndices"] = capturesWholeTree
                    ? parentIndices.indices.filter { parentIndices[$0] == nodeIndex } as Any : NSNull()
                treeMetadata["identifier"] = textMetadata(hit, kAXIdentifierAttribute as CFString)
                if missingRestore {
                    let identifier = attribute(hit, kAXIdentifierAttribute as CFString) as? String
                    treeMetadata["knownIdentifierRole"] = identifier == normalID ? "targetNormal"
                        : identifier == "chat.sidebar.archived.toggle" ? "archiveToggle"
                        : queryHit ? "targetRestore" : "other"
                }
                treeMetadata["label"] = textMetadata(hit, kAXDescriptionAttribute as CFString)
                treeMetadata["title"] = textMetadata(hit, kAXTitleAttribute as CFString)
                treeMetadata["help"] = textMetadata(hit, kAXHelpAttribute as CFString)
                if let data = try? JSONSerialization.data(withJSONObject: treeMetadata, options: [.sortedKeys]),
                   let encoded = String(data: data, encoding: .utf8) {
                    print("NATIVE_CONSUMER_ROW455_TREE_METADATA=" + encoded)
                }
            }
        }
        guard !incomplete else { return nil }
        return hits
    }
}

// B2127_CONFLICT_PASSIVE_BEGIN
#if MINISCANVAS_SHORTCUT_CONFLICT_DIAGNOSTICS_B2127
// Read-only diagnostics. No matcher, actions, events, pump or product changes.
@MainActor
extension NativeConsumerOwnedAX {
    private static func b2127Emit(_ fields: [String: Any]) {
        guard let bytes = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]),
              let text = String(data: bytes, encoding: .utf8) else { return }
        print("SHORTCUT_B2127_CONFLICT_PASSIVE=" + text)
    }

    static func observeB2127Conflict(in window: NSWindow, store: ShortcutStore, phase: String) {
        // This is a fresh, nonmutating query, NEVER the original handle result.
        let queried = store.conflict(for: .newSession, to: ShortcutBinding(key: ",", modifiers: ShortcutModifiers.command))
        b2127Emit([
            "phase": phase, "kind": "state-availability", "pid": getpid(),
            "windowNumber": window.windowNumber,
            "actual_handle_setBinding_return": "UNKNOWN_NOT_RETAINED_OR_EXPOSED",
            "actual_recorder_conflictError_nonNil": "UNKNOWN_PRIVATE_STATE_INSTANCE_NOT_EXPOSED",
            "actual_recorder_conflictError_text": "UNKNOWN_PRIVATE_STATE_INSTANCE_NOT_EXPOSED",
            "current_store_query_is_original_return": false,
            "current_store_conflict_nonNil": queried != nil,
            "current_store_conflict_text": queried?.message ?? "NONE",
            "current_newSession_binding": store.binding(for: .newSession).displayString
        ])
        func read(_ node: AXUIElement, _ name: CFString) -> (AXError, CFTypeRef?) {
            var raw: CFTypeRef?
            let status = AXUIElementCopyAttributeValue(node, name, &raw)
            return (status, raw)
        }
        func string(_ result: (AXError, CFTypeRef?)) -> String? {
            guard result.0 == .success, let raw = result.1,
                  CFGetTypeID(raw) == CFStringGetTypeID() else { return nil }
            return raw as? String
        }
        func owned(_ node: AXUIElement) -> Bool {
            var pid: pid_t = 0
            return AXUIElementGetPid(node, &pid) == .success && pid == getpid()
        }
        func initialFailure(_ reason: String) {
            b2127Emit(["phase": phase, "kind": "sheet-observation-end", "status": reason,
                       "complete": false, "pid": getpid(), "windowNumber": window.windowNumber])
        }
        let expectedID = window.accessibilityIdentifier()
        guard !expectedID.isEmpty else {
            initialFailure("OWN_WINDOW_ID_UNKNOWN"); return
        }
        let app = AXUIElementCreateApplication(getpid())
        guard AXUIElementSetMessagingTimeout(app, 0.05) == .success else {
            initialFailure("OWN_APP_TIMEOUT_SETUP_FAILED"); return
        }
        let windowsResult = read(app, kAXWindowsAttribute as CFString)
        guard windowsResult.0 == .success, let windows = windowsResult.1 as? [AXUIElement], windows.count <= 16 else {
            initialFailure("OWN_WINDOWS_UNREADABLE_OR_OVER_BUDGET"); return
        }
        let owners = windows.filter { owned($0) && string(read($0, kAXIdentifierAttribute as CFString)) == expectedID }
        guard owners.count == 1, let owner = owners.first else {
            initialFailure("OWN_WINDOW_NOT_UNIQUE"); return
        }
        // Separate AXWindows admitted only by an actual AppKit attached sheet.
        // Descendant AXSheet/AXDialog is admitted only under this exact owner.
        let sheets = window.sheets
        var roots: [(AXUIElement, Bool)] = [(owner, false)]
        var sheetIDs: [String] = []
        for sheet in sheets {
            let identifier = sheet.accessibilityIdentifier()
            guard sheet.sheetParent === window, !identifier.isEmpty else {
                initialFailure("ATTACHED_SHEET_ID_OR_PARENT_UNKNOWN"); return
            }
            sheetIDs.append(identifier)
            let matches = windows.filter { owned($0) && string(read($0, kAXIdentifierAttribute as CFString)) == identifier }
            guard matches.count <= 1 else { initialFailure("ATTACHED_SHEET_NOT_UNIQUE"); return }
            roots.append(contentsOf: matches.map { ($0, true) })
        }
        var queue = roots.map { ($0.0, 0, $0.1, false) }
        var visited: [AXUIElement] = []
        var index = 0
        var complete = true
        var errors = 0
        var sheetNodes = 0
        var matches = 0
        var protectedNodes = 0
        var scalarGetterCalls = 0
        // Includes anonymous inputs and every descendant of any protected input.
        // No value/title/description/valueDescription call is reachable there.
        let anonymousOrSecretScalarGetterCalls = 0
        while index < queue.count && visited.count < 2048 {
            let (node, depth, inheritedSheet, inheritedProtected) = queue[index]
            index += 1
            guard !visited.contains(where: { CFEqual($0, node) }) else { continue }
            visited.append(node)
            guard owned(node), AXUIElementSetMessagingTimeout(node, 0.05) == .success else {
                complete = false; errors += 1; continue
            }
            let roleResult = read(node, kAXRoleAttribute as CFString)
            let idResult = read(node, kAXIdentifierAttribute as CFString)
            let actualRole = string(roleResult)
            let actualID = string(idResult)
            let idKnown = idResult.0 == .success || idResult.0 == .noValue || idResult.0 == .attributeUnsupported
            if actualRole == nil || !idKnown { complete = false; errors += 1 }
            let protected = inheritedProtected || actualRole == nil || !idKnown
                || actualRole == "AXTextField" || actualRole == "AXTextArea"
                || actualRole == "AXSecureTextField" || actualID?.lowercased().contains("apikey") == true
                || actualID?.contains("ProviderEditSheet") == true
            let insideSheet = inheritedSheet || actualRole == "AXSheet" || actualRole == "AXDialog"
            if insideSheet && (actualRole == "AXSheet" || actualRole == "AXDialog") { sheetNodes += 1 }
            if protected { protectedNodes += 1 }
            if insideSheet && !protected {
                let names: [(String, CFString)] = [
                    ("label_description", kAXDescriptionAttribute as CFString),
                    ("title", kAXTitleAttribute as CFString),
                    ("placeholder", kAXPlaceholderValueAttribute as CFString),
                    ("value", kAXValueAttribute as CFString)
                ]
                var fields: [String: Any] = [:]
                var containsConflict = false
                for (key, name) in names {
                    scalarGetterCalls += 1
                    let result = read(node, name)
                    fields[key + "_status"] = result.0.rawValue
                    if let value = string(result) {
                        // No arbitrary nonmatching strings or input contents logged.
                        fields[key] = value.contains("冲突") ? value : "NONMATCH_REDACTED"
                        containsConflict = containsConflict || value.contains("冲突")
                    } else { fields[key] = "UNOBSERVED_NONSTRING_OR_MISSING" }
                    if result.0 != .success && result.0 != .noValue && result.0 != .attributeUnsupported {
                        complete = false; errors += 1
                    }
                }
                if containsConflict {
                    matches += 1
                    fields["phase"] = phase; fields["kind"] = "sheet-conflict-node"
                    fields["role"] = actualRole ?? "UNKNOWN"
                    fields["identifier"] = actualID ?? "UNOBSERVED"
                    fields["pid"] = getpid(); fields["ownerWindowID"] = expectedID
                    fields["windowNumber"] = window.windowNumber; fields["depth"] = depth
                    b2127Emit(fields)
                }
            }
            let children = read(node, kAXChildrenAttribute as CFString)
            if children.0 == .attributeUnsupported || children.0 == .noValue { continue }
            guard children.0 == .success, let items = children.1 as? [AXUIElement], depth < 24 || items.isEmpty else {
                complete = false; errors += 1; continue
            }
            queue.append(contentsOf: items.map { ($0, depth + 1, insideSheet, protected) })
        }
        complete = complete && index == queue.count
        b2127Emit([
            "phase": phase, "kind": "sheet-observation-end", "pid": getpid(),
            "windowNumber": window.windowNumber, "ownerWindowID": expectedID,
            "attachedSheetIDs": sheetIDs, "sheetNodes": sheetNodes, "visited": visited.count,
            "conflictMatches": matches, "protectedNodes": protectedNodes,
            "scalarGetterCalls": scalarGetterCalls,
            "anonymous_or_secret_fourGetterCalls": anonymousOrSecretScalarGetterCalls,
            "complete": complete, "errors": errors,
            "status": !complete ? "INCOMPLETE_UNKNOWN" : (sheetNodes == 0 && sheets.isEmpty ? "NO_SETTINGS_SHEET_OBSERVED" : "OBSERVED_NOT_BUSINESS_PASS")
        ])
    }
}
#endif
// B2127_CONFLICT_PASSIVE_END
