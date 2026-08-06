// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CapacitorSpotify",
    platforms: [.iOS(.v15)],
    products: [
        .library(
            name: "CapacitorSpotify",
            targets: ["SpotifyPlugin"])
    ],
    dependencies: [
        .package(url: "https://github.com/ionic-team/capacitor-swift-pm.git", from: "8.0.0"),
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
