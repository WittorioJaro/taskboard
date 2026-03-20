// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "taskboard",
    platforms: [
        .macOS(.v15),
    ],
    products: [
        .executable(name: "taskboard", targets: ["taskboard"]),
    ],
    targets: [
        .executableTarget(
            name: "taskboard"
        ),
    ]
)
