// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "CanvasApp",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        .package(path: "../CanvasCore"),
        .package(path: "../MinisCore")
    ],
    targets: [
        .executableTarget(
            name: "CanvasApp",
            dependencies: [
                .product(name: "CanvasCore", package: "CanvasCore"),
                .product(name: "MinisCore", package: "MinisCore")
            ]
        ),
        .testTarget(
            name: "CanvasAppTests",
            dependencies: ["CanvasApp"],
            // CLT-only 工具链（xcode-select 指向 CommandLineTools）下，swift-testing 的
            // Testing.framework 不在默认搜索路径，必须显式 -F；链接与运行时还需 rpath。
            // 固化到包内后，裸 `swift test --package-path src/CanvasApp` 即可真实编译运行
            // 测试（与 run_tests.sh 的 SWIFT_TEST_FLAGS 重复传参无害）。
            swiftSettings: [
                .unsafeFlags(["-F", "/Library/Developer/CommandLineTools/Library/Developer/Frameworks"])
            ],
            linkerSettings: [
                // 显式链接 Testing.framework：SwiftPM 不会自动为 import Testing 的测试
                // target 注入 -framework Testing，缺少会导致 runner 静默发现 0 个测试。
                .linkedFramework("Testing"),
                .unsafeFlags([
                    "-Xlinker", "-F", "-Xlinker", "/Library/Developer/CommandLineTools/Library/Developer/Frameworks",
                    "-Xlinker", "-rpath", "-Xlinker", "/Library/Developer/CommandLineTools/Library/Developer/Frameworks",
                    "-Xlinker", "-rpath", "-Xlinker", "/Library/Developer/CommandLineTools/Library/Developer/usr/lib"
                ])
            ]
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
