// swift-tools-version: 6.0
import Foundation
import PackageDescription

let packageDirectory = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .path

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
            name: "CWebP",
            path: "Sources/CWebP",
            publicHeadersPath: "include",
            linkerSettings: [
                .unsafeFlags([
                    "-L\(packageDirectory)/Vendor",
                    "-lwebp",
                    "-lsharpyuv"
                ])
            ]
        ),
        .target(
            name: "FileFormatterCore",
            dependencies: [
                .product(name: "FileFormatterRust", package: "FileFormatterRust"),
                "CWebP"
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
