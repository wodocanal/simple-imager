// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "SDCardCopy",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "SDCardCopy", targets: ["SDCardCopy"])
    ],
    targets: [
        .executableTarget(
            name: "SDCardCopy",
            path: "Sources/SDCardCopy"
        ),
        .testTarget(
            name: "SDCardCopyTests",
            dependencies: ["SDCardCopy"],
            path: "Tests/SDCardCopyTests"
        )
    ]
)
