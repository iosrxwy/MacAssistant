import Foundation
import Darwin

/// 宿主机 CPU 架构。
///
/// 一律用运行时 sysctl 判定,不用编译期 `#if arch(...)`:通用二进制的 x86_64 切片经
/// Rosetta 跑在 Apple Silicon 上时,编译期宏会把机器误判成 Intel。
public enum HostArchitecture: String, Sendable, CaseIterable {
    case appleSilicon
    case intel

    public static var current: HostArchitecture {
        isAppleSiliconHardware ? .appleSilicon : .intel
    }

    /// 物理机是否为 Apple Silicon。Rosetta 转译下该标志仍为真;Intel 机上该 oid 不存在。
    public static var isAppleSiliconHardware: Bool {
        sysctlFlag("hw.optional.arm64")
    }

    /// 当前进程是否由 Rosetta 转译执行。
    public static var isTranslated: Bool {
        sysctlFlag("sysctl.proc_translated")
    }

    /// 当前进程实际执行的切片,可能与机器架构不同。
    public static var processSlice: String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return L("arch.slice.unknown")
        #endif
    }

    /// Homebrew 在该架构上的默认安装前缀。
    public var homebrewPrefix: String {
        switch self {
        case .appleSilicon: return "/opt/homebrew"
        case .intel: return "/usr/local"
        }
    }

    public var displayName: String {
        switch self {
        case .appleSilicon: return "Apple Silicon(arm64)"
        case .intel: return "Intel(x86_64)"
        }
    }

    /// 某命令在 Homebrew 下的候选绝对路径,本机架构前缀优先。
    /// 两种前缀必须都给出,少一种就会在另一类机器上出现「明明装了却找不到」。
    public static func homebrewBinaryPaths(_ name: String) -> [String] {
        let host = current
        return ([host] + allCases.filter { $0 != host })
            .map { "\($0.homebrewPrefix)/bin/\(name)" }
    }

    /// 供界面展示:机器架构,并在进程被转译时说明实际运行切片。
    public static var summary: String {
        let machine = current.displayName
        guard isTranslated else { return machine }
        return L("arch.summary.translated", machine, processSlice)
    }

    private static func sysctlFlag(_ key: String) -> Bool {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(key, &value, &size, nil, 0) == 0 else { return false }
        return value == 1
    }
}
