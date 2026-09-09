// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Threadturn",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "Threadturn",
            path: "Sources/Threadturn",
            swiftSettings: [.unsafeFlags(["-Onone"])]
        )
    ],
    swiftLanguageVersions: [.v5]
)
