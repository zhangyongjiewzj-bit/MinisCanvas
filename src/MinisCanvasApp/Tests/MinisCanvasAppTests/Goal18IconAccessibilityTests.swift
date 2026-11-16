import AppKit
import SwiftUI
import Testing
@testable import MinisCanvasApp

/// S-28 / D-2：两层光栅图标（keyline 路径）对读屏只暴露一个带标签的元素。
@Suite("Goal18 layered icon exposes one accessibility element", .serialized)
@MainActor
struct Goal18IconAccessibilityTests {
    @Test("a labelled keyline icon is found exactly once by its label")
    func labelledKeylineIconIsSingleElement() async throws {
        let cache = MinisIconLayerCache()
        // Warm the layers first so the view renders both raster layers, not the
        // single-image fallback that would hide the duplicate.
        #expect(await cache.layers(for: .search) != nil)
        var sources: [MinisIconRenderSource] = []
        let lease = NativeTestHostLifecycle.begin("Goal18IconAX")
        let controller = NSHostingController(rootView: HStack {
            MinisIconView(.search, size: 14, accessibilityLabel: "G18_ICON_SINGLE_LABEL", cache: cache,
                          onAppearRender: { _, source in sources.append(source) })
        }.frame(width: 200, height: 60))
        controller.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 60),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        NativeTestHostLifecycle.bind(lease, to: window)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.makeKeyAndOrderFront(nil)
        defer {
            window.orderOut(nil)
            window.contentViewController = nil
            window.close()
            NativeTestHostLifecycle.end(window)
        }
        let deadline = Date().addingTimeInterval(4)
        var found: AnyObject?
        repeat {
            window.layoutIfNeeded()
            found = NativeConsumerOwnedAX.find(in: window, label: "G18_ICON_SINGLE_LABEL")
            if found == nil { try await Task.sleep(for: .milliseconds(50)) }
        } while found == nil && Date() < deadline
        #expect(sources.first == .keyline)
        // find(in:label:) returns nil unless exactly one element carries the label.
        #expect(found != nil)
    }

    @Test("an inspector section does not announce its SF Symbol name")
    func inspectorSectionHidesSymbolName() async throws {
        let lease = NativeTestHostLifecycle.begin("Goal18InspectorSymbolAX")
        let controller = NSHostingController(rootView: InspectorSection(
            identifier: "g18.inspector.symbol", title: "G18_SECTION_TITLE", icon: "wrench.and.screwdriver"
        ) { Text("G18_SECTION_BODY") }.frame(width: 300, height: 120))
        controller.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 120),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        NativeTestHostLifecycle.bind(lease, to: window)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.makeKeyAndOrderFront(nil)
        defer {
            window.orderOut(nil)
            window.contentViewController = nil
            window.close()
            NativeTestHostLifecycle.end(window)
        }
        // Positive control: the tree is readable (the title is found once).
        let deadline = Date().addingTimeInterval(4)
        var title: AnyObject?
        repeat {
            window.layoutIfNeeded()
            title = NativeConsumerOwnedAX.find(in: window, label: "G18_SECTION_TITLE")
            if title == nil { try await Task.sleep(for: .milliseconds(50)) }
        } while title == nil && Date() < deadline
        #expect(title != nil)
        #expect(NativeConsumerOwnedAX.find(in: window, label: "wrench") == nil)
    }
}
