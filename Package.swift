// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "DigiaMoEngage",
    platforms: [
        .iOS(.v17),
    ],
    products: [
        .library(
            name: "DigiaMoEngage",
            targets: ["DigiaMoEngage"]
        ),
    ],
    dependencies: [
        // The sibling checkout, not a version tag: the published constraint predates
        // core's CEP v2 surface and resolves a core this package can no longer compile
        // against. Repoint at a tag once core publishes one carrying that contract.
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
        // The seam's whole point: the plugin runs here with a fake MoEngageClient,
        // so no test needs a live MoEngage SDK (spec §10.5, plan N2 "seam rule").
        .testTarget(
            name: "DigiaMoEngageTests",
            dependencies: ["DigiaMoEngage"],
            path: "Tests/DigiaMoEngageTests"
        ),
    ]
)