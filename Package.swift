// swift-tools-version:5.9
// Builds the Mac menu bar app. The iPhone app is the Xcode project from project.yml.
import PackageDescription

let package = Package(
    name: "Googly",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "GooglyMac", targets: ["GooglyMac"]),
    ],
    targets: [
        .target(name: "GooglyShared", path: "Shared", exclude: ["Fonts"]),
        .target(name: "BlueyWebSearch", dependencies: ["GooglyShared"], path: "Mac/Sources/WebSearch"),
        .executableTarget(
            name: "GooglyMac",
            dependencies: ["GooglyShared", "BlueyWebSearch"],
            path: "Mac/Sources/GooglyMac"
        ),
        .testTarget(name: "GooglySharedTests", dependencies: ["GooglyShared"], path: "Tests/GooglySharedTests"),
        .testTarget(name: "BlueyWebSearchTests", dependencies: ["BlueyWebSearch", "GooglyShared"], path: "Tests/BlueyWebSearchTests"),
    ]
)
