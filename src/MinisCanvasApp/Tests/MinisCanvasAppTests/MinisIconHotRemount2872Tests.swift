import AppKit
import Foundation
import Testing
@testable import MinisCanvasApp

@Suite("2872 hot remount first-display cache consumer", .serialized)
@MainActor
struct MinisIconHotRemount2872Tests {
    @Test("production preparation feeds cached pixels to a fresh mount before its task")
    func hotFirstDisplayUsesPreparedCache() async throws {
        let bytes = try fixtureBytes()
        let reads = IconHotReadGate2872()
        let cache = MinisIconLayerCache { _ in
            await reads.noteRead()
            return bytes
        }
        var firstPublicationHadLayers = false
        await MinisIconView.prepareLayers(for: .search, cache: cache) {
            firstPublicationHadLayers = $0 != nil
        }
        #expect(firstPublicationHadLayers)
        // Exact body selection consumer, with fresh mount State still empty.
        // There is no await or preparation for this new appearance.
        let display = MinisIconView.displaySelection(
            for: .search, ownedIcon: nil, ownedLayers: nil, cache: cache
        )
        #expect(display.layers != nil)
        #expect(display.source == .keyline)
        #expect(await reads.readCount() == 1)
        let unrelated = MinisIconView.displaySelection(
            for: .folder, ownedIcon: .search, ownedLayers: display.layers, cache: cache
        )
        #expect(unrelated.layers == nil)
        #expect(unrelated.source == .fallback(systemName: MinisIcon.folder.fallbackSystemName))
        #expect(await reads.readCount() == 1)
    }

    @Test("unknown and failed entries select honest fallback without initiating reads",
          arguments: [false, true])
    func unknownOrFailedFirstDisplayIsFallback(invalid: Bool) async {
        let reads = IconHotReadGate2872()
        let cache = MinisIconLayerCache { _ in
            await reads.noteRead()
            return invalid ? MinisIconLayerBytes(primary: Data([0]), secondary: Data([1])) : nil
        }
        let cold = MinisIconView.displaySelection(
            for: .search, ownedIcon: nil, ownedLayers: nil, cache: cache
        )
        #expect(cold.layers == nil)
        #expect(cold.source == .fallback(systemName: "magnifyingglass"))
        #expect(await reads.readCount() == 0)
        await MinisIconView.prepareLayers(for: .search, cache: cache) { #expect($0 == nil) }
        for _ in 0..<10 {
            let failed = MinisIconView.displaySelection(
                for: .search, ownedIcon: .search, ownedLayers: nil, cache: cache
            )
            #expect(failed.layers == nil)
            #expect(failed.source == .fallback(systemName: "magnifyingglass"))
        }
        #expect(await reads.readCount() == 1)
    }

    @Test("late cancelled mount cannot change another owner's first-display selection",
          .timeLimit(.minutes(1)))
    func cancelledLateMountPreservesOtherOwnerDisplay() async throws {
        let bytes = try fixtureBytes()
        let gate = IconHotReadGate2872()
        let cache = MinisIconLayerCache { icon in
            if icon == .search { await gate.waitForRelease() }
            return bytes
        }
        await MinisIconView.prepareLayers(for: .folder, cache: cache) { #expect($0 != nil) }
        var retiredPublications = 0
        let retired = Task { @MainActor in
            await MinisIconView.prepareLayers(for: .search, cache: cache) { _ in
                retiredPublications += 1
            }
        }
        await gate.waitUntilBlocked()
        let current = MinisIconView.displaySelection(
            for: .folder, ownedIcon: nil, ownedLayers: nil, cache: cache
        )
        #expect(current.source == .keyline)
        var remainingStarted = false
        var remainingHadLayers = false
        let remaining = Task { @MainActor in
            remainingStarted = true
            await MinisIconView.prepareLayers(for: .search, cache: cache) {
                remainingHadLayers = $0 != nil
            }
        }
        while !remainingStarted { await Task.yield() }
        retired.cancel()
        await gate.release()
        await retired.value
        await remaining.value
        #expect(retiredPublications == 0)
        #expect(remainingHadLayers)
        let stillCurrent = MinisIconView.displaySelection(
            for: .folder, ownedIcon: nil, ownedLayers: nil, cache: cache
        )
        #expect(stillCurrent.source == .keyline)
        #expect(stillCurrent.layers != nil)
        let hotNewMount = MinisIconView.displaySelection(
            for: .search, ownedIcon: nil, ownedLayers: nil, cache: cache
        )
        #expect(hotNewMount.source == .keyline)
        #expect(hotNewMount.layers != nil)
    }

    private func fixtureBytes() throws -> MinisIconLayerBytes {
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 1, pixelsHigh: 1,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 4, bitsPerPixel: 32
        ))
        bitmap.bitmapData?.initialize(repeating: 0, count: 4)
        let bytes = try #require(bitmap.representation(using: .png, properties: [:]))
        return MinisIconLayerBytes(primary: bytes, secondary: bytes)
    }
}

private actor IconHotReadGate2872 {
    private var count = 0
    private var blocked = false
    private var releaseWaiter: CheckedContinuation<Void, Never>?
    private var blockedWaiter: CheckedContinuation<Void, Never>?

    func noteRead() { count += 1 }
    func readCount() -> Int { count }

    func waitForRelease() async {
        blocked = true
        blockedWaiter?.resume()
        blockedWaiter = nil
        await withCheckedContinuation { releaseWaiter = $0 }
    }

    func waitUntilBlocked() async {
        if blocked { return }
        await withCheckedContinuation { blockedWaiter = $0 }
    }

    func release() {
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}
