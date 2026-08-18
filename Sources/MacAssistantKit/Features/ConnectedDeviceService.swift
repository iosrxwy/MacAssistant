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

/// 设备上已安装的应用。导出时只做原样归档，不脱壳。
public struct InstalledApp: Identifiable, Hashable, Sendable {
    public var bundleIdentifier: String
    public var name: String
    public var version: String?
    public var shortVersion: String?

    public var id: String { bundleIdentifier }

    public init(
        bundleIdentifier: String,
        name: String,
        version: String? = nil,
        shortVersion: String? = nil
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.name = name
        self.version = version
        self.shortVersion = shortVersion
    }

    public var summary: String {
        var parts = [name, bundleIdentifier]
        if let shortVersion, !shortVersion.isEmpty { parts.append(shortVersion) }
        else if let version, !version.isEmpty { parts.append(version) }
        return parts.joined(separator: " · ")
    }
}

public enum ConnectedDeviceError: LocalizedError {
    case noDeviceTool
    case listFailed(String)
    case installFailed(String)
    case noDeviceSelected
    case listAppsFailed(String)
    case exportFailed(String)
    case noAppSelected
    case uninstallFailed(String)
    case downgradeNeedsConfirmation

    public var errorDescription: String? {
        switch self {
        case .noDeviceTool: return L("device.error.noTool")
        case let .listFailed(output): return L("device.error.listFailed", output)
        case let .installFailed(output): return L("device.error.installFailed", output)
        case .noDeviceSelected: return L("device.error.noDeviceSelected")
        case let .listAppsFailed(output): return L("device.error.listAppsFailed", output)
        case let .exportFailed(output): return L("device.error.exportFailed", output)
        case .noAppSelected: return L("device.error.noAppSelected")
        case let .uninstallFailed(output): return L("device.error.uninstallFailed", output)
        case .downgradeNeedsConfirmation: return L("device.error.downgradeNeedsConfirmation")
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

    public static var canListApps: Bool {
        ExternalTool.ideviceInstaller.isAvailable
    }

    public static var canExportApps: Bool {
        ExternalTool.ideviceInstaller.isAvailable
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

    /// 按版本关系安装、升级或降级。
    /// 降级默认提高 Build 后覆盖安装以保留数据；`uninstallFirst` 才会卸掉应用。
    public static func install(
        ipaAt url: URL,
        to device: ConnectedDevice,
        plan: AppInstallPlan,
        downgrade: AppDowngradeStrategy = .keepData(signMethod: .codesignAdhoc)
    ) throws {
        switch plan.relation {
        case .fresh, .unknown:
            try install(ipaAt: url, to: device)
        case .upgrade, .same:
            try upgrade(ipaAt: url, to: device)
        case .downgrade:
            switch downgrade {
            case let .keepData(signMethod):
                let prepared = try IpaService.prepareKeepDataDowngrade(
                    ipaAt: url,
                    installedBuild: plan.installedBuild,
                    signMethod: signMethod
                )
                try upgrade(ipaAt: prepared.outputIPA, to: device)
            case .uninstallFirst:
                try uninstall(plan.identity.bundleIdentifier, from: device)
                try install(ipaAt: url, to: device)
            }
        }
    }

    public static func upgrade(ipaAt url: URL, to device: ConnectedDevice) throws {
        if ExternalTool.ideviceInstaller.isAvailable {
            let modern = try ExternalTool.ideviceInstaller.run(["-u", device.udid, "upgrade", url.path])
            if modern.succeeded { return }
            let legacy = try ExternalTool.ideviceInstaller.run(["-u", device.udid, "-g", url.path])
            if legacy.succeeded { return }
            try install(ipaAt: url, to: device)
            return
        }
        try install(ipaAt: url, to: device)
    }

    public static func uninstall(_ bundleID: String, from device: ConnectedDevice) throws {
        guard ExternalTool.ideviceInstaller.isAvailable else { throw ConnectedDeviceError.noDeviceTool }
        let modern = try ExternalTool.ideviceInstaller.run(["-u", device.udid, "uninstall", bundleID])
        if modern.succeeded { return }
        let legacy = try ExternalTool.ideviceInstaller.run(["-u", device.udid, "-U", bundleID])
        if legacy.succeeded { return }
        throw ConnectedDeviceError.uninstallFailed(modern.combinedOutput)
    }

    public static func listInstalledApps(
        on device: ConnectedDevice,
        includeSystem: Bool = false
    ) throws -> [InstalledApp] {
        guard ExternalTool.ideviceInstaller.isAvailable else { throw ConnectedDeviceError.noDeviceTool }
        let scope = includeSystem ? "list_all" : "list_user"
        let xmlAttempts = [
            ["-u", device.udid, "list", "-o", "xml,\(scope)"],
            ["-u", device.udid, "-l", "-o", "xml,\(scope)"]
        ]
        for arguments in xmlAttempts {
            if let result = try? ExternalTool.ideviceInstaller.run(arguments), result.succeeded {
                let data = Data(result.stdout.utf8)
                if let apps = try? parseInstalledAppsPlist(data), !apps.isEmpty {
                    return apps.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                }
            }
        }
        let textAttempts = [
            ["-u", device.udid, "list", "-o", scope],
            ["-u", device.udid, "-l", "-o", scope],
            ["-u", device.udid, "-l"]
        ]
        var lastOutput = ""
        for arguments in textAttempts {
            let result = try ExternalTool.ideviceInstaller.run(arguments)
            lastOutput = result.combinedOutput
            if result.succeeded {
                let apps = parseInstalledAppsList(result.stdout)
                if !apps.isEmpty {
                    return apps.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                }
            }
        }
        throw ConnectedDeviceError.listAppsFailed(lastOutput)
    }

    /// 通过 installation_proxy 归档应用并保存为 IPA。这是原样拷贝，不解密 FairPlay。
    public static func exportApp(
        _ app: InstalledApp,
        from device: ConnectedDevice,
        toDirectory directory: URL
    ) throws -> IpaPackageResult {
        guard ExternalTool.ideviceInstaller.isAvailable else { throw ConnectedDeviceError.noDeviceTool }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stage = try FileSystemHelper.makeTemporaryDirectory(prefix: "device-export")
        defer { try? FileManager.default.removeItem(at: stage) }

        let attempts = [
            ["-u", device.udid, "archive", app.bundleIdentifier, "-o", "copy=\(stage.path),remove,app_only"],
            ["-u", device.udid, "-a", app.bundleIdentifier, "-o", "copy=\(stage.path),remove,app_only"]
        ]
        var lastOutput = ""
        var copied: URL?
        for arguments in attempts {
            let result = try ExternalTool.ideviceInstaller.run(arguments)
            lastOutput = result.combinedOutput
            if result.succeeded, let file = newestArchive(in: stage) {
                copied = file
                break
            }
        }
        guard let archive = copied else {
            throw ConnectedDeviceError.exportFailed(lastOutput)
        }
        let proposed = directory.appendingPathComponent(sanitizedIPAName(app))
        return try IpaService.adoptDeviceArchive(archive, outputURL: proposed)
    }

    static func parseInstalledAppsList(_ output: String) -> [InstalledApp] {
        output.split(whereSeparator: \.isNewline).compactMap { raw in
            parseInstalledAppLine(String(raw))
        }
    }

    static func parseInstalledAppLine(_ line: String) -> InstalledApp? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let lower = trimmed.lowercased()
        if lower.hasPrefix("total:") { return nil }
        if lower.hasPrefix("error") { return nil }
        guard let separator = trimmed.range(of: " - ") else { return nil }
        let bundleID = String(trimmed[..<separator.lowerBound]).trimmingCharacters(in: .whitespaces)
        guard bundleID.contains("."), bundleID.count > 2 else { return nil }
        let rest = String(trimmed[separator.upperBound...]).trimmingCharacters(in: .whitespaces)
        let split = splitAppNameAndAttributes(rest)
        var name = split.name
        if name.isEmpty { name = bundleID }
        var version: String?
        var shortVersion: String?
        for token in split.attributes.split(whereSeparator: \.isWhitespace) {
            let piece = String(token)
            if let value = piece.split(separator: "=").last.map(String.init) {
                if piece.hasPrefix("CFBundleVersion=") { version = value }
                if piece.hasPrefix("CFBundleShortVersionString=") { shortVersion = value }
            }
        }
        return InstalledApp(
            bundleIdentifier: bundleID,
            name: name,
            version: version,
            shortVersion: shortVersion
        )
    }

    static func splitAppNameAndAttributes(_ rest: String) -> (name: String, attributes: String) {
        var text = rest
        if text.first == "\"" {
            text.removeFirst()
            if let close = text.firstIndex(of: "\"") {
                let name = String(text[..<close])
                let attrs = String(text[text.index(after: close)...]).trimmingCharacters(in: .whitespaces)
                return (name, attrs)
            }
        }
        let markers = [" CFBundleVersion=", " CFBundleShortVersionString="]
        var cut: String.Index?
        for marker in markers {
            if let range = text.range(of: marker) {
                if cut == nil || range.lowerBound < cut! {
                    cut = range.lowerBound
                }
            }
        }
        if let cut {
            return (
                String(text[..<cut]).trimmingCharacters(in: .whitespaces),
                String(text[cut...]).trimmingCharacters(in: .whitespaces)
            )
        }
        return (text.trimmingCharacters(in: .whitespaces), "")
    }

    static func parseInstalledAppsPlist(_ data: Data) throws -> [InstalledApp] {
        let object = try PropertyListSerialization.propertyList(from: data, format: nil)
        let dictionaries: [[String: Any]]
        if let array = object as? [[String: Any]] {
            dictionaries = array
        } else if let dict = object as? [String: Any] {
            dictionaries = dict.values.compactMap { $0 as? [String: Any] }
        } else {
            return []
        }
        return dictionaries.compactMap { dict in
            let bundleID = string(dict["CFBundleIdentifier"]) ?? string(dict["bundleIdentifier"])
            guard let bundleID, bundleID.contains(".") else { return nil }
            let name = string(dict["CFBundleDisplayName"])
                ?? string(dict["CFBundleName"])
                ?? bundleID
            return InstalledApp(
                bundleIdentifier: bundleID,
                name: name,
                version: string(dict["CFBundleVersion"]),
                shortVersion: string(dict["CFBundleShortVersionString"])
            )
        }
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

    private static func newestArchive(in directory: URL) -> URL? {
        let items = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        let archives = items.filter { url in
            let ext = url.pathExtension.lowercased()
            let isFile = (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
            return isFile && ["ipa", "zip"].contains(ext)
        }
        return archives.max { lhs, rhs in
            let left = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let right = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return left < right
        }
    }

    private static func sanitizedIPAName(_ app: InstalledApp) -> String {
        let raw = app.name.isEmpty ? app.bundleIdentifier : app.name
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let cleaned = raw.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        let name = String(cleaned).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return (name.isEmpty ? app.bundleIdentifier : name) + ".ipa"
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
