import AppKit
import Foundation
import MinisCore
import SwiftUI
import Testing
@testable import MinisCanvasApp

@Suite("D-ICONB passive appearance consumer", .serialized)
@MainActor
struct MinisIconRenderObservation2989Tests {
    @Test("scene, token, instance and appearance counts stay distinct; fallback is never erased")
    func aggregationKeepsAppearanceFacts() {
        let telemetry = MinisIconRenderTelemetry()
        let main = MinisIconRenderObservation(telemetry: telemetry, scene: .mainWindow)
        let settings = MinisIconRenderObservation(telemetry: telemetry, scene: .settingsSheet)
        let instance = UUID()
        // Synthetic events exercise aggregation only. Native tests below
        // exercise the production renderer's actual onAppear and environment.
        main.onAppear(icon: .search, source: .fallback(systemName: "unreviewed-owned-symbol"), instanceID: instance)
        main.onAppear(icon: .search, source: .keyline, instanceID: instance)
        settings.onAppear(icon: .settings, source: .keyline, instanceID: UUID())
        let snapshot = telemetry.snapshot
        #expect(snapshot.counts().appearances == 3)
        #expect(snapshot.counts().uniqueInstances == 2)
        #expect(snapshot.counts().uniqueTokens == 2)
        #expect(snapshot.counts(in: .mainWindow).appearances == 2)
        #expect(snapshot.counts(in: .mainWindow).uniqueInstances == 1)
        #expect(snapshot.counts(in: .mainWindow).fallbackAppearances == 1)
        #expect(snapshot.counts(in: .mainWindow).observedKeylineFraction == 0.5)
        #expect(snapshot.counts().fallbackSystemNames == ["unreviewed-owned-symbol"])
        #expect(snapshot.discardedAppearances == 0)
        #expect(MinisIconRenderTelemetry().snapshot.counts().observedKeylineFraction == nil)
    }

    @Test("bounded sample explicitly reports truncation instead of claiming all process renders")
    func boundedSampleReportsDiscardedFacts() {
        let telemetry = MinisIconRenderTelemetry(capacity: 2)
        let context = MinisIconRenderObservation(telemetry: telemetry, scene: .mainWindow)
        context.onAppear(icon: .warning, source: .fallback(systemName: "warning-owned"), instanceID: UUID())
        context.onAppear(icon: .search, source: .keyline, instanceID: UUID())
        let previous = telemetry.snapshot
        context.onAppear(icon: .settings, source: .keyline, instanceID: UUID())
        #expect(previous.appearances.first?.source == .fallback(systemName: "warning-owned"))
        #expect(previous.discardedAppearances == 0)
        #expect(telemetry.snapshot.appearances.map(\.icon) == [.search, .settings])
        #expect(telemetry.snapshot.discardedAppearances == 1)
        #expect(telemetry.snapshot.counts().appearances == 2)
        // The retained fraction cannot certify the original 80/20 requirement.
    }

    @Test("actual hosted renderer feeds the root observer and preserves the optional callback",
          .enabled(if: ProcessInfo.processInfo.environment["MINISCANVAS_ICON_RENDER_UI_CONSUMER"] == "1",
                   "Requires the sole UI owner and the existing native formal-test host"))
    func nativeAppearanceAndRemountReachObserver() async throws {
        let telemetry = MinisIconRenderTelemetry()
        var callbacks: [MinisIconRenderSource] = []
        func view() -> some View {
            MinisIconView(.search, onAppearRender: { _, source in callbacks.append(source) })
                .observingMinisIconRenders(using: telemetry, scene: .mainWindow)
        }
        let first = try IconRender2989Host(view())
        defer { first.close() }
        try await awaitAppearances(1, telemetry: telemetry)
        #expect(callbacks.count == 1)
        #expect(telemetry.snapshot.appearances.first?.source == callbacks.first)
        let originalInstance = try #require(telemetry.snapshot.appearances.first?.instanceID)
        for width in [180.0, 320.0, 240.0] {
            first.resize(width: width)
            await Task.yield()
        }
        #expect(telemetry.snapshot.counts().appearances == 1, "layout must not manufacture onAppear events")
        first.close()
        let remounted = try IconRender2989Host(view())
        defer { remounted.close() }
        try await awaitAppearances(2, telemetry: telemetry)
        let snapshot = telemetry.snapshot
        #expect(callbacks.count == 2)
        #expect(snapshot.appearances.map(\.source) == callbacks)
        #expect(snapshot.appearances.last?.instanceID != originalInstance)
        #expect(snapshot.counts().appearances == 2)
        #expect(snapshot.counts().uniqueInstances == 2)
        #expect(snapshot.counts().uniqueTokens == 1)
    }

    @Test("main and settings actual renderers share one owner without collapsing equal tokens",
          .enabled(if: ProcessInfo.processInfo.environment["MINISCANVAS_ICON_RENDER_UI_CONSUMER"] == "1",
                   "Requires the sole UI owner and the existing native formal-test host"))
    func nativeScenesShareTheRootOwner() async throws {
        let telemetry = MinisIconRenderTelemetry()
        let main = try IconRender2989Host(
            MinisIconView(.settings).observingMinisIconRenders(using: telemetry, scene: .mainWindow))
        defer { main.close() }
        let settings = try IconRender2989Host(
            MinisIconView(.settings).observingMinisIconRenders(using: telemetry, scene: .settingsSheet))
        defer { settings.close() }
        try await awaitAppearances(2, telemetry: telemetry)
        let snapshot = telemetry.snapshot
        #expect(snapshot.counts(in: .mainWindow).appearances == 1)
        #expect(snapshot.counts(in: .settingsSheet).appearances == 1)
        #expect(snapshot.counts().uniqueTokens == 1)
        #expect(snapshot.counts().uniqueInstances == 2)
        #expect(snapshot.counts().keylineAppearances + snapshot.counts().fallbackAppearances == 2)
        #expect(snapshot.discardedAppearances == 0)
    }

    private func awaitAppearances(_ count: Int, telemetry: MinisIconRenderTelemetry) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(3))
        while telemetry.snapshot.appearances.count < count, clock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(telemetry.snapshot.appearances.count == count, "actual SwiftUI onAppear must reach the composition observer")
    }
}

@MainActor
private final class IconRender2989Host<Content: View> {
    let window: NSWindow
    private let controller: NSHostingController<Content>
    private var closed = false

    init(_ content: Content) throws {
        try #require(NSApplication.shared.isRunning, "requires the unchanged native test entry")
        try #require(FormalTestIsolationPaths.resolveCurrentProcess() != nil,
                     "native consumer must use the real nine-key formal-test contract")
        let lease = NativeTestHostLifecycle.begin("IconRender2989")
        controller = NSHostingController(rootView: content)
        controller.sizingOptions = []
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 80),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        NativeTestHostLifecycle.bind(lease, to: window)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        resize(width: 240)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    func resize(width: Double) {
        let size = NSSize(width: width, height: 80)
        window.setContentSize(size)
        controller.view.frame = NSRect(origin: .zero, size: size)
        window.layoutIfNeeded()
        controller.view.layoutSubtreeIfNeeded()
    }

    func close() {
        guard !closed else { return }
        closed = true
        window.orderOut(nil)
        window.contentViewController = nil
        window.close()
        NativeTestHostLifecycle.end(window)
    }
}
