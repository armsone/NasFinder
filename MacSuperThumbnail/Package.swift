// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "NasFinderSuperThumbnailMac",
    platforms: [.macOS(.v14)],
    products: [
        .executable(
            name: "NasFinderSuperThumbnailMac",
            targets: ["NasFinderSuperThumbnailMac"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.4")
    ],
    targets: [
        .executableTarget(
            name: "NasFinderSuperThumbnailMac",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle")
            ]
        ),
        .testTarget(
            name: "NasFinderSuperThumbnailMacTests",
            dependencies: ["NasFinderSuperThumbnailMac"]
        )
    ],
    swiftLanguageModes: [.v5]
)
