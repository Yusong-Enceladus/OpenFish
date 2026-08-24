// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OpenCodexMac",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "OpenCodex", targets: ["XMac"]),
    ],
    targets: [
        .executableTarget(
            name: "XMac",
            path: "Sources/XMac",
            resources: [.process("Resources")]
        ),
    ]
)
