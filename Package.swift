// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BatteryFlow",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "BatteryFlow", targets: ["BatteryFlow"])
    ],
    targets: [
        .executableTarget(
            name: "BatteryFlow",
            path: "Sources/BatteryFlow"
        ),
    ]
)
