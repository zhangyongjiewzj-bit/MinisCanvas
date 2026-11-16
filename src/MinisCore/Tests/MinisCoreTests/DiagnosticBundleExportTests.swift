import Foundation
import Testing
@testable import MinisCore

private func diagnosticTemporaryDirectory(_ label: String) throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "MinisCore-DiagnosticBundle-\(label)-\(UUID().uuidString)",
        isDirectory: true
    )
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func diagnosticFixtureReport() -> HealthReport {
    HealthReport(
        items: [
            HealthItem(
                name: "synthetic-provider",
                category: .providers,
                status: .warning,
                message: "synthetic raw error text should never be copied",
                details: [
                    "synthetic-secret=sk-SYNTHETIC-123456789",
                    "Authorization: Bearer SYNTHETIC-TOKEN",
                    "https://user:secret@example.invalid/v1",
                    "/Users/synthetic/private/project",
                    "完整对话：不要导出这段文本",
                ]
            ),
            HealthItem(
                name: "network",
                category: .network,
                status: .ok,
                message: "已连接",
                details: ["safe-count-only"]
            ),
        ],
        timestamp: Date(timeIntervalSince1970: 1_757_000_000)
    )
}

@Suite("P3-OBS-01 脱敏诊断包")
struct DiagnosticBundleExportTests {

    @Test func projectionUsesOnlyFixedModulesAndUnknownWhenReportMissing() throws {
        let bundle = try DiagnosticBundle(
            application: DiagnosticApplicationInfo(
                version: "1.2.3",
                build: "456",
                platformVersion: "14.6.1",
                architecture: "arm64"
            ),
            runtime: DiagnosticRuntimeSummary(
                appState: .ready,
                activeSessionPresent: true,
                activeSessionStreaming: false
            ),
            capturedAt: Date(timeIntervalSince1970: 1_756_000_000)
        )

        #expect(bundle.schemaVersion == DiagnosticBundle.currentSchemaVersion)
        #expect(bundle.modules.map(\.module) == DiagnosticBundleModule.allCases)
        #expect(bundle.modules.allSatisfy { $0.state == .unknown && $0.itemCount == nil })
        #expect(bundle.health.overall == .unknown)
        #expect(bundle.health.unknownCount == DiagnosticBundleModule.allCases.count)
        #expect(bundle.runtime.networkProbeTriggered == false)

        let data = try DiagnosticBundleExporter().encodedData(for: bundle)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let runtime = try #require(object["runtime"] as? [String: Any])
        #expect(runtime["active_session_present"] as? Bool == true)
        #expect(runtime["active_session_streaming"] as? Bool == false)
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains("health_snapshot_at"))
        #expect(!text.contains("item_count"))
    }

    @Test func encodedBytesContainUsefulSummaryAndNoSyntheticSensitiveValues() throws {
        let bundle = try DiagnosticBundle(
            application: DiagnosticApplicationInfo(
                version: "1.2.3",
                build: "456",
                platformVersion: "14.6.1",
                architecture: "arm64"
            ),
            healthReport: diagnosticFixtureReport(),
            runtime: DiagnosticRuntimeSummary(
                appState: .ready,
                activeSessionPresent: true,
                activeSessionStreaming: true
            ),
            capturedAt: Date(timeIntervalSince1970: 1_756_000_000)
        )
        let data = try DiagnosticBundleExporter().encodedData(for: bundle)
        let text = String(decoding: data, as: UTF8.self)

        for expected in [
            "schema_version",
            "captured_at",
            "platform_version",
            "modules",
            "health",
            "runtime",
            "unknown",
            "providers",
            "network",
            "warning",
            "network_probe_triggered",
        ] {
            #expect(text.contains(expected), "诊断包应包含固定字段 \(expected)")
        }
        for forbidden in [
            "SYNTHETIC",
            "Authorization:",
            "Bearer SYNTHETIC-TOKEN",
            "https://user:secret@example.invalid/v1",
            "/Users/synthetic/private/project",
            "完整对话：不要导出这段文本",
            "synthetic raw error text",
        ] {
            #expect(!text.contains(forbidden), "最终字节不得包含反例：\(forbidden)")
        }
        #expect(data.count <= DiagnosticBundleExporter.maximumBytes)
    }

    @Test func bundleDecodeRejectsUnknownTopLevelSchemaKey() throws {
        let bundle = try DiagnosticBundle(capturedAt: Date(timeIntervalSince1970: 1_756_000_000))
        let data = try DiagnosticBundleExporter().encodedData(for: bundle)
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["unexpected_field"] = "should be rejected"
        let malformed = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])

        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(DiagnosticBundle.self, from: malformed)
        }
    }

    @Test func oversizedHealthReportIsRejectedWithoutTouchingExistingTarget() throws {
        let directory = try diagnosticTemporaryDirectory("oversized")
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("diagnostics.json")
        let oldData = Data("old-target".utf8)
        try oldData.write(to: destination)

        let items = (0..<101).map { index in
            HealthItem(
                id: "synthetic-\(index)",
                name: "module-\(index)",
                category: .storage,
                status: .ok,
                message: "safe"
            )
        }
        do {
            _ = try DiagnosticBundle(healthReport: HealthReport(items: items))
            Issue.record("超大健康报告不应生成诊断快照")
        } catch let error as DiagnosticBundleSnapshotError {
            #expect(error == .tooManyHealthItems)
        } catch {
            Issue.record("应返回 tooManyHealthItems，实际为 \(error)")
        }
        #expect(try Data(contentsOf: destination) == oldData)
    }

    @Test func failedDestinationPreservesExistingTargetAndLeavesNoTempFile() throws {
        let directory = try diagnosticTemporaryDirectory("failed-destination")
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("diagnostics.json")
        let oldData = Data("old-target".utf8)
        try oldData.write(to: destination)

        let missingParent = directory.appendingPathComponent("missing", isDirectory: true)
            .appendingPathComponent("diagnostics.json")
        let bundle = try DiagnosticBundle(capturedAt: Date(timeIntervalSince1970: 1_756_000_000))
        #expect(throws: DiagnosticBundleExportError.destinationUnavailable) {
            try DiagnosticBundleExporter().export(bundle, to: missingParent)
        }
        #expect(try Data(contentsOf: destination) == oldData)
        let siblings = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        #expect(!siblings.contains { $0.lastPathComponent.hasSuffix(".tmp") })
    }

    @Test func outputSizeLimitPreservesExistingTarget() throws {
        let directory = try diagnosticTemporaryDirectory("size-limit")
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("diagnostics.json")
        let oldData = Data("old-target".utf8)
        try oldData.write(to: destination)
        let bundle = try DiagnosticBundle(capturedAt: Date(timeIntervalSince1970: 1_756_000_000))

        #expect(throws: DiagnosticBundleExportError.inputTooLarge) {
            try DiagnosticBundleExporter(maximumOutputBytes: 1).export(bundle, to: destination)
        }
        #expect(try Data(contentsOf: destination) == oldData)
    }

    @Test func cancelledExportPreservesExistingTarget() async throws {
        let directory = try diagnosticTemporaryDirectory("cancelled")
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("diagnostics.json")
        let oldData = Data("old-target".utf8)
        try oldData.write(to: destination)
        let bundle = try DiagnosticBundle(capturedAt: Date(timeIntervalSince1970: 1_756_000_000))
        let exporter = DiagnosticBundleExporter()

        let task = Task { () -> DiagnosticBundleExportError? in
            await Task.yield()
            do {
                _ = try exporter.export(bundle, to: destination)
                return nil
            } catch let error as DiagnosticBundleExportError {
                return error
            } catch {
                return nil
            }
        }
        task.cancel()
        let error = await task.value
        #expect(error == .cancelled)
        #expect(try Data(contentsOf: destination) == oldData)
    }

    @Test func successfulExportReplacesOnlyAtAtomicCompletion() throws {
        let directory = try diagnosticTemporaryDirectory("success")
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("diagnostics.json")
        try Data("old-target".utf8).write(to: destination)
        let bundle = try DiagnosticBundle(
            application: DiagnosticApplicationInfo(version: "1.2.3", build: "456"),
            healthReport: diagnosticFixtureReport(),
            runtime: DiagnosticRuntimeSummary(
                appState: .ready,
                activeSessionPresent: false,
                activeSessionStreaming: false
            ),
            capturedAt: Date(timeIntervalSince1970: 1_756_000_000)
        )

        let exporter = DiagnosticBundleExporter()
        let receipt = try exporter.export(bundle, to: destination)
        let repeatedReceipt = try exporter.export(bundle, to: destination)
        #expect(receipt.destinationURL == destination)
        #expect(repeatedReceipt.destinationURL == destination)
        #expect(receipt.byteCount == (try Data(contentsOf: destination)).count)
        #expect(try Data(contentsOf: destination) != Data("old-target".utf8))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(DiagnosticBundle.self, from: Data(contentsOf: destination))
        #expect(decoded == bundle)
        let siblings = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        #expect(!siblings.contains { $0.lastPathComponent.hasSuffix(".tmp") })
    }
}
