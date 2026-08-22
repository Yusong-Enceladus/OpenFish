// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OpenCodexIOS",
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "OpenCodexIOS", targets: ["XIOS"]),
    ],
    dependencies: [
        .package(url: "https://github.com/gonzalezreal/swift-markdown-ui", exact: "2.4.1"),
    ],
    targets: [
        .target(
            name: "XIOS",
            dependencies: [
                .product(name: "MarkdownUI", package: "swift-markdown-ui"),
            ],
            path: "Sources/XiOS"
        ),
    ]
)
