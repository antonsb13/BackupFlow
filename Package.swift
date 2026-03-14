// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BackupFlow",
    platforms: [
        .macOS(.v15)
    ],
    targets: [
        .executableTarget(
            name: "BackupFlow",
            path: "Sources/BackupFlow",
            resources: [
                .process("Resources")
            ]
        )
    ]
)
