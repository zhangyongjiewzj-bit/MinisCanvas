import AppKit
import ApplicationServices
@testable import MinisCanvasApp

/// Test-only, read-only lookup for controls that live outside the host window's
/// own AX tree: a popover window, or a sheet attached to another sheet.
/// NativeConsumerOwnedAX.find(in:) only reads the host window and its direct
/// sheets, so it cannot see those. This walks our own PID's AXWindows, their
/// children and their AXSheets. nil means unreadable or truncated; a count
/// other than one is returned as-is so callers never treat ambiguity as PASS.
@MainActor
enum NativeAppWideAXLookup {
    static func matches(identifier: String) -> [AXUIElement]? {
        let application = AXUIElementCreateApplication(getpid())
        guard AXUIElementSetMessagingTimeout(application, 0.05) == .success else { return nil }
        var rawWindows: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            application, kAXWindowsAttribute as CFString, &rawWindows
        ) == .success, let windows = rawWindows as? [AXUIElement], windows.count <= 32 else { return nil }
        var queue: [(AXUIElement, Int)] = windows.map { ($0, 0) }
        var visited: [AXUIElement] = []
        var hits: [AXUIElement] = []
        var index = 0
        var incomplete = false
        while index < queue.count && visited.count < 4096 {
            let (node, depth) = queue[index]
            index += 1
            guard !visited.contains(where: { CFEqual($0, node) }) else { continue }
            visited.append(node)
            _ = AXUIElementSetMessagingTimeout(node, 0.05)
            if (NativeConsumerOwnedAX.attribute(node, kAXIdentifierAttribute as CFString) as? String) == identifier {
                hits.append(node)
            }
            for name in [kAXChildrenAttribute as String, "AXSheets"] {
                var raw: CFTypeRef?
                let status = AXUIElementCopyAttributeValue(node, name as CFString, &raw)
                if status == .attributeUnsupported || status == .noValue { continue }
                guard status == .success, let children = raw as? [AXUIElement] else {
                    incomplete = true
                    continue
                }
                guard depth < 24 || children.isEmpty else { incomplete = true; continue }
                queue.append(contentsOf: children.map { ($0, depth + 1) })
            }
        }
        incomplete = incomplete || index < queue.count
        print("NATIVE_APP_WIDE_AX identifier=\(identifier) visited=\(visited.count) matches=\(hits.count) incomplete=\(incomplete)")
        return incomplete ? nil : hits
    }

    /// The single matching element, or nil when absent, ambiguous or unreadable.
    static func find(identifier: String) -> AnyObject? {
        guard let hits = matches(identifier: identifier), hits.count == 1 else { return nil }
        return hits[0]
    }
}
