// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MinisApp",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        .package(path: "../MinisCore")
    ],
    targets: [
        .executableTarget(
            name: "MinisApp",
            dependencies: ["MinisCore"]
        ),
        .testTarget(
            name: "MinisAppTests",
            dependencies: ["MinisApp"]
        )
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
