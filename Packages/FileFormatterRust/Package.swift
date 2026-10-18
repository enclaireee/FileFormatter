// swift-tools-version: 6.0
import Foundation
import PackageDescription

let packageDirectory = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .path

let package = Package(
    name: "FileFormatterRust",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "FileFormatterRust", targets: ["FileFormatterRust"])
    ],
    targets: [
        .target(
            name: "fileformatter_coreFFI",
            path: "Sources/CFFI",
            publicHeadersPath: "include",
            linkerSettings: [
                .unsafeFlags([
                    "-L\(packageDirectory)/Vendor",
                    "-lfileformatter_core"
                ])
            ]
        ),
        .target(
            name: "FileFormatterRust",
            dependencies: ["fileformatter_coreFFI"],
            path: "Sources/FileFormatterRust"
        )
    ]
)
