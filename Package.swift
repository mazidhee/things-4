// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Things4",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Things4", targets: ["Things4"])
    ],
    targets: [
        .executableTarget(
            name: "Things4",
            path: "Sources/Things4"
        )
    ]
)
