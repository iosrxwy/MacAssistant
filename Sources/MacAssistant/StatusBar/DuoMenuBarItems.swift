import Foundation

/// 读写其他 App 的偏好。可见性键在本机 `com.apple.controlcenter` 里核对过：
/// `NSStatusItem VisibleCC WiFi` / `Battery` 在用户域（任意主机），
/// `BatteryShowPercentage` 在 ByHost（当前主机）。
enum DuoPrefs {
    static func bool(_ key: String, domain: String, host: Bool = false) -> Bool? {
        guard let value = copy(key, domain: domain, host: host) else { return nil }
        return (value as? NSNumber)?.boolValue
    }

    static func double(_ key: String, domain: String, host: Bool = false) -> Double? {
        guard let value = copy(key, domain: domain, host: host) else { return nil }
        return (value as? NSNumber)?.doubleValue
    }

    static func int(_ key: String, domain: String, host: Bool = false) -> Int? {
        guard let value = copy(key, domain: domain, host: host) else { return nil }
        return (value as? NSNumber)?.intValue
    }

    static func setBool(_ key: String, domain: String, host: Bool = false, _ value: Bool?) {
        write(key, domain: domain, host: host, value: value.map { NSNumber(value: $0) })
    }

    static func setDouble(_ key: String, domain: String, host: Bool = false, _ value: Double?) {
        write(key, domain: domain, host: host, value: value.map { NSNumber(value: $0) })
    }

    static func setInt(_ key: String, domain: String, host: Bool = false, _ value: Int?) {
        write(key, domain: domain, host: host, value: value.map { NSNumber(value: $0) })
    }

    static func globalBool(_ key: String) -> Bool? {
        guard let value = CFPreferencesCopyValue(
            key as CFString,
            kCFPreferencesAnyApplication,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost
        ) else { return nil }
        return (value as? NSNumber)?.boolValue
    }

    static func setGlobalBool(_ key: String, _ value: Bool) {
        CFPreferencesSetValue(
            key as CFString,
            NSNumber(value: value),
            kCFPreferencesAnyApplication,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost
        )
        CFPreferencesSynchronize(
            kCFPreferencesAnyApplication,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost
        )
    }

    static func globalString(_ key: String) -> String? {
        CFPreferencesAppSynchronize(kCFPreferencesAnyApplication)
        return CFPreferencesCopyValue(
            key as CFString,
            kCFPreferencesAnyApplication,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost
        ) as? String
    }

    @discardableResult
    static func relaunch(_ processName: String, force: Bool = false) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        process.arguments = force ? ["-9", processName] : [processName]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            return true
        } catch {
            return false
        }
    }

    private static func copy(_ key: String, domain: String, host: Bool) -> CFPropertyList? {
        CFPreferencesCopyValue(
            key as CFString,
            domain as CFString,
            kCFPreferencesCurrentUser,
            host ? kCFPreferencesCurrentHost : kCFPreferencesAnyHost
        )
    }

    private static func write(_ key: String, domain: String, host: Bool, value: CFPropertyList?) {
        CFPreferencesSetValue(
            key as CFString,
            value,
            domain as CFString,
            kCFPreferencesCurrentUser,
            host ? kCFPreferencesCurrentHost : kCFPreferencesAnyHost
        )
        CFPreferencesSynchronize(
            domain as CFString,
            kCFPreferencesCurrentUser,
            host ? kCFPreferencesCurrentHost : kCFPreferencesAnyHost
        )
    }
}

/// 开启三合一图标时藏起系统 Wi-Fi 和电量（含百分比），关闭或退出时写回原来的值。
///
/// 这台机器上菜单栏里的系统图标由 ByHost `com.apple.controlcenter` 的
/// `WiFi` / `Battery` 整数控制：写成 8 后图标从菜单栏消失，键不存在时系统按原来的方式显示。
/// `BatteryShowPercentage` 控制百分比。`NSStatusItem VisibleCC *` 一并写回，但不单独决定显隐。
/// 不改 Bartender，也不动这两个图标的 Preferred Position。
@MainActor
enum DuoMenuBarItems {
    private static let domain = "com.apple.controlcenter"
    private static let wifiKey = "NSStatusItem VisibleCC WiFi"
    private static let batteryKey = "NSStatusItem VisibleCC Battery"
    private static let percentKey = "BatteryShowPercentage"
    private static let wifiModuleKey = "WiFi"
    private static let batteryModuleKey = "Battery"
    /// 在这台 macOS 26 上实测：8 会把对应系统图标移出菜单栏，无线网络本身仍然开着。
    private static let hiddenModule = 8
    private static let snapshotKey = "MacAssistant.DuoStatusBar.systemItemSnapshot"
    private static var generation = 0

    private struct Snapshot: Codable {
        var wifi: Bool?
        var battery: Bool?
        var percentage: Bool?
        var wifiModule: Int?
        var batteryModule: Int?
    }

    static func hide() {
        generation += 1
        let token = generation
        let snapshot = load() ?? capture()
        save(snapshot)
        let needsRestart = !isHidden
        applyHidden()
        guard needsRestart else { return }
        DuoPrefs.relaunch("ControlCenter", force: true)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard token == generation, !isHidden else { return }
            applyHidden()
            DuoPrefs.relaunch("ControlCenter", force: true)
        }
    }

    static func restore() {
        generation += 1
        let token = generation
        guard let snapshot = load() else { return }
        let needsRestart = !matches(snapshot)
        write(snapshot)
        guard needsRestart else {
            clear()
            return
        }
        DuoPrefs.relaunch("ControlCenter", force: true)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard token == generation, let snapshot = load() else { return }
            if matches(snapshot) {
                clear()
                return
            }
            write(snapshot)
            DuoPrefs.relaunch("ControlCenter", force: true)
        }
    }

    /// 退出时同步写回。ControlCenter 正常退出会把内存里的旧可见性刷回偏好，所以用 SIGKILL。
    static func restoreForQuit() {
        generation += 1
        guard let snapshot = load() else { return }
        write(snapshot)
        DuoPrefs.relaunch("ControlCenter", force: true)
        let deadline = Date().addingTimeInterval(0.6)
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        guard let latest = load() else { return }
        if matches(latest) {
            clear()
            return
        }
        write(latest)
        DuoPrefs.relaunch("ControlCenter", force: true)
    }

    private static var isHidden: Bool {
        DuoPrefs.int(wifiModuleKey, domain: domain, host: true) == hiddenModule
            && DuoPrefs.int(batteryModuleKey, domain: domain, host: true) == hiddenModule
            && DuoPrefs.bool(percentKey, domain: domain, host: true) == false
    }

    private static func applyHidden() {
        DuoPrefs.setInt(wifiModuleKey, domain: domain, host: true, hiddenModule)
        DuoPrefs.setInt(batteryModuleKey, domain: domain, host: true, hiddenModule)
        DuoPrefs.setBool(percentKey, domain: domain, host: true, false)
        DuoPrefs.setBool(wifiKey, domain: domain, false)
        DuoPrefs.setBool(batteryKey, domain: domain, false)
    }

    private static func matches(_ snapshot: Snapshot) -> Bool {
        DuoPrefs.int(wifiModuleKey, domain: domain, host: true) == snapshot.wifiModule
            && DuoPrefs.int(batteryModuleKey, domain: domain, host: true) == snapshot.batteryModule
            && DuoPrefs.bool(percentKey, domain: domain, host: true) == snapshot.percentage
            && DuoPrefs.bool(wifiKey, domain: domain) == snapshot.wifi
            && DuoPrefs.bool(batteryKey, domain: domain) == snapshot.battery
    }

    private static func write(_ snapshot: Snapshot) {
        DuoPrefs.setInt(wifiModuleKey, domain: domain, host: true, snapshot.wifiModule)
        DuoPrefs.setInt(batteryModuleKey, domain: domain, host: true, snapshot.batteryModule)
        DuoPrefs.setBool(percentKey, domain: domain, host: true, snapshot.percentage)
        DuoPrefs.setBool(wifiKey, domain: domain, snapshot.wifi)
        DuoPrefs.setBool(batteryKey, domain: domain, snapshot.battery)
    }

    private static func capture() -> Snapshot {
        Snapshot(
            wifi: DuoPrefs.bool(wifiKey, domain: domain),
            battery: DuoPrefs.bool(batteryKey, domain: domain),
            percentage: DuoPrefs.bool(percentKey, domain: domain, host: true),
            wifiModule: DuoPrefs.int(wifiModuleKey, domain: domain, host: true),
            batteryModule: DuoPrefs.int(batteryModuleKey, domain: domain, host: true)
        )
    }

    private static func load() -> Snapshot? {
        guard let data = UserDefaults.standard.data(forKey: snapshotKey) else { return nil }
        return try? JSONDecoder().decode(Snapshot.self, from: data)
    }

    private static func save(_ snapshot: Snapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        UserDefaults.standard.set(data, forKey: snapshotKey)
    }

    private static func clear() {
        UserDefaults.standard.removeObject(forKey: snapshotKey)
    }
}
