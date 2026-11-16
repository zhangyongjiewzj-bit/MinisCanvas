import Testing
import AppKit
import SwiftUI
@testable import MinisCanvasApp

@Suite("动态分隔 native consumer 与 geometry fixtures")
@MainActor
struct AdaptiveDividerNativeConsumerTests {
    @MainActor
    private struct HostedProductionDivider {
        let controller: NSHostingController<AnyView>
        let view: NSView
        let requestedWidth: Double
        let mainMinimumWidth: Double

        var effectiveWidth: Double {
            DeterministicSplitGeometry.effectiveSidebarWidth(
                containerWidth: view.frame.width,
                requestedSidebarWidth: requestedWidth,
                mainMinimumWidth: mainMinimumWidth
            )
        }

        init(containerWidth: Double, requestedWidth: Double, mainMinimumWidth: Double, fontSize: Double? = nil) {
            _ = NSApplication.shared
            self.requestedWidth = requestedWidth
            self.mainMinimumWidth = mainMinimumWidth
            let sizes = fontSize.map { [$0] } ?? AdaptiveDividerNativeContract.typographyPointSizes
            let productionView = DeterministicSplitView(
                sidebarWidth: requestedWidth,
                mainMinWidth: mainMinimumWidth
            ) {
                VStack {
                    ForEach(sizes, id: \.self) { size in
                        Text("production sidebar (Int(size))")
                            .font(.system(size: size))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(UF01NativePaneAXProbe(identifier: "uf01.production.sidebar"))
            } main: {
                VStack {
                    ForEach(sizes, id: \.self) { size in
                        Text("production main (Int(size))")
                            .font(.system(size: size))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(UF01NativePaneAXProbe(identifier: "uf01.production.main"))
            }
            let controller = NSHostingController(rootView: AnyView(productionView))
            controller.sizingOptions = []
            self.controller = controller
            self.view = controller.view
            self.view.setFrameSize(NSSize(width: containerWidth, height: 400))
        }

        func mountAndLayout(containerWidth: Double) -> NSWindow {
            let hostLease = NativeTestHostLifecycle.begin("UF01")
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: containerWidth, height: 400),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            NativeTestHostLifecycle.bind(hostLease, to: window)
            window.isReleasedWhenClosed = false
            window.contentViewController = controller
            window.setContentSize(NSSize(width: containerWidth, height: 400))
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
            for _ in 0..<30 {
                window.layoutIfNeeded()
                view.layoutSubtreeIfNeeded()
                view.display()
                _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
                if accessibilityFrame(for: "uf01.production.sidebar")?.isEmpty == false,
                   accessibilityFrame(for: "uf01.production.main")?.isEmpty == false { break }
            }
            NativeTestHostLifecycle.observe(window, phase: "sampled")
            let sidebar = UF01Snapshot(in: window, identifier: "uf01.production.sidebar")
            let main = UF01Snapshot(in: window, identifier: "uf01.production.main")
            print("UF01_NATIVE_PROBE requestedContainer=\(containerWidth) contentFrame=\(String(describing: window.contentView?.frame)) hostFrame=\(view.frame) visible=\(window.isVisible) key=\(window.isKeyWindow) active=\(NSApplication.shared.isActive) sidebar=\(sidebar) main=\(main)")
            return window
        }

        func accessibilityFrame(for identifier: String) -> CGRect? {
            if let window = view.window {
                return UF01Snapshot(in: window, identifier: identifier).frame
            }
            return UF01Snapshot(in: view, identifier: identifier).frame
        }
    }

    @Test("fixture hosts the actual DeterministicSplitView consumer and contract typography")
    func hostsProductionConsumerWithoutRunningNativeLayout() {
        let fixture = HostedProductionDivider(
            containerWidth: 800,
            requestedWidth: 700,
            mainMinimumWidth: 420
        )

        #expect(fixture.view.frame.width == 800)
        #expect(fixture.requestedWidth == 700)
        #expect(fixture.mainMinimumWidth == 420)
        #expect(AdaptiveDividerNativeContract.handleWidth == 5)
        #expect(AdaptiveDividerNativeContract.typographyPointSizes == [12, 13, 16, 20])
    }

    @Test("future native run mounts, lays out, resizes and reads actual production identifiers")
    func productionMountFixtureReadsRealViewResults() {
        let fixture = HostedProductionDivider(
            containerWidth: 1_280,
            requestedWidth: 700,
            mainMinimumWidth: 420
        )
        let window = fixture.mountAndLayout(containerWidth: 1_280)
        defer { window.orderOut(nil); window.contentViewController = nil; window.close(); NativeTestHostLifecycle.end(window) }

        #expect(fixture.accessibilityFrame(for: "uf01.production.sidebar") != nil)
        #expect(fixture.accessibilityFrame(for: "uf01.production.main") != nil)
        #expect(fixture.effectiveWidth == 700)
    }

    @Test("actual native pane frames cover every window width and typography size")
    func actualNativePaneFramesAcrossWindowAndTypographyMatrix() {
        for width in [600.0, 800.0, 1_000.0, 1_280.0, 1_600.0] {
            for fontSize in AdaptiveDividerNativeContract.typographyPointSizes {
                let fixture = HostedProductionDivider(containerWidth: width, requestedWidth: 700, mainMinimumWidth: 420, fontSize: fontSize)
                let window = fixture.mountAndLayout(containerWidth: width)
                defer { window.orderOut(nil); window.contentViewController = nil; window.close(); NativeTestHostLifecycle.end(window) }
                let sidebar = fixture.accessibilityFrame(for: "uf01.production.sidebar")
                let main = fixture.accessibilityFrame(for: "uf01.production.main")
                #expect(sidebar != nil, "width=\(width) font=\(fontSize)")
                #expect(main != nil, "width=\(width) font=\(fontSize)")
                if let sidebar, let main {
                    #expect(!sidebar.isEmpty && !main.isEmpty)
                    #expect(abs(sidebar.width - fixture.effectiveWidth) <= 1)
                    #expect(main.width >= 419)
                    #expect(abs(sidebar.maxX - main.minX) <= 1)
                    #expect(abs(sidebar.width + main.width - fixture.view.frame.width) <= 1)
                }
            }
        }
    }

    @Test("hosted production consumer preserves requested width through shrink expand and collapse")
    func hostedConsumerKeepsRequestedPreference() {
        var memory = SidebarWidthMemory(width: 700)
        let shrunk = HostedProductionDivider(
            containerWidth: 800,
            requestedWidth: memory.width,
            mainMinimumWidth: 420
        )
        #expect(shrunk.effectiveWidth == 380)
        #expect(memory.rememberedWidth == 700)

        memory.collapse()
        #expect(memory.width == 0)
        memory.expand()
        #expect(memory.width == 700)

        let expanded = HostedProductionDivider(
            containerWidth: 1_600,
            requestedWidth: memory.width,
            mainMinimumWidth: 420
        )
        #expect(expanded.effectiveWidth == 700)
        #expect(memory.rememberedWidth == 700)
    }

    @Test("geometry fixture: effective pane width never violates main minimum")
    func effectiveWidthPreservesMainMinimum() {
        for width in [600.0, 800.0, 1_000.0, 1_280.0, 1_600.0] {
            let effective = DeterministicSplitGeometry.effectiveSidebarWidth(
                containerWidth: width,
                requestedSidebarWidth: 900,
                mainMinimumWidth: 420
            )
            #expect(effective >= 0)
            #expect(effective + 420 <= width)
        }
    }

    @Test("geometry fixture: resize and collapse keep requested preference separate")
    func requestedMemorySurvivesTemporaryWindowShrink() {
        var memory = SidebarWidthMemory(width: 700)
        #expect(memory.rememberedWidth == 700)

        let shrunkEffective = DeterministicSplitGeometry.effectiveSidebarWidth(
            containerWidth: 800,
            requestedSidebarWidth: memory.width,
            mainMinimumWidth: 420
        )
        #expect(shrunkEffective == 380)
        #expect(memory.rememberedWidth == 700)

        memory.collapse()
        memory.expand()
        #expect(memory.width == 700)
    }

    @Test("geometry fixture: deterministic split rejects negative pane geometry")
    func negativeRequestIsSafe() {
        #expect(DeterministicSplitGeometry.effectiveSidebarWidth(
            containerWidth: 600,
            requestedSidebarWidth: -30,
            mainMinimumWidth: 420
        ) == 0)
    }
}

/// A transparent native view receives the pane's actual SwiftUI layout proposal.
/// Its AppKit AX frame measures the pane, unlike a .contain group whose AX bounds
/// are the union of the intrinsic text children. No expected width is injected.
@MainActor
private struct UF01NativePaneAXProbe: NSViewRepresentable {
    let identifier: String

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.group)
        view.setAccessibilityIdentifier(identifier)
        view.setAccessibilityLabel(identifier)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        nsView.setAccessibilityIdentifier(identifier)
    }
}

@MainActor
private struct UF01AXSnapshot {
    let found: Bool
    let frame: CGRect?
    let nodeType: String?
    let visitedCount: Int
    let traversalTruncated: Bool
    let sampledIdentifiers: [String]
}

@MainActor
private func UF01Snapshot(in root: AnyObject, identifier: String) -> UF01AXSnapshot {
    var queue: [AnyObject] = [root]
    var index = 0
    var visited = Set<ObjectIdentifier>()
    var sampledIdentifiers: [String] = []
    while index < queue.count && visited.count < 2_048 {
        let object = queue[index]
        index += 1
        guard visited.insert(ObjectIdentifier(object)).inserted else { continue }
        let native = object as? NSObject
        let ax = object as? NSAccessibilityProtocol
        let currentID = (UF01Getter(object, "accessibilityIdentifier") as? String)
            ?? (UF03LegacyAttribute(native, .identifier) as? String)
            ?? ax?.accessibilityIdentifier()
        if let currentID, !currentID.isEmpty, sampledIdentifiers.count < 12 {
            sampledIdentifiers.append(currentID)
        }
        if currentID == identifier {
            var frame = ax?.accessibilityFrame()
            if frame == nil || frame?.isEmpty == true,
               let position = UF03LegacyAttribute(native, .position) as? NSValue,
               let size = UF03LegacyAttribute(native, .size) as? NSValue {
                frame = CGRect(origin: position.pointValue, size: size.sizeValue)
            }
            // A private node may vend its identifier while omitting frame.
            // Read the same owned element's actual public position/size instead.
            let window = (root as? NSWindow) ?? (root as? NSView)?.window
            if frame == nil || frame?.isEmpty == true,
               let window,
               let publicNode = NativeConsumerOwnedAX.find(in: window, identifier: identifier) {
                frame = NativeConsumerOwnedAX.frame(publicNode)
            }
            return UF01AXSnapshot(found: true, frame: frame, nodeType: String(describing: type(of: object)), visitedCount: visited.count, traversalTruncated: false, sampledIdentifiers: sampledIdentifiers)
        }
        // SwiftUI may vend a single private AX proxy instead of an NSArray.
        // Preserve that object and its unignored replacement; dropping it
        // makes every identifier disappear while the host remains laid out.
        var children = UF01AXChildren(
            of: object,
            attribute: .childrenInNavigationOrderAttribute
        )
        if children.isEmpty {
            children = UF01AXChildren(of: object, attribute: .children)
        }
        if let view = object as? NSView { children.append(contentsOf: view.subviews) }
        if let window = object as? NSWindow, let content = window.contentView {
            children.append(content.superview ?? content)
        }
        func append(_ value: Any) {
            if let nested = value as? [Any] {
                for child in nested { append(child) }
            } else if let nested = value as? NSArray {
                for child in nested { append(child) }
            } else {
                queue.append(value as AnyObject)
            }
        }
        for child in children { append(child) }
    }
    let window = (root as? NSWindow) ?? (root as? NSView)?.window
    if let window, let publicNode = NativeConsumerOwnedAX.find(in: window, identifier: identifier) {
        return UF01AXSnapshot(
            found: true, frame: NativeConsumerOwnedAX.frame(publicNode),
            nodeType: "AXUIElement", visitedCount: visited.count,
            traversalTruncated: false, sampledIdentifiers: sampledIdentifiers + [identifier]
        )
    }
    return UF01AXSnapshot(found: false, frame: nil, nodeType: nil, visitedCount: visited.count, traversalTruncated: index < queue.count, sampledIdentifiers: sampledIdentifiers)
}

@MainActor
private func UF01AXChildren(
    of object: AnyObject,
    attribute: NSAccessibility.Attribute
) -> [Any] {
    let unignoredFromObject = NSAccessibility.unignoredChildrenForOnlyChild(from: object)
    let selectorName = attribute == .childrenInNavigationOrderAttribute
        ? "accessibilityChildrenInNavigationOrder"
        : "accessibilityChildren"
    guard let value = UF01Getter(object, selectorName)
        ?? UF03LegacyAttribute(object as? NSObject, attribute) else {
        return unignoredFromObject
    }
    if let values = value as? NSArray {
        let raw = values.map { $0 }
        return raw + NSAccessibility.unignoredChildren(from: raw) + unignoredFromObject
    }
    return [value] + NSAccessibility.unignoredChildrenForOnlyChild(from: value) + unignoredFromObject
}

@MainActor
private func UF01Getter(_ object: AnyObject, _ name: String) -> Any? {
    guard let native = object as? NSObject else { return nil }
    let selector = NSSelectorFromString(name)
    guard native.responds(to: selector), let value = native.perform(selector) else { return nil }
    return value.takeUnretainedValue()
}
