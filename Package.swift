// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "HEYCliKit",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(
            name: "HEYCliKit",
            targets: ["HEYCliKit"]
        ),
        .library(
            name: "HEYCliKitTestSupport",
            targets: ["HEYCliKitTestSupport"]
        )
    ],
    targets: [
        .target(
            name: "HEYCliKit",
            path: "Sources/HEYCliKit",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .target(
            name: "HEYCliKitTestSupport",
            dependencies: ["HEYCliKit"],
            path: "Sources/HEYCliKitTestSupport",
            resources: [
                .copy("Fixtures")
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .testTarget(
            name: "HEYCliKitTests",
            dependencies: ["HEYCliKit", "HEYCliKitTestSupport"],
            path: "Tests/HEYCliKitTests",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        )
    ]
)
