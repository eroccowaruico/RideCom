// swift-tools-version: 6.3

import PackageDescription

let package = Package(
    name: "CallControl",
    platforms: [.iOS("27.0"), .macOS("27.0"), .watchOS("27.0")],
    products: [.library(name: "CallControl", targets: ["CallControl"])],
    targets: [
        .target(name: "CallControl"),
        .testTarget(name: "CallControlTests", dependencies: ["CallControl"]),
    ],
    swiftLanguageModes: [.v6]
)
