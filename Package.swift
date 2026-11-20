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
        .package(url: "https://github.com/kylebrowning/APNSwift.git", .upToNextMajor(from: "8.0.0")),
        .package(url: "https://github.com/apple/swift-crypto.git", .upToNextMajor(from: "5.0.3")),
        .package(url: "https://github.com/apple/swift-http-types.git", .upToNextMajor(from: "1.8.0")),
        .package(url: "https://github.com/apple/swift-nio.git", .upToNextMajor(from: "2.104.0")),
        // Pinned to the commit that fixes connections that take longer than 250 ms to open.
        // Move to a version once that fix is tagged.
        .package(
            url: "https://github.com/needletails/http-connection-kit.git",
            revision: "602e6c211fa45573433e75042d96d00bf6d44580"),
    ],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .target(
            name: "IAPEntitlementEngine",
            dependencies: [
                .product(name: "HTTPTypes", package: "swift-http-types"),
                .product(name: "APNSCore", package: "APNSwift"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "HTTPConnectionKit", package: "http-connection-kit"),
            ],
            path: "Sources/EntitlementEngine"
        ),
        .testTarget(
            name: "IAPEntitlementEngineTests",
            dependencies: [
                "IAPEntitlementEngine",
                .product(name: "APNSCore", package: "APNSwift"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "HTTPConnectionKit", package: "http-connection-kit"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
            ],
            path: "Tests/EntitlementEngineTests"),
    ]
)
