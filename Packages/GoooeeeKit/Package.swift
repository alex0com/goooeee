// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "GoooeeeKit",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "GoooeeeCore", targets: ["GoooeeeCore"]),
        .library(name: "GoooeeeMarkdown", targets: ["GoooeeeMarkdown"]),
        .library(name: "GoooeeeMCP", targets: ["GoooeeeMCP"]),
        .library(name: "GoooeeeTranscript", targets: ["GoooeeeTranscript"]),
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-markdown.git", from: "0.7.3"),
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.10.0"),
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.12.0"),
        .package(url: "https://github.com/huggingface/swift-jinja.git", from: "2.5.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.6.0"),
    ],
    targets: [
        .target(
            name: "GoooeeeCore",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "Jinja", package: "swift-jinja"),
            ],
            resources: [.process("Resources")]
        ),
        .target(
            name: "GoooeeeMarkdown",
            dependencies: [
                .product(name: "Markdown", package: "swift-markdown"),
            ]
        ),
        .target(
            name: "GoooeeeMCP",
            dependencies: [
                "GoooeeeCore",
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "Logging", package: "swift-log"),
            ]
        ),
        .target(
            name: "GoooeeeTranscript",
            dependencies: ["GoooeeeCore", "GoooeeeMarkdown"]
        ),
        .testTarget(
            name: "GoooeeeTranscriptTests",
            dependencies: ["GoooeeeTranscript"]
        ),
        .testTarget(
            name: "GoooeeeCoreTests",
            dependencies: ["GoooeeeCore"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "GoooeeeMarkdownTests",
            dependencies: ["GoooeeeMarkdown"]
        ),
        .testTarget(
            name: "GoooeeeMCPTests",
            dependencies: ["GoooeeeMCP", "GoooeeeCore"]
        ),
    ]
)
