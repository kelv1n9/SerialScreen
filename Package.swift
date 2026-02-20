// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SerialScreen",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "SerialScreen", targets: ["SerialScreen"])
    ],
    targets: [
        .executableTarget(
            name: "SerialScreen"
        )
    ]
)
