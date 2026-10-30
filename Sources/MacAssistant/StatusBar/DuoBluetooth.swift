import Foundation
import IOBluetooth
import IOKit

/// `IOBluetoothPreference*` 在框架里导出，但没有写进公开头文件。菜单栏开关蓝牙用的就是这对函数。
@_silgen_name("IOBluetoothPreferenceGetControllerPowerState")
private func duoBluetoothPowerState() -> Int32

@_silgen_name("IOBluetoothPreferenceSetControllerPowerState")
private func duoBluetoothSetPowerState(_ state: Int32)

struct DuoBluetoothDevice: Identifiable, Equatable {
    var id: String { address }
    var address: String
    var name: String
    var connected: Bool
    var connecting: Bool
    var symbol: String
}

/// 菜单栏里的蓝牙模块：开关、已配对设备、连接和断开。
@MainActor
final class DuoBluetoothModel: ObservableObject {
    @Published private(set) var poweredOn: Bool?
    @Published private(set) var devices: [DuoBluetoothDevice] = []

    private let bridge = DuoBluetoothBridge()
    private var connectNote: IOBluetoothUserNotification?
    private var powerNotes: [NSObjectProtocol] = []
    private var connectingAddress: String?
    private var pendingAddress: String?
    private var connectGeneration = 0

    init() {
        bridge.onComplete = { [weak self] address, _ in
            Task { @MainActor in
                self?.finishConnect(address)
            }
        }
        bridge.onAnyConnect = { [weak self] in
            Task { @MainActor in
                self?.refresh()
            }
        }
        connectNote = IOBluetoothDevice.register(
            forConnectNotifications: bridge,
            selector: #selector(DuoBluetoothBridge.bluetoothDeviceConnected(_:device:))
        )
        let center = NotificationCenter.default
        let names: [Notification.Name] = [
            .IOBluetoothHostControllerPoweredOn,
            .IOBluetoothHostControllerPoweredOff
        ]
        for name in names {
            powerNotes.append(
                center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    Task { @MainActor in
                        self?.refresh()
                    }
                }
            )
        }
        refresh()
    }

    deinit {
        connectNote?.unregister()
        for note in powerNotes {
            NotificationCenter.default.removeObserver(note)
        }
    }

    /// 正在连接的那一台，或唯一已连接的设备。多台同时连着时标题改回「蓝牙」。
    var featured: DuoBluetoothDevice? {
        if let connectingAddress, let match = devices.first(where: { $0.address == connectingAddress }) {
            return match
        }
        let connected = devices.filter(\.connected)
        return connected.count == 1 ? connected[0] : nil
    }

    func refresh() {
        readPower()
        reloadDevices()
    }

    func setPower(_ on: Bool) {
        guard IOBluetoothHostController.default() != nil else { return }
        duoBluetoothSetPowerState(on ? 1 : 0)
        poweredOn = on
        if !on {
            connectGeneration += 1
            connectingAddress = nil
            pendingAddress = nil
        }
        reloadDevices()
        guard on, pendingAddress != nil else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            Task { @MainActor in
                self?.resumePendingConnect()
            }
        }
    }

    func activate(_ address: String) {
        guard let device = IOBluetoothDevice(addressString: address) else { return }
        if device.isConnected() {
            connectGeneration += 1
            connectingAddress = nil
            _ = device.closeConnection()
            refresh()
            return
        }
        if poweredOn != true {
            pendingAddress = address
            setPower(true)
            return
        }
        beginConnect(device)
    }

    private func readPower() {
        guard let controller = IOBluetoothHostController.default() else {
            poweredOn = nil
            return
        }
        switch controller.powerState {
        case kBluetoothHCIPowerStateON:
            poweredOn = true
        case kBluetoothHCIPowerStateOFF:
            poweredOn = false
        default:
            poweredOn = nil
        }
    }

    private func resumePendingConnect() {
        readPower()
        guard poweredOn == true, let pending = pendingAddress else { return }
        pendingAddress = nil
        guard let device = IOBluetoothDevice(addressString: pending), !device.isConnected() else {
            reloadDevices()
            return
        }
        beginConnect(device)
    }

    private func beginConnect(_ device: IOBluetoothDevice) {
        guard let address = device.addressString, !address.isEmpty else { return }
        if connectingAddress == address { return }
        connectGeneration += 1
        let generation = connectGeneration
        connectingAddress = address
        reloadDevices()
        let timeout = BluetoothHCIPageTimeout(0x4000)
        let started = device.openConnection(bridge, withPageTimeout: timeout, authenticationRequired: false) == kIOReturnSuccess
        if !started {
            connectingAddress = nil
            reloadDevices()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 12) { [weak self] in
            Task { @MainActor in
                guard let self, self.connectGeneration == generation else { return }
                self.connectingAddress = nil
                self.reloadDevices()
            }
        }
    }

    private func finishConnect(_ address: String) {
        if connectingAddress == address {
            connectGeneration += 1
            connectingAddress = nil
        }
        refresh()
    }

    private func reloadDevices() {
        let paired = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
        var ranked: [(DuoBluetoothDevice, Bool, Date)] = []
        ranked.reserveCapacity(paired.count)
        for device in paired {
            guard let address = device.addressString, !address.isEmpty else { continue }
            let name = device.nameOrAddress ?? address
            let connected = device.isConnected()
            if connected, connectingAddress == address {
                connectingAddress = nil
            }
            let item = DuoBluetoothDevice(
                address: address,
                name: name,
                connected: connected,
                connecting: !connected && address == connectingAddress,
                symbol: DuoBluetoothSymbol.pick(
                    name: name,
                    major: device.deviceClassMajor,
                    minor: device.deviceClassMinor
                )
            )
            ranked.append((item, device.isFavorite(), device.recentAccessDate() ?? .distantPast))
        }
        ranked.sort { lhs, rhs in
            if lhs.0.connecting != rhs.0.connecting { return lhs.0.connecting }
            if lhs.0.connected != rhs.0.connected { return lhs.0.connected }
            if lhs.1 != rhs.1 { return lhs.1 }
            return lhs.2 > rhs.2
        }
        let connected = ranked.filter(\.0.connected)
        let rest = ranked.filter { !$0.0.connected }
        let shown = connected + rest.prefix(max(0, 8 - connected.count))
        let next = shown.map(\.0)
        if next != devices {
            devices = next
        }
    }
}

private enum DuoBluetoothSymbol {
    static func pick(name: String, major: BluetoothDeviceClassMajor, minor: BluetoothDeviceClassMinor) -> String {
        let folded = name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        if folded.contains("airpods pro") { return "airpodspro" }
        if folded.contains("airpods max") { return "airpodsmax" }
        if folded.contains("airpods") { return "airpods" }
        if folded.contains("beats") { return "beats.headphones" }
        if folded.contains("keyboard") || name.contains("键盘") || name.contains("鍵盤") { return "keyboard" }
        if folded.contains("trackpad") || name.contains("触控板") || name.contains("觸控板") { return "rectangle.and.hand.point.up.left" }
        if folded.contains("mouse") || name.contains("鼠标") || name.contains("滑鼠") { return "computermouse" }
        if major == kBluetoothDeviceClassMajorAudio { return "headphones" }
        if major == kBluetoothDeviceClassMajorPhone { return "iphone" }
        if major == kBluetoothDeviceClassMajorComputer { return "laptopcomputer" }
        if major == kBluetoothDeviceClassMajorPeripheral {
            let kind = minor & 0x30
            if kind == kBluetoothDeviceClassMinorPeripheral1Keyboard { return "keyboard" }
            if kind == kBluetoothDeviceClassMinorPeripheral1Pointing { return "computermouse" }
            if kind == kBluetoothDeviceClassMinorPeripheral1Combo { return "keyboard" }
        }
        return "bluetooth"
    }
}

private final class DuoBluetoothBridge: NSObject {
    var onComplete: ((String, Bool) -> Void)?
    var onAnyConnect: (() -> Void)?

    @objc(connectionComplete:status:)
    func connectionComplete(_ device: IOBluetoothDevice?, status: Int32) {
        let address = device?.addressString ?? ""
        let ok = status == kIOReturnSuccess || device?.isConnected() == true
        onComplete?(address, ok)
    }

    @objc(bluetoothDeviceConnected:device:)
    func bluetoothDeviceConnected(_ notification: IOBluetoothUserNotification?, device: IOBluetoothDevice?) {
        _ = notification
        _ = device
        onAnyConnect?()
    }
}
