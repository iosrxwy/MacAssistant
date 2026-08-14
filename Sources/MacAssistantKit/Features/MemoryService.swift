import Foundation
import Darwin

public enum MemoryPressureLevel: String, Sendable {
    case healthy
    case warning
    case critical
    case unknown

    public var label: String {
        switch self {
        case .healthy: return L("memory.pressure.healthy")
        case .warning: return L("memory.pressure.warning")
        case .critical: return L("memory.pressure.critical")
        case .unknown: return L("memory.pressure.unknown")
        }
    }
}

public struct MemorySnapshot: Sendable {
    public let physical: UInt64
    public let used: UInt64
    public let cached: UInt64
    public let compressed: UInt64
    public let swapUsed: UInt64
    public let pressureFreePercent: Int?
    public let pressureLevel: MemoryPressureLevel
    public let capturedAt: Date

    public init(
        physical: UInt64,
        used: UInt64,
        cached: UInt64,
        compressed: UInt64,
        swapUsed: UInt64,
        pressureFreePercent: Int?,
        pressureLevel: MemoryPressureLevel,
        capturedAt: Date = Date()
    ) {
        self.physical = physical
        self.used = used
        self.cached = cached
        self.compressed = compressed
        self.swapUsed = swapUsed
        self.pressureFreePercent = pressureFreePercent
        self.pressureLevel = pressureLevel
        self.capturedAt = capturedAt
    }
}

public struct ProcessMemoryInfo: Identifiable, Hashable, Sendable {
    public let pid: Int32
    public let userID: UInt32
    public let rssBytes: UInt64
    public let executablePath: String

    public var id: Int32 { pid }
    public var name: String {
        let url = URL(fileURLWithPath: executablePath)
        let component = url.lastPathComponent
        return component.isEmpty ? executablePath : component
    }
    public var applicationBundlePath: String? {
        ProcessApplicationResolver.applicationBundlePath(forExecutablePath: executablePath)
    }

    public init(pid: Int32, userID: UInt32, rssBytes: UInt64, executablePath: String) {
        self.pid = pid
        self.userID = userID
        self.rssBytes = rssBytes
        self.executablePath = executablePath
    }
}

public enum ProcessApplicationResolver {
    /// 返回可执行路径所属的最外层 .app。嵌套 Helper.app 会自然映射到宿主 App。
    public static func applicationBundlePath(forExecutablePath path: String) -> String? {
        applicationBundlePaths(forExecutablePath: path).first
    }

    /// 从外到内返回路径中的所有 .app bundle，供 UI 判断嵌套 Helper 是否应使用宿主图标。
    public static func applicationBundlePaths(forExecutablePath path: String) -> [String] {
        guard path.hasPrefix("/") else { return [] }
        let components = URL(fileURLWithPath: path).standardizedFileURL.pathComponents
        var candidate = URL(fileURLWithPath: "/", isDirectory: true)
        var bundles: [String] = []

        for component in components.dropFirst() {
            candidate.appendPathComponent(component)
            if component.lowercased().hasSuffix(".app"), component.count > 4 {
                bundles.append(candidate.standardizedFileURL.path)
            }
        }
        return bundles
    }
}

public struct ProcessIconCacheKey: Hashable, Sendable {
    public let pid: Int32
    public let bundlePath: String?

    public init(pid: Int32, bundlePath: String?) {
        self.pid = pid
        self.bundlePath = bundlePath.map {
            URL(fileURLWithPath: $0).standardizedFileURL.path
        }
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs.bundlePath, rhs.bundlePath) {
        case let (.some(left), .some(right)):
            // 同一 App 的主进程与多个 Helper 共用一份图标。
            return left == right
        case (nil, nil):
            // 无法归属 App 时才按 PID 区分运行中的独立进程。
            return lhs.pid == rhs.pid
        default:
            return false
        }
    }

    public func hash(into hasher: inout Hasher) {
        if let bundlePath {
            hasher.combine(0)
            hasher.combine(bundlePath)
        } else {
            hasher.combine(1)
            hasher.combine(pid)
        }
    }
}

public enum ProcessSignal: Equatable, Sendable {
    case terminate
    case kill

    var rawValue: Int32 {
        switch self {
        case .terminate: return SIGTERM
        case .kill: return SIGKILL
        }
    }
}

public enum MemoryMaintenanceKind: Sendable, Equatable {
    case developerFileCacheBenchmark
}

public struct MemoryMaintenanceOperation: Sendable, Equatable {
    public let kind: MemoryMaintenanceKind
    public let title: String
    public let explanation: String
}

public enum MemoryServiceError: LocalizedError {
    case commandFailed(String)
    case invalidPID
    case protectedProcess(String)
    case permissionDenied
    case processNotFound
    case signalFailed(Int32)
    case purgeUnavailable

    public var errorDescription: String? {
        switch self {
        case let .commandFailed(output): return L("memory.error.command-failed", output)
        case .invalidPID: return L("memory.error.invalid-pid")
        case let .protectedProcess(name): return L("memory.error.protected-process", name)
        case .permissionDenied: return L("memory.error.permission-denied")
        case .processNotFound: return L("memory.error.process-not-found")
        case let .signalFailed(code): return L("memory.error.signal-failed", code)
        case .purgeUnavailable: return L("memory.error.purge-unavailable")
        }
    }
}

public enum MemoryService {
    public static let purgeOperation = MemoryMaintenanceOperation(
        kind: .developerFileCacheBenchmark,
        title: L("memory.purge.title"),
        explanation: L("memory.purge.explanation")
    )

    public static let protectedProcessNames: Set<String> = [
        "kernel_task", "launchd", "WindowServer", "loginwindow",
        "opendirectoryd", "securityd", "taskgated", "runningboardd"
    ]

    public static func snapshot() throws -> MemorySnapshot {
        let vm = try Shell.run("/usr/bin/vm_stat")
        guard vm.succeeded else { throw MemoryServiceError.commandFailed(vm.combinedOutput) }
        let parsed = parseVMStat(vm.stdout)

        let physical = ProcessInfo.processInfo.physicalMemory
        let pageSize = parsed.pageSize
        let compressedPages = parsed.pages["Pages occupied by compressor"] ?? 0

        let swapResult = try? Shell.run("/usr/sbin/sysctl", ["-n", "vm.swapusage"])
        let swapUsed = parseSwapUsage(swapResult?.stdout ?? "")

        let pressureResult = try? Shell.run("/usr/bin/memory_pressure", ["-Q"])
        let pressurePercent = parsePressureFreePercent(pressureResult?.stdout ?? "")

        return MemorySnapshot(
            physical: physical,
            used: min(physical, usedBytes(pages: parsed.pages, pageSize: pageSize)),
            cached: cachedFilesBytes(pages: parsed.pages, pageSize: pageSize),
            compressed: compressedPages * pageSize,
            swapUsed: swapUsed,
            pressureFreePercent: pressurePercent,
            pressureLevel: pressureLevel(freePercent: pressurePercent)
        )
    }

    /// 活动监视器口径的“已用内存”：App 匿名内存（扣除可随时回收的 purgeable）+ 联动 + 压缩。
    ///
    /// 不能用“物理内存 − 空闲页”估算：macOS 会把几乎所有未用内存拿去做文件缓存，
    /// 空闲页常年接近 0，那样算出的“已用”永远接近 100%，看起来像内存占用异常。
    public static func usedBytes(pages: [String: UInt64], pageSize: UInt64) -> UInt64 {
        let anonymous = pages["Anonymous pages"] ?? 0
        let purgeable = pages["Pages purgeable"] ?? 0
        let wired = pages["Pages wired down"] ?? 0
        let compressed = pages["Pages occupied by compressor"] ?? 0
        // purgeable 统计可能包含文件页，理论上可大于匿名页，做饱和减法。
        let appPages = anonymous > purgeable ? anonymous - purgeable : 0
        return (appPages + wired + compressed) * pageSize
    }

    /// 活动监视器口径的“已缓存文件”：文件页 + 可清除页。
    public static func cachedFilesBytes(pages: [String: UInt64], pageSize: UInt64) -> UInt64 {
        let fileBacked = pages["File-backed pages"] ?? 0
        let purgeable = pages["Pages purgeable"] ?? 0
        return (fileBacked + purgeable) * pageSize
    }

    public static func processes(currentUserOnly: Bool = true) throws -> [ProcessMemoryInfo] {
        let result = try Shell.run("/bin/ps", ["-axo", "pid=,uid=,rss=,comm="])
        guard result.succeeded else { throw MemoryServiceError.commandFailed(result.combinedOutput) }
        return parsePS(result.stdout, currentUserID: currentUserOnly ? getuid() : nil).map { process in
            ProcessMemoryInfo(
                pid: process.pid,
                userID: process.userID,
                rssBytes: process.rssBytes,
                executablePath: processExecutablePath(pid: process.pid) ?? process.executablePath
            )
        }
    }

    public static func parseVMStat(_ text: String) -> (pageSize: UInt64, pages: [String: UInt64]) {
        // 兜底用本机运行时页大小(Apple Silicon 16K、Intel 4K),不写死某一种架构的常量。
        var pageSize = UInt64(vm_page_size)
        if let range = text.range(of: #"page size of \d+ bytes"#, options: .regularExpression) {
            let digits = text[range].filter(\.isNumber)
            pageSize = UInt64(digits) ?? pageSize
        }

        var pages: [String: UInt64] = [:]
        for rawLine in text.split(separator: "\n") {
            guard let colon = rawLine.firstIndex(of: ":") else { continue }
            let key = rawLine[..<colon].trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            let value = rawLine[rawLine.index(after: colon)...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            if let count = UInt64(value) { pages[key] = count }
        }
        return (pageSize, pages)
    }

    public static func parseSwapUsage(_ text: String) -> UInt64 {
        guard let range = text.range(of: #"used = [0-9.]+[KMGTP]"#, options: .regularExpression) else {
            return 0
        }
        let token = text[range].replacingOccurrences(of: "used = ", with: "")
        return bytes(fromUnitString: token)
    }

    public static func parsePressureFreePercent(_ text: String) -> Int? {
        guard let range = text.range(of: #"free percentage:\s*\d+%"#, options: .regularExpression) else {
            return nil
        }
        return Int(text[range].filter(\.isNumber))
    }

    public static func pressureLevel(freePercent: Int?) -> MemoryPressureLevel {
        guard let freePercent else { return .unknown }
        if freePercent >= 20 { return .healthy }
        if freePercent >= 10 { return .warning }
        return .critical
    }

    public static func parsePS(_ text: String, currentUserID: uid_t?) -> [ProcessMemoryInfo] {
        text.split(separator: "\n").compactMap { rawLine in
            let columns = rawLine.split(maxSplits: 3, omittingEmptySubsequences: true) {
                $0.isWhitespace
            }
            guard columns.count == 4,
                  let pid = Int32(columns[0]),
                  let uid = UInt32(columns[1]),
                  let rssKB = UInt64(columns[2]),
                  pid > 1,
                  currentUserID == nil || uid == currentUserID
            else { return nil }
            let path = String(columns[3]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !path.isEmpty, rssKB > 0 else { return nil }
            return ProcessMemoryInfo(pid: pid, userID: uid, rssBytes: rssKB * 1024, executablePath: path)
        }
        .sorted {
            if $0.rssBytes == $1.rssBytes { return $0.pid < $1.pid }
            return $0.rssBytes > $1.rssBytes
        }
    }

    public static func validatePID(
        _ pid: Int32,
        processName: String,
        ownPID: Int32 = ProcessInfo.processInfo.processIdentifier
    ) throws {
        guard pid > 1 else { throw MemoryServiceError.invalidPID }
        if pid == ownPID { throw MemoryServiceError.protectedProcess(L("memory.process.self")) }
        if protectedProcessNames.contains(processName) {
            throw MemoryServiceError.protectedProcess(processName)
        }
    }

    public static func send(_ signal: ProcessSignal, to process: ProcessMemoryInfo) throws {
        try validatePID(process.pid, processName: process.name)
        guard Darwin.kill(process.pid, signal.rawValue) == 0 else {
            switch errno {
            case EPERM: throw MemoryServiceError.permissionDenied
            case ESRCH: throw MemoryServiceError.processNotFound
            default: throw MemoryServiceError.signalFailed(errno)
            }
        }
    }

    public static var purgeAvailable: Bool {
        FileManager.default.isExecutableFile(atPath: "/usr/bin/purge")
    }

    public static func purgeFileCache() throws -> CommandResult {
        guard purgeAvailable else { throw MemoryServiceError.purgeUnavailable }
        let result = try AdminRunner.run(executable: "/usr/bin/purge")
        guard result.succeeded else { throw MemoryServiceError.commandFailed(result.combinedOutput) }
        return result
    }

    public static func formatBytes(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .memory)
    }

    /// proc_pidpath 可能因进程退出或权限不足失败；这种情况静默使用 ps 提供的安全回退路径。
    public static func processExecutablePath(pid: Int32) -> String? {
        guard pid > 0 else { return nil }
        // PROC_PIDPATHINFO_MAXSIZE 是 4 * MAXPATHLEN，但该 C 宏不能直接导入 Swift。
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }

    private static func bytes(fromUnitString text: String) -> UInt64 {
        guard let suffix = text.last else { return 0 }
        let number = Double(text.dropLast()) ?? 0
        let multiplier: Double
        switch suffix {
        case "K": multiplier = 1_024
        case "M": multiplier = 1_024 * 1_024
        case "G": multiplier = 1_024 * 1_024 * 1_024
        case "T": multiplier = 1_024 * 1_024 * 1_024 * 1_024
        case "P": multiplier = 1_024 * 1_024 * 1_024 * 1_024 * 1_024
        default: return UInt64(number)
        }
        return UInt64(max(0, number * multiplier))
    }
}
