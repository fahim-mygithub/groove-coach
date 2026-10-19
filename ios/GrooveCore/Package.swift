// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "GrooveCore",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(name: "GrooveCore", targets: ["GrooveCore"]),
        .executable(name: "groove-score-cli", targets: ["GrooveScoreCLI"])
    ],
    targets: [
        .target(
            name: "GrooveCore",
            path: "Sources/GrooveCore"
        ),
        .executableTarget(
            name: "GrooveScoreCLI",
            dependencies: ["GrooveCore"],
            path: "Sources/GrooveScoreCLI"
        ),
        .testTarget(
            name: "GrooveCoreTests",
            dependencies: ["GrooveCore"],
            path: "Tests/GrooveCoreTests"
        )
    ]
)
