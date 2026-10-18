// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "swift-app-kit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SwiftAppKit", targets: ["SwiftAppKit"])
    ],
    targets: [
        .target(name: "SwiftAppKit", path: "Sources/SwiftAppKit")
    ]
)
