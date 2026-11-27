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
                .linkedFramework("Security")
            ]
        ),
        .executableTarget(
            name: "firnd",
            dependencies: ["FirnCore"],
            linkerSettings: [
                .linkedFramework("Virtualization"),
                .linkedFramework("SystemConfiguration"),
                .linkedFramework("Network"),
                .linkedFramework("Security")
            ]
        ),
        .executableTarget(
            name: "firn",
            dependencies: ["FirnCore"]
        ),
        .executableTarget(
            name: "FirnBar",
            dependencies: ["FirnCore"],
            linkerSettings: [
                .linkedFramework("AppKit")
            ]
        ),
        .executableTarget(
            name: "FirnCoreCheck",
            dependencies: ["FirnCore"]
        )
    ]
)
