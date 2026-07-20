// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "taskboard",
    platforms: [
        .macOS(.v15),
        .iOS(.v17),
    ],
    products: [
        .executable(name: "taskboard", targets: ["taskboard"]),
    ],
    dependencies: [
        .package(
            url: "https://github.com/supabase/supabase-swift.git",
            exact: "2.46.0"
        ),
    ],
    targets: [
        .executableTarget(
            name: "taskboard",
            dependencies: [
                .product(name: "Realtime", package: "supabase-swift"),
            ]
        ),
        .testTarget(
            name: "taskboardTests",
            dependencies: ["taskboard"]
        ),
    ]
)
