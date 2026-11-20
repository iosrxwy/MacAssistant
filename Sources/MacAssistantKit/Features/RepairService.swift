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
/// 批量删除本地快照时留下和删掉的日期。日期相同的快照会一起留下。
public struct SnapshotRetentionPlan: Equatable, Sendable {
    public let keptDates: Set<String>
    public let removableDates: [String]
}

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

    public static let flushDNSCommand = NetworkService.flushDNSCommand

    @discardableResult
    public static func flushDNS() throws -> CommandResult {
        try NetworkService.flushDNS()
    }

    // MARK: - 5. 查端口 -> 杀进程

    public static func processes(onPort port: Int) -> [PortProcess] {
        NetworkService.processes(onPort: port)
    }

    public static func killCommand(pids: [String], force: Bool) -> String {
        NetworkService.killCommand(pids: pids, force: force)
    }

    @discardableResult
    public static func kill(pids: [String], force: Bool) throws -> CommandResult {
        try NetworkService.kill(pids: pids, force: force)
    }

    // MARK: - Docker / Time Machine（系统清理页调用）

    /// 不带 `-a` 和 `--volumes`：不删未使用的镜像，也不删数据卷。
    public static let dockerPruneCommand = "docker system prune -f"

    @discardableResult
    public static func dockerPrune() throws -> CommandResult {
        try Shell.script(dockerPruneCommand)
    }

    /// 解析 `docker system df --format '{{json .}}'` 各行的 Reclaimable。
    public static func dockerReclaimableBytes(from dfOutput: String) -> Int64 {
        dockerReclaimableBytes(from: dfOutput, types: nil)
    }

    /// 这次 prune 实际会碰到的两类：停止的容器和构建缓存。镜像与数据卷不计入。
    public static func dockerPruneReclaimableBytes(from dfOutput: String) -> Int64 {
        dockerReclaimableBytes(from: dfOutput, types: ["Containers", "Build Cache"])
    }

    private static func dockerReclaimableBytes(from dfOutput: String, types: Set<String>?) -> Int64 {
        dfOutput.split(separator: "\n").reduce(0) { total, line in
            guard let data = String(line).data(using: .utf8),
                  let row = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let text = row["Reclaimable"] as? String
            else {
                return total
            }
            if let types {
                guard let type = row["Type"] as? String, types.contains(type) else { return total }
            }
            return total + parseDockerSize(text)
        }
    }

    public static func queryDockerReclaimable() -> Int64? {
        guard let docker = Shell.which("docker") else { return nil }
        guard let result = try? Shell.run(docker, ["system", "df", "--format", "{{json .}}"]),
              result.succeeded
        else {
            return nil
        }
        return dockerPruneReclaimableBytes(from: result.stdout)
    }

    /// 解析 Docker 的 "1.23GB (45%)" 字符串。
    public static func parseDockerSize(_ text: String) -> Int64 {
        let scanner = Scanner(string: text)
        guard let value = scanner.scanDouble() else { return 0 }
        let unit = scanner.scanCharacters(from: .letters)?.uppercased() ?? "B"
        let multiplier: Double
        switch unit {
        case "KB": multiplier = 1_000
        case "MB": multiplier = 1_000_000
        case "GB": multiplier = 1_000_000_000
        case "TB": multiplier = 1_000_000_000_000
        default: multiplier = 1
        }
        return Int64(value * multiplier)
    }

    // MARK: - Time Machine 本地快照

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

    /// 保留最新一张，以及名称以 `.backup` 结尾的上次备份。同一日期会一起留下，因为删日期会删掉该时刻的全部快照。
    public static func retentionPlan(for snapshots: [SnapshotEntry]) -> SnapshotRetentionPlan {
        let ordered = snapshots.sorted { lhs, rhs in
            if lhs.date != rhs.date { return lhs.date < rhs.date }
            return lhs.name < rhs.name
        }
        var kept = Set<String>()
        if let newest = ordered.last {
            kept.insert(newest.date)
        }
        if let backup = ordered.last(where: { $0.name.hasSuffix(".backup") }) {
            kept.insert(backup.date)
        }
        var seen = Set<String>()
        var removable: [String] = []
        for entry in ordered where !kept.contains(entry.date) {
            if seen.insert(entry.date).inserted {
                removable.append(entry.date)
            }
        }
        return SnapshotRetentionPlan(keptDates: kept, removableDates: removable)
    }

    public static func thinSnapshotsPreview(for snapshots: [SnapshotEntry]) -> String {
        if snapshots.isEmpty {
            return L("cleanup.snapshots.preview.policy")
        }
        let removable = retentionPlan(for: snapshots).removableDates
        if removable.isEmpty {
            return L("cleanup.snapshots.preview.none")
        }
        return removable.map { "tmutil deletelocalsnapshots \($0)" }.joined(separator: "\n")
    }

    @discardableResult
    public static func thinSnapshots() throws -> CommandResult {
        let dates = retentionPlan(for: localSnapshots()).removableDates
        guard !dates.isEmpty else {
            return CommandResult(exitCode: 0, stdout: L("cleanup.snapshots.none-removable"), stderr: "")
        }
        let commands = try dates.map { date in
            try AdminRunner.PrivilegedCommand(
                executable: "/usr/bin/tmutil",
                arguments: ["deletelocalsnapshots", validatedSnapshotDate(date)]
            )
        }
        return try AdminRunner.runSequence(commands)
    }

    private static func validatedSnapshotDate(_ date: String) throws -> String {
        guard date.range(of: #"^\d{4}-\d{2}-\d{2}-\d{6}$"#, options: .regularExpression) != nil else {
            throw NSError(domain: "RepairService", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: L("repair.error.invalid-snapshot-date")])
        }
        return date
    }

    @discardableResult
    public static func deleteSnapshot(date: String) throws -> CommandResult {
        try AdminRunner.run(
            executable: "/usr/bin/tmutil",
            arguments: ["deletelocalsnapshots", validatedSnapshotDate(date)]
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
