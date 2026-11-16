import AppKit
import ApplicationServices
import Foundation
@testable import MinisCanvasApp

// Shared verbatim Task08/2977 AX fixture. Only the eight used entry points
// change visibility; traversal and owned-window fallback remain unchanged.
@MainActor
func pumpAXRunLoop() {
    let deadline = Date(timeIntervalSinceNow: 0.05)
    _ = RunLoop.main.run(mode: .default, before: deadline)
}

@MainActor
private func findAX(
    _ object: AnyObject,
    identifier: String,
    visited: inout Set<ObjectIdentifier>,
    diagnostics: inout [String]
) -> AnyObject? {
    let objectID = ObjectIdentifier(object)
    guard visited.insert(objectID).inserted else { return nil }
    if axIdentifier(object) == identifier {
        return object
    }

    // AppKit declares the ordered getter as [NSAccessibilityElement], but SwiftUI
    // can vend private proxy objects in its backing NSArray. Calling the typed
    // protocol getter traps while bridging before this helper can inspect it.
    let ordered = rawAXChildren(
        of: object,
        attribute: .childrenInNavigationOrderAttribute
    )
    var children = ordered.isEmpty
        ? rawAXChildren(of: object, attribute: .children)
        : ordered
    // SwiftUI can vend an empty ordered list on an ignored AppKit wrapper.
    // Traverse the actual native view tree as well, including window toolbars.
    if let view = object as? NSView { children += view.subviews }
    if let window = object as? NSWindow, let content = window.contentView {
        children.append(content.superview ?? content)
    }
    if diagnostics.count < 16,
       let line = axDiagnosticLine(object, childCount: flattenAXChildren(children).count) {
        diagnostics.append(line)
    }
    for child in flattenAXChildren(children) {
        let childObject = child as AnyObject
        if let match = findAX(
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
private func rawAXChildren(
    of object: AnyObject,
    attribute: NSAccessibility.Attribute
) -> [Any] {
    let unignoredFromObject = NSAccessibility.unignoredChildrenForOnlyChild(from: object)
    let selectorName = attribute == .childrenInNavigationOrderAttribute
        ? "accessibilityChildrenInNavigationOrder"
        : "accessibilityChildren"
    guard let value = rawAXGetter(object, selectorName: selectorName)
        ?? UF03LegacyAttribute(object as? NSObject, attribute) else {
        return unignoredFromObject
    }
    if let values = value as? NSArray {
        let raw = values.map { $0 }
        return raw + NSAccessibility.unignoredChildren(from: raw) + unignoredFromObject
    }
    return [value] + NSAccessibility.unignoredChildrenForOnlyChild(from: value) + unignoredFromObject
}

private func flattenAXChildren(_ children: [Any]) -> [Any] {
    children.flatMap { child in
        if let nested = child as? [Any] { return flattenAXChildren(nested) }
        if let nested = child as? NSArray { return flattenAXChildren(nested.map { $0 }) }
        return [child]
    }
}

@MainActor
func findAX(_ object: AnyObject, identifier: String) -> AnyObject? {
    var visited = Set<ObjectIdentifier>()
    var diagnostics: [String] = []
    let result = findAX(
        object,
        identifier: identifier,
        visited: &visited,
        diagnostics: &diagnostics
    )
    let window = (object as? NSWindow) ?? (object as? NSView)?.window
    if let window, (result == nil || axRole(result!) == nil),
       let publicNode = NativeConsumerOwnedAX.find(in: window, identifier: identifier) {
        return publicNode
    }
    if result == nil {
        print("TASK_NATIVE_AX_MISSING identifier=\(identifier) visited=\(visited.count) root=\(type(of: object)) samples=\(diagnostics.joined(separator: " || "))")
    }
    return result
}

@MainActor
private func rawAXAttribute(
    _ object: AnyObject,
    _ attribute: NSAccessibility.Attribute
) -> Any? {
    UF03LegacyAttribute(object as? NSObject, attribute)
}

@MainActor
private func rawAXGetter(_ object: AnyObject, selectorName: String) -> Any? {
    guard let object = object as? NSObject else { return nil }
    let selector = NSSelectorFromString(selectorName)
    guard object.responds(to: selector),
          let result = object.perform(selector) else { return nil }
    return result.takeUnretainedValue()
}

@MainActor
private func axDiagnosticLine(_ object: AnyObject, childCount: Int) -> String? {
    let dynamicID = rawAXGetter(object, selectorName: "accessibilityIdentifier") as? String
    let legacyID = rawAXAttribute(object, .identifier) as? String
    let protocolID = (object as? NSAccessibilityProtocol)?.accessibilityIdentifier()
    let dynamicLabel = rawAXGetter(object, selectorName: "accessibilityLabel") as? String
    let legacyLabel = rawAXAttribute(object, .description) as? String
    let role = rawAXGetter(object, selectorName: "accessibilityRole")
        ?? rawAXAttribute(object, .role)
    let meaningful = [dynamicID, legacyID, protocolID, dynamicLabel, legacyLabel]
        .contains { !($0 ?? "").isEmpty }
    guard meaningful else { return nil }
    let objectValue = object as? NSObject
    let ordered = objectValue?.responds(
        to: NSSelectorFromString("accessibilityChildrenInNavigationOrder")
    ) ?? false
    let children = objectValue?.responds(
        to: NSSelectorFromString("accessibilityChildren")
    ) ?? false
    return "type=\(type(of: object)) dynamicID=\(dynamicID ?? "") legacyID=\(legacyID ?? "") protocolID=\(protocolID ?? "") dynamicLabel=\(dynamicLabel ?? "") legacyLabel=\(legacyLabel ?? "") role=\(String(describing: role)) ordered=\(ordered) children=\(children) childCount=\(childCount)"
}

@MainActor
private func axIdentifier(_ object: AnyObject) -> String? {
    if let identifier = rawAXGetter(object, selectorName: "accessibilityIdentifier") as? String,
       !identifier.isEmpty {
        return identifier
    }
    if let identifier = rawAXAttribute(object, .identifier) as? String,
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
func axRole(_ object: AnyObject) -> NSAccessibility.Role? {
    if NativeConsumerOwnedAX.element(object) != nil { return NativeConsumerOwnedAX.role(object) }
    return (object as? NSAccessibilityProtocol)?.accessibilityRole()
        ?? rawAXAttribute(object, .role) as? NSAccessibility.Role
}

@MainActor
func axEnabled(_ object: AnyObject) -> Bool {
    if NativeConsumerOwnedAX.element(object) != nil { return NativeConsumerOwnedAX.enabled(object) ?? false }
    return (object as? NSAccessibilityProtocol)?.isAccessibilityEnabled()
        ?? (rawAXAttribute(object, .enabled) as? Bool)
        ?? false
}

@MainActor
func axLabel(_ object: AnyObject) -> String? {
    if NativeConsumerOwnedAX.element(object) != nil { return NativeConsumerOwnedAX.label(object) }
    return (object as? NSAccessibilityProtocol)?.accessibilityLabel()
        ?? rawAXAttribute(object, .description) as? String
}

@MainActor
func axValue(_ object: AnyObject) -> String? {
    if NativeConsumerOwnedAX.element(object) != nil {
        return NativeConsumerOwnedAX.attribute(object, kAXValueAttribute as CFString) as? String
    }
    return (object as? NSAccessibilityProtocol)?.accessibilityValue() as? String
        ?? rawAXAttribute(object, .value) as? String
}

@MainActor
func axFocused(_ object: AnyObject) -> Bool {
    if NativeConsumerOwnedAX.element(object) != nil {
        return NativeConsumerOwnedAX.attribute(object, kAXFocusedAttribute as CFString) as? Bool ?? false
    }
    return (object as? NSAccessibilityProtocol)?.isAccessibilityFocused()
        ?? rawAXAttribute(object, .focused) as? Bool
        ?? false
}

@MainActor
func axPress(_ object: AnyObject) -> Bool {
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
