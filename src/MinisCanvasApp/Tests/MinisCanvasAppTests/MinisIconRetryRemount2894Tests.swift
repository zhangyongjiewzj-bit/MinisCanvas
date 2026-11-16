import AppKit
import Foundation
import Testing
@testable import MinisCanvasApp

@Suite("2894 failed first-display concurrent remount retry consumer")
@MainActor
struct MinisIconRetryRemount2894Tests {
    @Test("failed first display retries once for two remount owners, retaining surviving owner pixels",
          .timeLimit(.minutes(1)))
    func twoRemountsShareRetryAfterFailedFirstRead() async throws {
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 1, pixelsHigh: 1,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 4, bitsPerPixel: 32
        ))
        bitmap.bitmapData?.initialize(repeating: 0, count: 4)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        let bytes = MinisIconLayerBytes(primary: png, secondary: png)
        let reader = RetryReadGate2894()
        let cache = MinisIconLayerCache { _ in
            await reader.nextResult(bytes)
        }
        var firstHadLayers = true
        await MinisIconView.prepareLayers(for: .search, cache: cache) {
            firstHadLayers = $0 != nil
        }
        #expect(!firstHadLayers)
        #expect(await reader.readCount() == 1)
        let failedDisplay = MinisIconView.displaySelection(
            for: .search, ownedIcon: nil, ownedLayers: nil, cache: cache
        )
        #expect(failedDisplay.layers == nil)
        #expect(failedDisplay.source == .fallback(systemName: "magnifyingglass"))

        var retiredPublications = 0
        var survivingPublications = 0
        var survivingHadLayers = false
        let retiredMount = Task { @MainActor in
            await MinisIconView.prepareLayers(for: .search, cache: cache) { _ in
                retiredPublications += 1
            }
        }
        await reader.waitUntilRetryBlocked()
        var survivingStarted = false
        let survivingMount = Task { @MainActor in
            survivingStarted = true
            await MinisIconView.prepareLayers(for: .search, cache: cache) {
                survivingPublications += 1
                survivingHadLayers = $0 != nil
            }
        }
        while !survivingStarted { await Task.yield() }
        // Selection while both mounts await the retry remains pure fallback.
        for _ in 0..<10 {
            let pending = MinisIconView.displaySelection(
                for: .search, ownedIcon: nil, ownedLayers: nil, cache: cache
            )
            #expect(pending.layers == nil)
            #expect(pending.source == .fallback(systemName: "magnifyingglass"))
        }
        #expect(await reader.readCount() == 2)
        retiredMount.cancel()
        await reader.releaseRetry()
        await retiredMount.value
        await survivingMount.value
        #expect(retiredPublications == 0)
        #expect(survivingPublications == 1)
        #expect(survivingHadLayers)
        #expect(await reader.readCount() == 2)

        // Late cancelled publication cannot discard the successful cache used
        // by another surviving/remounted view's real first-display consumer.
        let hotDisplay = MinisIconView.displaySelection(
            for: .search, ownedIcon: nil, ownedLayers: nil, cache: cache
        )
        #expect(hotDisplay.layers != nil)
        #expect(hotDisplay.source == .keyline)
        #expect(await reader.readCount() == 2)
    }
}

private actor RetryReadGate2894 {
    private var count = 0
    private var retryBlocked = false
    private var retryWaiter: CheckedContinuation<Void, Never>?
    private var startedWaiter: CheckedContinuation<Void, Never>?

    func nextResult(_ bytes: MinisIconLayerBytes) async -> MinisIconLayerBytes? {
        count += 1
        if count == 1 { return nil }
        retryBlocked = true
        startedWaiter?.resume()
        startedWaiter = nil
        await withCheckedContinuation { retryWaiter = $0 }
        return bytes
    }

    func waitUntilRetryBlocked() async {
        if retryBlocked { return }
        await withCheckedContinuation { startedWaiter = $0 }
    }

    func releaseRetry() {
        retryWaiter?.resume()
        retryWaiter = nil
    }

    func readCount() -> Int { count }
}
