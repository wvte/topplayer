// swift-tools-version:5.7
import PackageDescription

let package = Package(
    name: "TopplayerCore",
    platforms: [.iOS(.v15), .macOS(.v12)],
    products: [.library(name: "TopplayerCore", targets: ["TopplayerCore"])],
    targets: [
        .target(name: "TopplayerCore", linkerSettings: [.linkedLibrary("sqlite3")]),
        .testTarget(name: "TopplayerCoreTests", dependencies: ["TopplayerCore"], resources: [.copy("Resources")]),
    ]
)
