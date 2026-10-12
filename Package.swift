// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MacClaudeUsage",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "MacClaudeUsage", targets: ["MacClaudeUsage"])
    ],
    targets: [
        .executableTarget(
            name: "MacClaudeUsage",
            path: "Sources/MacClaudeUsage",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "MacClaudeUsageTests",
            dependencies: ["MacClaudeUsage"],
            path: "Tests/MacClaudeUsageTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
