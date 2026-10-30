// swift-tools-version: 6.4
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "iap-entitlement-engine",
    platforms: [
        .macOS(.v15),
        .iOS(.v18)
    ],
    products: [
        // Products define the executables and libraries a package produces, making them visible to other packages.
        .library(
            name: "IAPEntitlementEngine",
            targets: ["IAPEntitlementEngine"]),
    ],
    dependencies: [
        .package(url: "https://github.com/swift-server-community/APNSwift.git", .upToNextMajor(from: "8.0.0")),
        .package(url: "https://github.com/swift-server/async-http-client.git", .upToNextMajor(from: "1.36.2")),
        .package(url: "https://github.com/apple/swift-http-types.git", .upToNextMajor(from: "1.8.0")),
        .package(url: "https://github.com/apple/swift-nio.git", .upToNextMajor(from: "2.104.0")),
        .package(url: "https://github.com/needle-tail/needletail-logger.git", .upToNextMajor(from: "3.2.1")),
    ],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .target(
            name: "IAPEntitlementEngine",
            dependencies: [
                .product(name: "HTTPTypes", package: "swift-http-types"),
                .product(name: "APNS", package: "APNSwift"),
                .product(name: "APNSCore", package: "APNSwift"),
                .product(name: "AsyncHTTPClient", package: "async-http-client"),
                .product(name: "NeedleTailLogger", package: "needletail-logger"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
            ]
        ),
        .testTarget(
            name: "IAPEntitlementEngineTests",
            dependencies: [
                "IAPEntitlementEngine",
                .product(name: "APNS", package: "APNSwift"),
                .product(name: "APNSCore", package: "APNSwift"),
                .product(name: "AsyncHTTPClient", package: "async-http-client"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
            ]),
    ]
)
