// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "SimpleImager",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "SimpleImager", targets: ["SimpleImager"])
    ],
    targets: [
        .executableTarget(
            name: "SimpleImager",
            path: "Sources/SimpleImager"
        ),
        .testTarget(
            name: "SimpleImagerTests",
            dependencies: ["SimpleImager"],
            path: "Tests/SimpleImagerTests"
        )
    ]
)
