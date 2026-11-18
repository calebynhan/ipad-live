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
        // Wi-Fi streaming protocol shared with the iPad app (iPadSender/ compiles these same files).
        .target(
            name: "LiveLink",
            path: "Sources/LiveLink",
            linkerSettings: [
                .linkedFramework("CoreMedia"),
                .linkedFramework("Network"),
                .linkedFramework("VideoToolbox"),
            ]
        ),
        // The Mac app itself. scripts/build-app.sh wraps this binary into "iPad Live.app".
        .executableTarget(
            name: "iPadLive",
            dependencies: ["iPadLiveCore", "LiveLink"],
            path: "Sources/iPadLive",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreMediaIO"),
                .linkedFramework("SystemConfiguration"),
            ]
        ),
        .testTarget(
            name: "iPadLiveCoreTests",
            dependencies: ["iPadLiveCore"],
            path: "Tests/iPadLiveCoreTests"
        ),
        .testTarget(
            name: "LiveLinkTests",
            dependencies: ["LiveLink"],
            path: "Tests/LiveLinkTests"
        ),
    ]
)
