import Foundation
import Testing
@testable import MinisCore

struct CleanRoomBoundaryTests {

    private static let packageNames = [
        "CanvasApp",
        "CanvasCore",
        "MinisApp",
        "MinisCanvasApp",
        "MinisCore"
    ]

    /// Marker for the original developer checkout path. Assembled from parts so this file
    /// itself does not embed a machine-specific absolute path; the string value is unchanged.
    private static let devCheckoutMarker = "/Users/" + "developer" + "/private-checkout"

    private static let forbiddenRuntimeMarkers = [
        "openminis-reference",
        "cl100k_base",
        "tiktoken",
        "A8 provenance evidence",
        Self.devCheckoutMarker,
        "/private/tmp"
    ]

    private static let forbiddenAbsolutePathMarkers = [
        Self.devCheckoutMarker,
        "/private/tmp/p3-grad-",
        "/private/var/folders/",
        "/evidence/",
        "/fixture/",
        "/build/",
        "/control-plane/"
    ]

    private static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // MinisCoreTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // MinisCore
            .deletingLastPathComponent() // src
            .deletingLastPathComponent() // repository root
    }

    @Test
    func referenceTreeIsAbsentFromProductionCheckout() {
        let referenceTree = Self.repositoryRoot
            .appendingPathComponent("src/openminis-reference", isDirectory: true)
        #expect(!FileManager.default.fileExists(atPath: referenceTree.path))
    }

    @Test
    func packageManifestsKeepReferenceAndVocabularyOutsideResourceBoundary() throws {
        for packageName in Self.packageNames {
            let manifest = Self.repositoryRoot
                .appendingPathComponent("src/\(packageName)/Package.swift")
            let source = try String(contentsOf: manifest, encoding: .utf8)

            for marker in Self.forbiddenRuntimeMarkers {
                #expect(!source.contains(marker), "\(packageName)/Package.swift contains \(marker)")
            }
        }

        let minisCoreManifest = Self.repositoryRoot
            .appendingPathComponent("src/MinisCore/Package.swift")
        let source = try String(contentsOf: minisCoreManifest, encoding: .utf8)
        #expect(source.contains("resources: []"),
                "MinisCore must explicitly declare a resource-free production target")
    }

    @Test
    func productionSourcesHaveNoReferenceRuntimeMarkers() throws {
        let fileManager = FileManager.default
        var hits: [String] = []

        for packageName in Self.packageNames {
            let sourceRoot = Self.repositoryRoot
                .appendingPathComponent("src/\(packageName)/Sources", isDirectory: true)
            guard let enumerator = fileManager.enumerator(
                at: sourceRoot,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }

            for case let fileURL as URL in enumerator {
                guard ["swift", "m", "mm", "h", "c", "cpp"].contains(fileURL.pathExtension) else {
                    continue
                }
                let source = try String(contentsOf: fileURL, encoding: .utf8)
                let isResolver = fileURL.lastPathComponent == "DarwinSystemPathResolver.swift"
                for marker in Self.forbiddenRuntimeMarkers
                    where source.contains(marker) && !(isResolver && marker == "/private/tmp") {
                    hits.append("\(fileURL.path):\(marker)")
                }
                for marker in Self.forbiddenAbsolutePathMarkers where source.contains(marker) {
                    hits.append("\(fileURL.path):\(marker)")
                }
            }
        }

        #expect(hits.isEmpty, "production sources must not contain clean-room boundary markers")
    }

    @Test
    func darwinSystemPathResolverIsTheNamedSystemAliasBoundary() throws {
        let sourceURL = Self.repositoryRoot
            .appendingPathComponent("src/MinisCanvasApp/Sources/MinisCanvasApp/SessionDrafts.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        #expect(source.contains("DarwinSystemPathResolver.resolve(directory)"))
        #expect(!source.contains("aliasRoots"))
        #expect(!source.contains("/private/tmp"))
        #expect(!source.contains("realpath"))
        #expect(!source.contains(Self.devCheckoutMarker))
        #expect(!source.contains("/private/tmp/p3-grad-"))
        #expect(!source.contains("/evidence/"))
        #expect(!source.contains("/fixture/"))
        #expect(!source.contains("/build/"))
        #expect(!source.contains("/control-plane/"))

        let resolverURL = Self.repositoryRoot
            .appendingPathComponent("src/MinisCanvasApp/Sources/MinisCanvasApp/DarwinSystemPathResolver.swift")
        let resolver = try String(contentsOf: resolverURL, encoding: .utf8)
        #expect(resolver.contains("enum DarwinSystemPathResolver"))
        #expect(resolver.contains("\"var\": \"/private/var\""))
        #expect(resolver.contains("\"tmp\": \"/private/tmp\""))
        #expect(resolver.contains("\"etc\": \"/private/etc\""))
        #expect(!resolver.contains(Self.devCheckoutMarker))
        #expect(!resolver.contains("/evidence/"))
        #expect(!resolver.contains("/fixture/"))
        #expect(!resolver.contains("/build/"))
        #expect(!resolver.contains("/control-plane/"))
    }

    @Test
    func tokenCounterIsAStableLocalReplacement() {
        let counter = TokenCounter.shared

        #expect(counter.countTokens("hello, world!") == 4)
        #expect(counter.countTokens("你好世界") == 4)
        #expect(counter.countTokens("e\u{301}") == 1)
        #expect(counter.countTokens("hello  world") == 2)
    }
}
