import AppKit
import Foundation
import MinisCore
import SwiftUI
import Testing
@testable import MinisCanvasApp

@Suite("0410 actual icon first-frame background resource consumer", .serialized)
@MainActor
struct MinisIconFirstFrame0410Tests {
    @Test("real body appears while resource I/O is blocked, then displays orange PNG pixels and a hot remount",
          .enabled(if: ProcessInfo.processInfo.environment["MINISCANVAS_ICON_STARTUP_UI_CONSUMER"] == "1",
                   "requires sole UI owner, unchanged native entry and nine-key formal-test isolation"),
          .timeLimit(.minutes(1)))
    func coldBodyDoesNotWaitForMetadataAndHotBodyUsesSuccessfulPixels() async throws {
        let bytes = try fixtureBytes()
        let reads = IconFirstFrameReads0410()
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let cache = MinisIconLayerCache { icon in
            await MinisIconView.readLayerBytes(for: icon) { _ in
                let onMain = Thread.isMainThread
                Task { await reads.started(onMain: onMain) }
                release.wait()
                return bytes
            }
        }
        let telemetry = MinisIconRenderTelemetry()
        var sources: [MinisIconRenderSource] = []
        func content() -> some View {
            MinisIconView(.search, state: .active, size: 40, cache: cache,
                          onAppearRender: { _, source in sources.append(source) })
                .observingMinisIconRenders(using: telemetry, scene: .mainWindow)
                .frame(width: 80, height: 80)
                .background(Color.white)
        }
        let first = try IconFirstFrameHost0410(content())
        defer { first.close() }
        try await waitUntil { await reads.count() == 1 && sources.count == 1 }
        var mainPulse = false
        await Task { @MainActor in mainPulse = true }.value
        #expect(mainPulse)
        #expect(first.window.isVisible)
        #expect(!(await reads.onMain()))
        #expect(cache.cachedLayers(for: .search) == nil)
        #expect(sources == [.fallback(systemName: "magnifyingglass")])
        #expect(telemetry.snapshot.appearances.map(\.source) == sources)
        let pendingPixels = try first.pixels()
        #expect(pendingPixels.orangePixels > 0, "actual active fallback must be visible")
        #expect(pendingPixels.centralOrangeFraction < 0.65, "pending SF glyph is not the solid fixture PNG")

        release.signal()
        try await waitUntil { cache.cachedLayers(for: .search) != nil }
        try await waitUntil { ((try? first.pixels().centralOrangeFraction) ?? 0) > 0.65 }
        #expect(await reads.count() == 1)
        #expect(sources.count == 1, "image completion must not manufacture another onAppear")
        #expect(telemetry.snapshot.counts().appearances == 1)
        #expect(telemetry.snapshot.appearances.first?.source == .fallback(systemName: "magnifyingglass"))
        first.close()

        let hot = try IconFirstFrameHost0410(content())
        defer { hot.close() }
        try await waitUntil { sources.count == 2 }
        #expect(sources.last == .keyline)
        #expect(telemetry.snapshot.counts().appearances == 2)
        #expect(telemetry.snapshot.counts().uniqueInstances == 2)
        #expect(telemetry.snapshot.appearances.map(\.source) == sources)
        #expect(try hot.pixels().centralOrangeFraction > 0.65)
        #expect(await reads.count() == 1, "success cache must feed the new body's first appearance without rereading")
    }

    @Test("actual failed native mount keeps fallback and redraws never retry filesystem work",
          .enabled(if: ProcessInfo.processInfo.environment["MINISCANVAS_ICON_STARTUP_UI_CONSUMER"] == "1",
                   "requires sole UI owner and unchanged native formal-test host"),
          arguments: [false, true])
    func failedBodyRetainsHonestFallbackWithoutRedrawRetries(invalid: Bool) async throws {
        let reads = IconFirstFrameReads0410()
        let cache = MinisIconLayerCache { icon in
            await MinisIconView.readLayerBytes(for: icon) { _ in
                let onMain = Thread.isMainThread
                Task { await reads.started(onMain: onMain) }
                return invalid ? MinisIconLayerBytes(primary: Data([0]), secondary: Data([1])) : nil
            }
        }
        let telemetry = MinisIconRenderTelemetry()
        var sources: [MinisIconRenderSource] = []
        let host = try IconFirstFrameHost0410(
            MinisIconView(.search, state: .active, size: 40, cache: cache,
                          onAppearRender: { _, source in sources.append(source) })
                .observingMinisIconRenders(using: telemetry, scene: .mainWindow)
                .frame(width: 80, height: 80).background(Color.white)
        )
        defer { host.close() }
        try await waitUntil { await reads.count() == 1 && sources.count == 1 }
        for width in [100.0, 120.0, 80.0] {
            host.resize(width: width)
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(sources == [.fallback(systemName: "magnifyingglass")])
        #expect(telemetry.snapshot.counts().appearances == 1)
        #expect(telemetry.snapshot.appearances.map(\.source) == sources)
        #expect(cache.cachedLayers(for: .search) == nil)
        #expect(!(await reads.onMain()))
        #expect(await reads.count() == 1)
        let pixels = try host.pixels()
        #expect(pixels.orangePixels > 0)
        #expect(pixels.centralOrangeFraction < 0.65)
    }

    private func waitUntil(_ predicate: @MainActor () async -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(3))
        while !(await predicate()) {
            try #require(clock.now < deadline, "actual native body/reader/bitmap state did not become ready")
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func fixtureBytes() throws -> MinisIconLayerBytes {
        func png(_ color: NSColor) throws -> Data {
            let bitmap = try #require(NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 32, bitsPerPixel: 32))
            for x in 0..<8 { for y in 0..<8 { bitmap.setColor(color, atX: x, y: y) } }
            return try #require(bitmap.representation(using: .png, properties: [:]))
        }
        // A solid primary and transparent secondary are owned test pixels.
        // No user or branded resource is replaced by this fixture.
        return try MinisIconLayerBytes(primary: png(.white), secondary: png(.clear))
    }
}

private actor IconFirstFrameReads0410 {
    private var readCount = 0
    private var mainThread = false
    func started(onMain: Bool) { readCount += 1; mainThread = mainThread || onMain }
    func count() -> Int { readCount }
    func onMain() -> Bool { mainThread }
}

@MainActor
private final class IconFirstFrameHost0410<Content: View> {
    let window: NSWindow
    private let controller: NSHostingController<Content>
    private var closed = false

    init(_ content: Content) throws {
        try #require(NSApplication.shared.isRunning, "requires unchanged native test entry")
        try #require(FormalTestIsolationPaths.resolveCurrentProcess() != nil,
                     "must use the original nine-key formal-test contract")
        let lease = NativeTestHostLifecycle.begin("IconFirstFrame0410")
        controller = NSHostingController(rootView: content)
        controller.sizingOptions = []
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 80, height: 80),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        NativeTestHostLifecycle.bind(lease, to: window)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        resize(width: 80)
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

    func pixels() throws -> (orangePixels: Int, centralOrangeFraction: Double) {
        window.layoutIfNeeded()
        controller.view.layoutSubtreeIfNeeded()
        controller.view.display()
        let bitmap = try #require(controller.view.bitmapImageRepForCachingDisplay(in: controller.view.bounds))
        controller.view.cacheDisplay(in: controller.view.bounds, to: bitmap)
        let left = bitmap.pixelsWide / 3, right = bitmap.pixelsWide * 2 / 3
        let bottom = bitmap.pixelsHigh / 3, top = bitmap.pixelsHigh * 2 / 3
        var orange = 0, central = 0, centralCount = 0
        for x in 0..<bitmap.pixelsWide {
            for y in 0..<bitmap.pixelsHigh {
                let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB)
                // 第 1 套陶土橙 A84E2A（浅色强调，取代原 A7A 橙 D97707）；测试的是渲染出来的
                // 像素，而不是拿 token 跟自己比较。
                let matches = color.map {
                    abs($0.redComponent - 168.0 / 255) < 0.10 &&
                    abs($0.greenComponent - 78.0 / 255) < 0.10 &&
                    abs($0.blueComponent - 42.0 / 255) < 0.10 && $0.alphaComponent > 0.9
                } ?? false
                if matches { orange += 1 }
                if x >= left && x < right && y >= bottom && y < top {
                    centralCount += 1
                    if matches { central += 1 }
                }
            }
        }
        try #require(centralCount > 0)
        return (orange, Double(central) / Double(centralCount))
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
