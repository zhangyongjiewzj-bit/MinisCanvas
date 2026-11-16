import Foundation
import Testing

/// D-CANVAS-28 contract: the production bridge must never attach one DraftStore
/// instance to both persistence domains. This is intentionally a source
/// contract because BridgeStore assembly is the boundary under review; runtime
/// tests cannot observe the private local instances after construction.
struct DCanvas28PersistenceIsolationTests {
    private enum SourceFixtureError: Error, CustomStringConvertible {
        case missingSourceRootEnvironment
        case unreadableAdmissionManifest(URL)
        case invalidAdmissionManifest(URL)
        case missingBridgeStore(URL)

        var description: String {
            switch self {
            case .missingSourceRootEnvironment:
                return "neither MINISCANVAS_SOURCE_ROOT nor an admission manifest candidate root was provided"
            case let .unreadableAdmissionManifest(url):
                return "admission manifest is unreadable: \(url.path)"
            case let .invalidAdmissionManifest(url):
                return "admission manifest has no candidate worktree: \(url.path)"
            case let .missingBridgeStore(url):
                return "BridgeStore.swift fixture is missing or not a regular file: \(url.path)"
            }
        }
    }

    private func bridgeSource() throws -> String {
        let environment = ProcessInfo.processInfo.environment
        let sourceRootPath: String
        if let explicitRoot = environment["MINISCANVAS_SOURCE_ROOT"], !explicitRoot.isEmpty {
            sourceRootPath = explicitRoot
        } else if let manifestPath = environment["RUN_TESTS_ADMISSION_JSON"], !manifestPath.isEmpty {
            let manifestURL = URL(fileURLWithPath: manifestPath)
            guard let data = try? Data(contentsOf: manifestURL) else {
                throw SourceFixtureError.unreadableAdmissionManifest(manifestURL)
            }
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let candidate = object["candidate"] as? [String: Any],
                  let manifestRoot = candidate["worktree"] as? String,
                  !manifestRoot.isEmpty else {
                throw SourceFixtureError.invalidAdmissionManifest(manifestURL)
            }
            sourceRootPath = manifestRoot
        } else {
            // Match the existing source-contract fixtures: this compiled file
            // names its actual checkout, without a runner/environment override.
            sourceRootPath = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent().path
        }
        let sourceRoot = URL(fileURLWithPath: sourceRootPath, isDirectory: true)
            .standardizedFileURL
        let url = sourceRoot
            .appendingPathComponent("src", isDirectory: true)
            .appendingPathComponent("MinisCanvasApp", isDirectory: true)
            .appendingPathComponent("Sources", isDirectory: true)
            .appendingPathComponent("MinisCanvasApp", isDirectory: true)
            .appendingPathComponent("BridgeStore.swift")
        guard FileManager.default.fileExists(atPath: url.path),
              (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
            throw SourceFixtureError.missingBridgeStore(url)
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    @Test("production bridge attaches independent Chat and Canvas draft stores")
    func productionAssemblyUsesIndependentRoots() throws {
        let source = try bridgeSource()
        #expect(source.contains("let chatDrafts = DraftStore(directory: sessionDirectory)"))
        #expect(source.contains("let canvasDrafts = DraftStore("))
        #expect(source.contains("sessionDirectory.appendingPathComponent(\"canvas\", isDirectory: true)"))
        #expect(source.contains("canvas.attachDraftStore(canvasDrafts)"))
        #expect(source.contains("chat.attachDraftStore(chatDrafts)"))
        #expect(!source.contains("let drafts = DraftStore(directory: sessionDirectory)"))
        #expect(!source.contains("canvas.attachDraftStore(drafts)"))
        #expect(!source.contains("chat.attachDraftStore(drafts)"))
    }
}
