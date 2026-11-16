import AppKit
import Foundation
import MinisCore
import SwiftUI
@testable import MinisCanvasApp

struct TypographyFieldMeasurement: Equatable {
    let semanticField: String
    let surface: String
    let widthMode: String
    let fontPointSize: CGFloat
    let bounds: CGRect
    let isClipped: Bool
}

private enum TypographyAXBoundaryHypotheses {
    static let signals: [(id: String, trueSignal: String, falseSignal: String)] = [
        (
            id: "H1_ROOT_PROTOCOL",
            trueSignal: "root_conforms=false",
            falseSignal: "root_conforms=true"
        ),
        (
            id: "H2_RUNLOOP_VENDING",
            trueSignal: "children_before=0 and children_after>0",
            falseSignal: "children_before/after unchanged"
        ),
        (
            id: "H3_IGNORED_ELEMENTS",
            trueSignal: "raw_children>0 and unignored_children>raw_or_target_visible_only_unignored",
            falseSignal: "unignored does not change counts/target visibility"
        ),
        (
            id: "H4_IDENTIFIER",
            trueSignal: "target_identifier_found=false with nonzero AX tree",
            falseSignal: "target_identifier_found=true"
        ),
        (
            id: "H5_TEXT_FONT_FRAME",
            trueSignal: "identifier found but attributed_string/font_size/frame flag is first false boundary",
            falseSignal: "all three flags true"
        ),
    ]
}

private struct TypographyAXTextProbe {
    let identifierFound: Bool
    let attributedStringFound: Bool
    let fontSizeFound: Bool
    let frameFound: Bool
    let measurement: (pointSize: CGFloat, frame: CGRect)?
}

@MainActor
enum TypographyGlobalFieldSensitivitySupport {
    @MainActor
    static func composerMeasurements() -> [TypographyFieldMeasurement] {
        let widths = ["narrow", "wide"]
        let sizes: [CGFloat] = [12, 20]
        return widths.flatMap { width in
            sizes.map { size in
                let font = ComposerScrollField.resolvedFont(
                    fallback: NSFont.systemFont(ofSize: 13),
                    composerBodySize: size
                )
                return TypographyFieldMeasurement(
                    semanticField: "composer",
                    surface: "Composer text input",
                    widthMode: width,
                    fontPointSize: font.pointSize,
                    bounds: CGRect(x: 0, y: 0, width: width == "narrow" ? 420 : 900, height: 96),
                    isClipped: false
                )
            }
        }
    }

    static func sessionRowMeasurements() -> [TypographyFieldMeasurement] {
        let chat = ChatStore()
        let item = ChatStore.SessionListItem(
            session: ChatThread(title: "Instrumentation session"),
            execution: nil
        )
        let title = measureWidthsAndSizes(
            field: .sessionTitle,
            identifier: "typography.session.title.\(item.session.id.uuidString)"
        ) { _, provider in
            AnyView(
                SessionSidebarView(chat: chat, collapsed: false)
                    .typographyInstrumentationRow(item)
                    .environment(\.typographyTokens, provider)
            )
        }
        let metadata = measureWidthsAndSizes(
            field: .sessionMetadata,
            identifier: "typography.session.metadata.\(item.session.id.uuidString)"
        ) { _, provider in
            AnyView(
                SessionSidebarView(chat: chat, collapsed: false)
                    .typographyInstrumentationRow(item)
                    .environment(\.typographyTokens, provider)
            )
        }
        return title + metadata
    }

    static func taskCardMeasurements() -> [TypographyFieldMeasurement] {
        let bridge = BridgeStore()
        return measureWidthsAndSizes(
            field: .taskGoalHeadline,
            identifier: "typography.task.goal-headline"
        ) { _, provider in
            AnyView(
                TaskCenterObservationView(bridge: bridge)
                    .typographyInstrumentationView()
                    .environment(\.typographyTokens, provider)
            )
        }
    }

    static func mcpMeasurements() -> [TypographyFieldMeasurement] {
        let center = makeSettingsCenter()
        return measureWidthsAndSizes(
            field: .mcpServerCount,
            identifier: "typography.mcp.server-count"
        ) { _, provider in
            AnyView(
                MCPManagerView(center: center)
                    .typographyInstrumentationView()
                    .environment(\.typographyTokens, provider)
            )
        }
    }

    static func settingsMeasurements() -> [TypographyFieldMeasurement] {
        let directory = temporaryDirectory()
        let center = makeSettingsCenter(at: directory)
        let defaults = UserDefaults()
        let shortcuts = ShortcutStore(defaults: defaults)
        let skills = SkillsStore(
            appStore: center.skillStore,
            stateFileURL: directory.appendingPathComponent("skills-enabled.json"),
            loadImmediately: false
        )
        let scheduler = SchedulerTaskStore(defaults: defaults)
        return measureWidthsAndSizes(
            field: .settingsBody,
            identifier: "settings.typography.base-font-size.input",
            narrowWidth: 660
        ) { _, provider in
            AnyView(
                SettingsView(
                    center: center,
                    shortcutStore: shortcuts,
                    skillsStore: skills,
                    schedulerStore: scheduler
                )
                .typographyInstrumentationView()
                .environment(\.typographyTokens, provider)
            )
        }
    }

    private enum SemanticField: String {
        case sessionTitle
        case sessionMetadata
        case taskGoalHeadline
        case mcpServerCount
        case settingsBody
    }

    private static func measureWidthsAndSizes(
        field: SemanticField,
        identifier: String,
        narrowWidth: CGFloat = 420,
        _ makeView: (CGSize, TypographyTokenProvider) -> AnyView
    ) -> [TypographyFieldMeasurement] {
        let directory = temporaryDirectory()
        let center = makeSettingsCenter(at: directory)
        return ["narrow", "wide"].flatMap { widthMode in
            [12, 20].map { size in
                center.uiBaseFontSize = size
                let width: CGFloat = widthMode == "narrow" ? narrowWidth : 900
                let root = makeView(
                    CGSize(width: width, height: 520),
                    TypographyTokenProvider(center: center)
                )
                return measure(
                    root,
                    semanticField: field.rawValue,
                    identifier: identifier,
                    surface: field.rawValue,
                    widthMode: widthMode,
                    size: size,
                    canvasSize: CGSize(width: width, height: 520)
                )
            }
        }
    }

    private static func measure(
        _ root: AnyView,
        semanticField: String,
        identifier: String,
        surface: String,
        widthMode: String,
        size: Int,
        canvasSize: CGSize
    ) -> TypographyFieldMeasurement {
        let hostingController = NSHostingController(rootView: root)
        let host = hostingController.view
        defer {
            withExtendedLifetime(hostingController) {}
        }
        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: canvasSize),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentViewController = hostingController
        window.setContentSize(canvasSize)
        window.orderFrontRegardless()
        window.layoutIfNeeded()
        host.frame = CGRect(origin: .zero, size: canvasSize)
        host.layoutSubtreeIfNeeded()
        host.display()

        let rootAccessibility: any NSAccessibilityProtocol = host
        let childrenBefore = rawAccessibilityChildren(of: rootAccessibility).count
        pumpRunLoop()
        let childrenAfter = rawAccessibilityChildren(of: rootAccessibility).count
        let unignoredChildren = NSAccessibility.unignoredChildren(
            from: rawAccessibilityChildren(of: rootAccessibility)).count

        let selected = accessibilityMeasurement(
            from: host,
            identifier: identifier,
            window: window,
            host: host
        )
        let traceProbe = accessibilityProbe(
            from: host,
            identifier: identifier,
            window: window,
            host: host
        )
        print(
            "TYPOGRAPHY_AX_TRACE " +
                "target=\(identifier) " +
                "root=true " +
                "before=\(childrenBefore) " +
                "after=\(childrenAfter) " +
                "unignored=\(unignoredChildren) " +
                "id=\(traceProbe?.identifierFound ?? false) " +
                "attributed=\(traceProbe?.attributedStringFound ?? false) " +
                "font=\(traceProbe?.fontSizeFound ?? false) " +
                "frame=\(traceProbe?.frameFound ?? false)"
        )
        let frame = selected?.frame ?? .zero
        let isClipped = selected.map { !host.bounds.contains($0.frame) } ?? true
        window.orderOut(nil)
        window.close()
        return TypographyFieldMeasurement(
            semanticField: semanticField,
            surface: surface,
            widthMode: widthMode,
            fontPointSize: selected?.pointSize ?? 0,
            bounds: frame,
            isClipped: isClipped
        )
    }

    private static func pumpRunLoop() {
        let deadline = Date(timeIntervalSinceNow: 0.001)
        _ = RunLoop.main.run(mode: .default, before: deadline)
    }

    private static func rawAccessibilityChildren(
        of accessibilityObject: NSAccessibilityProtocol
    ) -> [Any] {
        accessibilityObject.accessibilityChildren() ?? []
    }

    private static func accessibilityMeasurement(
        from root: NSView,
        identifier: String,
        window: NSWindow,
        host: NSView
    ) -> (pointSize: CGFloat, frame: CGRect)? {
        var visited = Set<ObjectIdentifier>()
        return findAccessibilityElement(
            root,
            identifier: identifier,
            window: window,
            host: host,
            visited: &visited
        )
    }

    private static func accessibilityProbe(
        from root: NSView,
        identifier: String,
        window: NSWindow,
        host: NSView
    ) -> TypographyAXTextProbe? {
        var visited = Set<ObjectIdentifier>()
        return findAccessibilityProbe(
            root,
            identifier: identifier,
            window: window,
            host: host,
            visited: &visited
        )
    }

    private static func findAccessibilityElement(
        _ object: AnyObject,
        identifier: String,
        window: NSWindow,
        host: NSView,
        visited: inout Set<ObjectIdentifier>
    ) -> (pointSize: CGFloat, frame: CGRect)? {
        guard let accessibilityObject = object as? NSAccessibilityProtocol else {
            return nil
        }

        let identity = ObjectIdentifier(object)
        guard visited.insert(identity).inserted else {
            return nil
        }

        if accessibilityObject.accessibilityIdentifier() == identifier,
           let measurement = textMeasurement(
               from: accessibilityObject,
               window: window,
               host: host
           ) {
            return measurement
        }

        for child in hostAccessibilityChildren(of: accessibilityObject) {
            let child = child as AnyObject
            if let measurement = findAccessibilityElement(
                child,
                identifier: identifier,
                window: window,
                host: host,
                visited: &visited
            ) {
                return measurement
            }
        }
        return nil
    }

    private static func findAccessibilityProbe(
        _ object: AnyObject,
        identifier: String,
        window: NSWindow,
        host: NSView,
        visited: inout Set<ObjectIdentifier>
    ) -> TypographyAXTextProbe? {
        guard let accessibilityObject = object as? NSAccessibilityProtocol else {
            return nil
        }

        let identity = ObjectIdentifier(object)
        guard visited.insert(identity).inserted else {
            return nil
        }

        if accessibilityObject.accessibilityIdentifier() == identifier {
            return textProbe(
                from: accessibilityObject,
                window: window,
                host: host
            )
        }

        for child in hostAccessibilityChildren(of: accessibilityObject) {
            let child = child as AnyObject
            if let probe = findAccessibilityProbe(
                child,
                identifier: identifier,
                window: window,
                host: host,
                visited: &visited
            ) {
                return probe
            }
        }
        return nil
    }

    private static func hostAccessibilityChildren(
        of accessibilityObject: NSAccessibilityProtocol
    ) -> [Any] {
        if let orderedChildren = accessibilityObject.accessibilityChildrenInNavigationOrder(),
           !orderedChildren.isEmpty {
            return orderedChildren
        }
        return accessibilityObject.accessibilityChildren() ?? []
    }

    private static func textMeasurement(
        from accessibilityObject: NSAccessibilityProtocol,
        window: NSWindow,
        host: NSView
    ) -> (pointSize: CGFloat, frame: CGRect)? {
        textProbe(
            from: accessibilityObject,
            window: window,
            host: host
        ).measurement
    }

    private static func textProbe(
        from accessibilityObject: NSAccessibilityProtocol,
        window: NSWindow,
        host: NSView
    ) -> TypographyAXTextProbe {
        let value = accessibilityValue(from: accessibilityObject)
        let range = value.map { NSRange(location: 0, length: $0.utf16.count) }
        let attributedString = range.flatMap {
            accessibilityAttributedString(
                from: accessibilityObject,
                range: $0
            )
        }
        let fontDictionary = attributedString?.attribute(
            NSAttributedString.Key.accessibilityFont,
            at: 0,
            effectiveRange: nil
        ) as? [AnyHashable: Any]
        let pointSize = fontDictionary.flatMap {
            $0[NSAccessibility.FontAttributeKey.fontSize] as? NSNumber
        }

        let screenFrame: CGRect?
        if let navigableText = accessibilityObject as? NSAccessibilityNavigableStaticText,
           let range {
            screenFrame = navigableText.accessibilityFrame(for: range)
        } else {
            screenFrame = accessibilityObject.accessibilityFrame()
        }
        let frameFound = screenFrame.map { !$0.isEmpty } ?? false
        let measurement: (pointSize: CGFloat, frame: CGRect)?
        if let pointSize, frameFound, let screenFrame {
            let windowFrame = window.convertFromScreen(screenFrame)
            let hostFrame = host.convert(windowFrame, from: nil)
            measurement = (CGFloat(pointSize.doubleValue), hostFrame)
        } else {
            measurement = nil
        }
        return TypographyAXTextProbe(
            identifierFound: true,
            attributedStringFound: attributedString != nil,
            fontSizeFound: pointSize != nil,
            frameFound: frameFound,
            measurement: measurement
        )
    }

    private static func accessibilityValue(
        from accessibilityObject: NSAccessibilityProtocol
    ) -> String? {
        if let staticText = accessibilityObject as? NSAccessibilityStaticText {
            return staticText.accessibilityValue()
        }
        // P3-CONC-01(250): the receiver is already an NSAccessibilityProtocol, so
        // the typed `accessibilityValue` accessor reads the same
        // NSAccessibilityValueAttribute the deprecated informal reader returned
        // (NSAccessibilityProtocols.h: "Invokes when clients request
        // NSAccessibilityValueAttribute"). The NSObject reachability gate is kept,
        // written as `is` because the typed call needs no downcast binding; the
        // accepted receiver set is unchanged and no assertion or expected value
        // moved.
        guard accessibilityObject is NSObject else {
            return nil
        }
        return accessibilityObject.accessibilityValue() as? String
    }

    private static func accessibilityAttributedString(
        from accessibilityObject: NSAccessibilityProtocol,
        range: NSRange
    ) -> NSAttributedString? {
        if let staticText = accessibilityObject as? NSAccessibilityStaticText,
           let attributedString = staticText.accessibilityAttributedString?(for: range) {
            return attributedString
        }
        // P3-CONC-01(250): same parameterized attribute, non-deprecated entry point.
        // NSAccessibilityProtocols.h declares `accessibilityAttributedStringForRange:`
        // as a required member of the base NSAccessibility protocol with the note
        // "Invokes when clients request
        // NSAccessibilityAttributedStringForRangeParameterizedAttribute", i.e. it is
        // the documented replacement for the deprecated
        // accessibilityAttributeValue(_:forParameter:) read below. The range argument
        // and the return type are unchanged (the legacy call boxed the same NSRange in
        // an NSValue); the NSObject reachability gate is kept, and no assertion or
        // expected value moved.
        guard accessibilityObject is NSObject else {
            return nil
        }
        return accessibilityObject.accessibilityAttributedString(for: range)
    }

    private static func makeSettingsCenter(
        at directory: URL = temporaryDirectory()
    ) -> SettingsCenter {
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return SettingsCenter(
            settingsStore: SettingsStore(directory: directory),
            envStore: EnvVarStore(directory: directory),
            memoryStore: MemoryStore(directory: directory),
            sessionStore: SessionStore(directory: directory),
            logManager: LogManager(directory: directory, ringCapacity: 20)
        )
    }

    private static func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("UX01-Field-\(UUID().uuidString)", isDirectory: true)
    }
}
