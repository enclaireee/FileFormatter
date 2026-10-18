// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FileFormatterCore",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "FileFormatterCore", targets: ["FileFormatterCore"])
    ],
    dependencies: [
        .package(path: "../FileFormatterRust")
    ],
    targets: [
        .target(
            name: "FileFormatterCore",
            dependencies: [
                .product(name: "FileFormatterRust", package: "FileFormatterRust")
            ],
            path: "Sources/FileFormatterCore"
        ),
        .testTarget(
            name: "FileFormatterCoreTests",
            dependencies: ["FileFormatterCore"],
            path: "Tests/FileFormatterCoreTests"
        )
    ]
)
