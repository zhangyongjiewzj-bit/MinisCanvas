import Foundation
import Testing
@testable import MinisCanvasApp

@Suite("One app resource owner preserves packaged and DEV lookup contracts")
@MainActor
struct MinisCanvasResourceBundleTests {
    private let payloads: [String: Data] = [
        "KeylineIcons/Raster/filter-primary.png": Data("synthetic-raster".utf8),
        "Legal/LICENSE": Data("synthetic-license".utf8),
        "FieldFixtures/media2397.mp4": Data("synthetic-media".utf8)
    ]

    private func withRoot(_ body: (URL) throws -> Void) throws {
        let root = try B1ARCHOriginalFixtureSupport.makeRoot("resource-owner")
        defer { B1ARCHOriginalFixtureSupport.cleanupRoot(root) }
        try body(root)
    }

    private func makeBundle(at url: URL) throws -> Bundle {
        for (relativePath, bytes) in payloads {
            let file = url.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try bytes.write(to: file, options: .atomic)
        }
        return try #require(Bundle(url: url))
    }

    private func resource(_ relativePath: String, in bundle: Bundle) throws -> URL {
        let path = relativePath as NSString
        let filename = path.lastPathComponent as NSString
        return try #require(bundle.url(
            forResource: filename.deletingPathExtension,
            withExtension: filename.pathExtension.isEmpty ? nil : filename.pathExtension,
            subdirectory: path.deletingLastPathComponent
        ))
    }

    @Test(arguments: ["app", "dev"])
    func packagedResourcesWinBeforeEitherFallback(host: String) throws {
        try withRoot { root in
            let executable = root.appendingPathComponent(
                host == "app" ? "SyntheticMinisCanvas.app" : "minis-dev", isDirectory: true
            )
            let resources = executable.appendingPathComponent("Contents/Resources", isDirectory: true)
            let expected = try makeBundle(at: resources.appendingPathComponent(
                "MinisCanvasApp_MinisCanvasApp.bundle", isDirectory: true
            ))
            let resolution = try #require(MinisCanvasResourceBundle.resolve(
                mainBundleURL: executable, mainResourceURL: resources,
                owningBundle: { fatalError("packaged resources must win before owner fallback") },
                moduleBundle: { fatalError("packaged resources must not evaluate Bundle.module") }
            ))
            #expect(resolution.origin == .packagedResources)
            #expect(resolution.bundle.bundleURL.standardizedFileURL == expected.bundleURL.standardizedFileURL)
            #expect(resolution.resourceURL?.standardizedFileURL == expected.resourceURL?.standardizedFileURL)
            for (relativePath, bytes) in payloads {
                #expect(try Data(contentsOf: resource(relativePath, in: resolution.bundle)) == bytes)
            }
        }
    }

    @Test func devFallbackIsLazyAndReportsItsEffectiveURL() throws {
        try withRoot { root in
            let expected = try makeBundle(at: root.appendingPathComponent("DevResources.bundle"))
            var visits: [String] = []
            let resolution = try #require(MinisCanvasResourceBundle.resolve(
                mainBundleURL: root.appendingPathComponent("minis-dev"), mainResourceURL: nil,
                owningBundle: { visits.append("owner"); return nil },
                moduleBundle: { visits.append("module"); return expected }
            ))
            #expect(visits == ["owner", "module"])
            #expect(resolution.origin == .swiftPackage)
            #expect(resolution.bundle.bundleURL == expected.bundleURL)
            #expect(resolution.resourceURL == expected.resourceURL)
            #expect(try Data(contentsOf: resource("FieldFixtures/media2397.mp4", in: resolution.bundle))
                    == payloads["FieldFixtures/media2397.mp4"])
        }
    }

    @Test func devOwningBundlePrecedesModuleFallback() throws {
        try withRoot { root in
            let expected = try makeBundle(at: root.appendingPathComponent("OwningExecutable.bundle"))
            var ownerVisits = 0
            let resolution = try #require(MinisCanvasResourceBundle.resolve(
                mainBundleURL: root.appendingPathComponent("minis-tests"), mainResourceURL: nil,
                owningBundle: { ownerVisits += 1; return expected },
                moduleBundle: { fatalError("an owning executable must precede module fallback") }
            ))
            #expect(ownerVisits == 1)
            #expect(resolution.origin == .owningExecutable)
            #expect(resolution.bundle.bundleURL == expected.bundleURL)
        }
    }

    @Test(arguments: ["missing", "file", "no-resource-url"])
    func packagedMissingResourcesNeverLoadsExternalOwner(shape: String) throws {
        try withRoot { root in
            let app = root.appendingPathComponent("SyntheticMinisCanvas.app", isDirectory: true)
            let resources = app.appendingPathComponent("Contents/Resources", isDirectory: true)
            try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            if shape == "file" {
                try Data("not a resource directory".utf8).write(to: resources.appendingPathComponent(
                    "MinisCanvasApp_MinisCanvasApp.bundle"
                ))
            }
            let resolution = MinisCanvasResourceBundle.resolve(
                mainBundleURL: app,
                mainResourceURL: shape == "no-resource-url" ? nil : resources,
                owningBundle: { fatalError("an app may not read an external executable's resources") },
                moduleBundle: { fatalError("an app may not read SwiftPM build scratch") }
            )
            #expect(resolution == nil)
        }
    }

    @Test func currentResourcesMatchShippedPayloads() throws {
        let resolution = try #require(MinisCanvasResourceBundle.current)
        #expect(resolution.resourceURL != nil)
        let sourceResources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/MinisCanvasApp/Resources")
        for (sourcePath, bundlePath) in [
            ("ThirdParty/KeylineIcons/Raster/filter-primary.png", "KeylineIcons/Raster/filter-primary.png"),
            ("Legal/LICENSE", "Legal/LICENSE"),
            ("Legal/NOTICE", "Legal/NOTICE"),
            ("FieldFixtures/media2397.mp4", "FieldFixtures/media2397.mp4")
        ] {
            let expected = try Data(contentsOf: sourceResources.appendingPathComponent(sourcePath))
            let actual = try Data(contentsOf: resource(bundlePath, in: resolution.bundle))
            #expect(!actual.isEmpty)
            #expect(actual == expected)
        }
    }
}
