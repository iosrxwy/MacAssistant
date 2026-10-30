import SwiftUI
import AppKit
import MacAssistantKit

@main
struct MacAssistantApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @AppStorage(SceneBackdropSettings.defaultsKey) private var sceneRaw = SceneBackdropID.system.rawValue

    var body: some Scene {
        WindowGroup(id: "main") {
            RootView(initialSelection: initialRoute)
                .frame(minWidth: 940, minHeight: 620)
                .tint(.appAccent)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(before: .toolbar) {
                Picker(L("about.scene.title"), selection: sceneBinding) {
                    ForEach(SceneBackdropID.allCases) { scene in
                        Text(scene.title).tag(scene.rawValue)
                    }
                }
                .pickerStyle(.inline)
            }
        }
    }

    private var sceneBinding: Binding<String> {
        Binding(
            get: { SceneBackdropID.resolved(sceneRaw).rawValue },
            set: { sceneRaw = $0 }
        )
    }

    private var initialRoute: SidebarItem {
        let arguments = ProcessInfo.processInfo.arguments
        guard let flag = arguments.firstIndex(of: "--route"),
              arguments.indices.contains(flag + 1),
              let route = SidebarItem(rawValue: arguments[flag + 1])
        else {
            return .dashboard
        }
        return route
    }
}

/// 设置为常规 App(出现在 Dock),并在启动后激活窗口。
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        // 必须在第一扇窗口出来之前写：macOS 26 默认把侧栏收成一块浮着的圆角玻璃。
        // 关掉后侧栏贴窗边、拉满高度，接近 Codex / Finder 的通栏做法。
        UserDefaults.standard.set(false, forKey: "NSSplitViewItemSidebarDefaultsToFloatingAppearance")
        UserDefaults.standard.set(0.0, forKey: "NSSplitViewItemGlassMinimumCornerRadius")
        AppIconLoader.install()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)

        if ProcessInfo.processInfo.environment["MACASSISTANT_ICON_PROBE"] == "1" {
            let size = NSApplication.shared.applicationIconImage.size
            print("MACASSISTANT_ICON_READY \(Int(size.width))x\(Int(size.height))")
            NSApplication.shared.terminate(nil)
            return
        }

        DuoStatusBarController.shared.install()

        Task.detached(priority: .utility) {
            _ = AppleIDSigningService.renewDueJobs()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        DuoStatusBarController.shared.prepareForTermination()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !DuoStatusBarController.shared.isEnabled
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            DuoStatusBarController.shared.showMainWindow()
        }
        return true
    }
}

private enum AppIconLoader {
    static func install() {
        // 发布 .app 由 Info.plist + AppIcon.icns 提供图标；裸 SwiftPM 运行才读取 Bundle.module。
        guard Bundle.main.bundleURL.pathExtension.lowercased() != "app" else { return }
        guard let url = Bundle.module.url(forResource: "AppIcon", withExtension: "png"),
              let image = NSImage(contentsOf: url),
              image.size.width > 0,
              image.size.height > 0
        else {
            assertionFailure("SwiftPM AppIcon.png resource is missing or invalid")
            return
        }
        NSApplication.shared.applicationIconImage = image
    }
}
