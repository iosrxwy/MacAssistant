import Foundation

/// 通过 macOS 系统授权框(osascript + administrator privileges)以 root 权限执行命令,
/// 避免在界面里明文收集密码——密码框由系统弹出。
public enum AdminRunner {
    public struct PrivilegedCommand: Sendable, Equatable {
        public let executable: String
        public let arguments: [String]

        public init(executable: String, arguments: [String] = []) throws {
            guard AdminRunner.allowedExecutables.contains(executable),
                  !arguments.contains(where: { $0.contains("\0") })
            else {
                throw AdminRunnerError.notAllowed(executable)
            }
        if executable == "/usr/bin/defaults" {
            guard AdminRunner.isAllowedDefaultsInvocation(arguments) else {
                throw AdminRunnerError.notAllowed(executable)
            }
        }
        if executable == "/usr/bin/pmset" {
            guard AdminRunner.isAllowedPmsetInvocation(arguments) else {
                throw AdminRunnerError.notAllowed(executable)
            }
        }
        self.executable = executable
        self.arguments = arguments
    }

        public var shellCommand: String {
            ([executable] + arguments).map(AdminRunner.shellQuote).joined(separator: " ")
        }
    }

    public static let allowedExecutables: Set<String> = [
        "/usr/bin/xattr", "/usr/bin/dscacheutil", "/usr/bin/killall", "/bin/kill",
        "/usr/bin/tmutil", "/usr/sbin/softwareupdate", "/usr/bin/purge", "/usr/bin/defaults",
        "/usr/bin/pmset"
    ]

    /// 只允许改系统 Software Update 这一份偏好，避免提权后 `defaults` 写到任意域。
    public static let allowedDefaultsDomains: Set<String> = [
        SoftwareUpdatePolicyService.domainPath
    ]

    /// 将命令转义为 AppleScript 字符串字面量内容(处理反斜杠与双引号)。
    /// 暴露为独立函数以便单元测试。
    public static func appleScriptEscape(_ command: String) -> String {
        command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// 生成实际交给 osascript 的 AppleScript 语句。
    /// `prompt` 会显示在系统授权框里，用来说明这次授权会维持到退出应用。
    public static func makeScript(for command: String, prompt: String? = nil) -> String {
        let commandText = appleScriptEscape(command)
        guard let prompt, !prompt.isEmpty else {
            return "do shell script \"\(commandText)\" with administrator privileges"
        }
        let promptText = appleScriptEscape(prompt)
        return "do shell script \"\(commandText)\" with prompt \"\(promptText)\" with administrator privileges"
    }

    public static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// 只允许给当前电源改能耗模式。0 自动，1 低电量，2 高电量。不能带其他参数。
    public static func isAllowedPmsetInvocation(_ arguments: [String]) -> Bool {
        arguments.count == 3
            && (arguments[0] == "-b" || arguments[0] == "-c")
            && arguments[1] == "powermode"
            && (arguments[2] == "0" || arguments[2] == "1" || arguments[2] == "2")
    }

    /// `defaults write|delete` 仅放行 Software Update 域里已知的键和固定参数形态。
    public static func isAllowedDefaultsInvocation(_ arguments: [String]) -> Bool {
        guard arguments.count >= 3 else { return false }
        let action = arguments[0]
        let domain = arguments[1]
        let key = arguments[2]
        guard allowedDefaultsDomains.contains(domain),
              SoftwareUpdatePolicyService.writableKeys.contains(key)
        else {
            return false
        }
        switch action {
        case "write" where key == "RecommendedUpdates":
            return arguments == ["write", domain, key, "-array"]
        case "write":
            return arguments.count == 5
                && arguments[3] == "-bool"
                && (arguments[4] == "true" || arguments[4] == "false")
        case "delete":
            return arguments.count == 3
        default:
            return false
        }
    }

    /// 以管理员权限执行 allowlist 中的可执行文件与参数数组。
    @discardableResult
    public static func run(executable: String, arguments: [String] = []) throws -> CommandResult {
        let command = try PrivilegedCommand(executable: executable, arguments: arguments)
        return try runSequence([command])
    }

    @discardableResult
    public static func runSequence(_ commands: [PrivilegedCommand]) throws -> CommandResult {
        guard !commands.isEmpty else { throw AdminRunnerError.emptyCommand }
        let command = commands.map(\.shellCommand).joined(separator: " && ")
        return try Shell.run("/usr/bin/osascript", ["-e", makeScript(for: command)])
    }

    /// 是否为用户取消授权导致的失败(-128)。
    public static func isCancelled(_ result: CommandResult) -> Bool {
        result.stderr.contains("-128") || result.stderr.contains("User canceled")
    }
}

public enum AdminRunnerError: LocalizedError {
    case notAllowed(String)
    case emptyCommand

    public var errorDescription: String? {
        switch self {
        case let .notAllowed(executable): return L("admin.error.notAllowed", executable)
        case .emptyCommand: return L("admin.error.emptyCommand")
        }
    }
}
