// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "SnapHaul",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "SnapHaulKit",
            targets: ["SnapHaulKit"]
        ),
        .executable(
            name: "SnapHaul",
            targets: ["SnapHaul"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
        .package(url: "https://github.com/daisuke-t-jp/xxHash-Swift.git", from: "1.1.0")
        // Sparkle (auto-updates) is excluded from development builds.
        // Add back when distributing with a Developer ID certificate.
        // .package(url: "https://github.com/sparkle-project/Sparkle.git", from: "2.6.0")
    ],
    targets: [
        // System library — libmtp C bridge
        .systemLibrary(
            name: "CLibMTP",
            path: "Sources/CLibMTP",
            pkgConfig: "libmtp",
            providers: [.brew(["libmtp"])]
        ),

        // C utilities — high-performance file copy, ls parser, Spotlight control
        .target(
            name: "CTransferUtils",
            path: "Sources/CTransferUtils",
            publicHeadersPath: "include"
        ),

        // Shared framework — models, protocols, utilities
        .target(
            name: "SnapHaulKit",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "xxHash-Swift", package: "xxHash-Swift")
            ],
            path: "Sources/MediaIngestKit"
        ),

        // Host app
        .executableTarget(
            name: "SnapHaul",
            dependencies: [
                "SnapHaulKit",
                "CLibMTP",
                "CTransferUtils"
            ],
            path: "Sources/App",
            resources: [
                .copy("Resources")
            ]
        ),

        // Unit tests
        .testTarget(
            name: "SnapHaulTests",
            dependencies: ["SnapHaulKit", "SnapHaul"],
            path: "Tests/UnitTests"
        )
    ]
)
