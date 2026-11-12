// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "FreeRetina",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "CVirtualDisplay", linkerSettings: [.linkedFramework("CoreGraphics")]),
        .executableTarget(
            name: "freeretina",
            dependencies: ["CVirtualDisplay"],
            path: "Sources/FreeRetina",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
