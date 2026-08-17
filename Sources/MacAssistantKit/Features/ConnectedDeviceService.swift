import Foundation

/// USB / 网络上的一台 iOS 设备。UDID 用于向 Apple 注册并写入描述文件。
public struct ConnectedDevice: Identifiable, Hashable, Sendable, Codable {
    public var udid: String
    public var name: String
    public var productType: String?
    public var osVersion: String?
    public var transport: Transport
    /// `devicectl` 使用的 CoreDevice identifier，可能与 UDID 不同。
    public var coreDeviceIdentifier: String?

    public var id: String { udid }

    public enum Transport: String, Sendable, Codable, Hashable {
        case usb
        case network
        case unknown
    }

    public init(
        udid: String,
        name: String,
        productType: String? = nil,
        osVersion: String? = nil,
        transport: Transport = .unknown,
        coreDeviceIdentifier: String? = nil
    ) {
        self.udid = udid
        self.name = name
        self.productType = productType
        self.osVersion = osVersion
        self.transport = transport
        self.coreDeviceIdentifier = coreDeviceIdentifier
    }

    public var summary: String {
        var parts = [name]
        if let osVersion, !osVersion.isEmpty { parts.append("iOS \(osVersion)") }
        if let productType, !productType.isEmpty { parts.append(productType) }
        parts.append(udid)
        return parts.joined(separator: " · ")
    }
}

public enum ConnectedDeviceError: LocalizedError {
    case noDeviceTool
    case listFailed(String)
    case installFailed(String)
    case noDeviceSelected

    public var errorDescription: String? {
        switch self {
        case .noDeviceTool: return L("device.error.noTool")
        case let .listFailed(output): return L("device.error.listFailed", output)
        case let .installFailed(output): return L("device.error.installFailed", output)
        case .noDeviceSelected: return L("device.error.noDeviceSelected")
        }
    }
}

/// 连接设备：优先 libimobiledevice（idevice_id / ideviceinfo / ideviceinstaller），
/// 再回退 `xcrun devicectl` 与 `xcrun xctrace`。协议与工具来自 libimobiledevice 与 Xcode。
public enum ConnectedDeviceService {

    public static var canListDevices: Bool {
        ExternalTool.ideviceID.isAvailable
            || ExternalTool.xcrun.isAvailable
    }

    public static var canInstall: Bool {
        ExternalTool.ideviceInstaller.isAvailable
            || ExternalTool.xcrun.isAvailable
            || ExternalTool.xtool.isAvailable
    }

    public static func listDevices() throws -> [ConnectedDevice] {
        var merged: [String: ConnectedDevice] = [:]
        var errors: [String] = []

        if ExternalTool.ideviceID.isAvailable {
            do {
                for device in try listViaLibimobiledevice() {
                    merged[device.udid] = device
                }
            } catch {
                errors.append(error.localizedDescription)
            }
        }

        if let xctrace = try? listViaXCTrace() {
            for device in xctrace where merged[device.udid] == nil {
                merged[device.udid] = device
            }
        }

        if let coreDevice = try? listViaDeviceCtl() {
            for device in coreDevice {
                if var existing = merged[device.udid] {
                    if existing.coreDeviceIdentifier == nil {
                        existing.coreDeviceIdentifier = device.coreDeviceIdentifier
                    }
                    if existing.name.isEmpty { existing.name = device.name }
                    merged[device.udid] = existing
                } else {
                    merged[device.udid] = device
                }
            }
        }

        let devices = merged.values
            .filter(isInstallablePhone)
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        if devices.isEmpty, !errors.isEmpty, merged.isEmpty {
            throw ConnectedDeviceError.listFailed(errors.joined(separator: "\n"))
        }
        return devices
    }

    public static func install(ipaAt url: URL, to device: ConnectedDevice) throws {
        if ExternalTool.ideviceInstaller.isAvailable {
            let result = try runIdeviceInstaller(ipa: url, udid: device.udid)
            if result.succeeded { return }
            throw ConnectedDeviceError.installFailed(result.combinedOutput)
        }
        if ExternalTool.xcrun.isAvailable {
            try installViaDeviceCtl(ipaAt: url, device: device)
            return
        }
        if ExternalTool.xtool.isAvailable {
            let result = try ExternalTool.xtool.run(["install", url.path])
            guard result.succeeded else { throw ConnectedDeviceError.installFailed(result.combinedOutput) }
            return
        }
        throw ConnectedDeviceError.noDeviceTool
    }

    // MARK: - libimobiledevice

    static func parseIdeviceIDList(_ output: String) -> [String] {
        output.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { isLikelyUDID($0) }
    }

    private static func listViaLibimobiledevice() throws -> [ConnectedDevice] {
        var udids: [String] = []
        if let usb = try? ExternalTool.ideviceID.run(["-l"]), usb.succeeded {
            udids += parseIdeviceIDList(usb.stdout)
        }
        if let network = try? ExternalTool.ideviceID.run(["-n"]), network.succeeded {
            for id in parseIdeviceIDList(network.stdout) where !udids.contains(id) {
                udids.append(id)
            }
        }
        guard !udids.isEmpty else {
            let probe = try ExternalTool.ideviceID.run(["-l"])
            if !probe.succeeded {
                throw ConnectedDeviceError.listFailed(probe.combinedOutput)
            }
            return []
        }
        return udids.map { udid in
            let name = ideviceValue(udid: udid, key: "DeviceName") ?? udid
            let product = ideviceValue(udid: udid, key: "ProductType")
            let version = ideviceValue(udid: udid, key: "ProductVersion")
            return ConnectedDevice(
                udid: udid,
                name: name,
                productType: product,
                osVersion: version,
                transport: .usb
            )
        }
    }

    private static func ideviceValue(udid: String, key: String) -> String? {
        guard ExternalTool.ideviceInfo.isAvailable,
              let result = try? ExternalTool.ideviceInfo.run(["-u", udid, "-k", key]),
              result.succeeded
        else { return nil }
        let value = result.trimmedOutput
        return value.isEmpty ? nil : value
    }

    private static func runIdeviceInstaller(ipa: URL, udid: String) throws -> CommandResult {
        let modern = try ExternalTool.ideviceInstaller.run(["-u", udid, "install", ipa.path])
        if modern.succeeded { return modern }
        let legacy = try ExternalTool.ideviceInstaller.run(["-u", udid, "-i", ipa.path])
        return legacy.succeeded ? legacy : modern
    }

    // MARK: - xctrace

    /// `xcrun xctrace list devices` 的设备段。忽略 Simulator 与本机 Mac。
    static func parseXCTraceDevices(_ output: String) -> [ConnectedDevice] {
        var devices: [ConnectedDevice] = []
        var inDevices = false
        for raw in output.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("==") {
                inDevices = line.lowercased().contains("devices") && !line.lowercased().contains("simulator")
                continue
            }
            guard inDevices, !line.isEmpty else { continue }
            if let device = parseXCTraceLine(line) {
                devices.append(device)
            }
        }
        return devices
    }

    static func parseXCTraceLine(_ line: String) -> ConnectedDevice? {
        // Name (version) (UDID)  或  Name (UDID)
        guard let lastOpen = line.lastIndex(of: "("),
              let lastClose = line.lastIndex(of: ")"),
              lastOpen < lastClose
        else { return nil }
        let udid = String(line[line.index(after: lastOpen)..<lastClose])
            .trimmingCharacters(in: .whitespaces)
        guard isLikelyUDID(udid) else { return nil }
        let prefix = String(line[..<lastOpen]).trimmingCharacters(in: .whitespaces)
        var name = prefix
        var version: String?
        if let versionOpen = prefix.lastIndex(of: "("),
           let versionClose = prefix.lastIndex(of: ")"),
           versionOpen < versionClose {
            version = String(prefix[prefix.index(after: versionOpen)..<versionClose])
            name = String(prefix[..<versionOpen]).trimmingCharacters(in: .whitespaces)
        }
        return ConnectedDevice(udid: udid, name: name, osVersion: version, transport: .unknown)
    }

    private static func listViaXCTrace() throws -> [ConnectedDevice] {
        guard ExternalTool.xcrun.isAvailable else { return [] }
        let result = try ExternalTool.xcrun.run(["xctrace", "list", "devices"])
        return parseXCTraceDevices(result.combinedOutput)
    }

    // MARK: - devicectl

    static func parseDeviceCtlJSON(_ data: Data) throws -> [ConnectedDevice] {
        let object = try JSONSerialization.jsonObject(with: data)
        guard let root = object as? [String: Any] else { return [] }
        let devices = extractDeviceDictionaries(from: root)
        return devices.compactMap(parseDeviceCtlEntry)
    }

    static func parseDeviceCtlEntry(_ dict: [String: Any]) -> ConnectedDevice? {
        let hardware = dictionary(dict["hardwareProperties"]) ?? [:]
        let properties = dictionary(dict["deviceProperties"]) ?? [:]
        let connection = dictionary(dict["connectionProperties"]) ?? [:]
        let udid = string(hardware["udid"])
            ?? string(dict["udid"])
            ?? string(dict["identifier"])
            ?? ""
        guard isLikelyUDID(udid) || isLikelyUDID(string(dict["identifier"]) ?? "") else { return nil }
        let resolvedUDID = isLikelyUDID(udid) ? udid : (string(dict["identifier"]) ?? udid)
        let name = string(properties["name"])
            ?? string(dict["name"])
            ?? string(hardware["marketingName"])
            ?? resolvedUDID
        let platform = (string(hardware["platform"]) ?? string(dict["platform"]) ?? "").lowercased()
        if !platform.isEmpty, !["ios", "ipados", "tvos", "watchos"].contains(where: { platform.contains($0) }) {
            return nil
        }
        let transport: ConnectedDevice.Transport
        let transportValue = (string(connection["transportType"]) ?? "").lowercased()
        if transportValue.contains("wired") || transportValue.contains("usb") {
            transport = .usb
        } else if transportValue.contains("network") || transportValue.contains("wifi") {
            transport = .network
        } else {
            transport = .unknown
        }
        return ConnectedDevice(
            udid: resolvedUDID,
            name: name,
            productType: string(hardware["marketingName"]) ?? string(hardware["productType"]),
            osVersion: string(hardware["osVersionNumber"])
                ?? string(hardware["osVersion"])
                ?? string(properties["osVersionOverride"]),
            transport: transport,
            coreDeviceIdentifier: string(dict["identifier"])
        )
    }

    private static func listViaDeviceCtl() throws -> [ConnectedDevice] {
        guard ExternalTool.xcrun.isAvailable else { return [] }
        let jsonURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("devicectl-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: jsonURL) }
        let result = try ExternalTool.xcrun.run([
            "devicectl", "list", "devices", "--json-output", jsonURL.path
        ])
        guard FileManager.default.fileExists(atPath: jsonURL.path) else {
            if !result.succeeded { throw ConnectedDeviceError.listFailed(result.combinedOutput) }
            return []
        }
        return try parseDeviceCtlJSON(Data(contentsOf: jsonURL))
    }

    private static func installViaDeviceCtl(ipaAt url: URL, device: ConnectedDevice) throws {
        let work = try FileSystemHelper.makeTemporaryDirectory(prefix: "devicectl-install")
        defer { try? FileManager.default.removeItem(at: work) }
        let extract = work.appendingPathComponent("x")
        try IpaService.unzip(url, to: extract)
        try IpaService.validatePayloadStructure(in: extract)
        let app = try IpaService.locateApp(in: extract)
        let identifier = device.coreDeviceIdentifier ?? device.udid
        let result = try ExternalTool.xcrun.run([
            "devicectl", "device", "install", "app",
            "--device", identifier,
            app.path
        ])
        guard result.succeeded else { throw ConnectedDeviceError.installFailed(result.combinedOutput) }
    }

    // MARK: - 过滤

    public static func isLikelyUDID(_ value: String) -> Bool {
        let compact = value.replacingOccurrences(of: "-", with: "")
        guard compact.count >= 16, compact.count <= 40,
              compact.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) })
        else { return false }
        return true
    }

    static func isInstallablePhone(_ device: ConnectedDevice) -> Bool {
        let name = device.name.lowercased()
        if name.contains("simulator") { return false }
        if name.contains("macbook") || name.contains("mac mini") || name.contains("mac pro")
            || name.contains("mac studio") || name.hasPrefix("mac ") {
            return false
        }
        if let product = device.productType?.lowercased(),
           product.contains("mac") && !product.contains("iphone") && !product.contains("ipad") {
            return false
        }
        return isLikelyUDID(device.udid)
    }

    private static func extractDeviceDictionaries(from root: [String: Any]) -> [[String: Any]] {
        if let result = dictionary(root["result"]), let devices = result["devices"] as? [[String: Any]] {
            return devices
        }
        if let devices = root["devices"] as? [[String: Any]] { return devices }
        if let info = dictionary(root["info"]), let devices = info["devices"] as? [[String: Any]] {
            return devices
        }
        return []
    }

    private static func dictionary(_ value: Any?) -> [String: Any]? {
        value as? [String: Any]
    }

    private static func string(_ value: Any?) -> String? {
        if let text = value as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }
}
