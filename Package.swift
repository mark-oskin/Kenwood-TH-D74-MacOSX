// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "THD74",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "THD74Kit", targets: ["THD74Kit"]),
        .executable(name: "thd74", targets: ["thd74"]),
        .executable(name: "THD74App", targets: ["THD74App"]),
    ],
    targets: [
        .target(name: "THD74Kit"),
        .executableTarget(name: "thd74", dependencies: ["THD74Kit"]),
        .executableTarget(name: "THD74App", dependencies: ["THD74Kit"]),
        .testTarget(name: "THD74KitTests", dependencies: ["THD74Kit"]),
    ]
)
