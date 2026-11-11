// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "AIUsage",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "AIUsage", targets: ["AIUsage"]),
    ],
    targets: [
        .target(name: "AIUsageKit"),
        .executableTarget(name: "AIUsage", dependencies: ["AIUsageKit"]),
        .testTarget(
            name: "AIUsageKitTests",
            dependencies: ["AIUsageKit"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
