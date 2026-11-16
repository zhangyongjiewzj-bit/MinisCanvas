import Foundation
import Testing
@testable import MinisCanvasApp

/// D-CONC2: production ChatStore load/refresh ownership under an inverted completion order.
@Suite("D-CONC2 ChatStore picker catalog generation")
@MainActor
struct CONC2PickerCatalogGenerationConsumerTests {
    @Test func loadCompletesBeforeRefreshWithoutPublishingStaleCatalog() async throws {
        let chat = ChatStore()
        let stale = PickerCatalogItem(id: "skill:stale", kind: .skill, name: "stale", detail: "")
        let refreshed = PickerCatalogItem(id: "skill:refreshed", kind: .skill, name: "refreshed", detail: "")
        let loadEntered = DispatchSemaphore(value: 0)
        let releaseLoad = DispatchSemaphore(value: 0)
        let refreshEntered = DispatchSemaphore(value: 0)
        let releaseRefresh = DispatchSemaphore(value: 0)
        defer {
            releaseLoad.signal()
            releaseRefresh.signal()
        }

        chat.pickerCatalogLoader = {
            loadEntered.signal()
            guard releaseLoad.wait(timeout: .now() + 10) == .success else { return [] }
            return [stale]
        }
        chat.pickerCatalogRefreshLoader = {
            refreshEntered.signal()
            guard releaseRefresh.wait(timeout: .now() + 10) == .success else { return [] }
            return [refreshed]
        }

        let olderLoad = chat.loadPickerCatalogInBackground()
        let loadStarted = await Task.detached {
            waitForPickerSignal(loadEntered, timeoutSeconds: 5)
        }.value
        #expect(loadStarted)
        guard loadStarted else { return }

        chat.refreshPickerCatalogInBackground()
        let refreshStarted = await Task.detached {
            waitForPickerSignal(refreshEntered, timeoutSeconds: 5)
        }.value
        #expect(refreshStarted)
        guard refreshStarted else { return }

        releaseLoad.signal()
        await olderLoad.value
        #expect(chat.pickerCatalog.isEmpty,
                "A superseded load must not publish while refresh is still in flight")
        #expect(chat.isPickerCatalogLoading,
                "The superseded load must not clear refresh loading ownership")

        releaseRefresh.signal()
        for _ in 0..<100 where chat.pickerCatalog.map(\.id) != ["skill:refreshed"] {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(chat.pickerCatalog.map(\.id) == ["skill:refreshed"])
        #expect(!chat.isPickerCatalogLoading)
    }

    @Test func olderCatalogLoadCannotOverwriteCompletedRefresh() async throws {
        let chat = ChatStore()
        let old = PickerCatalogItem(id: "skill:old", kind: .skill, name: "old", detail: "")
        let refreshed = PickerCatalogItem(id: "skill:refreshed", kind: .skill, name: "refreshed", detail: "")
        let oldEntered = DispatchSemaphore(value: 0)
        let releaseOld = DispatchSemaphore(value: 0)
        let refreshEntered = DispatchSemaphore(value: 0)
        let releaseRefresh = DispatchSemaphore(value: 0)
        defer {
            releaseOld.signal()
            releaseRefresh.signal()
        }

        chat.pickerCatalogLoader = {
            oldEntered.signal()
            guard releaseOld.wait(timeout: .now() + 10) == .success else { return [] }
            return [old]
        }
        chat.pickerCatalogRefreshLoader = {
            refreshEntered.signal()
            guard releaseRefresh.wait(timeout: .now() + 10) == .success else { return [] }
            return [refreshed]
        }

        let olderLoad = chat.loadPickerCatalogInBackground()
        let loadStarted = await Task.detached {
            waitForPickerSignal(oldEntered, timeoutSeconds: 5)
        }.value
        #expect(loadStarted, "The older production load must reach its controlled barrier")
        guard loadStarted else { return }

        chat.refreshPickerCatalogInBackground()
        let refreshStarted = await Task.detached {
            waitForPickerSignal(refreshEntered, timeoutSeconds: 5)
        }.value
        #expect(refreshStarted, "The production refresh must reach its controlled barrier")
        guard refreshStarted else { return }

        releaseRefresh.signal()
        for _ in 0..<100 where chat.pickerCatalog.map(\.id) != ["skill:refreshed"] {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(chat.pickerCatalog.map(\.id) == ["skill:refreshed"],
                "The refresh must publish before the older load is released")

        chat.togglePickerItem(refreshed)
        #expect(chat.selectedPickerItems.map(\.id) == ["skill:refreshed"])

        releaseOld.signal()
        await olderLoad.value
        #expect(chat.pickerCatalog.map(\.id) == ["skill:refreshed"],
                "A late older load must not replace a newer completed refresh")
        #expect(chat.selectedPickerItems.map(\.id) == ["skill:refreshed"],
                "The older load must not prune a selection from the refreshed catalog")
        #expect(chat.draftText == "@refreshed",
                "The older load must not erase the refreshed selection from the draft")
    }

    @Test func olderCatalogLoadCannotClearNewerLoadOwnership() async throws {
        let chat = ChatStore()
        let refreshed = PickerCatalogItem(id: "skill:refreshed", kind: .skill, name: "refreshed", detail: "")
        let newer = PickerCatalogItem(id: "skill:newer", kind: .skill, name: "newer", detail: "")
        let oldEntered = DispatchSemaphore(value: 0)
        let releaseOld = DispatchSemaphore(value: 0)
        let newEntered = DispatchSemaphore(value: 0)
        let releaseNew = DispatchSemaphore(value: 0)
        defer {
            releaseOld.signal()
            releaseNew.signal()
            releaseNew.signal()
        }

        chat.pickerCatalogLoader = {
            oldEntered.signal()
            guard releaseOld.wait(timeout: .now() + 10) == .success else { return [] }
            return []
        }
        let olderLoad = chat.loadPickerCatalogInBackground()
        let oldStarted = await Task.detached {
            waitForPickerSignal(oldEntered, timeoutSeconds: 5)
        }.value
        #expect(oldStarted)
        guard oldStarted else { return }

        chat.pickerCatalogRefreshLoader = { [refreshed] }
        chat.refreshPickerCatalogInBackground()
        for _ in 0..<100 where chat.pickerCatalog.map(\.id) != ["skill:refreshed"] {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(chat.pickerCatalog.map(\.id) == ["skill:refreshed"])
        guard chat.pickerCatalog.map(\.id) == ["skill:refreshed"] else { return }

        chat.pickerCatalogLoader = {
            newEntered.signal()
            guard releaseNew.wait(timeout: .now() + 10) == .success else { return [] }
            return [newer]
        }
        let newerLoad = chat.loadPickerCatalogInBackground()
        let newStarted = await Task.detached {
            waitForPickerSignal(newEntered, timeoutSeconds: 5)
        }.value
        #expect(newStarted)
        guard newStarted else { return }

        releaseOld.signal()
        await olderLoad.value
        #expect(chat.isPickerCatalogLoading,
                "The old completion must not clear the newer in-flight load state")

        let repeatedRequest = chat.loadPickerCatalogInBackground()
        let duplicateStarted = await Task.detached {
            waitForPickerSignal(newEntered, timeoutSeconds: 1)
        }.value
        #expect(!duplicateStarted,
                "The old completion must not clear the newer task handle and start a duplicate scan")

        releaseNew.signal()
        releaseNew.signal()
        await newerLoad.value
        await repeatedRequest.value
        #expect(chat.pickerCatalog.map(\.id) == ["skill:newer"])
    }
}

// Keep timed semaphore waits in a synchronous detached-worker helper. The
// async tests await the worker, so the production loader's gated order and
// original 5/1-second observation windows remain unchanged.
private func waitForPickerSignal(
    _ signal: DispatchSemaphore, timeoutSeconds: Int
) -> Bool {
    signal.wait(timeout: .now() + DispatchTimeInterval.seconds(timeoutSeconds)) == .success
}
