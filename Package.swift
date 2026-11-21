// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Sidemoon",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SidemoonCore", targets: ["SidemoonCore"]),
        .executable(name: "sidemoon", targets: ["sidemoon"]),
        // The companion app binary. Named differently from the CLI so the two never collide on a
        // case-insensitive file system; scripts/build-app.sh wraps it into Sidemoon.app.
        .executable(name: "SidemoonApp", targets: ["SidemoonApp"]),
    ],
    dependencies: [
        // Automatic updates for the direct download. Only the app target links it.
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1"),
    ],
    targets: [
        .target(name: "SidemoonCore"),
        .executableTarget(name: "sidemoon", dependencies: ["SidemoonCore"]),
        // View model and pure UI logic, kept free of AppKit so it can be tested headless.
        .target(name: "SidemoonCompanion", dependencies: ["SidemoonCore"]),
        .executableTarget(
            name: "SidemoonApp",
            dependencies: ["SidemoonCore", "SidemoonCompanion", .product(name: "Sparkle", package: "Sparkle")]
        ),
        .testTarget(
            name: "SidemoonCoreTests",
            dependencies: ["SidemoonCore"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(name: "SidemoonCompanionTests", dependencies: ["SidemoonCore", "SidemoonCompanion"]),
    ]
)
