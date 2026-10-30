import CoreAudio
import CoreWLAN
import Foundation
import IOKit.ps
import Network

enum DuoBatteryTone: Equatable {
    case normal
    case charging
    case lowPower
    case critical
    case absent
}

enum DuoPowerSource: Equatable {
    case battery
    case adapter
    case none
}

enum DuoLink: Equatable {
    case wifi(bars: Int, reachable: Bool)
    case wifiOff
    case wifiIdle
    case ethernet
    case offline
}

struct DuoPathFlags: Equatable {
    var known = false
    var satisfied = false
    var wifi = false
    var wired = false

    static let unknown = DuoPathFlags()
}

struct DuoMenuStatus: Equatable {
    var batteryPercent: Int
    var batteryTone: DuoBatteryTone
    var powerSource: DuoPowerSource
    /// 系统 `IsCharging`。刚插上电源时它会比 `PowerSourceState` 晚几秒，图标不要等它。
    var isCharging: Bool
    var minutesToFull: Int?
    var minutesToEmpty: Int?
    var link: DuoLink
    var wifiPowerOn: Bool?
    var volumeScalar: Double?
    var isMuted: Bool
    var outputName: String?

    static let unknown = DuoMenuStatus(
        batteryPercent: 100,
        batteryTone: .absent,
        powerSource: .none,
        isCharging: false,
        minutesToFull: nil,
        minutesToEmpty: nil,
        link: .offline,
        wifiPowerOn: nil,
        volumeScalar: nil,
        isMuted: false,
        outputName: nil
    )

    var volumeBars: Int {
        guard let volumeScalar, !isMuted, volumeScalar > 0 else { return 0 }
        if volumeScalar <= 0.25 { return 1 }
        if volumeScalar <= 0.50 { return 2 }
        if volumeScalar <= 0.75 { return 3 }
        return 4
    }

    var iconKey: String {
        "\(batteryPercent)|\(batteryTone)|\(link)|\(volumeBars)"
    }
}

enum DuoStatusReader {
    static func snapshot(path: DuoPathFlags) -> DuoMenuStatus {
        let battery = readBattery()
        let audio = DuoSystemAudio.read()
        let wifi = DuoWiFi.read()
        return DuoMenuStatus(
            batteryPercent: battery.percent,
            batteryTone: battery.tone,
            powerSource: battery.power,
            isCharging: battery.isCharging,
            minutesToFull: battery.minutesToFull,
            minutesToEmpty: battery.minutesToEmpty,
            link: readLink(wifi: wifi.state, path: path),
            wifiPowerOn: wifi.powerOn,
            volumeScalar: audio.scalar,
            isMuted: audio.muted,
            outputName: audio.name
        )
    }

    private struct BatteryReading {
        var percent: Int
        var tone: DuoBatteryTone
        var power: DuoPowerSource
        var isCharging: Bool
        var minutesToFull: Int?
        var minutesToEmpty: Int?
    }

    private static func readBattery() -> BatteryReading {
        let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        guard let raw = copyBattery() else {
            return BatteryReading(
                percent: 100,
                tone: .absent,
                power: .none,
                isCharging: false,
                minutesToFull: nil,
                minutesToEmpty: nil
            )
        }

        // 插上电源时 PowerSourceState 先变成 AC Power，IsCharging 往往要晚几秒。
        // 图标按「已经不是电池供电」立刻画绿色和闪电；拔电后 onBattery 马上为真，闪电同时去掉。
        let tone: DuoBatteryTone
        if raw.onAdapter {
            tone = .charging
        } else if raw.onBattery, raw.percent < 20 {
            tone = .critical
        } else if lowPower {
            tone = .lowPower
        } else {
            tone = .normal
        }

        let power: DuoPowerSource
        if raw.onBattery {
            power = .battery
        } else if raw.onAdapter {
            power = .adapter
        } else {
            power = .none
        }

        return BatteryReading(
            percent: raw.percent,
            tone: tone,
            power: power,
            isCharging: raw.charging,
            minutesToFull: raw.charging ? raw.minutesToFull : nil,
            minutesToEmpty: raw.onBattery ? raw.minutesToEmpty : nil
        )
    }

    private struct RawBattery {
        var percent: Int
        var charging: Bool
        var onBattery: Bool
        var onAdapter: Bool
        var minutesToFull: Int?
        var minutesToEmpty: Int?
    }

    private static func copyBattery() -> RawBattery? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
        else { return nil }

        for item in list {
            guard let description = IOPSGetPowerSourceDescription(blob, item)?.takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey as String] as? String == kIOPSInternalBatteryType as String
            else { continue }

            let current = intValue(description[kIOPSCurrentCapacityKey as String])
            let maximum = intValue(description[kIOPSMaxCapacityKey as String])
            let percent: Int
            if let current, let maximum, maximum > 0 {
                if maximum <= 100 {
                    percent = min(100, max(0, current))
                } else {
                    percent = min(100, max(0, Int((Double(current) / Double(maximum) * 100).rounded())))
                }
            } else {
                percent = 0
            }

            let state = description[kIOPSPowerSourceStateKey as String] as? String
            let onBattery = state == kIOPSBatteryPowerValue as String
            let onAdapter = state == kIOPSACPowerValue as String
            return RawBattery(
                percent: percent,
                charging: boolValue(description[kIOPSIsChargingKey as String]),
                onBattery: onBattery,
                onAdapter: onAdapter,
                minutesToFull: saneMinutes(intValue(description[kIOPSTimeToFullChargeKey as String])),
                minutesToEmpty: saneMinutes(intValue(description[kIOPSTimeToEmptyKey as String]))
            )
        }
        return nil
    }

    static func setWiFiPower(_ on: Bool) -> Bool {
        guard let interface = CWWiFiClient.shared().interface() else { return false }
        do {
            try interface.setPower(on)
            return true
        } catch {
            return false
        }
    }

    private static func readLink(wifi: DuoWiFi.State, path: DuoPathFlags) -> DuoLink {
        switch wifi {
        case .off:
            if path.known && path.wired { return .ethernet }
            return .wifiOff
        case .unavailable:
            if path.known && (path.wired || path.satisfied) { return .ethernet }
            return .offline
        case .idle:
            if path.known && path.wired && path.satisfied { return .ethernet }
            return .wifiIdle
        case .associated(let rssi):
            let reachable = !path.known || path.satisfied
            return .wifi(bars: bars(for: rssi), reachable: reachable)
        }
    }

    /// 与 Status Trio 相同的 RSSI 分档：-55 / -70 / -85 dBm。
    static func bars(for rssi: Int) -> Int {
        if rssi >= -55 { return 3 }
        if rssi >= -70 { return 2 }
        if rssi >= -85 { return 1 }
        return 0
    }

    private static func saneMinutes(_ value: Int?) -> Int? {
        guard let value, value > 0, value < 60 * 24 * 3 else { return nil }
        return value
    }

    private static func intValue(_ value: Any?) -> Int? {
        switch value {
        case let number as NSNumber: return number.intValue
        case let int as Int: return int
        default: return nil
        }
    }

    private static func boolValue(_ value: Any?) -> Bool {
        switch value {
        case let number as NSNumber: return number.boolValue
        case let flag as Bool: return flag
        default: return false
        }
    }
}

private enum DuoWiFi {
    struct Probe {
        var state: State
        var powerOn: Bool?
    }

    enum State {
        case unavailable
        case off
        case idle
        case associated(rssi: Int)
    }

    static func read() -> Probe {
        guard let interface = CWWiFiClient.shared().interface() else {
            return Probe(state: .unavailable, powerOn: nil)
        }
        guard interface.powerOn() else { return Probe(state: .off, powerOn: false) }
        let rssi = interface.rssiValue()
        guard rssi != 0 else { return Probe(state: .idle, powerOn: true) }
        return Probe(state: .associated(rssi: rssi), powerOn: true)
    }
}

enum DuoSystemAudio {
    struct Reading: Equatable {
        var scalar: Double?
        var muted: Bool
        var name: String?
    }

    static func read() -> Reading {
        let device = defaultOutputDevice()
        guard device != 0 else { return Reading(scalar: nil, muted: false, name: nil) }
        let scalar = readFloat(kAudioDevicePropertyVolumeScalar, device: device).map { Double($0) }
        let muted = (readUInt32(kAudioDevicePropertyMute, device: device) ?? 0) != 0
        return Reading(scalar: scalar, muted: muted, name: deviceName(device))
    }

    static func setScalar(_ value: Double) {
        let device = defaultOutputDevice()
        guard device != 0 else { return }
        let scalar = Float(min(1, max(0, value)))
        _ = writeFloat(kAudioDevicePropertyVolumeScalar, device: device, value: scalar)
        if scalar > 0 {
            _ = writeUInt32(kAudioDevicePropertyMute, device: device, value: 0)
        }
    }

    static func setMuted(_ muted: Bool) {
        let device = defaultOutputDevice()
        guard device != 0 else { return }
        _ = writeUInt32(kAudioDevicePropertyMute, device: device, value: muted ? 1 : 0)
    }

    private static let elements: [AudioObjectPropertyElement] = [
        kAudioObjectPropertyElementMain, 1, 2
    ]

    private static func defaultOutputDevice() -> AudioDeviceID {
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
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
        guard status == noErr else { return 0 }
        return device
    }

    private static func readFloat(
        _ selector: AudioObjectPropertySelector,
        device: AudioDeviceID
    ) -> Float? {
        for element in elements {
            var address = outputAddress(selector, element: element)
            guard AudioObjectHasProperty(device, &address) else { continue }
            var value = Float(0)
            var size = UInt32(MemoryLayout<Float>.size)
            let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value)
            if status == noErr { return value }
        }
        return nil
    }

    private static func readUInt32(
        _ selector: AudioObjectPropertySelector,
        device: AudioDeviceID
    ) -> UInt32? {
        for element in elements {
            var address = outputAddress(selector, element: element)
            guard AudioObjectHasProperty(device, &address) else { continue }
            var value = UInt32(0)
            var size = UInt32(MemoryLayout<UInt32>.size)
            let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value)
            if status == noErr { return value }
        }
        return nil
    }

    @discardableResult
    private static func writeFloat(
        _ selector: AudioObjectPropertySelector,
        device: AudioDeviceID,
        value: Float
    ) -> Bool {
        var wrote = false
        for element in elements {
            var address = outputAddress(selector, element: element)
            guard AudioObjectHasProperty(device, &address) else { continue }
            var value = value
            let size = UInt32(MemoryLayout<Float>.size)
            if AudioObjectSetPropertyData(device, &address, 0, nil, size, &value) == noErr {
                wrote = true
            }
        }
        return wrote
    }

    @discardableResult
    private static func writeUInt32(
        _ selector: AudioObjectPropertySelector,
        device: AudioDeviceID,
        value: UInt32
    ) -> Bool {
        var wrote = false
        for element in elements {
            var address = outputAddress(selector, element: element)
            guard AudioObjectHasProperty(device, &address) else { continue }
            var value = value
            let size = UInt32(MemoryLayout<UInt32>.size)
            if AudioObjectSetPropertyData(device, &address, 0, nil, size, &value) == noErr {
                wrote = true
            }
        }
        return wrote
    }

    private static func deviceName(_ device: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(device, &address) else { return nil }
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &name)
        guard status == noErr else { return nil }
        return name?.takeRetainedValue() as String?
    }

    private static func outputAddress(
        _ selector: AudioObjectPropertySelector,
        element: AudioObjectPropertyElement
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: element
        )
    }
}

final class DuoPathMonitor {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "MacAssistant.DuoPath")
    var onChange: ((DuoPathFlags) -> Void)?

    func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            let flags = DuoPathFlags(
                known: true,
                satisfied: path.status == .satisfied,
                wifi: path.usesInterfaceType(.wifi),
                wired: path.usesInterfaceType(.wiredEthernet)
            )
            self?.onChange?(flags)
        }
        monitor.start(queue: queue)
    }
}
