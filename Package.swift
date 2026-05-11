// swift-tools-version: 6.0

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
        // System library — libmtp (LIBMTP_Init() required for macOS USB authorization)
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

        // Native MTP protocol stack — container framing, bulk transfer, session management
        .target(
            name: "CMTPCore",
            path: "Sources/CMTPCore",
            publicHeadersPath: "include",
            cSettings: [
                .unsafeFlags([
                    "-I/opt/homebrew/opt/libusb/include/libusb-1.0",
                    "-I/usr/local/opt/libusb/include/libusb-1.0"
                ])
            ],
            linkerSettings: [
                .linkedLibrary("usb-1.0"),
                .unsafeFlags([
                    "-L/opt/homebrew/opt/libusb/lib",
                    "-L/usr/local/opt/libusb/lib"
                ])
            ]
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
                "CTransferUtils",
                "CMTPCore"
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
    ],
    swiftLanguageModes: [.v6]
)
