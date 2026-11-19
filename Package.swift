// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MonetizationOS",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "MonetizationOS", targets: ["MonetizationOS"]),
        // A separate product so an app that only needs decisions never links WebKit.
        .library(name: "MonetizationOSUI", targets: ["MonetizationOSUI"]),
    ],
    targets: [
        // WebPaywall/shared is the web paywall's document and scripts, a copy of the Android SDK's (scripts/check-shared.sh).
        .target(name: "MonetizationOS", path: "Sources/MonetizationOS", resources: [.copy("PrivacyInfo.xcprivacy"), .copy("WebPaywall/shared")]),
        .target(name: "MonetizationOSUI", dependencies: ["MonetizationOS"], path: "Sources/MonetizationOSUI"),
        .testTarget(name: "MOSTests", dependencies: ["MonetizationOS", "MonetizationOSUI"], path: "Tests/MOSTests"),
    ],
    swiftLanguageModes: [.v6]
)
