// swift-tools-version: 6.1
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "DependencyGraph",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
        .package(url: "https://github.com/tuist/XcodeProj", from: "9.0.0")
    ],
    targets: [
        .executableTarget(
            name: "DependencyGraph",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "XcodeProj", package: "XcodeProj")
            ]
        ),
        .testTarget(
            name: "DependencyGraphTests",
            dependencies: ["DependencyGraph"],
            resources: [
                .copy("Fixtures")
            ]
        ),
    ]
)
