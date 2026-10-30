import Combine
import Darwin
import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// 扫描本机 Applications 目录，并按显示名 / 文件名做搜索。
public enum MacAppLibrary {
    public static var defaultSearchDirectories: [URL] {
        [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Applications", isDirectory: true)
        ]
    }

    public static func discover(
        in directories: [URL] = defaultSearchDirectories
    ) -> [URL] {
        let found = directories.flatMap { directory -> [URL] in
            apps(in: directory)
        }
        return Array(Set(found)).sorted {
            displayName(of: $0).localizedStandardCompare(displayName(of: $1)) == .orderedAscending
        }
    }

    private static func apps(in directory: URL) -> [URL] {
        let children = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return children.filter { isAppBundle($0) }
    }

    private static func isAppBundle(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "app" && FileSystemHelper.isDirectory(url)
    }

    public static func displayName(of app: URL) -> String {
        let key = app.standardizedFileURL.path
        if let cached = DisplayNameCache.name(for: key) { return cached }
        let name: String
        if let plist = try? IpaService.infoPlist(appBundle: app) {
            if let value = plist["CFBundleDisplayName"] as? String, !value.isEmpty {
                name = value
            } else if let value = plist["CFBundleName"] as? String, !value.isEmpty {
                name = value
            } else {
                name = app.deletingPathExtension().lastPathComponent
            }
        } else {
            name = app.deletingPathExtension().lastPathComponent
        }
        DisplayNameCache.store(name, for: key)
        return name
    }

    public static func invalidateCaches(for app: URL? = nil) {
        let key = app?.standardizedFileURL.path
        DisplayNameCache.invalidate(key)
    }

    public static func matches(_ app: URL, search: String) -> Bool {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return true }
        if TextSearch.matches(displayName(of: app), needle: query)
            || TextSearch.matches(app.deletingPathExtension().lastPathComponent, needle: query)
            || TextSearch.matches(app.path, needle: query)
            || TextSearch.matches(bundleID(of: app) ?? "", needle: query) {
            return true
        }
        return isWeChatQuery(query) && looksLikeWeChat(app)
    }

    public static func bundleID(of app: URL) -> String? {
        plistString(app, key: "CFBundleIdentifier")
    }

    public static func marketingVersion(of app: URL) -> String? {
        plistString(app, key: "CFBundleShortVersionString")
    }

    /// 列表和标题用来区分同名副本，例如 `WeChat.app · 4.1.10`。
    public static func copyLabel(of app: URL) -> String {
        let folder = app.lastPathComponent
        guard let version = marketingVersion(of: app) else { return folder }
        return "\(folder) · \(version)"
    }

    private static func plistString(_ app: URL, key: String) -> String? {
        let plist = try? IpaService.infoPlist(appBundle: app)
        let value = (plist?[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (value?.isEmpty == false) ? value : nil
    }

    /// 本机常同时装着 `WeChat.app` 和 `微信.app`，显示名却都是 WeChat。
    private static let wechatQueries: Set<String> = ["微信", "wechat", "weixin"]

    static func isWeChatQuery(_ query: String) -> Bool {
        wechatQueries.contains(query.lowercased())
    }

    static func looksLikeWeChat(_ app: URL) -> Bool {
        let name = displayName(of: app).lowercased()
        let folder = app.deletingPathExtension().lastPathComponent.lowercased()
        let identifier = bundleID(of: app)?.lowercased() ?? ""
        return name.contains("wechat") || name.contains("微信")
            || folder.contains("wechat") || folder.contains("微信")
            || identifier.contains("xinwechat") || identifier == "com.tencent.xin"
    }

    public static func filtered(_ apps: [URL], search: String) -> [URL] {
        apps.filter { matches($0, search: search) }
    }
}

/// 监听 Applications 目录变化，1 秒防抖后重扫。进程内共用一份列表，进页不再整表重扫。
@MainActor
public final class MacAppLibraryMonitor: ObservableObject {
    public static let shared = MacAppLibraryMonitor()

    @Published public private(set) var apps: [URL] = []
    @Published public var extras: [URL] = []
    @Published public var searchText = ""
    @Published public private(set) var isScanning = false

    private var monitors: [DispatchSourceFileSystemObject] = []
    private var refreshTask: Task<Void, Never>?
    private let directories: [URL]
    private let persistToProcessCache: Bool
    private var watchersStarted = false

    public var visibleApps: [URL] {
        let merged = Array(Set(apps + extras.filter { FileSystemHelper.isDirectory($0) }))
            .sorted {
                MacAppLibrary.displayName(of: $0)
                    .localizedStandardCompare(MacAppLibrary.displayName(of: $1)) == .orderedAscending
            }
        return MacAppLibrary.filtered(merged, search: searchText)
    }

    public init(directories: [URL] = MacAppLibrary.defaultSearchDirectories) {
        self.directories = directories
        persistToProcessCache = directories.map(\.path) == MacAppLibrary.defaultSearchDirectories.map(\.path)
        if persistToProcessCache, let cached = ProcessCache.apps, !cached.isEmpty {
            apps = cached
            extras = ProcessCache.extras
        }
    }

    deinit {
        monitors.forEach { $0.cancel() }
        refreshTask?.cancel()
    }

    public func addExtra(_ url: URL) {
        guard url.pathExtension.lowercased() == "app", FileSystemHelper.isDirectory(url) else { return }
        if !extras.contains(url) { extras.append(url) }
        if !apps.contains(url) { apps.append(url) }
        persist()
    }

    /// 有缓存就直接显示；只在第一次或手动刷新时扫盘。
    public func ensureLoaded() {
        startWatchersIfNeeded()
        if apps.isEmpty {
            reload()
        }
    }

    public func reload() {
        isScanning = true
        MacAppLibrary.invalidateCaches()
        let directories = self.directories
        Task.detached(priority: .userInitiated) { [weak self] in
            let discovered = MacAppLibrary.discover(in: directories)
            await self?.apply(discovered)
        }
    }

    public func startWatching() {
        ensureLoaded()
    }

    public func stopWatching() {
        monitors.forEach { $0.cancel() }
        monitors.removeAll()
        refreshTask?.cancel()
        refreshTask = nil
        watchersStarted = false
    }

    private func startWatchersIfNeeded() {
        guard !watchersStarted else { return }
        watchersStarted = true
        for directory in directories {
            guard FileManager.default.fileExists(atPath: directory.path) else { continue }
            let descriptor = open(directory.path, O_EVTONLY)
            guard descriptor >= 0 else { continue }
            let monitor = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor,
                eventMask: [.write, .extend, .delete, .rename, .attrib],
                queue: .main
            )
            monitor.setEventHandler { [weak self] in
                self?.scheduleReload()
            }
            monitor.setCancelHandler {
                close(descriptor)
            }
            monitor.resume()
            monitors.append(monitor)
        }
    }

    private func scheduleReload() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            self?.reload()
        }
    }

    private func apply(_ discovered: [URL]) {
        apps = discovered
        extras.removeAll { extra in
            discovered.contains(extra) || !FileSystemHelper.isDirectory(extra)
        }
        isScanning = false
        persist()
    }

    private func persist() {
        guard persistToProcessCache else { return }
        ProcessCache.apps = apps
        ProcessCache.extras = extras
    }
}

private enum ProcessCache {
    static var apps: [URL]?
    static var extras: [URL] = []
}

private enum DisplayNameCache {
    private static let lock = NSLock()
    private static var names: [String: String] = [:]

    static func name(for key: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return names[key]
    }

    static func store(_ name: String, for key: String) {
        lock.lock()
        names[key] = name
        lock.unlock()
    }

    static func invalidate(_ key: String?) {
        lock.lock()
        if let key {
            names.removeValue(forKey: key)
        } else {
            names.removeAll()
        }
        lock.unlock()
    }
}

#if canImport(AppKit)
public enum MacAppIconCache {
    private static let lock = NSLock()
    private static var images: [String: NSImage] = [:]

    public static func image(for app: URL, pointSize: CGFloat = 64) -> NSImage {
        let key = "\(app.path)#\(Int(pointSize.rounded()))"
        lock.lock()
        if let cached = images[key] {
            lock.unlock()
            return cached
        }
        lock.unlock()
        let image = NSWorkspace.shared.icon(forFile: app.path)
        image.size = NSSize(width: pointSize, height: pointSize)
        lock.lock()
        images[key] = image
        lock.unlock()
        return image
    }

    static func invalidate(_ key: String?) {
        lock.lock()
        if let key {
            images.removeValue(forKey: key)
        } else {
            images.removeAll()
        }
        lock.unlock()
    }
}
#endif
