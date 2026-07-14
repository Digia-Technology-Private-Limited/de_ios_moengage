// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "DigiaMoEngage",
    platforms: [
        .iOS(.v15),
    ],
    products: [
        .library(
            name: "DigiaMoEngage",
            targets: ["DigiaMoEngage"]
        ),
    ],
    dependencies: [
        // Digia Engage iOS SDK — local sibling checkout used for iOS 15 validation.
        .package(path: "../core"),
        // MoEngage iOS SDK
        .package(
            url: "https://github.com/moengage/MoEngage-iOS-SDK.git",
            from: "9.18.0"
        ),
    ],
    targets: [
        .target(
            name: "DigiaMoEngage",
            dependencies: [
                .product(name: "DigiaEngage", package: "core"),
                .product(name: "MoEngageInApps", package: "MoEngage-iOS-SDK"),
            ],
            path: "Sources/DigiaMoEngage"
        ),
    ]
)
