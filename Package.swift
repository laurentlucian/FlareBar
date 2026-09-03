// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FlareBar",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "FlareBar", targets: ["FlareBar"])],
    targets: [
        .target(name: "FlareBarCore"),
        .executableTarget(
            name: "FlareBar",
            dependencies: ["FlareBarCore"],
            resources: [.copy("Resources")]
        ),
        .testTarget(name: "FlareBarTests", dependencies: ["FlareBarCore"]),
    ]
)
