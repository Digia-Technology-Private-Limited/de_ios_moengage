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
        // Digia Engage iOS SDK
        .package(url: "https://github.com/Digia-Technology-Private-Limited/de_ios_core.git", from: "3.13.2"),
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
                .product(name: "DigiaEngage", package: "de_ios_core"),
                .product(name: "MoEngageInApps", package: "MoEngage-iOS-SDK"),
            ],
            path: "Sources/DigiaMoEngage"
        ),
    ]
)
