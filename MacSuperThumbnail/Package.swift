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
    targets: [
        .executableTarget(name: "NasFinderSuperThumbnailMac"),
        .testTarget(
            name: "NasFinderSuperThumbnailMacTests",
            dependencies: ["NasFinderSuperThumbnailMac"]
        )
    ],
    swiftLanguageModes: [.v5]
)
