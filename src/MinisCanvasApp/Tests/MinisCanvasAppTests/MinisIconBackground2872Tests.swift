import AppKit
import Foundation
import Testing
@testable import MinisCanvasApp

@Suite("2872 icon display background resource ownership", .serialized)
@MainActor
struct MinisIconBackground2872Tests {
    @Test("stalled production I/O preserves main-actor pulse and the remaining same-icon owner",
          .timeLimit(.minutes(1)))
    func stalledReadAndCancelledMount() async throws {
        let bytes = try fixtureBytes()
        let started = IconReadStarted2872()
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let cache = MinisIconLayerCache { icon in
            await MinisIconView.readLayerBytes(for: icon) { _ in
                let onMain = Thread.isMainThread
                Task { await started.markStarted(onMain: onMain) }
                release.wait()
                return bytes
            }
        }
        var retiredPublications = 0
        var remainingPublications = 0
        var remainingHadLayers = false
        var remainingStarted = false
        let retired = Task { @MainActor in
            await MinisIconView.prepareLayers(for: .search, cache: cache) { _ in
                retiredPublications += 1
            }
        }
        await started.waitUntilStarted()
        // This pulse executes while the same production resource queue is
        // stopped before its result. A synchronous UI reader cannot reach it.
        var pulse = false
        await Task { @MainActor in pulse = true }.value
        #expect(pulse)
        #expect(!(await started.didReadOnMain()))
        let remaining = Task { @MainActor in
            remainingStarted = true
            await MinisIconView.prepareLayers(for: .search, cache: cache) { layers in
                remainingPublications += 1
                remainingHadLayers = layers != nil
            }
        }
        while !remainingStarted { await Task.yield() }
        retired.cancel()
        release.signal()
        await retired.value
        await remaining.value
        #expect(retiredPublications == 0)
        #expect(remainingPublications == 1)
        #expect(remainingHadLayers)
        #expect(await started.readCount() == 1)

        // A fresh mount receives the already loaded layers without rereading
        // files; the cancelled mount did not poison the shared resource owner.
        var remountHadLayers = false
        await MinisIconView.prepareLayers(for: .search, cache: cache) { layers in
            remountHadLayers = layers != nil
        }
        #expect(remountHadLayers)
        #expect(await started.readCount() == 1)
    }

    @Test("late retired icon cannot replace the new icon's publication",
          .timeLimit(.minutes(1)))
    func changedIconRejectsLatePublication() async throws {
        let bytes = try fixtureBytes()
        let gate = IconReadStarted2872()
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let cache = MinisIconLayerCache { icon in
            if icon == .search {
                return await MinisIconView.readLayerBytes(for: icon) { _ in
                    let onMain = Thread.isMainThread
                    Task { await gate.markStarted(onMain: onMain) }
                    release.wait()
                    return bytes
                }
            }
            return bytes
        }
        var displayed: MinisIcon?
        let old = Task { @MainActor in
            await MinisIconView.prepareLayers(for: .search, cache: cache) { _ in
                displayed = .search
            }
        }
        await gate.waitUntilStarted()
        old.cancel()
        await MinisIconView.prepareLayers(for: .folder, cache: cache) { layers in
            if layers != nil { displayed = .folder }
        }
        #expect(displayed == .folder)
        release.signal()
        await old.value
        #expect(displayed == .folder)
    }

    @Test("missing or invalid resource data retains fallback and permits a remount retry",
          arguments: [false, true])
    func missingResourcesRemainFallback(invalid: Bool) async {
        let reads = IconReadStarted2872()
        let cache = MinisIconLayerCache { _ in
            await reads.markStarted(onMain: false)
            return invalid ? MinisIconLayerBytes(primary: Data([0]), secondary: Data([1])) : nil
        }
        var result: MinisIconRenderSource?
        for _ in 0..<2 {
            await MinisIconView.prepareLayers(for: .search, cache: cache) { layers in
                result = layers == nil ? .fallback(systemName: MinisIcon.search.fallbackSystemName) : .keyline
            }
            #expect(result == .fallback(systemName: "magnifyingglass"))
        }
        #expect(await reads.readCount() == 2)
    }

    @Test("a temporary failed resource read can recover on the next mount")
    func remountRecoversAfterFailedRead() async throws {
        let bytes = try fixtureBytes()
        let reads = IconReadStarted2872()
        let cache = MinisIconLayerCache { _ in
            await reads.markStarted(onMain: false)
            return await reads.readCount() == 1 ? nil : bytes
        }
        var hadLayers = false
        await MinisIconView.prepareLayers(for: .search, cache: cache) { hadLayers = $0 != nil }
        #expect(!hadLayers)
        await MinisIconView.prepareLayers(for: .search, cache: cache) { hadLayers = $0 != nil }
        #expect(hadLayers)
        #expect(await reads.readCount() == 2)
    }

    private func fixtureBytes() throws -> MinisIconLayerBytes {
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 1, pixelsHigh: 1,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 4, bitsPerPixel: 32
        ))
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        return MinisIconLayerBytes(primary: data, secondary: data)
    }
}

private actor IconReadStarted2872 {
    private var count = 0
    private var onMain = false
    private var waiter: CheckedContinuation<Void, Never>?

    func markStarted(onMain: Bool) {
        count += 1
        self.onMain = self.onMain || onMain
        waiter?.resume()
        waiter = nil
    }

    func waitUntilStarted() async {
        if count > 0 { return }
        await withCheckedContinuation { waiter = $0 }
    }

    func readCount() -> Int { count }
    func didReadOnMain() -> Bool { onMain }
}
