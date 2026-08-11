// swift-tools-version: 5.9
import PackageDescription

// Package and product names must stay in sync with the npm package name:
// the Capacitor CLI derives "JacquesbeetsCapacitorSpotify" from
// "@jacquesbeets/capacitor-spotify" when generating the app's CapApp-SPM
// manifest, and SwiftPM rejects the dependency if the names differ.
let package = Package(
    name: "JacquesbeetsCapacitorSpotify",
    // iOS 14 floor: Capacitor 7 apps build their CapApp-SPM package for
    // iOS 14, and SwiftPM refuses any dependency with a higher minimum.
    platforms: [.iOS(.v14)],
    products: [
        .library(
            name: "JacquesbeetsCapacitorSpotify",
            targets: ["SpotifyPlugin"])
    ],
    dependencies: [
        .package(url: "https://github.com/ionic-team/capacitor-swift-pm.git", "7.0.0"..<"9.0.0"),
        .package(url: "https://github.com/spotify/ios-sdk.git", exact: "5.0.1")
    ],
    targets: [
        .target(
            name: "SpotifyPlugin",
            dependencies: [
                .product(name: "Capacitor", package: "capacitor-swift-pm"),
                .product(name: "Cordova", package: "capacitor-swift-pm"),
                .product(name: "SpotifyiOS", package: "ios-sdk")
            ],
            path: "ios/Sources/SpotifyPlugin"),
        .testTarget(
            name: "SpotifyPluginTests",
            dependencies: ["SpotifyPlugin"],
            path: "ios/Tests/SpotifyPluginTests")
    ]
)
