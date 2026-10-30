import AppKit
import Combine
import MacAssistantKit
import SwiftUI

@MainActor
final class DuoStatusBarController: NSObject, ObservableObject {
    static let shared = DuoStatusBarController()

    @Published private(set) var status: DuoMenuStatus {
        didSet { renderIconIfNeeded() }
    }

    private(set) var isEnabled: Bool
    var openMainWindow: (() -> Void)?

    private var statusItem: NSStatusItem?
    private let pathMonitor = DuoPathMonitor()
    private var pathFlags = DuoPathFlags.unknown
    private var timer: Timer?
    private var chargeWatch: Timer?
    private var chargeWatchDeadline: Date?
    private var chargeWatchBatteryStreak = 0
    private var powerSource: CFRunLoopSource?
    private var localScrollMonitor: Any?
    private var globalScrollMonitor: Any?
    private var renderedKey = ""
    private var monitoring = false
    let actions = DuoQuickActions()
    let bluetooth = DuoBluetoothModel()
    private lazy var panel = DuoStatusPanelController(model: self)

    private override init() {
        let stored = UserDefaults.standard.object(forKey: Self.enabledKey)
        status = .unknown
        isEnabled = stored == nil ? true : UserDefaults.standard.bool(forKey: Self.enabledKey)
        super.init()
    }

    func install() {
        startMonitoring()
        if isEnabled {
            DuoMenuBarItems.hide()
        } else {
            DuoMenuBarItems.restore()
        }
        applyStatusItem()
        refresh()
    }

    func prepareForTermination() {
        panel.close()
        actions.releaseTransient()
        DuoMenuBarItems.restoreForQuit()
    }

    func setEnabled(_ enabled: Bool) {
        if enabled != isEnabled {
            objectWillChange.send()
            isEnabled = enabled
            UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
        }
        if !enabled {
            panel.close()
            DuoMenuBarItems.restore()
            applyStatusItem()
            renderIcon(force: true)
            return
        }
        DuoMenuBarItems.hide()
        applyStatusItem()
        renderIcon(force: true)
    }

    func refresh() {
        let next = DuoStatusReader.snapshot(path: pathFlags)
        if next != status {
            status = next
        } else {
            renderIconIfNeeded()
        }
        actions.refreshPassive(onBattery: next.powerSource == .battery)
        if isPanelShown {
            bluetooth.refresh()
        }
    }

    var isPanelShown: Bool { panel.isShown }

    func setWiFiPower(_ on: Bool) {
        guard DuoStatusReader.setWiFiPower(on) else { return }
        refresh()
    }

    func closePanel() {
        panel.close()
    }

    func showDestination(_ destination: AppDestination) {
        panel.close()
        DuoNavigation.pending = destination
        showMainWindow()
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .duoOpenDestination, object: nil)
        }
    }

    func setVolume(_ value: Double) {
        let clamped = min(1, max(0, value))
        DuoSystemAudio.setScalar(clamped)
        if clamped == 0 {
            DuoSystemAudio.setMuted(true)
        }
        var next = status
        next.volumeScalar = clamped
        next.isMuted = clamped == 0
        status = next
    }

    func toggleMuted() {
        let muted = !status.isMuted
        DuoSystemAudio.setMuted(muted)
        var next = status
        next.isMuted = muted
        status = next
    }

    func showMainWindow() {
        panel.close()
        NSApp.setActivationPolicy(.regular)
        if let window = mainWindow() {
            if window.isMiniaturized {
                window.deminiaturize(nil)
            }
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        openMainWindow?()
        NSApp.activate(ignoringOtherApps: true)
    }

    func closePopover() {
        panel.close()
    }

    private func startMonitoring() {
        guard !monitoring else { return }
        monitoring = true

        pathMonitor.onChange = { [weak self] flags in
            DispatchQueue.main.async {
                guard let self else { return }
                self.pathFlags = flags
                self.refresh()
            }
        }
        pathMonitor.start()

        let context = Unmanaged.passUnretained(self).toOpaque()
        if let source = IOPSNotificationCreateRunLoopSource({ raw in
            guard let raw else { return }
            let controller = Unmanaged<DuoStatusBarController>.fromOpaque(raw).takeUnretainedValue()
            let apply = { controller.notePowerChanged() }
            if Thread.isMainThread {
                MainActor.assumeIsolated(apply)
            } else {
                DispatchQueue.main.async(execute: apply)
            }
        }, context)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            powerSource = source
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(systemHint),
            name: .NSProcessInfoPowerStateDidChange,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(systemHint),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(systemHint),
            name: Notification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil
        )

        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refresh()
            }
        }
    }

    /// 电源通知一到就重画。若这时还读不到正在充电，短轮询最多 8 秒，稳了就回到 2 秒定时器。
    private func notePowerChanged() {
        refresh()
        beginChargeWatch()
    }

    private func beginChargeWatch() {
        chargeWatch?.invalidate()
        chargeWatchDeadline = Date().addingTimeInterval(8)
        chargeWatchBatteryStreak = status.powerSource == .battery ? 1 : 0
        guard !chargeWatchIsSettled() else {
            chargeWatch = nil
            return
        }
        let timer = Timer(timeInterval: 0.4, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else {
                    timer.invalidate()
                    return
                }
                self.refresh()
                if self.status.powerSource == .battery {
                    self.chargeWatchBatteryStreak += 1
                } else {
                    self.chargeWatchBatteryStreak = 0
                }
                if self.chargeWatchIsSettled() {
                    self.endChargeWatch()
                }
            }
        }
        chargeWatch = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func chargeWatchIsSettled() -> Bool {
        if let chargeWatchDeadline, Date() >= chargeWatchDeadline { return true }
        switch status.powerSource {
        case .battery:
            return chargeWatchBatteryStreak >= 2
        case .none:
            return true
        case .adapter:
            return status.isCharging || status.batteryPercent >= 100
        }
    }

    private func endChargeWatch() {
        chargeWatch?.invalidate()
        chargeWatch = nil
        chargeWatchDeadline = nil
    }

    @objc private func systemHint() {
        renderedKey = ""
        refresh()
    }

    private func applyStatusItem() {
        if isEnabled {
            createStatusItem()
        } else {
            removeStatusItem()
        }
    }

    private func createStatusItem() {
        UserDefaults.standard.set(true, forKey: "NSStatusItem Visible \(Self.autosaveName)")
        if UserDefaults.standard.object(forKey: "NSStatusItem Preferred Position \(Self.autosaveName)") == nil {
            // 没有位置时系统会把它排进刘海空隙，菜单栏上看不到。160 落在控制中心附近的可见区。
            UserDefaults.standard.set(160.0, forKey: "NSStatusItem Preferred Position \(Self.autosaveName)")
        }
        if let statusItem {
            statusItem.isVisible = true
            return
        }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = Self.autosaveName
        item.behavior = .removalAllowed
        item.isVisible = true
        let button = item.button
        button?.imagePosition = .imageOnly
        button?.imageScaling = .scaleNone
        button?.target = self
        button?.action = #selector(handleClick(_:))
        button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem = item
        installScrollMonitors()
        renderedKey = ""
    }

    private func removeStatusItem() {
        removeScrollMonitors()
        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
        }
        statusItem = nil
        renderedKey = ""
    }

    private func renderIconIfNeeded() {
        renderIcon(force: false)
    }

    private func renderIcon(force: Bool) {
        guard let button = statusItem?.button else { return }
        let appearance = button.effectiveAppearance
        let scale = button.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let key = status.iconKey + "|\(scale)|\(appearanceName(appearance))|\(LocalizationSettings.current.rawValue)"
        if !force, key == renderedKey, button.image != nil { return }
        renderedKey = key
        let tip = DuoStatusText.tooltip(status)
        button.image = DuoStatusIcon.image(
            status: status,
            pointSize: DuoStatusIcon.menuPointSize,
            appearance: appearance,
            scale: scale
        )
        button.toolTip = tip
        button.setAccessibilityLabel(tip)
    }

    private func appearanceName(_ appearance: NSAppearance) -> String {
        appearance.bestMatch(from: [.aqua, .darkAqua])?.rawValue ?? appearance.name.rawValue
    }

    @objc private func handleClick(_ sender: Any?) {
        let event = NSApp.currentEvent
        let right = event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true
        if right {
            showMenu()
        } else {
            togglePopover()
        }
    }

    private func togglePopover() {
        guard let button = statusItem?.button else { return }
        panel.toggle(from: button)
    }

    private func showMenu() {
        panel.close()
        guard let button = statusItem?.button else { return }
        let menu = makeMenu()
        if let event = NSApp.currentEvent {
            NSMenu.popUpContextMenu(menu, with: event, for: button)
        } else {
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height), in: button)
        }
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(item(L("duo.openApp"), action: #selector(openAppFromMenu)))
        menu.addItem(item(L("duo.hideIcon"), action: #selector(hideIconFromMenu)))
        menu.addItem(.separator())
        menu.addItem(item(L("duo.quit"), action: #selector(quitFromMenu)))
        return menu
    }

    private func item(_ title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func openAppFromMenu() {
        showMainWindow()
    }

    @objc private func hideIconFromMenu() {
        setEnabled(false)
        if mainWindow()?.isVisible != true {
            showMainWindow()
        }
    }

    @objc private func quitFromMenu() {
        NSApp.terminate(nil)
    }

    private func mainWindow() -> NSWindow? {
        NSApp.windows.first { window in
            window.level == .normal && window.canBecomeMain
        }
    }

    private func installScrollMonitors() {
        guard localScrollMonitor == nil else { return }
        localScrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, self.pointerIsOverStatusItem() else { return event }
            self.adjustVolume(with: event)
            return nil
        }
        globalScrollMonitor = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, self.pointerIsOverStatusItem() else { return }
            self.adjustVolume(with: event)
        }
    }

    private func removeScrollMonitors() {
        if let localScrollMonitor {
            NSEvent.removeMonitor(localScrollMonitor)
        }
        if let globalScrollMonitor {
            NSEvent.removeMonitor(globalScrollMonitor)
        }
        localScrollMonitor = nil
        globalScrollMonitor = nil
    }

    private func pointerIsOverStatusItem() -> Bool {
        guard let button = statusItem?.button, let window = button.window else { return false }
        let frame = window.convertToScreen(button.convert(button.bounds, to: nil))
        return frame.contains(NSEvent.mouseLocation)
    }

    private func adjustVolume(with event: NSEvent) {
        guard status.volumeScalar != nil else { return }
        let delta: Double
        if event.hasPreciseScrollingDeltas {
            delta = min(0.08, max(-0.08, Double(event.scrollingDeltaY) / 280))
        } else {
            delta = event.scrollingDeltaY < 0 ? -0.06 : 0.06
        }
        guard delta != 0 else { return }
        let current = status.isMuted ? 0 : (status.volumeScalar ?? 0)
        setVolume(current + delta)
    }

    private static let enabledKey = "MacAssistant.DuoStatusBar.enabled"
    static let autosaveName = "MacAssistantDuoStatus"
}

enum DuoStatusText {
    static func tooltip(_ status: DuoMenuStatus) -> String {
        L("duo.tooltip", "\(status.batteryPercent)%", link(status.link), volume(status))
    }

    static func batteryTitle(_ status: DuoMenuStatus) -> String {
        L("duo.battery.percent", status.batteryPercent)
    }

    static func powerSource(_ status: DuoMenuStatus) -> String {
        switch status.powerSource {
        case .battery: return L("duo.power.battery")
        case .adapter: return L("duo.power.adapter")
        case .none: return L("duo.power.none")
        }
    }

    /// 主面板上的剩余时间，不重复电源来源。
    static func batteryTime(_ status: DuoMenuStatus) -> String? {
        switch status.batteryTone {
        case .absent:
            return nil
        case .charging:
            guard status.isCharging else { return L("duo.onPower") }
            guard let minutes = status.minutesToFull else { return L("duo.charging") }
            return L("duo.time.full", duration(minutes))
        case .critical, .lowPower, .normal:
            guard status.powerSource != .adapter, let minutes = status.minutesToEmpty else { return nil }
            return L("duo.time.left", duration(minutes))
        }
    }

    static func batterySubtitle(_ status: DuoMenuStatus) -> String {
        switch status.batteryTone {
        case .absent:
            return L("duo.noBattery")
        case .charging:
            guard status.isCharging else { return L("duo.onPower") }
            guard let minutes = status.minutesToFull else { return L("duo.charging") }
            return L("duo.charging.time", duration(minutes))
        case .critical:
            return remaining(L("duo.lowBattery"), minutes: status.minutesToEmpty, key: "duo.remaining")
        case .lowPower:
            return remaining(L("duo.lowPower"), minutes: status.minutesToEmpty, key: "duo.remaining")
        case .normal:
            if status.powerSource == .adapter {
                return L("duo.onPower")
            }
            return remaining(L("duo.onBattery"), minutes: status.minutesToEmpty, key: "duo.remaining")
        }
    }

    static func link(_ link: DuoLink) -> String {
        switch link {
        case .wifi(let bars, true):
            return L("duo.wifi.connected", bars)
        case .wifi(let bars, false):
            return L("duo.wifi.noInternet", bars)
        case .wifiOff:
            return L("duo.wifi.off")
        case .wifiIdle:
            return L("duo.wifi.idle")
        case .ethernet:
            return L("duo.wifi.ethernet")
        case .offline:
            return L("duo.wifi.offline")
        }
    }

    static func volume(_ status: DuoMenuStatus) -> String {
        if status.volumeScalar == nil {
            return L("duo.volume.unavailable")
        }
        if status.isMuted {
            return L("duo.volume.muted")
        }
        let percent = Int(((status.volumeScalar ?? 0) * 100).rounded())
        if let name = status.outputName, !name.isEmpty {
            return L("duo.volume.named", percent, name)
        }
        return L("duo.volume.level", percent)
    }

    private static func remaining(_ title: String, minutes: Int?, key: String) -> String {
        guard let minutes else { return title }
        return L(key, title, duration(minutes))
    }

    private static func duration(_ minutes: Int) -> String {
        let hours = minutes / 60
        let remain = minutes % 60
        if hours > 0 {
            return L("duo.time.hm", hours, remain)
        }
        return L("duo.time.m", remain)
    }
}
