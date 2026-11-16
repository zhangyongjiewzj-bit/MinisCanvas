import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

@Suite("K39 provider launch consumer")
@MainActor
struct ProviderLaunchConsumerTests {
    @Test("snapshot preserves healthy and degraded providers independently")
    func snapshotKeepsIndependentHealth() {
        let snapshot = ProviderLaunchSnapshot(statuses: [
            ProviderLaunchStatus(
                providerID: "broken",
                state: .degraded(.keychainUnavailable)
            ),
            ProviderLaunchStatus(providerID: "healthy", state: .ready)
        ])

        #expect(snapshot.readyProviderIDs == ["healthy"])
        #expect(snapshot.degradedProviderIDs == ["broken"])
        #expect(snapshot.status(for: "HEALTHY")?.state == .ready)
        #expect(snapshot.status(for: "broken")?.state == .degraded(.keychainUnavailable))
        #expect(snapshot.status(for: "broken")?.state.isRecoverable == true)
    }

    @Test("status callback publishes recovery without retaining the old degraded state")
    func callbackPublishesRecovery() throws {
        let previous = EnvCredentials.supplementarySource
        defer { EnvCredentials.supplementarySource = previous }
        EnvCredentials.supplementarySource = { name in
            name == "RECOVERING" ? "fixture-key" : nil
        }

        let chat = ChatStore()
        var snapshots: [ProviderLaunchSnapshot] = []
        chat.onProviderLaunchSnapshotChanged = { snapshots.append($0) }
        let provider = EnvVarEntry(
            name: "RECOVERING",
            value: "",
            isSecret: true,
            valueInKeychain: true,
            baseURL: "https://provider.example.test/v1",
            modelNames: ["fixture-model"]
        )
        chat.providerRecordsSource = { [provider] }
        chat.setCustomProvider(provider)
        _ = try chat.activeProvider()

        #expect(snapshots.count == 1)
        #expect(snapshots.last?.readyProviderIDs == ["RECOVERING"])
        #expect(snapshots.last?.degradedProviderIDs.isEmpty == true)
    }

    @Test("Settings and turn runtime consume the same launch projection")
    func compositionWiringUsesSharedProjection() throws {
        let root = repositoryRoot()
        let appSource = try String(
            contentsOf: root.appendingPathComponent(
                "src/MinisCanvasApp/Sources/MinisCanvasApp/MinisCanvasApp.swift"
            ),
            encoding: .utf8
        )
        let bridgeSource = try String(
            contentsOf: root.appendingPathComponent(
                "src/MinisCanvasApp/Sources/MinisCanvasApp/BridgeStore.swift"
            ),
            encoding: .utf8
        )
        #expect(appSource.contains("onProviderLaunchSnapshotChanged"))
        #expect(appSource.contains("updateProviderLaunchSnapshot(snapshot)"))
        #expect(
            bridgeSource.contains("providerLaunchSnapshot: chat.providerLaunchSnapshot")
                || bridgeSource.contains("providerLaunchSnapshot: self.chat.providerLaunchSnapshot"),
            "turn snapshots must consume the live ChatStore launch projection"
        )
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
