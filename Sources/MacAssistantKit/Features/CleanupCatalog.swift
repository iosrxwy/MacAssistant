import Foundation

/// 用户级清理目录。只列可再生或需单独确认的路径，不扫家目录、不碰 Application Support 整棵。
enum CleanupCatalog {
    /// Application Support 下只允许这些叶目录名进入可删目标。
    /// `Service Worker` 里的 CacheStorage / ScriptCache 不在此列：清掉会丢掉网页推送和离线应用。
    static let allowedApplicationSupportLeaves: Set<String> = [
        "Cache", "Code Cache", "GPUCache", "htmlcache", "CachedData", "CachedExtensionVSIXs", "logs",
        "cache2", "startupCache", "ShaderCache", "GrShaderCache", "GraphiteDawnCache",
        "PersistentCache", "Media Cache Files", "Backup",
        "vm_bundles", "OptGuideOnDeviceModel"
    ]

    static func definitions(homeDirectory: URL) -> [CleanupTargetDefinition] {
        func h(_ path: String) -> URL { homeDirectory.appendingPathComponent(path) }
        let browser = CleanupSafetyDetails(
            removes: L("cleanup.safety.browser.removes"),
            keeps: L("cleanup.safety.browser.keeps"),
            note: L("cleanup.safety.browser.note")
        )
        let build = CleanupSafetyDetails(
            removes: L("cleanup.safety.build.removes"),
            keeps: L("cleanup.safety.build.keeps"),
            note: L("cleanup.safety.build.note")
        )
        let packages = CleanupSafetyDetails(
            removes: L("cleanup.safety.package.removes"),
            keeps: L("cleanup.safety.package.keeps"),
            note: L("cleanup.safety.package.note")
        )
        let ide = CleanupSafetyDetails(
            removes: L("cleanup.safety.ide.removes"),
            keeps: L("cleanup.safety.ide.keeps"),
            note: L("cleanup.safety.ide.note")
        )
        let backups = CleanupSafetyDetails(
            removes: L("cleanup.safety.backups.removes"),
            keeps: L("cleanup.safety.backups.keeps"),
            note: L("cleanup.safety.backups.note")
        )
        let firmware = CleanupSafetyDetails(
            removes: L("cleanup.safety.firmware.removes"),
            keeps: L("cleanup.safety.firmware.keeps"),
            note: L("cleanup.safety.firmware.note")
        )
        let mailDownloads = CleanupSafetyDetails(
            removes: L("cleanup.safety.mail-downloads.removes"),
            keeps: L("cleanup.safety.mail-downloads.keeps"),
            note: L("cleanup.safety.mail-downloads.note")
        )

        func item(
            _ id: String,
            name: String,
            detail: String,
            paths: [URL],
            risk: CleanupRisk = .safe,
            action: CleanupAction = .moveContentsToTrash,
            category: CleanupCategory,
            systemImage: String,
            safety: CleanupSafetyDetails? = nil
        ) -> CleanupTargetDefinition {
            CleanupTargetDefinition(
                id: id,
                name: name,
                detail: detail,
                paths: paths,
                risk: risk,
                action: action,
                defaultSelected: false,
                category: category,
                systemImage: systemImage,
                safetyDetails: safety
            )
        }

        return [
            item(
                "ios-backups",
                name: L("cleanup.ios-backups.name"),
                detail: L("cleanup.ios-backups.detail"),
                paths: [h("Library/Application Support/MobileSync/Backup")],
                risk: .caution,
                category: .systemData,
                systemImage: "iphone",
                safety: backups
            ),
            item(
                "device-firmware",
                name: L("cleanup.device-firmware.name"),
                detail: L("cleanup.device-firmware.detail"),
                paths: [
                    h("Library/iTunes/iPhone Software Updates"),
                    h("Library/iTunes/iPad Software Updates"),
                    h("Library/iTunes/iPod Software Updates"),
                    h("Library/iTunes/Watch Software Updates"),
                    h("Library/iTunes/Vision Software Updates")
                ],
                category: .systemData,
                systemImage: "arrow.down.circle",
                safety: firmware
            ),
            item(
                "mail-downloads",
                name: L("cleanup.mail-downloads.name"),
                detail: L("cleanup.mail-downloads.detail"),
                paths: [h("Library/Containers/com.apple.mail/Data/Library/Mail Downloads")],
                risk: .caution,
                category: .systemData,
                systemImage: "paperclip",
                safety: mailDownloads
            ),
            item(
                "ios-device-logs",
                name: L("cleanup.ios-device-logs.name"),
                detail: L("cleanup.ios-device-logs.detail"),
                paths: [h("Library/Developer/Xcode/iOS Device Logs")],
                category: .systemData,
                systemImage: "doc.text",
                safety: build
            ),
            item(
                "quicklook",
                name: L("cleanup.quicklook.name"),
                detail: L("cleanup.quicklook.detail"),
                paths: [h("Library/Caches/com.apple.QuickLook.thumbnailcache")],
                category: .systemData,
                systemImage: "eye",
                safety: build
            ),
            item(
                "android-avd",
                name: L("cleanup.android-avd.name"),
                detail: L("cleanup.android-avd.detail"),
                paths: [h(".android/avd")],
                risk: .caution,
                category: .systemData,
                systemImage: "square.stack.3d.up",
                safety: CleanupSafetyDetails(
                    removes: L("cleanup.safety.android-avd.removes"),
                    keeps: L("cleanup.safety.android-avd.keeps"),
                    note: L("cleanup.safety.android-avd.note")
                )
            ),
            item(
                "android-sdk-images",
                name: L("cleanup.android-sdk-images.name"),
                detail: L("cleanup.android-sdk-images.detail"),
                paths: [h("Library/Android/sdk/system-images")],
                risk: .caution,
                category: .systemData,
                systemImage: "square.stack.3d.down.right",
                safety: CleanupSafetyDetails(
                    removes: L("cleanup.safety.android-sdk.removes"),
                    keeps: L("cleanup.safety.android-sdk.keeps"),
                    note: L("cleanup.safety.android-sdk.note")
                )
            ),
            item(
                "android-sdk-ndk",
                name: L("cleanup.android-sdk-ndk.name"),
                detail: L("cleanup.android-sdk-ndk.detail"),
                paths: [h("Library/Android/sdk/ndk")],
                risk: .caution,
                category: .systemData,
                systemImage: "cpu",
                safety: CleanupSafetyDetails(
                    removes: L("cleanup.safety.android-sdk.removes"),
                    keeps: L("cleanup.safety.android-sdk.keeps"),
                    note: L("cleanup.safety.android-sdk.note")
                )
            ),
            item(
                "android-sdk-platforms",
                name: L("cleanup.android-sdk-platforms.name"),
                detail: L("cleanup.android-sdk-platforms.detail"),
                paths: [h("Library/Android/sdk/platforms")],
                risk: .caution,
                category: .systemData,
                systemImage: "square.stack.3d.up",
                safety: CleanupSafetyDetails(
                    removes: L("cleanup.safety.android-sdk.removes"),
                    keeps: L("cleanup.safety.android-sdk.keeps"),
                    note: L("cleanup.safety.android-sdk.note")
                )
            ),
            item(
                "android-sdk-cache",
                name: L("cleanup.android-sdk-cache.name"),
                detail: L("cleanup.android-sdk-cache.detail"),
                paths: [h(".android/cache")],
                category: .systemData,
                systemImage: "arrow.down.circle",
                safety: packages
            ),
            item(
                "android-studio-caches",
                name: L("cleanup.android-studio-caches.name"),
                detail: L("cleanup.android-studio-caches.detail"),
                paths: [h("Library/Caches/Google/AndroidStudio")],
                category: .systemData,
                systemImage: "internaldrive",
                safety: ide
            ),
            item(
                "ollama-models",
                name: L("cleanup.ollama-models.name"),
                detail: L("cleanup.ollama-models.detail"),
                paths: [h(".ollama/models")],
                risk: .caution,
                category: .systemData,
                systemImage: "brain",
                safety: CleanupSafetyDetails(
                    removes: L("cleanup.safety.models.removes"),
                    keeps: L("cleanup.safety.models.keeps"),
                    note: L("cleanup.safety.models.note")
                )
            ),
            item(
                "huggingface-cache",
                name: L("cleanup.huggingface-cache.name"),
                detail: L("cleanup.huggingface-cache.detail"),
                paths: [h(".cache/huggingface")],
                risk: .caution,
                category: .systemData,
                systemImage: "brain.head.profile",
                safety: CleanupSafetyDetails(
                    removes: L("cleanup.safety.models.removes"),
                    keeps: L("cleanup.safety.models.keeps"),
                    note: L("cleanup.safety.models.note")
                )
            ),
            item(
                "torch-cache",
                name: L("cleanup.torch-cache.name"),
                detail: L("cleanup.torch-cache.detail"),
                paths: [h(".cache/torch")],
                risk: .caution,
                category: .systemData,
                systemImage: "flame",
                safety: CleanupSafetyDetails(
                    removes: L("cleanup.safety.models.removes"),
                    keeps: L("cleanup.safety.models.keeps"),
                    note: L("cleanup.safety.models.note")
                )
            ),
            item(
                "lmstudio-models",
                name: L("cleanup.lmstudio-models.name"),
                detail: L("cleanup.lmstudio-models.detail"),
                paths: [h(".lmstudio/models")],
                risk: .caution,
                category: .systemData,
                systemImage: "brain",
                safety: CleanupSafetyDetails(
                    removes: L("cleanup.safety.models.removes"),
                    keeps: L("cleanup.safety.models.keeps"),
                    note: L("cleanup.safety.models.note")
                )
            ),
            item(
                "nvm-versions",
                name: L("cleanup.nvm-versions.name"),
                detail: L("cleanup.nvm-versions.detail"),
                paths: [h(".nvm/versions")],
                risk: .caution,
                category: .systemData,
                systemImage: "number.circle",
                safety: CleanupSafetyDetails(
                    removes: L("cleanup.safety.toolchains.removes"),
                    keeps: L("cleanup.safety.toolchains.keeps"),
                    note: L("cleanup.safety.toolchains.note")
                )
            ),
            item(
                "rustup-toolchains",
                name: L("cleanup.rustup-toolchains.name"),
                detail: L("cleanup.rustup-toolchains.detail"),
                paths: [h(".rustup/toolchains")],
                risk: .caution,
                category: .systemData,
                systemImage: "wrench.and.screwdriver",
                safety: CleanupSafetyDetails(
                    removes: L("cleanup.safety.toolchains.removes"),
                    keeps: L("cleanup.safety.toolchains.keeps"),
                    note: L("cleanup.safety.toolchains.note")
                )
            ),
            item(
                "pyenv-versions",
                name: L("cleanup.pyenv-versions.name"),
                detail: L("cleanup.pyenv-versions.detail"),
                paths: [h(".pyenv/versions")],
                risk: .caution,
                category: .systemData,
                systemImage: "number.square",
                safety: CleanupSafetyDetails(
                    removes: L("cleanup.safety.toolchains.removes"),
                    keeps: L("cleanup.safety.toolchains.keeps"),
                    note: L("cleanup.safety.toolchains.note")
                )
            ),
            item(
                "cocoapods-repos",
                name: L("cleanup.cocoapods-repos.name"),
                detail: L("cleanup.cocoapods-repos.detail"),
                paths: [h(".cocoapods/repos")],
                category: .systemData,
                systemImage: "shippingbox",
                safety: packages
            ),
            item(
                "vm-utm",
                name: L("cleanup.vm-utm.name"),
                detail: L("cleanup.vm-utm.detail"),
                paths: [h("Library/Containers/com.utmapp.UTM/Data/Documents")],
                risk: .caution,
                category: .systemData,
                systemImage: "desktopcomputer",
                safety: CleanupSafetyDetails(
                    removes: L("cleanup.safety.vm.removes"),
                    keeps: L("cleanup.safety.vm.keeps"),
                    note: L("cleanup.safety.vm.note")
                )
            ),
            item(
                "vm-tart",
                name: L("cleanup.vm-tart.name"),
                detail: L("cleanup.vm-tart.detail"),
                paths: [h(".tart/vms")],
                risk: .caution,
                category: .systemData,
                systemImage: "desktopcomputer",
                safety: CleanupSafetyDetails(
                    removes: L("cleanup.safety.vm.removes"),
                    keeps: L("cleanup.safety.vm.keeps"),
                    note: L("cleanup.safety.vm.note")
                )
            ),
            item(
                "vm-parallels",
                name: L("cleanup.vm-parallels.name"),
                detail: L("cleanup.vm-parallels.detail"),
                paths: [h("Parallels")],
                risk: .caution,
                category: .systemData,
                systemImage: "desktopcomputer",
                safety: CleanupSafetyDetails(
                    removes: L("cleanup.safety.vm.removes"),
                    keeps: L("cleanup.safety.vm.keeps"),
                    note: L("cleanup.safety.vm.note")
                )
            ),
            item(
                "vm-virtualbox",
                name: L("cleanup.vm-virtualbox.name"),
                detail: L("cleanup.vm-virtualbox.detail"),
                paths: [h("VirtualBox VMs")],
                risk: .caution,
                category: .systemData,
                systemImage: "desktopcomputer",
                safety: CleanupSafetyDetails(
                    removes: L("cleanup.safety.vm.removes"),
                    keeps: L("cleanup.safety.vm.keeps"),
                    note: L("cleanup.safety.vm.note")
                )
            ),
            item(
                "vm-vmware",
                name: L("cleanup.vm-vmware.name"),
                detail: L("cleanup.vm-vmware.detail"),
                paths: [h("Virtual Machines.localized")],
                risk: .caution,
                category: .systemData,
                systemImage: "desktopcomputer",
                safety: CleanupSafetyDetails(
                    removes: L("cleanup.safety.vm.removes"),
                    keeps: L("cleanup.safety.vm.keeps"),
                    note: L("cleanup.safety.vm.note")
                )
            ),
            item(
                "slack-cache",
                name: L("cleanup.slack-cache.name"),
                detail: L("cleanup.slack-cache.detail"),
                paths: [
                    h("Library/Application Support/Slack/Cache")
                ],
                category: .systemData,
                systemImage: "bubble.left.and.bubble.right",
                safety: browser
            ),
            item(
                "discord-cache",
                name: L("cleanup.discord-cache.name"),
                detail: L("cleanup.discord-cache.detail"),
                paths: [h("Library/Application Support/discord/Cache")],
                category: .systemData,
                systemImage: "bubble.left",
                safety: browser
            ),
            item(
                "spotify-cache",
                name: L("cleanup.spotify-cache.name"),
                detail: L("cleanup.spotify-cache.detail"),
                paths: [h("Library/Application Support/Spotify/PersistentCache")],
                category: .systemData,
                systemImage: "music.note",
                safety: browser
            ),
            item(
                "adobe-media-cache",
                name: L("cleanup.adobe-media-cache.name"),
                detail: L("cleanup.adobe-media-cache.detail"),
                paths: [h("Library/Application Support/Adobe/Common/Media Cache Files")],
                category: .systemData,
                systemImage: "film",
                safety: build
            ),
            item(
                "claude-vm",
                name: L("cleanup.claude-vm.name"),
                detail: L("cleanup.claude-vm.detail"),
                paths: [h("Library/Application Support/Claude/vm_bundles")],
                risk: .caution,
                category: .systemData,
                systemImage: "shippingbox",
                safety: CleanupSafetyDetails(
                    removes: L("cleanup.safety.claude-vm.removes"),
                    keeps: L("cleanup.safety.claude-vm.keeps"),
                    note: L("cleanup.safety.claude-vm.note")
                )
            ),
            item(
                "chrome-on-device-model",
                name: L("cleanup.chrome-on-device-model.name"),
                detail: L("cleanup.chrome-on-device-model.detail"),
                paths: [h("Library/Application Support/Google/Chrome/OptGuideOnDeviceModel")],
                risk: .caution,
                category: .systemData,
                systemImage: "brain",
                safety: CleanupSafetyDetails(
                    removes: L("cleanup.safety.chrome-model.removes"),
                    keeps: L("cleanup.safety.chrome-model.keeps"),
                    note: L("cleanup.safety.chrome-model.note")
                )
            ),
            item(
                "chrome",
                name: L("cleanup.chrome.name"),
                detail: "~/Library/Caches/Google/Chrome",
                paths: [h("Library/Caches/Google/Chrome"), h("Library/Caches/Google/Chrome Canary")],
                category: .apps,
                systemImage: "globe",
                safety: browser
            ),
            item(
                "firefox",
                name: L("cleanup.firefox.name"),
                detail: "~/Library/Caches/Firefox",
                paths: [h("Library/Caches/Firefox")],
                category: .apps,
                systemImage: "globe",
                safety: browser
            ),
            item(
                "safari",
                name: L("cleanup.safari.name"),
                detail: L("cleanup.safari.detail"),
                paths: [
                    h("Library/Caches/com.apple.Safari"),
                    h("Library/Containers/com.apple.Safari/Data/Library/Caches")
                ],
                category: .apps,
                systemImage: "safari",
                safety: browser
            ),
            item(
                "edge",
                name: L("cleanup.edge.name"),
                detail: "~/Library/Caches/Microsoft Edge",
                paths: [h("Library/Caches/Microsoft Edge")],
                category: .apps,
                systemImage: "globe",
                safety: browser
            ),
            item(
                "brave",
                name: L("cleanup.brave.name"),
                detail: "~/Library/Caches/BraveSoftware/Brave-Browser",
                paths: [h("Library/Caches/BraveSoftware/Brave-Browser")],
                category: .apps,
                systemImage: "shield",
                safety: browser
            ),
            item(
                "vscode",
                name: L("cleanup.vscode.name"),
                detail: L("cleanup.vscode.detail"),
                paths: [
                    h("Library/Caches/com.microsoft.VSCode"),
                    h("Library/Application Support/Code/Cache"),
                    h("Library/Application Support/Code/CachedData"),
                    h("Library/Application Support/Code/CachedExtensionVSIXs"),
                    h("Library/Application Support/Code/GPUCache"),
                    h("Library/Application Support/Code/logs")
                ],
                category: .apps,
                systemImage: "chevron.left.forwardslash.chevron.right",
                safety: ide
            ),
            item(
                "cursor",
                name: L("cleanup.cursor.name"),
                detail: L("cleanup.cursor.detail"),
                paths: [
                    h("Library/Caches/Cursor"),
                    h("Library/Application Support/Cursor/Cache"),
                    h("Library/Application Support/Cursor/CachedData"),
                    h("Library/Application Support/Cursor/CachedExtensionVSIXs"),
                    h("Library/Application Support/Cursor/GPUCache"),
                    h("Library/Application Support/Cursor/logs")
                ],
                category: .apps,
                systemImage: "character.cursor.ibeam",
                safety: ide
            ),
            item(
                "jetbrains",
                name: L("cleanup.jetbrains.name"),
                detail: "~/Library/Caches/JetBrains",
                paths: [h("Library/Caches/JetBrains")],
                category: .apps,
                systemImage: "laptopcomputer",
                safety: ide
            ),
            item(
                "xcode-derived",
                name: L("cleanup.xcode-derived.name"),
                detail: L("cleanup.xcode-derived.detail"),
                paths: [h("Library/Developer/Xcode/DerivedData")],
                category: .xcode,
                systemImage: "hammer",
                safety: build
            ),
            item(
                "xcode-caches",
                name: L("cleanup.xcode-caches.name"),
                detail: "~/Library/Caches/com.apple.dt.Xcode",
                paths: [h("Library/Caches/com.apple.dt.Xcode")],
                category: .xcode,
                systemImage: "internaldrive",
                safety: build
            ),
            item(
                "xcode-devicesupport",
                name: L("cleanup.xcode-devicesupport.name"),
                detail: L("cleanup.xcode-devicesupport.detail"),
                paths: [
                    h("Library/Developer/Xcode/iOS DeviceSupport"),
                    h("Library/Developer/Xcode/watchOS DeviceSupport"),
                    h("Library/Developer/Xcode/tvOS DeviceSupport"),
                    h("Library/Developer/Xcode/visionOS DeviceSupport")
                ],
                risk: .caution,
                category: .xcode,
                systemImage: "iphone",
                safety: CleanupSafetyDetails(
                    removes: L("cleanup.safety.devicesupport.removes"),
                    keeps: L("cleanup.safety.devicesupport.keeps"),
                    note: L("cleanup.safety.devicesupport.note")
                )
            ),
            item(
                "xcode-archives",
                name: L("cleanup.xcode-archives.name"),
                detail: L("cleanup.xcode-archives.detail"),
                paths: [h("Library/Developer/Xcode/Archives")],
                risk: .viewOnly,
                action: .viewOnly,
                category: .xcode,
                systemImage: "archivebox"
            ),
            item(
                "xcode-xctestdevices",
                name: L("cleanup.xcode-xctestdevices.name"),
                detail: L("cleanup.xcode-xctestdevices.detail"),
                paths: [h("Library/Developer/XCTestDevices")],
                category: .xcode,
                systemImage: "hammer",
                safety: build
            ),
            item(
                "xcode-previews",
                name: L("cleanup.xcode-previews.name"),
                detail: L("cleanup.xcode-previews.detail"),
                paths: [h("Library/Developer/Xcode/UserData/Previews")],
                category: .xcode,
                systemImage: "eye",
                safety: build
            ),
            item(
                "xcode-swiftpm",
                name: L("cleanup.xcode-swiftpm.name"),
                detail: L("cleanup.xcode-swiftpm.detail"),
                paths: [
                    h("Library/org.swift.swiftpm"),
                    h("Library/Caches/org.swift.swiftpm"),
                    h("Library/Developer/Xcode/SourcePackages/artifacts")
                ],
                category: .xcode,
                systemImage: "shippingbox",
                safety: packages
            ),
            item(
                "simulator-caches",
                name: L("cleanup.simulator-caches.name"),
                detail: L("cleanup.simulator-caches.detail"),
                paths: [h("Library/Developer/CoreSimulator/Caches")],
                category: .xcode,
                systemImage: "square.stack.3d.up",
                safety: build
            ),
            item(
                "simulator-runtimes",
                name: L("cleanup.simulator-runtimes.name"),
                detail: L("cleanup.simulator-runtimes.detail"),
                paths: [h("Library/Developer/CoreSimulator/Profiles/Runtimes")],
                risk: .external,
                action: .externalTool,
                category: .xcode,
                systemImage: "square.stack.3d.up"
            ),
            item(
                "logs",
                name: L("cleanup.logs.name"),
                detail: L("cleanup.logs.detail"),
                paths: [h("Library/Logs")],
                risk: .caution,
                category: .system,
                systemImage: "doc.text"
            ),
            item(
                "trash",
                name: L("cleanup.trash.name"),
                detail: L("cleanup.trash.detail"),
                paths: [h(".Trash")],
                risk: .permanent,
                action: .emptyTrashPermanently,
                category: .system,
                systemImage: "trash"
            ),
            item(
                "npm",
                name: L("cleanup.npm.name"),
                detail: "~/.npm/_cacache",
                paths: [h(".npm/_cacache")],
                category: .packageManager,
                systemImage: "cube.box",
                safety: packages
            ),
            item(
                "yarn",
                name: L("cleanup.yarn.name"),
                detail: "~/Library/Caches/Yarn",
                paths: [h("Library/Caches/Yarn")],
                category: .packageManager,
                systemImage: "cube.box",
                safety: packages
            ),
            item(
                "pnpm",
                name: L("cleanup.pnpm.name"),
                detail: "~/Library/pnpm/store, ~/Library/Caches/pnpm, ~/.cache/pnpm",
                paths: [
                    h("Library/pnpm/store"),
                    h("Library/Caches/pnpm"),
                    h(".cache/pnpm")
                ],
                category: .packageManager,
                systemImage: "cube.box",
                safety: packages
            ),
            item(
                "bun",
                name: L("cleanup.bun.name"),
                detail: "~/.bun/install/cache",
                paths: [h(".bun/install/cache")],
                category: .packageManager,
                systemImage: "hare",
                safety: packages
            ),
            item(
                "deno",
                name: L("cleanup.deno.name"),
                detail: "~/Library/Caches/deno",
                paths: [h("Library/Caches/deno")],
                category: .packageManager,
                systemImage: "bolt",
                safety: packages
            ),
            item(
                "pip",
                name: L("cleanup.pip.name"),
                detail: "~/Library/Caches/pip, ~/.cache/pip",
                paths: [
                    h("Library/Caches/pip"),
                    h(".cache/pip")
                ],
                category: .packageManager,
                systemImage: "cube.box",
                safety: packages
            ),
            item(
                "uv",
                name: L("cleanup.uv.name"),
                detail: "~/.cache/uv",
                paths: [h(".cache/uv")],
                category: .packageManager,
                systemImage: "cube.box",
                safety: packages
            ),
            item(
                "homebrew",
                name: L("cleanup.homebrew.name"),
                detail: L("cleanup.homebrew.detail"),
                paths: [h("Library/Caches/Homebrew")],
                risk: .external,
                action: .externalTool,
                category: .packageManager,
                systemImage: "terminal"
            ),
            item(
                "cocoapods",
                name: L("cleanup.cocoapods.name"),
                detail: "~/Library/Caches/CocoaPods",
                paths: [h("Library/Caches/CocoaPods")],
                category: .packageManager,
                systemImage: "cube.box",
                safety: packages
            ),
            item(
                "carthage",
                name: L("cleanup.carthage.name"),
                detail: "~/Library/Caches/org.carthage.CarthageKit",
                paths: [h("Library/Caches/org.carthage.CarthageKit")],
                category: .packageManager,
                systemImage: "cube.box",
                safety: packages
            ),
            item(
                "gradle",
                name: L("cleanup.gradle.name"),
                detail: "~/.gradle/caches",
                paths: [h(".gradle/caches")],
                category: .packageManager,
                systemImage: "cube.box",
                safety: packages
            ),
            item(
                "gradle-wrapper",
                name: L("cleanup.gradle-wrapper.name"),
                detail: "~/.gradle/wrapper/dists",
                paths: [h(".gradle/wrapper/dists")],
                category: .packageManager,
                systemImage: "cube.box",
                safety: packages
            ),
            item(
                "maven",
                name: L("cleanup.maven.name"),
                detail: "~/.m2/repository",
                paths: [h(".m2/repository")],
                category: .packageManager,
                systemImage: "building.columns",
                safety: packages
            ),
            item(
                "go-build",
                name: L("cleanup.go-build.name"),
                detail: "~/Library/Caches/go-build",
                paths: [h("Library/Caches/go-build")],
                category: .packageManager,
                systemImage: "leaf",
                safety: build
            ),
            item(
                "go-modules",
                name: L("cleanup.go-modules.name"),
                detail: "~/go/pkg/mod/cache",
                paths: [h("go/pkg/mod/cache")],
                category: .packageManager,
                systemImage: "leaf",
                safety: packages
            ),
            item(
                "cargo",
                name: L("cleanup.cargo.name"),
                detail: "~/.cargo/registry/cache",
                paths: [h(".cargo/registry/cache")],
                category: .packageManager,
                systemImage: "wrench",
                safety: packages
            ),
            item(
                "playwright",
                name: L("cleanup.playwright.name"),
                detail: "~/Library/Caches/ms-playwright",
                paths: [h("Library/Caches/ms-playwright")],
                category: .packageManager,
                systemImage: "theatermasks",
                safety: packages
            ),
            item(
                "node-gyp",
                name: L("cleanup.node-gyp.name"),
                detail: "~/Library/Caches/node-gyp",
                paths: [h("Library/Caches/node-gyp")],
                category: .packageManager,
                systemImage: "hammer",
                safety: packages
            ),
            item(
                "flutter",
                name: L("cleanup.flutter.name"),
                detail: "~/.pub-cache",
                paths: [h(".pub-cache")],
                category: .packageManager,
                systemImage: "bird",
                safety: packages
            )
        ]
    }
}
