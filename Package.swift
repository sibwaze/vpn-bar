// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "VPNBarApp",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v12)
    ],
    products: [
        .executable(
            name: "VPNBarApp",
            targets: ["VPNBarApp"]
        )
    ],
    dependencies: [],
    targets: [
        .executableTarget(
            name: "VPNBarApp",
            dependencies: [],
            path: "Sources/VPNBarApp",
            resources: [
                .process("Resources")
            ]
        ),
        .testTarget(
            name: "VPNBarAppTests",
            dependencies: ["VPNBarApp"],
            path: "Tests/VPNBarAppTests"
        )
    ]
)
