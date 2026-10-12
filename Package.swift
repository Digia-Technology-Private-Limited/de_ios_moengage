// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "DigiaMoEngage",
    platforms: [
        // Follows core, which requires iOS 15. Keep these in lockstep with
        // DigiaEngage's Package.swift and podspec — a plugin must never demand a
        // higher floor than the core it depends on, or it silently excludes apps
        // that can run the core perfectly well. MoEngageCore itself only requires
        // iOS 11, so core is the binding constraint here, not the MoEngage SDK.
        .iOS(.v15),
    ],
    products: [
        .library(
            name: "DigiaMoEngage",
            targets: ["DigiaMoEngage"]
        ),
    ],
    dependencies: [
        // 4.0.0 is the first core release carrying the CEP v2 contract this package
        // compiles against; a range, so a host app can take any later 4.x.
        .package(
            url: "https://github.com/Digia-Technology-Private-Limited/digia_engage_ios.git",
            from: "4.0.0"
        ),
        // MoEngage's documented SPM URL. Tags before 9.23.0 carry no Package.swift.
        // 11.x changes linkage and must be adopted in a separately tested release.
        .package(
            url: "https://github.com/moengage/apple-sdk.git",
            "9.23.0"..<"11.0.0"
        ),
    ],
    targets: [
        .target(
            name: "DigiaMoEngage",
            dependencies: [
                .product(name: "DigiaEngage", package: "digia_engage_ios"),
                .product(name: "MoEngageInApps", package: "apple-sdk"),
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
