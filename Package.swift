// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MacAssistant",
    // 开发语言：任何语言缺词条时回退到简体中文。
    defaultLocalization: "zh-Hans",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "MacAssistant", targets: ["MacAssistant"]),
        .library(name: "MacAssistantKit", targets: ["MacAssistantKit"])
    ],
    targets: [
        .target(
            name: "MacAssistantKit",
            path: "Sources/MacAssistantKit",
            resources: [
                .process("Localization")
            ]
        ),
        .executableTarget(
            name: "MacAssistant",
            dependencies: ["MacAssistantKit"],
            path: "Sources/MacAssistant",
            // AppIcon.png 必须保持 copy：build_app.sh 会校验它与 canonical PNG 的哈希一致。
            // 语言资源单独放在 Localization/ 下，避免与 copy 规则争夺同一路径。
            resources: [
                .copy("Resources/AppIcon.png"),
                .process("Localization")
            ]
        )
    ]
)
