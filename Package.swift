// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "Aereo",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .executable(
            name: "Aereo",
            targets: ["AereoApp"]
        ),
        .library(
            name: "AereoCore",
            targets: ["AereoCore"]
        ),
    ],
    dependencies: [],
    targets: [
        // MARK: - App Target
        .executableTarget(
            name: "AereoApp",
            dependencies: [
                "AereoCore",
                "AereoUI",
            ],
            path: "Sources/AereoApp"
        ),

        // MARK: - Core Engine
        .target(
            name: "AereoCore",
            dependencies: [],
            path: "Sources/AereoCore"
        ),

        // MARK: - SwiftUI Interface
        .target(
            name: "AereoUI",
            dependencies: ["AereoCore"],
            path: "Sources/AereoUI"
        ),

        // MARK: - Tests
        .testTarget(
            name: "AereoCoreTests",
            dependencies: ["AereoCore"],
            path: "Tests/AereoCoreTests"
        ),
    ]
)
