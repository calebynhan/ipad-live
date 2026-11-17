// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "iPadLive",
    platforms: [.macOS(.v14)],
    targets: [
        // Pure layout math, kept separate so it can be unit tested without a Mac app or an iPad.
        .target(
            name: "iPadLiveCore",
            path: "Sources/iPadLiveCore"
        ),
        // The Mac app itself. scripts/build-app.sh wraps this binary into "iPad Live.app".
        .executableTarget(
            name: "iPadLive",
            dependencies: ["iPadLiveCore"],
            path: "Sources/iPadLive",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreMediaIO"),
            ]
        ),
        .testTarget(
            name: "iPadLiveCoreTests",
            dependencies: ["iPadLiveCore"],
            path: "Tests/iPadLiveCoreTests"
        ),
    ]
)
