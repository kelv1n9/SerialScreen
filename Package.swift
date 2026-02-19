// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SerialScreenSwift",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "SerialScreen", targets: ["SerialScreenSwift"])
    ],
    targets: [
        .executableTarget(
            name: "SerialScreenSwift"
        )
    ]
)
