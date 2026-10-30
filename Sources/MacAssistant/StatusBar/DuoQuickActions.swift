import AppKit
import ApplicationServices
import CoreAudio
import CoreServices
import CoreWLAN
import Foundation
import IOKit.pwr_mgt
import MacAssistantKit
import SystemConfiguration

enum DuoEnergyMode: Int, Equatable {
    case automatic = 0
    case low = 1
    case high = 2
}

/// 保持亮屏的时长。`forever` 不设超时。
enum DuoAwakeSpan: Int, CaseIterable, Identifiable {
    case forever = 0
    case fiveMinutes = 5
    case thirtyMinutes = 30
    case oneHour = 60
    case twoHours = 120
    case fiveHours = 300
    case eightHours = 480

    var id: Int { rawValue }

    var seconds: TimeInterval? {
        self == .forever ? nil : TimeInterval(rawValue * 60)
    }
}

struct DuoDisk: Identifiable, Equatable {
    var id: String { path }
    var name: String
    var path: String
}

/// 菜单栏面板里的本机开关。思路参考 OnlySwitch（jacklandrin，MIT），交互和调用都是这里自己写的。
@MainActor
final class DuoQuickActions: ObservableObject {
    @Published private(set) var dockHidden: Bool
    @Published private(set) var dockFailure: DuoDockFailure?
    @Published private(set) var widgetsHidden = false
    @Published private(set) var stageManagerEnabled = false
    @Published private(set) var desktopHidden = false
    @Published private(set) var micMuted: Bool?
    @Published private(set) var awake = false
    @Published private(set) var awakeDeadline: Date?
    @Published private(set) var awakeSpan: DuoAwakeSpan = .twoHours
    @Published private(set) var preventLidSleep = false
    @Published private(set) var screenClean = false
    @Published private(set) var energyMode: DuoEnergyMode?
    @Published private(set) var supportsHighPower = false
    @Published private(set) var energyFailed = false
    @Published private(set) var knownNetworks: [String] = []
    @Published private(set) var currentSSID: String?
    @Published private(set) var currentSecured = false
    @Published private(set) var currentHotspotName: String?
    @Published private(set) var nearbyHotspots: [DuoNearbyHotspot] = []
    @Published private(set) var networksUnreadable = false
    @Published private(set) var keyboardLocked = false
    @Published private(set) var keyboardNeedsAccess = false
    @Published private(set) var menuBarAutoHide = false
    @Published private(set) var hiddenFilesShown = false
    @Published private(set) var darkMode = false
    @Published private(set) var darkFailed = false
    @Published private(set) var showExtensions = false
    @Published private(set) var showPathbar = false
    @Published private(set) var clipboardCleared = false
    @Published private(set) var sessionFailed = false
    @Published private(set) var trashFailed = false
    @Published private(set) var toolEpoch = 0
    @Published private(set) var disks: [DuoDisk] = []
    @Published private(set) var derivedBytes: Int64?
    @Published private(set) var derivedReady = false

    private var displayAssertion: IOPMAssertionID = 0
    private var lidAssertion: IOPMAssertionID = 0
    private var awakeTimer: Timer?
    private var lastEnergyRead = Date.distantPast
    private var lastNetworkRead = Date.distantPast
    private var cleanWindows: [NSWindow] = []
    private var cleanMonitor: Any?
    private var wifiDeviceName: String?

    private let dockFlagKey = "MacAssistant.DuoQuick.dockHidden"
    private let dockSnapshotKey = "MacAssistant.DuoQuick.dockSnapshot"
    private let awakeSpanKey = "MacAssistant.DuoQuick.awakeMinutes"
    private let awakeLidKey = "MacAssistant.DuoQuick.awakeLid"

    init() {
        dockHidden = UserDefaults.standard.bool(forKey: dockFlagKey)
        if UserDefaults.standard.object(forKey: awakeSpanKey) != nil,
           let span = DuoAwakeSpan(rawValue: UserDefaults.standard.integer(forKey: awakeSpanKey)) {
            awakeSpan = span
        }
        preventLidSleep = UserDefaults.standard.bool(forKey: awakeLidKey)
        refreshToggles()
        scanDerivedData()
    }

    func refreshPassive(onBattery: Bool) {
        if awake, let awakeDeadline, awakeDeadline <= Date() {
            releaseAwake()
        }
        refreshToggles()
        if Date().timeIntervalSince(lastEnergyRead) > 15 {
            readEnergy(onBattery: onBattery)
        }
    }

    func refreshForDisplay(onBattery: Bool) {
        refreshToggles()
        menuBarAutoHide = DuoMenuBarAutoHide.read()
        readEnergy(onBattery: onBattery)
        if Date().timeIntervalSince(lastNetworkRead) > 20 {
            loadKnownNetworks()
        } else {
            applyCurrentWiFi(DuoCurrentWiFi.read(device: wifiDevice()))
        }
    }

    func setDockHidden(_ hidden: Bool) {
        if let failure = DuoDockAutoHide.write(hidden) {
            dockHidden = DuoDockAutoHide.read()
            dockFailure = failure
            return
        }
        dockFailure = nil
        let actual = DuoDockAutoHide.read()
        dockHidden = actual
        UserDefaults.standard.set(actual, forKey: dockFlagKey)
        if !actual {
            UserDefaults.standard.removeObject(forKey: dockSnapshotKey)
            if (DuoPrefs.double("autohide-delay", domain: "com.apple.dock") ?? 0) >= 500 {
                DuoPrefs.setDouble("autohide-delay", domain: "com.apple.dock", nil)
            }
        }
    }

    func setWidgetsHidden(_ hidden: Bool) {
        let value = hidden ? 1 : 0
        // 只写偏好。WindowManager 会收到偏好变化并自己刷新布局。
        // 结束 WindowManager 进程会整屏闪一下，并把窗口收成「显示桌面」。
        DuoPrefs.setInt("StandardHideWidgets", domain: "com.apple.WindowManager", value)
        DuoPrefs.setInt("StageManagerHideWidgets", domain: "com.apple.WindowManager", value)
        widgetsHidden = widgetsAreHidden()
    }

    func setStageManager(_ on: Bool) {
        DuoPrefs.setInt("GloballyEnabled", domain: "com.apple.WindowManager", on ? 1 : 0)
        stageManagerEnabled = (DuoPrefs.int("GloballyEnabled", domain: "com.apple.WindowManager") ?? 0) != 0
    }

    private func widgetsAreHidden() -> Bool {
        (DuoPrefs.int("StandardHideWidgets", domain: "com.apple.WindowManager") ?? 0) != 0
            || (DuoPrefs.int("StageManagerHideWidgets", domain: "com.apple.WindowManager") ?? 0) != 0
    }

    func setDesktopHidden(_ hidden: Bool) {
        DuoPrefs.setBool("CreateDesktop", domain: "com.apple.finder", !hidden)
        desktopHidden = hidden
        DuoPrefs.relaunch("Finder")
    }

    func setMicMuted(_ muted: Bool) {
        guard DuoInputMute.set(muted) else { return }
        micMuted = DuoInputMute.read()
    }

    func setAwake(_ on: Bool) {
        if on {
            beginAwake(span: awakeSpan)
        } else {
            releaseAwake()
        }
    }

    /// 选时长会立刻按这个时长重新计时。关着的时候点一项，等于打开并开始。
    func selectAwakeSpan(_ span: DuoAwakeSpan) {
        awakeSpan = span
        UserDefaults.standard.set(span.rawValue, forKey: awakeSpanKey)
        beginAwake(span: span)
    }

    /// 合盖时不休眠：在同一段计时里再拿一份「阻止闲置睡眠」断言。
    /// 系统在没有外接显示器时，合上盖子仍可能睡眠；这份断言覆盖的是闲置睡眠和合盖续用。
    func setPreventLidSleep(_ on: Bool) {
        preventLidSleep = on
        UserDefaults.standard.set(on, forKey: awakeLidKey)
        guard awake else {
            if !on { clearLidAssertion() }
            return
        }
        if on {
            let timeout = awakeDeadline.map { max(1, $0.timeIntervalSinceNow) } ?? 0
            installLidAssertion(timeout: timeout)
        } else {
            clearLidAssertion()
        }
    }

    func setScreenClean(_ on: Bool) {
        if on {
            showCleanCover()
        } else {
            hideCleanCover()
        }
    }

    func setEnergy(_ mode: DuoEnergyMode, onBattery: Bool) {
        guard mode != .high || supportsHighPower else { return }
        // 授权框只在本次打开后的第一次切换出现，随后复用已经提权的会话。
        switch PrivilegedEnergySession.shared.apply(onBattery: onBattery, mode: mode.rawValue) {
        case .applied:
            energyFailed = false
        case .cancelled:
            break
        case .failed:
            energyFailed = true
        }
        readEnergy(onBattery: onBattery)
    }

    func ejectDisks() {
        let urls = disks.compactMap { URL(fileURLWithPath: $0.path) }
        for url in urls {
            try? NSWorkspace.shared.unmountAndEjectDevice(at: url)
        }
        refreshDisks()
    }

    func setKeyboardLocked(_ on: Bool) {
        if !on {
            DuoKeyboardGuard.shared.stop()
            keyboardLocked = false
            return
        }
        if !AXIsProcessTrusted() {
            let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            let options = [key: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        }
        let started = DuoKeyboardGuard.shared.start { [weak self] in
            self?.setKeyboardLocked(false)
        }
        keyboardLocked = started
        keyboardNeedsAccess = !started
    }

    func setMenuBarAutoHide(_ on: Bool) {
        guard DuoMenuBarAutoHide.write(on) else { return }
        menuBarAutoHide = DuoMenuBarAutoHide.read()
    }

    func setHiddenFilesShown(_ shown: Bool) {
        DuoPrefs.setBool("AppleShowAllFiles", domain: "com.apple.finder", shown)
        hiddenFilesShown = shown
        DuoPrefs.relaunch("Finder")
    }

    func emptyTrash() {
        trashFailed = !DuoTrash.empty()
    }

    func setDarkMode(_ on: Bool) {
        guard DuoSystemAppearance.setDark(on), DuoSystemAppearance.isDark == on else {
            darkMode = DuoSystemAppearance.isDark
            darkFailed = true
            return
        }
        darkFailed = false
        darkMode = on
    }

    func setShowExtensions(_ shown: Bool) {
        DuoPrefs.setGlobalBool("AppleShowAllExtensions", shown)
        showExtensions = shown
        DuoPrefs.relaunch("Finder")
    }

    func setShowPathbar(_ shown: Bool) {
        DuoPrefs.setBool("ShowPathbar", domain: "com.apple.finder", shown)
        showPathbar = shown
        DuoPrefs.relaunch("Finder")
    }

    func clearClipboard() {
        NSPasteboard.general.clearContents()
        clipboardCleared = true
    }

    func sleepNow() {
        sessionFailed = !DuoSession.sleep()
    }

    func restartNow() {
        sessionFailed = !DuoSession.restart()
    }

    func logOutNow() {
        sessionFailed = !DuoSession.perform("log out")
    }

    func toolsInOrder() -> [DuoToolID] {
        _ = toolEpoch
        return DuoToolPrefs.order()
    }

    func toolIsShown(_ id: DuoToolID) -> Bool {
        _ = toolEpoch
        return DuoToolPrefs.isShown(id)
    }

    func setToolShown(_ id: DuoToolID, _ shown: Bool) {
        DuoToolPrefs.setShown(id, shown)
        toolEpoch += 1
    }

    func moveTools(from source: IndexSet, to destination: Int) {
        DuoToolPrefs.reorder(from: source, to: destination)
        toolEpoch += 1
    }

    func releaseTransient() {
        releaseAwake()
        hideCleanCover()
        DuoKeyboardGuard.shared.stop()
        keyboardLocked = false
        PrivilegedEnergySession.shared.stop()
    }

    private func refreshToggles() {
        dockHidden = DuoDockAutoHide.read()
        widgetsHidden = widgetsAreHidden()
        stageManagerEnabled = (DuoPrefs.int("GloballyEnabled", domain: "com.apple.WindowManager") ?? 0) != 0
        desktopHidden = DuoPrefs.bool("CreateDesktop", domain: "com.apple.finder") == false
        hiddenFilesShown = DuoPrefs.bool("AppleShowAllFiles", domain: "com.apple.finder") == true
        showExtensions = DuoPrefs.globalBool("AppleShowAllExtensions") == true
        showPathbar = DuoPrefs.bool("ShowPathbar", domain: "com.apple.finder") == true
        darkMode = DuoPrefs.globalString("AppleInterfaceStyle") == "Dark"
        micMuted = DuoInputMute.read()
        applyCurrentWiFi(DuoCurrentWiFi.read(device: wifiDevice()))
        refreshDisks()
    }

    private func applyCurrentWiFi(_ reading: DuoCurrentWiFi.Reading) {
        currentSSID = reading.ssid
        currentSecured = reading.secured
        currentHotspotName = reading.isPersonalHotspot ? reading.ssid : nil
        nearbyHotspots = reading.nearbyHotspots
    }

    private func readEnergy(onBattery: Bool) {
        lastEnergyRead = Date()
        guard let result = try? Shell.run("/usr/bin/pmset", ["-g", "custom"]), result.succeeded else {
            energyMode = nil
            supportsHighPower = false
            return
        }
        let parsed = DuoEnergyReader.parse(result.stdout, onBattery: onBattery)
        energyMode = parsed.mode
        supportsHighPower = parsed.supportsHigh
    }

    private func loadKnownNetworks() {
        lastNetworkRead = Date()
        let device = wifiDevice()
        guard let result = try? Shell.run(
            "/usr/sbin/networksetup",
            ["-listpreferredwirelessnetworks", device]
        ), result.succeeded else {
            knownNetworks = []
            networksUnreadable = true
            return
        }
        let names = result.stdout
            .components(separatedBy: .newlines)
            .dropFirst()
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        knownNetworks = names
        networksUnreadable = false
        applyCurrentWiFi(DuoCurrentWiFi.read(device: device))
    }

    private func wifiDevice() -> String {
        if let wifiDeviceName { return wifiDeviceName }
        let fallback = "en0"
        guard let result = try? Shell.run("/usr/sbin/networksetup", ["-listallhardwareports"]),
              result.succeeded
        else {
            wifiDeviceName = fallback
            return fallback
        }
        var sawWiFi = false
        for line in result.stdout.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("Hardware Port:") {
                let port = trimmed.replacingOccurrences(of: "Hardware Port:", with: "")
                    .trimmingCharacters(in: .whitespaces)
                sawWiFi = port.caseInsensitiveCompare("Wi-Fi") == .orderedSame
                    || port.caseInsensitiveCompare("AirPort") == .orderedSame
                continue
            }
            if sawWiFi, trimmed.hasPrefix("Device:") {
                let device = trimmed.replacingOccurrences(of: "Device:", with: "")
                    .trimmingCharacters(in: .whitespaces)
                if !device.isEmpty {
                    wifiDeviceName = device
                    return device
                }
            }
        }
        wifiDeviceName = fallback
        return fallback
    }

    private func refreshDisks() {
        let keys: Set<URLResourceKey> = [
            .volumeIsEjectableKey, .volumeIsRemovableKey, .volumeIsInternalKey, .volumeNameKey
        ]
        let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: Array(keys),
            options: [.skipHiddenVolumes]
        ) ?? []
        disks = urls.compactMap { url in
            guard url.path != "/" else { return nil }
            let values = try? url.resourceValues(forKeys: keys)
            let ejectable = values?.volumeIsEjectable == true || values?.volumeIsRemovable == true
            guard ejectable, values?.volumeIsInternal != true else { return nil }
            let name = values?.volumeName ?? url.lastPathComponent
            return DuoDisk(name: name, path: url.path)
        }
    }

    private func scanDerivedData() {
        let url = DuoDerivedData.url
        DispatchQueue.global(qos: .utility).async {
            let bytes = DuoDerivedData.byteCount(at: url)
            Task { @MainActor in
                self.derivedBytes = bytes
                self.derivedReady = true
            }
        }
    }

    private func beginAwake(span: DuoAwakeSpan) {
        clearAwakeResources()
        var identifier: IOPMAssertionID = 0
        let timeout = span.seconds ?? 0
        let result = IOPMAssertionCreateWithDescription(
            kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
            "Mac小助手" as CFString,
            nil,
            nil,
            nil,
            timeout,
            kIOPMAssertionTimeoutActionTurnOff as CFString,
            &identifier
        )
        guard result == kIOReturnSuccess else {
            awakeDeadline = nil
            awake = false
            return
        }
        displayAssertion = identifier
        if let seconds = span.seconds {
            let deadline = Date().addingTimeInterval(seconds)
            awakeDeadline = deadline
            let timer = Timer(fire: deadline, interval: 0, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.releaseAwake()
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            awakeTimer = timer
        } else {
            awakeDeadline = nil
        }
        if preventLidSleep {
            installLidAssertion(timeout: timeout)
        }
        awake = true
    }

    private func installLidAssertion(timeout: TimeInterval) {
        clearLidAssertion()
        var identifier: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithDescription(
            kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
            "Mac小助手" as CFString,
            nil,
            nil,
            nil,
            timeout,
            kIOPMAssertionTimeoutActionTurnOff as CFString,
            &identifier
        )
        guard result == kIOReturnSuccess else { return }
        lidAssertion = identifier
    }

    private func clearLidAssertion() {
        if lidAssertion != 0 {
            IOPMAssertionRelease(lidAssertion)
            lidAssertion = 0
        }
    }

    private func clearAwakeResources() {
        awakeTimer?.invalidate()
        awakeTimer = nil
        if displayAssertion != 0 {
            IOPMAssertionRelease(displayAssertion)
            displayAssertion = 0
        }
        clearLidAssertion()
    }

    private func releaseAwake() {
        clearAwakeResources()
        awakeDeadline = nil
        awake = false
    }

    private func showCleanCover() {
        hideCleanCover()
        let hint = L("duo.shortcut.clean.hint")
        let windows: [NSWindow] = NSScreen.screens.map { screen in
            let window = DuoCleanWindow(screen: screen, hint: hint)
            window.onEscape = { [weak self] in
                self?.hideCleanCover()
            }
            window.orderFrontRegardless()
            return window
        }
        cleanWindows = windows
        windows.first?.makeKey()
        NSApp.activate(ignoringOtherApps: true)
        cleanMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard self?.screenClean == true || self?.cleanWindows.isEmpty == false else { return event }
            if event.keyCode == 53 {
                self?.hideCleanCover()
            }
            return nil
        }
        screenClean = true
    }

    private func hideCleanCover() {
        let monitor = cleanMonitor
        cleanMonitor = nil
        cleanWindows.forEach { $0.orderOut(nil) }
        cleanWindows = []
        screenClean = false
        if let monitor {
            DispatchQueue.main.async {
                NSEvent.removeMonitor(monitor)
            }
        }
    }

    private func loadDockSnapshot() -> DockSnapshot? {
        guard let data = UserDefaults.standard.data(forKey: dockSnapshotKey) else { return nil }
        return try? JSONDecoder().decode(DockSnapshot.self, from: data)
    }

    private struct DockSnapshot: Codable {
        var autohide: Bool?
        var delay: Double?
    }
}

enum DuoDerivedData {
    static var url: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Developer/Xcode/DerivedData", isDirectory: true)
    }

    static func byteCount(at url: URL) -> Int64? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else { return nil }
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            guard let values = try? file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                  values.isRegularFile == true
            else { continue }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }
}

enum DuoEnergyReader {
    struct Reading {
        var mode: DuoEnergyMode?
        var supportsHigh: Bool
    }

    static func parse(_ text: String, onBattery: Bool) -> Reading {
        let lines = text.components(separatedBy: .newlines)
        let supportsHigh = lines.contains { line in
            line.trimmingCharacters(in: .whitespaces).hasPrefix("powermode")
        }
        let section = onBattery ? "Battery Power:" : "AC Power:"
        var inside = false
        for line in lines {
            if isHeader(line) {
                inside = line.trimmingCharacters(in: .whitespaces) == section
                continue
            }
            guard inside else { continue }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let key: String
            if trimmed.hasPrefix("lowpowermode") {
                key = "lowpowermode"
            } else if trimmed.hasPrefix("powermode") {
                key = "powermode"
            } else {
                continue
            }
            let raw = trimmed.dropFirst(key.count).trimmingCharacters(in: .whitespaces)
            guard let value = Int(raw), let mode = DuoEnergyMode(rawValue: value) else {
                return Reading(mode: nil, supportsHigh: supportsHigh)
            }
            if mode == .high && !supportsHigh {
                return Reading(mode: nil, supportsHigh: false)
            }
            return Reading(mode: mode, supportsHigh: supportsHigh)
        }
        return Reading(mode: nil, supportsHigh: supportsHigh)
    }

    private static func isHeader(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.hasSuffix(":") && trimmed == line.trimmingCharacters(in: .newlines)
            && !line.hasPrefix(" ") && !line.hasPrefix("\t")
    }
}

enum DuoAwakeText {
    static func title(_ span: DuoAwakeSpan) -> String {
        switch span {
        case .forever:
            return L("duo.shortcut.awake.forever")
        case .fiveMinutes, .thirtyMinutes:
            return L("duo.shortcut.awake.minutes", span.rawValue)
        case .oneHour:
            return L("duo.shortcut.awake.oneHour")
        case .twoHours, .fiveHours, .eightHours:
            return L("duo.shortcut.awake.hours", span.rawValue / 60)
        }
    }

    static func clock(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.setLocalizedDateFormatFromTemplate("jm")
        return formatter.string(from: date)
    }
}

enum DuoQuickText {
    static func byteText(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

enum DuoSystemSettings {
    static func battery() {
        open([
            "x-apple.systempreferences:com.apple.Battery-Settings.extension",
            "x-apple.systempreferences:com.apple.preference.battery"
        ])
    }

    static func wifi() {
        open([
            "x-apple.systempreferences:com.apple.wifi-settings-extension",
            "x-apple.systempreferences:com.apple.preference.network"
        ])
    }

    static func bluetooth() {
        open([
            "x-apple.systempreferences:com.apple.BluetoothSettings",
            "x-apple.systempreferences:com.apple.preferences.Bluetooth",
            "x-apple.systempreferences:com.apple.BluetoothSettings-Settings.extension"
        ])
    }

    private static func open(_ urls: [String]) {
        for raw in urls {
            guard let url = URL(string: raw), NSWorkspace.shared.open(url) else { continue }
            return
        }
    }
}

private enum DuoInputMute {
    private static let scalarKey = "MacAssistant.DuoQuick.inputScalar"
    private static let elements: [AudioObjectPropertyElement] = [
        kAudioObjectPropertyElementMain, 1, 2
    ]

    static func read() -> Bool? {
        let device = defaultInput()
        guard device != 0 else { return nil }
        if hasMute(device), let muted = readMute(device) {
            return muted
        }
        if let scalar = readScalar(device) {
            return scalar <= 0.001
        }
        return nil
    }

    static func set(_ muted: Bool) -> Bool {
        let device = defaultInput()
        guard device != 0 else { return false }
        if hasMute(device) {
            return writeMute(device, muted)
        }
        if muted {
            if let scalar = readScalar(device), scalar > 0.001 {
                UserDefaults.standard.set(Double(scalar), forKey: scalarKey)
            }
            return writeScalar(device, 0)
        }
        let stored = UserDefaults.standard.object(forKey: scalarKey) as? Double ?? 0.5
        UserDefaults.standard.removeObject(forKey: scalarKey)
        return writeScalar(device, Float(min(1, max(0.05, stored))))
    }

    private static func defaultInput() -> AudioDeviceID {
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &device
        )
        return status == noErr ? device : 0
    }

    private static func hasMute(_ device: AudioDeviceID) -> Bool {
        elements.contains { element in
            var address = inputAddress(kAudioDevicePropertyMute, element: element)
            return AudioObjectHasProperty(device, &address)
        }
    }

    private static func readMute(_ device: AudioDeviceID) -> Bool? {
        for element in elements {
            var address = inputAddress(kAudioDevicePropertyMute, element: element)
            guard AudioObjectHasProperty(device, &address) else { continue }
            var value = UInt32(0)
            var size = UInt32(MemoryLayout<UInt32>.size)
            if AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr {
                return value != 0
            }
        }
        return nil
    }

    private static func writeMute(_ device: AudioDeviceID, _ muted: Bool) -> Bool {
        var wrote = false
        for element in elements {
            var address = inputAddress(kAudioDevicePropertyMute, element: element)
            guard AudioObjectHasProperty(device, &address) else { continue }
            var value: UInt32 = muted ? 1 : 0
            let size = UInt32(MemoryLayout<UInt32>.size)
            if AudioObjectSetPropertyData(device, &address, 0, nil, size, &value) == noErr {
                wrote = true
            }
        }
        return wrote
    }

    private static func readScalar(_ device: AudioDeviceID) -> Float? {
        for element in elements {
            var address = inputAddress(kAudioDevicePropertyVolumeScalar, element: element)
            guard AudioObjectHasProperty(device, &address) else { continue }
            var value = Float(0)
            var size = UInt32(MemoryLayout<Float>.size)
            if AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr {
                return value
            }
        }
        return nil
    }

    private static func writeScalar(_ device: AudioDeviceID, _ scalar: Float) -> Bool {
        var wrote = false
        for element in elements {
            var address = inputAddress(kAudioDevicePropertyVolumeScalar, element: element)
            guard AudioObjectHasProperty(device, &address) else { continue }
            var value = scalar
            let size = UInt32(MemoryLayout<Float>.size)
            if AudioObjectSetPropertyData(device, &address, 0, nil, size, &value) == noErr {
                wrote = true
            }
        }
        return wrote
    }

    private static func inputAddress(
        _ selector: AudioObjectPropertySelector,
        element: AudioObjectPropertyElement
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: element
        )
    }
}

private final class DuoCleanWindow: NSWindow {
    var onEscape: (() -> Void)?

    init(screen: NSScreen, hint: String) {
        super.init(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        setFrame(screen.frame, display: false)
        isOpaque = true
        backgroundColor = .black
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        let label = NSTextField(labelWithString: hint)
        label.textColor = NSColor.white.withAlphaComponent(0.85)
        label.font = .systemFont(ofSize: 16, weight: .medium)
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView(frame: screen.frame)
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.black.cgColor
        content.addSubview(label)
        contentView = content
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            label.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -48)
        ])
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            onEscape?()
            return
        }
    }

    override func mouseDown(with event: NSEvent) {}
}

enum DuoToolID: String, CaseIterable, Identifiable {
    case bluetooth
    case dock, widgets, stageManager, mic, desktop, awake, clean, keyboard, menuBar, hiddenFiles, emptyTrash, derived, eject
    case darkMode, extensions, pathbar, clipboard, sleep, restart, logout
    var id: String { rawValue }
}

enum DuoToolPrefs {
    private static let orderKey = "MacAssistant.DuoQuick.toolOrder"
    private static let hiddenKey = "MacAssistant.DuoQuick.toolHidden"
    private static let shownKey = "MacAssistant.DuoQuick.toolShown"
    /// 蓝牙是后加的。已经保存过勾选的人，第一次见到它时默认打开，之后以勾选为准。
    private static let bluetoothShownMigratedKey = "MacAssistant.DuoQuick.bluetoothIntroduced"
    /// 这次补工具之前就存在的项目。老的自定义记录里没有新工具，不能把它们算成已勾选。
    private static let legacyIDs: Set<String> = [
        "dock", "widgets", "mic", "desktop", "awake", "clean", "keyboard", "menuBar",
        "hiddenFiles", "emptyTrash", "derived", "eject"
    ]

    static func order() -> [DuoToolID] {
        let saved = UserDefaults.standard.stringArray(forKey: orderKey) ?? []
        var result: [DuoToolID] = []
        for raw in saved {
            if let id = DuoToolID(rawValue: raw), !result.contains(id) {
                result.append(id)
            }
        }
        let savedHadBluetooth = result.contains(.bluetooth)
        for id in preferredOrder where !result.contains(id) {
            result.append(id)
        }
        if !savedHadBluetooth, let index = result.firstIndex(of: .bluetooth), index != 0 {
            result.remove(at: index)
            result.insert(.bluetooth, at: 0)
        }
        return result
    }

    /// 默认按使用频率分组。已保存的顺序排在前面，新工具按这个顺序补到后面。
    static let preferredOrder: [DuoToolID] = [
        .bluetooth,
        .darkMode, .dock, .desktop, .widgets, .stageManager, .menuBar, .hiddenFiles, .extensions, .pathbar,
        .mic, .keyboard,
        .clean, .clipboard, .emptyTrash, .derived, .eject, .awake, .sleep, .logout, .restart
    ]

    /// 没改过自定义时，第一屏只留这几项，其余到「自定义」里再打开。
    private static let defaultVisible: Set<DuoToolID> = [.bluetooth, .clean, .keyboard, .awake]

    static func isShown(_ id: DuoToolID) -> Bool {
        currentShown().contains(id)
    }

    static func setShown(_ id: DuoToolID, _ shown: Bool) {
        var shownIDs = currentShown()
        if shown {
            shownIDs.insert(id)
        } else {
            shownIDs.remove(id)
        }
        UserDefaults.standard.set(shownIDs.map(\.rawValue).sorted(), forKey: shownKey)
    }

    private static func currentShown() -> Set<DuoToolID> {
        let migrated = UserDefaults.standard.bool(forKey: bluetoothShownMigratedKey)
        if let saved = UserDefaults.standard.stringArray(forKey: shownKey) {
            var ids = Set(saved.compactMap(DuoToolID.init(rawValue:)))
            if !migrated {
                ids.insert(.bluetooth)
                UserDefaults.standard.set(ids.map(\.rawValue).sorted(), forKey: shownKey)
                UserDefaults.standard.set(true, forKey: bluetoothShownMigratedKey)
            }
            return ids
        }
        if !migrated {
            UserDefaults.standard.set(true, forKey: bluetoothShownMigratedKey)
        }
        if let hidden = UserDefaults.standard.stringArray(forKey: hiddenKey) {
            let hiddenSet = Set(hidden)
            var ids = Set(legacyIDs.compactMap(DuoToolID.init(rawValue:)).filter { !hiddenSet.contains($0.rawValue) })
            ids.insert(.bluetooth)
            return ids
        }
        return defaultVisible
    }

    static func reorder(from source: IndexSet, to destination: Int) {
        var list = order()
        let moving = source.sorted().compactMap { list.indices.contains($0) ? list[$0] : nil }
        for index in source.sorted(by: >) where list.indices.contains(index) {
            list.remove(at: index)
        }
        let index = min(max(0, destination - source.filter { $0 < destination }.count), list.count)
        list.insert(contentsOf: moving, at: index)
        UserDefaults.standard.set(list.map(\.rawValue), forKey: orderKey)
    }
}

struct DuoNearbyHotspot: Identifiable, Equatable {
    var id: String { name }
    var name: String
    var bars: Int
    var band: String?
}

enum DuoCurrentWiFi {
    struct Reading: Equatable {
        var ssid: String?
        var secured: Bool
        var isPersonalHotspot: Bool
        var nearbyHotspots: [DuoNearbyHotspot]
    }

    static func read(device: String) -> Reading {
        let secured = currentSecurityIsClosed()
        let ssid = coreWLANSSID() ?? associatedSSID(device: device)
        let hotspotNames = personalHotspotNames()
        let nearby = nearbyHotspots(named: hotspotNames)
        return Reading(
            ssid: ssid,
            secured: secured,
            isPersonalHotspot: ssid.map { name in
                hotspotNames.contains { $0.caseInsensitiveCompare(name) == .orderedSame }
            } ?? false,
            nearbyHotspots: nearby
        )
    }

    /// 用上次扫描结果里、并且系统配置标成个人热点的网络。不发起新扫描，避免弹出定位权限。
    private static func nearbyHotspots(named hotspotNames: [String]) -> [DuoNearbyHotspot] {
        guard !hotspotNames.isEmpty,
              let cached = CWWiFiClient.shared().interface()?.cachedScanResults()
        else { return [] }
        var best: [String: DuoNearbyHotspot] = [:]
        for network in cached {
            guard let name = network.ssid,
                  hotspotNames.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame })
            else { continue }
            let rssi = network.rssiValue
            let candidate = DuoNearbyHotspot(
                name: name,
                bars: DuoStatusReader.bars(for: rssi),
                band: bandLabel(network.wlanChannel)
            )
            if let existing = best[name.lowercased()], existing.bars >= candidate.bars {
                continue
            }
            best[name.lowercased()] = candidate
        }
        return best.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private static func bandLabel(_ channel: CWChannel?) -> String? {
        switch channel?.channelBand {
        case .band2GHz: return "2.4G"
        case .band5GHz: return "5G"
        case .band6GHz: return "6G"
        default: return nil
        }
    }

    private static func personalHotspotNames() -> [String] {
        guard let profiles = CWWiFiClient.shared().interface()?.configuration()?.networkProfiles else {
            return []
        }
        var names: [String] = []
        for case let profile as CWNetworkProfile in profiles {
            guard profile.responds(to: Selector(("isPersonalHotspot"))),
                  (profile.value(forKey: "isPersonalHotspot") as? NSNumber)?.boolValue == true,
                  let name = profile.ssid, !name.isEmpty
            else { continue }
            names.append(name)
        }
        return names
    }

    private static func currentSecurityIsClosed() -> Bool {
        guard let iface = CWWiFiClient.shared().interface(), iface.powerOn(), iface.rssiValue() != 0 else {
            return false
        }
        let security = iface.security()
        return security != .none && security != .unknown
    }

    private static func associatedSSID(device: String) -> String? {
        guard let iface = CWWiFiClient.shared().interface(), iface.powerOn(), iface.rssiValue() != 0 else {
            return nil
        }
        let hits = scanHits(device: device)
        let channel = iface.wlanChannel()?.channelNumber
        let rssi = iface.rssiValue()
        let sameChannel = hits.filter { $0.channel == channel }
        let pool = sameChannel.isEmpty ? (hits.count == 1 ? hits : []) : sameChannel
        return pool.min { abs($0.rssi - rssi) < abs($1.rssi - rssi) }?.ssid
    }

    /// 没有定位权限时 `ssid()` 会立刻返回空，不会弹授权框。已经授权时用它。
    private static func coreWLANSSID() -> String? {
        guard let iface = CWWiFiClient.shared().interface() else { return nil }
        let name = iface.ssid()?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let name, !name.isEmpty else { return nil }
        return name
    }

    private struct Hit {
        var ssid: String
        var channel: Int?
        var rssi: Int
    }

    /// 当前关联被系统涂掉时，AirPort 状态里的扫描记录仍带着 SSID、信道和信号。
    private static func scanHits(device: String) -> [Hit] {
        guard let store = SCDynamicStoreCreate(nil, "MacAssistant.WiFi" as CFString, nil, nil) else { return [] }
        let key = "State:/Network/Interface/\(device)/AirPort" as CFString
        guard let info = SCDynamicStoreCopyValue(store, key) as? [String: Any],
              let blob = info["CachedScanRecord"] as? Data,
              let root = try? PropertyListSerialization.propertyList(from: blob, options: [], format: nil) as? [String: Any],
              let objects = root["$objects"] as? [Any]
        else { return [] }

        var hits: [Hit] = []
        for object in objects {
            guard let dict = object as? [String: Any],
                  let keys = dict["NS.keys"] as? [Any],
                  let values = dict["NS.objects"] as? [Any]
            else { continue }
            var map: [String: Any] = [:]
            for pair in zip(keys, values) {
                guard let key = resolve(pair.0, objects: objects) as? String,
                      let value = resolve(pair.1, objects: objects) else { continue }
                map[key] = value
            }
            let ssid = (map["SSID_STR"] as? String) ?? (map["SSID"] as? String)
            guard let ssid, !ssid.isEmpty else { continue }
            hits.append(Hit(
                ssid: ssid,
                channel: (map["CHANNEL"] as? NSNumber)?.intValue,
                rssi: (map["RSSI"] as? NSNumber)?.intValue ?? 0
            ))
        }
        return hits
    }

    private static func resolve(_ value: Any, objects: [Any], depth: Int = 0) -> Any? {
        if depth > 8 { return nil }
        if let index = uidValue(value), objects.indices.contains(index) {
            return resolve(objects[index], objects: objects, depth: depth + 1)
        }
        if let text = value as? String { return text }
        if let data = value as? Data {
            if let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !text.isEmpty,
               text.unicodeScalars.allSatisfy({ $0.value >= 32 && $0.value != 127 }) {
                return text
            }
            return data
        }
        if let number = value as? NSNumber { return number }
        return nil
    }

    private static func uidValue(_ value: Any) -> Int? {
        if let dict = value as? [String: Any], let index = dict["CF$UID"] as? Int { return index }
        let text = String(describing: value)
        guard text.contains("UID"), let range = text.range(of: "value = ") else { return nil }
        let digits = text[range.upperBound...].prefix { $0.isNumber }
        return Int(digits)
    }
}

enum DuoMenuBarAutoHide {
    static func read() -> Bool {
        guard let script = NSAppleScript(source: "tell application \"System Events\" to get autohide menu bar of dock preferences") else {
            return false
        }
        var error: NSDictionary?
        let descriptor = script.executeAndReturnError(&error)
        return error == nil && descriptor.booleanValue
    }

    static func write(_ hidden: Bool) -> Bool {
        let value = hidden ? "true" : "false"
        let script = NSAppleScript(source: "tell application \"System Events\" to set autohide menu bar of dock preferences to \(value)")
        var error: NSDictionary?
        script?.executeAndReturnError(&error)
        return error == nil
    }
}

enum DuoDockFailure: Equatable {
    /// 系统事件拒绝了自动化。
    case denied
    /// 自动隐藏没有真正改变。
    case failed
}

enum DuoDockAutoHide {
    private typealias Getter = @convention(c) () -> Bool
    private typealias Setter = @convention(c) (Bool) -> Void

    /// Dock 自己的自动隐藏接口。系统事件在菜单栏面板的主线程上经常静默失败
    ///（权限框被挡住，或 AppleEvent 超时），错误以前又被丢掉，开关就像没点到。
    /// 这个调用不结束 Dock 进程，也不会整屏白闪。
    private static let getter: Getter? = symbol("CoreDockGetAutoHideEnabled")
    private static let setter: Setter? = symbol("CoreDockSetAutoHideEnabled")

    private static func symbol<T>(_ name: String) -> T? {
        guard let library = dlopen(
            "/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices",
            RTLD_LAZY
        ), let pointer = dlsym(library, name) else { return nil }
        return unsafeBitCast(pointer, to: T.self)
    }

    static func read() -> Bool {
        if let getter { return getter() }
        CFPreferencesAppSynchronize("com.apple.dock" as CFString)
        if let stored = DuoPrefs.bool("autohide", domain: "com.apple.dock") {
            return stored
        }
        return scriptRead() ?? false
    }

    static func write(_ hidden: Bool) -> DuoDockFailure? {
        if let setter {
            setter(hidden)
            if read() == hidden { return nil }
        }
        switch scriptWrite(hidden) {
        case .ok where read() == hidden:
            return nil
        case .denied:
            return .denied
        case .ok, .failed:
            return .failed
        }
    }

    private static func scriptRead() -> Bool? {
        guard let script = NSAppleScript(
            source: "tell application \"System Events\" to get autohide of dock preferences"
        ) else { return nil }
        var error: NSDictionary?
        let descriptor = script.executeAndReturnError(&error)
        guard error == nil else { return nil }
        return descriptor.booleanValue
    }

    private static func scriptWrite(_ hidden: Bool) -> ScriptResult {
        let value = hidden ? "true" : "false"
        guard let script = NSAppleScript(
            source: "tell application \"System Events\" to set the autohide of the dock preferences to \(value)"
        ) else { return .failed }
        var error: NSDictionary?
        script.executeAndReturnError(&error)
        guard let error else { return .ok }
        let number = (error[NSAppleScript.errorNumber] as? NSNumber)?.intValue
        return number == -1743 ? .denied : .failed
    }

    private enum ScriptResult {
        case ok
        case denied
        case failed
    }
}

enum DuoSystemAppearance {
    static var isDark: Bool {
        guard let script = NSAppleScript(
            source: "tell application \"System Events\" to tell appearance preferences to get dark mode"
        ) else { return false }
        var error: NSDictionary?
        let descriptor = script.executeAndReturnError(&error)
        return error == nil && descriptor.booleanValue
    }

    static func setDark(_ on: Bool) -> Bool {
        let value = on ? "true" : "false"
        guard let script = NSAppleScript(source: """
        tell application "System Events"
            tell appearance preferences
                set dark mode to \(value)
            end tell
        end tell
        """) else { return false }
        var error: NSDictionary?
        script.executeAndReturnError(&error)
        return error == nil
    }
}

enum DuoSession {
    static func sleep() -> Bool {
        (try? Shell.run("/usr/bin/pmset", ["sleepnow"]))?.succeeded == true
    }

    /// 重新启动这台 Mac。事件直接发给系统进程（loginwindow）。
    /// System Events 的 `restart` 会按保存状态把当前软件退出再打开，电脑并不重启。
    static func restart() -> Bool {
        sendToSystem(AEEventID(kAERestart))
    }

    static func perform(_ command: String) -> Bool {
        guard command == "log out" else { return false }
        let script = NSAppleScript(source: "tell application \"System Events\" to \(command)")
        var error: NSDictionary?
        script?.executeAndReturnError(&error)
        return error == nil
    }

    private static func sendToSystem(_ eventID: AEEventID) -> Bool {
        var psn = ProcessSerialNumber(highLongOfPSN: 0, lowLongOfPSN: UInt32(kSystemProcess))
        var target = AEAddressDesc()
        guard AECreateDesc(
            DescType(typeProcessSerialNumber),
            &psn,
            MemoryLayout<ProcessSerialNumber>.size,
            &target
        ) == noErr else { return false }
        defer { AEDisposeDesc(&target) }

        var event = AppleEvent()
        guard AECreateAppleEvent(
            AEEventClass(kCoreEventClass),
            eventID,
            &target,
            AEReturnID(kAutoGenerateReturnID),
            AETransactionID(kAnyTransactionID),
            &event
        ) == noErr else { return false }
        defer { AEDisposeDesc(&event) }

        var reply = AppleEvent()
        let sent = AESendMessage(&event, &reply, AESendMode(kAENoReply), kAEDefaultTimeout)
        if sent == noErr {
            AEDisposeDesc(&reply)
        }
        return sent == noErr
    }
}

enum DuoTrash {
    static func empty() -> Bool {
        let script = NSAppleScript(source: "tell application \"Finder\" to empty trash")
        var error: NSDictionary?
        script?.executeAndReturnError(&error)
        return error == nil
    }
}

final class DuoKeyboardGuard {
    static let shared = DuoKeyboardGuard()
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var onEscape: (() -> Void)?

    func start(onEscape: @escaping () -> Void) -> Bool {
        stop()
        self.onEscape = onEscape
        let mask = (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, _ in
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    if let tap = DuoKeyboardGuard.shared.tap {
                        CGEvent.tapEnable(tap: tap, enable: true)
                    }
                    return Unmanaged.passUnretained(event)
                }
                if type == .keyDown, event.getIntegerValueField(.keyboardEventKeycode) == 53 {
                    DispatchQueue.main.async {
                        DuoKeyboardGuard.shared.onEscape?()
                    }
                }
                return nil
            },
            userInfo: nil
        ) else {
            self.onEscape = nil
            return false
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.source = source
        return true
    }

    func stop() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        tap = nil
        source = nil
        onEscape = nil
    }
}
