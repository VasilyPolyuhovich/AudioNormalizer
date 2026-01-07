// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "AudioNormalizer",
    platforms: [
        .iOS(.v18),
        .macOS(.v15)
    ],
    products: [
        .library(
            name: "AudioNormalizer",
            targets: ["AudioNormalizer"]
        ),
    ],
    targets: [
        .target(
            name: "AudioNormalizer",
            dependencies: [],
            path: "Source"
        ),
    ],
    swiftLanguageModes: [.v6]
)
