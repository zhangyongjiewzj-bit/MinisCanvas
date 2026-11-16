import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

private func appDiagnosticTemporaryDirectory(_ label: String) throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "MinisCanvasApp-DiagnosticExport-\(label)-\(UUID().uuidString)",
        isDirectory: true
    )
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

@Suite("P3-OBS-01 App 脱敏诊断导出 consumer")
@MainActor
struct DiagnosticExportConsumerTests {

    private func makeController(report: HealthReport? = nil) -> DiagnosticExportController {
        DiagnosticExportController(
            healthReportProvider: { report },
            applicationInfoProvider: {
                DiagnosticApplicationInfo(
                    version: "1.2.3",
                    build: "456",
                    platformVersion: "14.6.1",
                    architecture: "arm64"
                )
            },
            runtimeSummaryProvider: {
                DiagnosticRuntimeSummary(
                    appState: .ready,
                    activeSessionPresent: true,
                    activeSessionStreaming: false
                )
            },
            clock: { Date(timeIntervalSince1970: 1_756_000_000) }
        )
    }

    @Test func currentCachedProviderFailureReachesExportWithoutAnotherProbe() async throws {
        let isolated = try RuntimeIsolationProfile.makeIsolatedTest(
            label: "diagnostic-cached-failure", processEnvironment: ["SWIFT_TESTING_ENABLED": "1"],
            processArguments: ["swiftpm-testing-helper"])
        defer { try? FileManager.default.removeItem(at: isolated.rootDirectory) }
        let root = isolated.rootDirectory
        let domain = "diagnostic-cache-" + UUID().uuidString
        defer { UserDefaults(suiteName: domain)?.removePersistentDomain(forName: domain) }
        let keychain = KeychainStore(backing: InMemoryKeychainBacking())
        let center = SettingsCenter(
            settingsStore: SettingsStore(directory: root.appendingPathComponent("settings")),
            envStore: EnvVarStore(directory: root.appendingPathComponent("providers"), keychain: keychain),
            memoryStore: MemoryStore(directory: root.appendingPathComponent("memory")),
            sessionStore: SessionStore(directory: isolated.sessionDirectory),
            logManager: LogManager(directory: root.appendingPathComponent("logs")),
            mcpManager: MCPServerManager(fileURL: root.appendingPathComponent("mcp.json"), keychain: keychain),
            skillStore: SkillStore(skillsRoot: root.appendingPathComponent("skills")),
            usageStore: UsageStore(domain: .suite(domain)),
            providerReadinessTransport: FailClosedProviderReadinessTransport(),
            providerReadinessDeployment: .remote)
        let name = "DIAGNOSTIC_SYNTHETIC_PROVIDER"
        #expect(center.saveProvider(name: name, apiKey: "private-diagnostic-value",
            baseURL: "https://fixture.invalid/v1", modelNames: ["model"], protocolType: .openaiCompatible))
        #expect(center.diagnosticCachedFailures() == nil)
        let report = try #require(await center.checkProviderReadiness(forProviderName: name))
        #expect(report.reachability.status == .failed)
        let now = report.checkedAt.addingTimeInterval(1)
        let health = DiagnosticHealthRunController(profile: isolated, checker: { _ in
            Issue.record("Export must not run the storage probe")
            return .refused
        }, cachedFailureReportProvider: { center.diagnosticCachedFailures(now: now) }, clock: { now })
        let exporter = DiagnosticExportController(healthReportProvider: { health.reportForExport() }, clock: { now })
        let bundle = try exporter.makeBundle()
        #expect(bundle.modules.first { $0.module == .providers }?.state == .error)
        #expect(bundle.modules.first { $0.module == .network }?.state == .error)
        #expect(bundle.modules.first { $0.module == .storage }?.state == .unknown)
        #expect(bundle.healthSnapshotAt == report.checkedAt)
        #expect(!bundle.runtime.networkProbeTriggered)
        let text = String(decoding: try JSONEncoder().encode(bundle), as: UTF8.self)
        #expect(!text.contains(root.path) && !text.contains("private-diagnostic-value"))
        #expect(!text.contains("fixture.invalid") && !text.contains(name))
        #expect(center.diagnosticCachedFailures(now: report.checkedAt.addingTimeInterval(601)) == nil)
        #expect(center.diagnosticCachedFailures(now: report.checkedAt.addingTimeInterval(-1)) == nil)

        // This production mutation bypasses SettingsCenter's local cache
        // invalidator. Reload leaves the old report, whose binding must fail.
        #expect(center.envStore.saveProvider(name: name, credential: .keepExisting,
            baseURL: "https://changed.invalid/v1", modelNames: ["model"], protocolType: .openaiCompatible))
        center.reloadEnv()
        #expect(!center.providerReadinessReports.isEmpty)
        #expect(center.diagnosticCachedFailures(now: now) == nil)
        #expect(try exporter.makeBundle().modules.allSatisfy { $0.state == .unknown })

        _ = try #require(await center.checkProviderReadiness(forProviderName: name))
        let liveNow = Date()
        let reboundHealth = DiagnosticHealthRunController(profile: isolated, checker: { _ in .refused },
            cachedFailureReportProvider: { center.diagnosticCachedFailures(now: liveNow) }, clock: { liveNow })
        let reboundExport = DiagnosticExportController(
            healthReportProvider: { reboundHealth.reportForExport() }, clock: { liveNow })
        #expect(try reboundExport.makeBundle().modules.contains { $0.state == .error })
        let displaced = root.deletingLastPathComponent().appendingPathComponent(root.lastPathComponent + "-displaced")
        defer { try? FileManager.default.removeItem(at: displaced) }
        try FileManager.default.moveItem(at: root, to: displaced)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        #expect(!isolated.isDisposableRootIntact)
        #expect(try reboundExport.makeBundle().modules.allSatisfy { $0.state == .unknown })
    }

    @Test func controllerWritesRealLocalArtifactAndReportsReceipt() async throws {
        let directory = try appDiagnosticTemporaryDirectory("success")
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("diagnostics.json")
        let controller = makeController()

        await controller.export(to: destination)

        guard case .succeeded(let receipt) = controller.state else {
            Issue.record("导出应返回成功 receipt，实际状态为 \(controller.state)")
            return
        }
        #expect(receipt.destinationURL == destination)
        #expect(receipt.byteCount > 0)
        #expect(FileManager.default.fileExists(atPath: destination.path))
        let data = try Data(contentsOf: destination)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let bundle = try decoder.decode(DiagnosticBundle.self, from: data)
        #expect(bundle.modules.map(\.module) == DiagnosticBundleModule.allCases)
        #expect(bundle.health.overall == .unknown)
        #expect(bundle.runtime.networkProbeTriggered == false)
    }

    @Test func completedReceiptIgnoresLateAndRepeatedCancelRequests() async throws {
        let directory = try appDiagnosticTemporaryDirectory("late-cancel")
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("diagnostics.json")
        let controller = makeController()

        await controller.export(to: destination)

        guard case .succeeded(let receipt) = controller.state else {
            Issue.record("导出应先完成，才能验证提交后的迟到取消")
            return
        }
        let completedData = try Data(contentsOf: destination)
        controller.cancel()
        controller.cancel()

        #expect(controller.state == .succeeded(receipt))
        #expect(try Data(contentsOf: destination) == completedData)
    }

    @Test func controllerFinalBytesDropSyntheticSensitiveReportFields() async throws {
        let directory = try appDiagnosticTemporaryDirectory("redaction")
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("diagnostics.json")
        let report = HealthReport(items: [
            HealthItem(
                name: "synthetic-provider",
                category: .providers,
                status: .error,
                message: "synthetic raw error text",
                details: [
                    "sk-SYNTHETIC-123456789",
                    "Authorization: Bearer SYNTHETIC-TOKEN",
                    "https://user:secret@example.invalid/v1",
                    "/Users/synthetic/private/project",
                    "完整对话：不要导出这段文本",
                ]
            ),
        ])
        let controller = makeController(report: report)

        await controller.export(to: destination)

        #expect(controller.lastReceipt != nil)
        let text = String(decoding: try Data(contentsOf: destination), as: UTF8.self)
        for forbidden in [
            "SYNTHETIC",
            "Authorization:",
            "https://user:secret@example.invalid/v1",
            "/Users/synthetic/private/project",
            "完整对话：不要导出这段文本",
            "synthetic raw error text",
        ] {
            #expect(!text.contains(forbidden), "App consumer 最终字节不得包含：\(forbidden)")
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let bundle = try decoder.decode(DiagnosticBundle.self, from: Data(text.utf8))
        #expect(bundle.health.overall == .error)
    }

    @Test func controllerCancellationNeverReportsSuccessOrCreatesTarget() async throws {
        let directory = try appDiagnosticTemporaryDirectory("cancel")
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("diagnostics.json")
        let controller = makeController()
        let oldData = Data("old-target".utf8)
        try oldData.write(to: destination)

        let task = Task { @MainActor in
            await controller.export(to: destination)
        }
        task.cancel()
        await task.value

        #expect(controller.state == .cancelled)
        #expect(try Data(contentsOf: destination) == oldData)
    }

    @Test func oversizedReportIsRejectedAndExistingTargetRemainsUnchanged() async throws {
        let directory = try appDiagnosticTemporaryDirectory("oversized")
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("diagnostics.json")
        let oldData = Data("old-target".utf8)
        try oldData.write(to: destination)
        let report = HealthReport(items: (0..<101).map { index in
            HealthItem(
                id: "synthetic-\(index)",
                name: "storage-\(index)",
                category: .storage,
                status: .ok,
                message: "safe"
            )
        })
        let controller = makeController(report: report)

        await controller.export(to: destination)

        #expect(controller.failureReason == .snapshotTooLarge)
        #expect(try Data(contentsOf: destination) == oldData)
    }

    @Test func menuAndViewKeepExportSeparateFromExplicitHealthRun() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let appSource = try String(
            contentsOf: packageRoot.appendingPathComponent("Sources/MinisCanvasApp/MinisCanvasApp.swift"),
            encoding: .utf8
        )
        let viewSource = try String(
            contentsOf: packageRoot.appendingPathComponent("Sources/MinisCanvasApp/DiagnosticExportView.swift"),
            encoding: .utf8
        )
        let controllerSource = try String(
            contentsOf: packageRoot.appendingPathComponent("Sources/MinisCanvasApp/DiagnosticExportController.swift"),
            encoding: .utf8
        )

        #expect(appSource.contains("导出脱敏诊断包…"))
        #expect(appSource.contains("checker: DiagnosticIsolatedStorageProbe.check"))
        #expect(appSource.contains("diagnosticHealth?.reportForExport()"))
        #expect(appSource.contains("healthController: diagnosticHealthRunController"))
        #expect(viewSource.contains("NSSavePanel()"))
        #expect(viewSource.contains("controller.export(to: destinationURL)"))
        #expect(viewSource.contains("await healthController.run()"))
        #expect(controllerSource.contains("DiagnosticBundle("))
        #expect(!controllerSource.contains("DiagnosticRunner("))
    }
}
