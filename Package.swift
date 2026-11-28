// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Firn",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "FirnCore", targets: ["FirnCore"]),
        .executable(name: "firnd", targets: ["firnd"]),
        .executable(name: "firn", targets: ["firn"]),
        .executable(name: "FirnBar", targets: ["FirnBar"])
    ],
    targets: [
        .target(
            name: "FirnCore",
            linkerSettings: [
                .linkedFramework("SystemConfiguration"),
                .linkedFramework("Security"),
                .linkedFramework("Metal")
            ]
        ),
        .executableTarget(
            name: "firnd",
            dependencies: ["FirnCore"],
            linkerSettings: [
                .linkedFramework("Virtualization"),
                .linkedFramework("SystemConfiguration"),
                .linkedFramework("Network"),
                .linkedFramework("Security"),
                .linkedFramework("CoreServices"),
                .linkedFramework("Metal")
            ]
        ),
        .executableTarget(
            name: "firn",
            dependencies: ["FirnCore"],
            linkerSettings: [
                .linkedFramework("Virtualization")
            ]
        ),
        .executableTarget(
            name: "FirnBar",
            dependencies: ["FirnCore"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI")
            ]
        ),
        .executableTarget(
            name: "FirnCoreCheck",
            dependencies: ["FirnCore"]
        )
    ]
)
