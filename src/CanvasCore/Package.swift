// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "CanvasCore",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "CanvasCore", targets: ["CanvasCore"]),
        .executable(name: "CanvasPerfBenchmark", targets: ["CanvasPerfBenchmark"]),
        .executable(name: "CanvasPerfBaseline", targets: ["CanvasPerfBaseline"])
    ],
    targets: [
        .target(name: "CanvasCore"),
        .executableTarget(name: "CanvasPerfBenchmark", dependencies: ["CanvasCore"]),
        .executableTarget(name: "CanvasPerfBaseline", dependencies: ["CanvasCore"]),
        .testTarget(name: "CanvasCoreTests", dependencies: ["CanvasCore"]),
        .testTarget(name: "CanvasPerfBaselineTests", dependencies: ["CanvasCore"])
    ]
)

// D-CONC1: keep ordinary package builds in Swift 6 complete checking, and
// make every compiler warning fail the build instead of silently shipping it.
for target in package.targets {
    target.swiftSettings = (target.swiftSettings ?? []) + [
        .swiftLanguageMode(.v6),
        .unsafeFlags(["-strict-concurrency=complete", "-warnings-as-errors"])
    ]
}
