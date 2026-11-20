import Foundation
import Darwin

/// 两次采样之间的 CPU 时间。100% 表示一个核心被占满，可以超过 100%。
public struct ProcessCPUSample: Sendable, Equatable {
    public var nanoseconds: UInt64
    public var capturedAt: Date
    public var percent: Double?

    public init(nanoseconds: UInt64, capturedAt: Date, percent: Double?) {
        self.nanoseconds = nanoseconds
        self.capturedAt = capturedAt
        self.percent = percent
    }
}

public enum ProcessCPUAccounting {
    /// 低于这个值的占用留空，避免列表里铺满 0.0%。
    public static let minimumVisiblePercent = 0.1
    /// 比这更密的刷新沿用上一次百分比，避免手动刷新把间隔压得太短。
    public static let minimumInterval: TimeInterval = 0.25

    public static func percent(
        currentNanoseconds: UInt64,
        previousNanoseconds: UInt64,
        elapsed: TimeInterval
    ) -> Double? {
        guard elapsed > 0, currentNanoseconds >= previousNanoseconds else { return nil }
        let delta = currentNanoseconds - previousNanoseconds
        let value = Double(delta) / (elapsed * 1_000_000_000) * 100
        guard value >= minimumVisiblePercent, value <= 10_000 else { return nil }
        return value
    }

    public static func format(_ percent: Double) -> String {
        String(format: "%.1f%%", percent)
    }

    /// 第一次见到某个 PID 时百分比为空。间隔太短则保留上一次的百分比和基线。
    public static func annotate(
        _ processes: [ProcessMemoryInfo],
        history: [Int32: ProcessCPUSample],
        now: Date
    ) -> (processes: [ProcessMemoryInfo], history: [Int32: ProcessCPUSample]) {
        var next: [Int32: ProcessCPUSample] = [:]
        next.reserveCapacity(processes.count)
        let updated = processes.map { process -> ProcessMemoryInfo in
            let previous = history[process.pid]
            let elapsed = previous.map { now.timeIntervalSince($0.capturedAt) } ?? 0
            let percent: Double?
            let stored: ProcessCPUSample
            if let previous, elapsed < minimumInterval {
                percent = previous.percent
                stored = previous
            } else if let previous {
                percent = Self.percent(
                    currentNanoseconds: process.cpuTimeNanoseconds,
                    previousNanoseconds: previous.nanoseconds,
                    elapsed: elapsed
                )
                stored = ProcessCPUSample(
                    nanoseconds: process.cpuTimeNanoseconds,
                    capturedAt: now,
                    percent: percent
                )
            } else {
                percent = nil
                stored = ProcessCPUSample(
                    nanoseconds: process.cpuTimeNanoseconds,
                    capturedAt: now,
                    percent: nil
                )
            }
            next[process.pid] = stored
            return process.settingCPUPercent(percent)
        }
        return (updated, next)
    }
}

public enum ProcessListSort: String, Sendable, Equatable {
    case memory
    case cpu
    case name
}

public struct ProcessAppGroup: Identifiable, Hashable, Sendable {
    public let id: String
    public let bundlePath: String?
    public let processes: [ProcessMemoryInfo]

    public var displayName: String {
        processes.first?.displayName ?? ""
    }

    public var memoryBytes: UInt64 {
        processes.reduce(0) { $0 + $1.memoryBytes }
    }

    /// 组内有读数才相加。全都还没有第二次采样时保持空白。
    public var cpuPercent: Double? {
        let values = processes.compactMap(\.cpuPercent)
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +)
    }

    public var isStopped: Bool {
        !processes.isEmpty && processes.allSatisfy(\.isStopped)
    }

    /// 点组头时操作主进程。没有主进程就用组里的第一个。
    public var primaryProcess: ProcessMemoryInfo? {
        processes.first(where: MemoryService.isApplicationMainProcess) ?? processes.first
    }
}

public enum ProcessListOrganizer {
    public static func sorted(_ processes: [ProcessMemoryInfo], by sort: ProcessListSort) -> [ProcessMemoryInfo] {
        processes.sorted { isBefore($0, $1, sort: sort) }
    }

    /// 有外层 .app 的收成一组；没有的各自成行。组内和组间用同一个排序。
    public static func groups(from processes: [ProcessMemoryInfo], sort: ProcessListSort) -> [ProcessAppGroup] {
        var buckets: [String: [ProcessMemoryInfo]] = [:]
        var order: [String] = []
        for process in processes {
            let key = process.applicationBundlePath ?? "pid:\(process.pid)"
            if buckets[key] == nil {
                order.append(key)
            }
            buckets[key, default: []].append(process)
        }
        let grouped = order.compactMap { key -> ProcessAppGroup? in
            guard let members = buckets[key], !members.isEmpty else { return nil }
            return ProcessAppGroup(
                id: key,
                bundlePath: members[0].applicationBundlePath,
                processes: sorted(members, by: sort)
            )
        }
        return grouped.sorted { isBeforeGroup($0, $1, sort: sort) }
    }

    static func isBefore(_ lhs: ProcessMemoryInfo, _ rhs: ProcessMemoryInfo, sort: ProcessListSort) -> Bool {
        switch sort {
        case .memory:
            return MemoryService.isHigherMemoryUsage(lhs, rhs)
        case .cpu:
            let left = lhs.cpuPercent ?? -1
            let right = rhs.cpuPercent ?? -1
            if left != right { return left > right }
            return MemoryService.isHigherMemoryUsage(lhs, rhs)
        case .name:
            let order = lhs.displayName.localizedStandardCompare(rhs.displayName)
            if order != .orderedSame { return order == .orderedAscending }
            return lhs.pid < rhs.pid
        }
    }

    static func isBeforeGroup(_ lhs: ProcessAppGroup, _ rhs: ProcessAppGroup, sort: ProcessListSort) -> Bool {
        switch sort {
        case .memory:
            if lhs.memoryBytes != rhs.memoryBytes { return lhs.memoryBytes > rhs.memoryBytes }
        case .cpu:
            let left = lhs.cpuPercent ?? -1
            let right = rhs.cpuPercent ?? -1
            if left != right { return left > right }
            if lhs.memoryBytes != rhs.memoryBytes { return lhs.memoryBytes > rhs.memoryBytes }
        case .name:
            let order = lhs.displayName.localizedStandardCompare(rhs.displayName)
            if order != .orderedSame { return order == .orderedAscending }
        }
        return lhs.id < rhs.id
    }
}

public enum ProcessArrival {
    /// 第一次采样不算「新出现」，否则整表都会亮一下。
    public static func freshPIDs(previous: Set<Int32>?, current: [Int32]) -> Set<Int32> {
        guard let previous else { return [] }
        return Set(current).subtracting(previous)
    }
}

public enum ProcessArguments {
    /// `KERN_PROCARGS2`：开头是 argc，接着是可执行路径，空字节对齐后再是 argv。
    public static func parse(_ buffer: [UInt8]) -> [String] {
        guard buffer.count >= MemoryLayout<Int32>.size else { return [] }
        let argc = buffer.withUnsafeBytes { raw in
            Int(raw.load(as: Int32.self))
        }
        guard argc > 0, argc < 4096 else { return [] }
        var offset = MemoryLayout<Int32>.size

        func readString() -> String? {
            guard offset < buffer.count else { return nil }
            let start = offset
            while offset < buffer.count, buffer[offset] != 0 {
                offset += 1
            }
            let bytes = buffer[start..<offset]
            if offset < buffer.count { offset += 1 }
            guard !bytes.isEmpty else { return "" }
            return String(bytes: bytes, encoding: .utf8) ?? ""
        }

        _ = readString()
        while offset < buffer.count, buffer[offset] == 0 {
            offset += 1
        }
        var arguments: [String] = []
        arguments.reserveCapacity(argc)
        for _ in 0..<argc {
            guard let argument = readString() else { break }
            arguments.append(argument)
            if offset >= buffer.count { break }
        }
        return arguments
    }

    public static func commandLine(_ arguments: [String]) -> String {
        arguments.map { argument in
            argument.contains(where: \.isWhitespace) ? "\"\(argument)\"" : argument
        }
        .joined(separator: " ")
    }

    /// 短名字放得下、又不是 Helper 时，不必为了窗口备注去读整段参数和环境。
    public static func shouldReadCommandTitle(executablePath: String, shortName: String) -> Bool {
        if shortName.utf8.count >= 31 { return true }
        let base = ProcessDisplayNameResolver.executableName(executablePath)
        if shortName.compare(base, options: [.caseInsensitive, .diacriticInsensitive]) != .orderedSame {
            return true
        }
        let path = executablePath.lowercased()
        if path.contains("helper") { return true }
        if path.contains(".app/contents/frameworks/") { return true }
        return false
    }

    public static func listTitle(executablePath: String, shortName: String, arguments: [String]?) -> String {
        if shouldReadCommandTitle(executablePath: executablePath, shortName: shortName),
           let first = arguments?.first,
           !first.isEmpty {
            return first
        }
        if !shortName.isEmpty { return shortName }
        if let first = arguments?.first, !first.isEmpty { return first }
        return executablePath
    }

    public static func read(pid: Int32) -> [String]? {
        guard pid > 0 else { return nil }
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0, size > 0 else { return nil }
        // 参数区后面跟着整个环境。设个上限，避免异常进程把刷新拖住。
        let capped = min(size, 1_048_576)
        var buffer = [UInt8](repeating: 0, count: capped)
        var written = capped
        let status = buffer.withUnsafeMutableBytes { raw in
            sysctl(&mib, u_int(mib.count), raw.baseAddress, &written, nil, 0)
        }
        guard status == 0, written > 0 else { return nil }
        return parse(Array(buffer.prefix(written)))
    }
}
