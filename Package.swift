// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CodexPeek",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(
            name: "CodexPeek",
            targets: ["CodexPeek"]
        )
    ],
    targets: [
        .executableTarget(
            name: "CodexPeek",
            path: "Sources/CodexPeek",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ServiceManagement")
            ]
        )
    ]
)
