import Foundation

/// 占用某端口的进程。
public struct PortProcess: Identifiable, Sendable, Hashable {
    public let id = UUID()
    public let pid: String
    public let command: String
    public init(pid: String, command: String) {
        self.pid = pid
        self.command = command
    }
}

/// 一条 Time Machine 本地快照。
public struct SnapshotEntry: Identifiable, Sendable, Hashable {
    public let id = UUID()
    public let name: String     // 完整快照名
    public let date: String     // 供 deletelocalsnapshots 使用的日期串
    public init(name: String, date: String) {
        self.name = name
        self.date = date
    }
}

public struct GatekeeperActionPlan: Sendable, Equatable {
    public let diagnosticExecutables: [String]
    public let diagnosticArguments: [[String]]
    public let commandPreview: String
    public let settingsURL: String
    public let guidance: String
}

/// 「App 修复 / 签名与隔离」页面背后的一键操作实现。
/// 纯命令构造函数与解析函数便于单元测试;执行函数在需要时自动通过系统授权框提权。
public enum RepairService {

    /// 跳转「系统设置 > 隐私与安全性」的深层链接。
    public static let privacySecurityURL = "x-apple.systempreferences:com.apple.preference.security?Privacy"

    // MARK: - 通用工具

    /// 用单引号安全包裹路径,防止空格/特殊字符注入。
    public static func shellQuote(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// 判断命令输出是否因权限不足而失败(用于决定是否提权重试)。
    private static func needsPrivilege(_ result: CommandResult) -> Bool {
        if result.succeeded { return false }
        let text = (result.stdout + result.stderr).lowercased()
        return text.contains("operation not permitted")
            || text.contains("permission denied")
            || text.contains("not permitted")
            || text.contains("eperm")
    }

    // MARK: - 1. 去隔离 / 修复「App 已损坏」

    public static func dequarantineCommand(appPath: String, fullReset: Bool) -> String {
        let q = shellQuote(appPath)
        if fullReset {
            return "xattr -cr \(q)"
        }
        return "xattr -rd com.apple.quarantine \(q); xattr -rd com.apple.provenance \(q)"
    }

    /// 去除隔离属性。先尝试普通权限,失败(权限不足)再走系统授权框。
    @discardableResult
    public static func removeQuarantine(app: URL, fullReset: Bool) throws -> CommandResult {
        let cmd = dequarantineCommand(appPath: app.path, fullReset: fullReset)
        let local = try Shell.script(cmd)
        if needsPrivilege(local) {
            if fullReset {
                return try AdminRunner.run(executable: "/usr/bin/xattr", arguments: ["-cr", app.path])
            }
            return try AdminRunner.runSequence([
                try AdminRunner.PrivilegedCommand(
                    executable: "/usr/bin/xattr",
                    arguments: ["-rd", "com.apple.quarantine", app.path]
                ),
                try AdminRunner.PrivilegedCommand(
                    executable: "/usr/bin/xattr",
                    arguments: ["-rd", "com.apple.provenance", app.path]
                )
            ])
        }
        return local
    }

    // MARK: - 2. ad-hoc 重签名(失败回退逐层)

    public static func resignCommandPreview(appPath: String, removeSignatureFirst: Bool) -> String {
        let q = shellQuote(appPath)
        var lines: [String] = []
        if removeSignatureFirst { lines.append("codesign --remove-signature \(q)") }
        lines.append("# " + L("repair.resign.preview.layered"))
        lines.append("codesign --force --sign - <\(L("repair.resign.preview.inner-component"))>")
        lines.append("codesign --force --sign - \(q)")
        lines.append("codesign --verify --strict --verbose=4 \(q)")
        return lines.joined(separator: "\n")
    }

    /// ad-hoc 重签名：由内向外逐层签名；`--deep` 不用于签名。
    public static func adhocResign(app: URL, removeSignatureFirst: Bool) throws -> (result: CommandResult, usedLayered: Bool) {
        if removeSignatureFirst {
            let removal = try BinaryService.removeSignature(fileAt: app)
            guard removal.succeeded else {
                throw NSError(domain: "RepairService", code: Int(removal.exitCode),
                              userInfo: [NSLocalizedDescriptionKey: removal.combinedOutput])
            }
        }
        let inner = FileSystemHelper.allFiles(in: app) { MachOIdentifier.isMachO(fileAt: $0) }
            .sorted { $0.pathComponents.count > $1.pathComponents.count }
        for file in inner {
            let result = try BinaryService.adhocSign(fileAt: file)
            guard result.succeeded else {
                throw NSError(domain: "RepairService", code: Int(result.exitCode),
                              userInfo: [NSLocalizedDescriptionKey: L("repair.error.sign-failed", file.lastPathComponent, result.combinedOutput)])
            }
        }
        let final = try BinaryService.adhocSign(fileAt: app)
        guard final.succeeded else {
            throw NSError(domain: "RepairService", code: Int(final.exitCode),
                          userInfo: [NSLocalizedDescriptionKey: final.combinedOutput])
        }
        let verify = try ExternalTool.codesign.run(["--verify", "--strict", "--verbose=4", app.path])
        guard verify.succeeded else {
            throw NSError(domain: "RepairService", code: Int(verify.exitCode),
                          userInfo: [NSLocalizedDescriptionKey: L("repair.error.verify-failed", verify.combinedOutput)])
        }
        return (verify, true)
    }

    // MARK: - 3. Gatekeeper 只读诊断与官方覆盖流程

    public static func gatekeeperPlan(
        appPath: String,
        macOSMajorVersion: Int = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
    ) -> GatekeeperActionPlan {
        let executables = ["/usr/bin/codesign", "/usr/sbin/spctl", "/usr/bin/xattr"]
        let arguments = [
            ["-dv", "--verbose=4", appPath],
            ["--assess", "--type", "execute", "--verbose=4", appPath],
            ["-lr", appPath]
        ]
        let preview = zip(executables, arguments).map { pair in
            ([pair.0] + pair.1).map(shellQuote).joined(separator: " ")
        }.joined(separator: "\n")
        let versionText = macOSMajorVersion >= 15 ? "macOS \(macOSMajorVersion)" : L("repair.gatekeeper.current-macos")
        return GatekeeperActionPlan(
            diagnosticExecutables: executables,
            diagnosticArguments: arguments,
            commandPreview: preview,
            settingsURL: privacySecurityURL,
            guidance: L("repair.gatekeeper.guidance", versionText)
        )
    }

    // MARK: - 4. 刷新 DNS

    public static let flushDNSCommand = "sudo dscacheutil -flushcache; sudo killall -HUP mDNSResponder"

    @discardableResult
    public static func flushDNS() throws -> CommandResult {
        try AdminRunner.runSequence([
            try AdminRunner.PrivilegedCommand(
                executable: "/usr/bin/dscacheutil",
                arguments: ["-flushcache"]
            ),
            try AdminRunner.PrivilegedCommand(
                executable: "/usr/bin/killall",
                arguments: ["-HUP", "mDNSResponder"]
            )
        ])
    }

    // MARK: - 5. 查端口 -> 杀进程

    /// 列出占用某端口的进程(基于 lsof)。
    public static func processes(onPort port: Int) -> [PortProcess] {
        guard port > 0, port <= 65535 else { return [] }
        guard let r = try? Shell.run("/usr/sbin/lsof", ["-nP", "-i", ":\(port)"]) else { return [] }
        var seen = Set<String>()
        var result: [PortProcess] = []
        for line in r.stdout.split(separator: "\n").dropFirst() {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard parts.count >= 2 else { continue }
            if seen.insert(parts[1]).inserted {
                result.append(PortProcess(pid: parts[1], command: parts[0]))
            }
        }
        return result
    }

    public static func killCommand(pids: [String], force: Bool) -> String {
        "kill \(force ? "-9" : "-15") \(pids.joined(separator: " "))"
    }

    @discardableResult
    public static func kill(pids: [String], force: Bool) throws -> CommandResult {
        let validated = pids.compactMap(Int32.init)
        guard validated.count == pids.count, validated.allSatisfy({ $0 > 1 }) else {
            throw NSError(domain: "RepairService", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: L("repair.error.invalid-pid-list")])
        }
        guard !validated.isEmpty else {
            return CommandResult(exitCode: 0, stdout: L("repair.kill.no-process"), stderr: "")
        }
        let arguments = [force ? "-9" : "-15"] + validated.map(String.init)
        let local = try Shell.run("/bin/kill", arguments)
        if needsPrivilege(local) {
            return try AdminRunner.run(executable: "/bin/kill", arguments: arguments)
        }
        return local
    }

    // MARK: - 7. 清理开发缓存

    /// 开发相关的可清理目标(Xcode / brew / npm·pip 等,用户级、无需 sudo)。
    public static func devCacheTargets() -> [CleanupTarget] {
        let ids: Set<String> = ["xcode-derived", "xcode-devicesupport", "simulator-caches",
                                 "homebrew", "npm", "yarn", "pip", "cocoapods", "gradle"]
        return CleanupService.makeTargets().filter { ids.contains($0.id) }
    }

    public static let dockerPruneCommand = "docker system prune -a --volumes -f"

    @discardableResult
    public static func dockerPrune() throws -> CommandResult {
        try Shell.script(dockerPruneCommand)
    }

    // MARK: - 8. Time Machine 本地快照

    /// 从快照名(com.apple.TimeMachine.2026-01-07-221601.local)提取日期串。
    public static func parseSnapshotDate(_ name: String) -> String? {
        guard let range = name.range(of: #"\d{4}-\d{2}-\d{2}-\d{6}"#, options: .regularExpression) else {
            return nil
        }
        return String(name[range])
    }

    public static func localSnapshots() -> [SnapshotEntry] {
        guard let r = try? Shell.run("/usr/bin/tmutil", ["listlocalsnapshots", "/"]) else { return [] }
        return r.stdout.split(separator: "\n").compactMap { line in
            let name = line.trimmingCharacters(in: .whitespaces)
            guard let date = parseSnapshotDate(name) else { return nil }
            return SnapshotEntry(name: name, date: date)
        }
    }

    public static let thinSnapshotsCommand = "sudo tmutil thinlocalsnapshots / 999999999999 4"

    @discardableResult
    public static func thinSnapshots() throws -> CommandResult {
        try AdminRunner.run(
            executable: "/usr/bin/tmutil",
            arguments: ["thinlocalsnapshots", "/", "999999999999", "4"]
        )
    }

    @discardableResult
    public static func deleteSnapshot(date: String) throws -> CommandResult {
        guard date.range(of: #"^\d{4}-\d{2}-\d{2}-\d{6}$"#, options: .regularExpression) != nil else {
            throw NSError(domain: "RepairService", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: L("repair.error.invalid-snapshot-date")])
        }
        return try AdminRunner.run(
            executable: "/usr/bin/tmutil",
            arguments: ["deletelocalsnapshots", date]
        )
    }

    // MARK: - 9. 重启界面组件

    @discardableResult
    public static func restart(_ processName: String) throws -> CommandResult {
        try Shell.run("/usr/bin/killall", [processName])
    }

    // MARK: - 12. 安装 Rosetta 2

    public static let rosettaCommand = "softwareupdate --install-rosetta --agree-to-license"

    /// 运行时已存在即可确认装过;文件缺失不能反过来断定未安装,只用于给出「无需重复安装」提示。
    public static let rosettaRuntimePresent: Bool = FileManager.default.fileExists(
        atPath: "/Library/Apple/usr/libexec/oah/libRosettaRuntime"
    )

    @discardableResult
    public static func installRosetta() throws -> CommandResult {
        guard HostArchitecture.isAppleSiliconHardware else {
            throw NSError(domain: "RepairService", code: 1, userInfo: [
                NSLocalizedDescriptionKey: L("repair.error.rosetta-apple-silicon-only")
            ])
        }
        return try AdminRunner.run(
            executable: "/usr/sbin/softwareupdate",
            arguments: ["--install-rosetta", "--agree-to-license"]
        )
    }
}
