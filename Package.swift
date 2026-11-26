// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AgentBrowser",
    platforms: [.macOS("14.0")],
    products: [
        .executable(name: "agent-browser", targets: ["AgentBrowser"]),
        .library(name: "AgentBrowserCore", targets: ["AgentBrowserCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/ml-explore/mlx-swift-lm.git", exact: "3.32.3"),
        .package(url: "https://github.com/huggingface/swift-huggingface.git", from: "0.9.0"),
        .package(url: "https://github.com/huggingface/swift-transformers.git", from: "1.3.0"),
    ],
    targets: [
        .target(
            name: "CEngine",
            path: "Sources/CEngine",
            publicHeadersPath: "include"
        ),
        .target(
            name: "AgentBrowserModel",
            dependencies: [
                .product(name: "MLXVLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "HuggingFace", package: "swift-huggingface"),
                .product(name: "Tokenizers", package: "swift-transformers"),
            ],
            path: "Sources/AgentBrowserModel",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "AgentBrowserCore",
            dependencies: [
                "CEngine",
                "AgentBrowserModel",
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
            ],
            path: "Sources/AgentBrowserCore",
            swiftSettings: [.swiftLanguageMode(.v6)],
            linkerSettings: [
                .unsafeFlags(["-L", "Engine/target/release", "-lagent_browser_engine"]),
                .linkedLibrary("iconv"),
                .linkedFramework("AppKit"),
                .linkedFramework("CoreFoundation"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("CoreText"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("IOSurface"),
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
                .linkedFramework("Security"),
                .linkedFramework("Network"),
                .linkedFramework("UniformTypeIdentifiers"),
                .linkedFramework("ImageIO"),
                .linkedFramework("VideoToolbox"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("AVFoundation"),
            ]
        ),
        .executableTarget(
            name: "AgentBrowser",
            dependencies: ["AgentBrowserCore"],
            path: "Sources/AgentBrowser",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
