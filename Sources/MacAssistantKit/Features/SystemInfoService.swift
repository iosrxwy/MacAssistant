import Foundation
import Darwin

public struct InfoItem: Identifiable, Sendable {
    public let id = UUID()
    public let label: String
    public let value: String
    public let systemImage: String

    public init(_ label: String, _ value: String, _ systemImage: String) {
        self.label = label
        self.value = value
        self.systemImage = systemImage
    }
}

/// 系统信息快照,用于仪表盘展示。
public struct SystemSnapshot: Sendable {
    public var items: [InfoItem]
    public var memoryUsedFraction: Double
    public var memoryUsedText: String
    public var diskUsedFraction: Double
    public var diskUsedText: String
    public var batteryLevel: Double?
    public var batteryState: String?
}

public enum SystemInfoService {

    public static func snapshot() -> SystemSnapshot {
        var items: [InfoItem] = []

        let pi = ProcessInfo.processInfo
        items.append(InfoItem(L("sysinfo.hostname"), pi.hostName, "network"))
        items.append(InfoItem("macOS", macOSVersion(), "apple.logo"))
        items.append(InfoItem(L("sysinfo.model"), sysctlString("hw.model") ?? L("sysinfo.unknown"), "desktopcomputer"))
        items.append(InfoItem(L("sysinfo.chip"), sysctlString("machdep.cpu.brand_string") ?? L("sysinfo.unknown"), "cpu"))
        items.append(InfoItem(L("sysinfo.architecture"), HostArchitecture.summary, "cpu"))

        let physical = sysctlInt("hw.physicalcpu") ?? 0
        let logical = sysctlInt("hw.logicalcpu") ?? UInt64(pi.activeProcessorCount)
        items.append(InfoItem(L("sysinfo.cpu.cores"),
                              L("sysinfo.cpu.cores.value", String(physical), String(logical)),
                              "cpu.fill"))

        let total = pi.physicalMemory
        items.append(InfoItem(L("sysinfo.memory.total"), FileSystemHelper.humanReadableSize(Int64(total)), "memorychip"))
        items.append(InfoItem(L("sysinfo.uptime"), formatUptime(pi.systemUptime), "clock"))

        // 内存使用
        let mem = memoryUsage(total: total)
        items.append(InfoItem(L("sysinfo.memory.used"), "\(FileSystemHelper.humanReadableSize(Int64(mem.used))) / \(FileSystemHelper.humanReadableSize(Int64(total)))", "gauge.with.dots.needle.67percent"))

        // 磁盘
        let disk = diskUsage()
        items.append(InfoItem(L("sysinfo.disk"), "\(FileSystemHelper.humanReadableSize(disk.used)) / \(FileSystemHelper.humanReadableSize(disk.total))", "internaldrive"))

        // 电池
        let battery = batteryInfo()
        if let level = battery.level {
            items.append(InfoItem(L("sysinfo.battery"), "\(Int(level * 100))%\(battery.state.map { " · \($0)" } ?? "")", "battery.100"))
        }

        return SystemSnapshot(
            items: items,
            memoryUsedFraction: total > 0 ? Double(mem.used) / Double(total) : 0,
            memoryUsedText: "\(FileSystemHelper.humanReadableSize(Int64(mem.used))) / \(FileSystemHelper.humanReadableSize(Int64(total)))",
            diskUsedFraction: disk.total > 0 ? Double(disk.used) / Double(disk.total) : 0,
            diskUsedText: "\(FileSystemHelper.humanReadableSize(disk.used)) / \(FileSystemHelper.humanReadableSize(disk.total))",
            batteryLevel: battery.level,
            batteryState: battery.state
        )
    }

    // MARK: - sysctl 辅助

    public static func sysctlString(_ key: String) -> String? {
        var size = 0
        guard sysctlbyname(key, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(key, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }

    public static func sysctlInt(_ key: String) -> UInt64? {
        var value: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        if sysctlbyname(key, &value, &size, nil, 0) == 0 { return value }
        var value32: UInt32 = 0
        size = MemoryLayout<UInt32>.size
        if sysctlbyname(key, &value32, &size, nil, 0) == 0 { return UInt64(value32) }
        return nil
    }

    // MARK: - 具体信息

    static func macOSVersion() -> String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        let build = sysctlString("kern.osversion") ?? ""
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)\(build.isEmpty ? "" : " (\(build))")"
    }

    /// 与内存工具页共用活动监视器口径，避免两个页面对“已用内存”给出不同数字。
    static func memoryUsage(total: UInt64) -> (used: UInt64, free: UInt64) {
        guard let result = try? Shell.run("/usr/bin/vm_stat"), result.succeeded else {
            return (0, total)
        }
        let parsed = MemoryService.parseVMStat(result.stdout)
        let used = min(total, MemoryService.usedBytes(pages: parsed.pages, pageSize: parsed.pageSize))
        return (used, total - used)
    }

    static func diskUsage() -> (used: Int64, total: Int64, free: Int64) {
        guard let attrs = try? FileManager.default.attributesOfFileSystem(forPath: "/") else {
            return (0, 0, 0)
        }
        let total = (attrs[.systemSize] as? NSNumber)?.int64Value ?? 0
        let free = (attrs[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
        return (total - free, total, free)
    }

    static func batteryInfo() -> (level: Double?, state: String?) {
        guard let result = try? Shell.run("/usr/bin/pmset", ["-g", "batt"]), result.succeeded else {
            return (nil, nil)
        }
        let text = result.stdout
        guard let percentRange = text.range(of: #"\d+%"#, options: .regularExpression) else {
            return (nil, nil)
        }
        let percentString = text[percentRange].replacingOccurrences(of: "%", with: "")
        let level = (Double(percentString) ?? 0) / 100.0
        let state: String?
        if text.contains("discharging") { state = L("sysinfo.battery.discharging") }
        else if text.contains("charging") { state = L("sysinfo.battery.charging") }
        else if text.contains("charged") { state = L("sysinfo.battery.charged") }
        else if text.contains("AC attached") || text.contains("AC Power") { state = L("sysinfo.battery.ac-power") }
        else { state = nil }
        return (level, state)
    }

    static func formatUptime(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        let days = total / 86400
        let hours = (total % 86400) / 3600
        let minutes = (total % 3600) / 60
        var parts: [String] = []
        if days > 0 { parts.append(L("sysinfo.uptime.days", days)) }
        if hours > 0 { parts.append(L("sysinfo.uptime.hours", hours)) }
        parts.append(L("sysinfo.uptime.minutes", minutes))
        return parts.joined(separator: " ")
    }
}
