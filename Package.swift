// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "FileFan",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "FileFanCore", targets: ["FileFanCore"]),
        .executable(name: "FileFan", targets: ["FileFan"])
    ],
    targets: [
        .target(name: "FileFanCore", resources: [.process("Resources")]),
        .executableTarget(name: "FileFan", dependencies: ["FileFanCore"]),
        .executableTarget(name: "FileFanBackendQA", dependencies: ["FileFanCore"], path: "scripts/backend-qa"),
        .testTarget(name: "FileFanCoreTests", dependencies: ["FileFanCore"]),
        .testTarget(name: "FileFanUITests", dependencies: ["FileFan"])
    ]
)
