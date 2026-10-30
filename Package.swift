// swift-tools-version: 5.9
import PackageDescription
import Foundation

var targets: [Target] = [
    .target(
        name: "AssetCatalogSupport",
        path: "Sources/AssetCatalogSupport",
        publicHeadersPath: "include"
    ),
    .target(
        name: "MacAssistantKit",
        dependencies: ["AssetCatalogSupport"],
        path: "Sources/MacAssistantKit",
        resources: [
            .process("Localization"),
            .copy("Resources/libsubstrate.dylib"),
            .copy("Resources/CloneSupport"),
            .copy("Resources/CuteIcons"),
            .copy("Resources/FolderCostumes"),
            .copy("Resources/AIIcons")
        ],
        linkerSettings: [
            .linkedFramework("IOKit"),
            .linkedFramework("AppKit")
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
        ],
        linkerSettings: [
            .linkedFramework("CoreWLAN"),
            .linkedFramework("CoreAudio"),
            .linkedFramework("IOBluetooth"),
            .linkedFramework("IOKit"),
            .linkedFramework("Network"),
            .linkedFramework("SystemConfiguration"),
            .linkedFramework("ApplicationServices")
        ]
    ),
    // 只跑 pmset 的小程序。菜单栏进程不把自己提权，避免整份 SwiftUI 应用以 root 启动。
    .executableTarget(
        name: "MacAssistantEnergyHelper",
        path: "Sources/MacAssistantEnergyHelper"
    )
]

// Tests/ 不在公开树里时跳过，避免 clone 后因缺路径导致 `swift build` 失败。
if FileManager.default.fileExists(atPath: "Tests/MacAssistantKitTests") {
    targets.append(
        .testTarget(
            name: "MacAssistantKitTests",
            dependencies: ["MacAssistantKit", "MacAssistantEnergyHelper"],
            path: "Tests/MacAssistantKitTests"
        )
    )
}

let package = Package(
    name: "MacAssistant",
    // 开发语言：任何语言缺词条时回退到简体中文。
    defaultLocalization: "zh-Hans",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "MacAssistant", targets: ["MacAssistant"]),
        .executable(name: "MacAssistantEnergyHelper", targets: ["MacAssistantEnergyHelper"]),
        .library(name: "MacAssistantKit", targets: ["MacAssistantKit"])
    ],
    targets: targets
)
