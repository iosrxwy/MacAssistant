import SwiftUI
import AppKit
import MacAssistantKit

@main
struct MacAssistantApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            RootView(initialSelection: initialRoute)
                .frame(minWidth: 940, minHeight: 620)
                .tint(.appAccent)
        }
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
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
        AppIconLoader.install()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)

        if ProcessInfo.processInfo.environment["MACASSISTANT_ICON_PROBE"] == "1" {
            let size = NSApplication.shared.applicationIconImage.size
            print("MACASSISTANT_ICON_READY \(Int(size.width))x\(Int(size.height))")
            NSApplication.shared.terminate(nil)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
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
