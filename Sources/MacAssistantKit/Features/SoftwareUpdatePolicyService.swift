import Foundation

/// macOS 系统「软件更新」自动检查 / 下载 / 安装的策略。
///
/// 只写 Apple 公开的 `com.apple.SoftwareUpdate` 偏好和 `softwareupdate --schedule`，
/// 不伪装系统版本、不改 hosts、不停 `softwareupdated`。
public struct SoftwareUpdatePolicy: Equatable, Sendable {
    public var automaticCheckEnabled: Bool
    public var automaticDownload: Bool
    public var automaticallyInstallMacOSUpdates: Bool
    public var configDataInstall: Bool
    public var criticalUpdateInstall: Bool
    /// 为 true 时才会动系统数据文件 / 安全更新那两项；默认关掉 macOS 升级即可。
    public var writeSecurityDataKeys: Bool
    /// 关掉自动更新时清空已缓存的“可用更新”列表，避免设置里还挂着红点。
    public var clearRecommendedUpdates: Bool

    public init(
        automaticCheckEnabled: Bool,
        automaticDownload: Bool,
        automaticallyInstallMacOSUpdates: Bool,
        configDataInstall: Bool = true,
        criticalUpdateInstall: Bool = true,
        writeSecurityDataKeys: Bool = false,
        clearRecommendedUpdates: Bool = false
    ) {
        self.automaticCheckEnabled = automaticCheckEnabled
        self.automaticDownload = automaticDownload
        self.automaticallyInstallMacOSUpdates = automaticallyInstallMacOSUpdates
        self.configDataInstall = configDataInstall
        self.criticalUpdateInstall = criticalUpdateInstall
        self.writeSecurityDataKeys = writeSecurityDataKeys
        self.clearRecommendedUpdates = clearRecommendedUpdates
    }

    /// 系统自动检查、下载、安装 macOS 更新都已关掉。
    public var suppressesAutomaticMacOSUpdates: Bool {
        !automaticCheckEnabled && !automaticDownload && !automaticallyInstallMacOSUpdates
    }

    /// 三项里有的开、有的关。
    public var isPartial: Bool {
        let flags = [automaticCheckEnabled, automaticDownload, automaticallyInstallMacOSUpdates]
        return flags.contains(true) && flags.contains(false)
    }

    public static let automatic = SoftwareUpdatePolicy(
        automaticCheckEnabled: true,
        automaticDownload: true,
        automaticallyInstallMacOSUpdates: true
    )

    public static func automatic(includingSecurityData: Bool) -> SoftwareUpdatePolicy {
        SoftwareUpdatePolicy(
            automaticCheckEnabled: true,
            automaticDownload: true,
            automaticallyInstallMacOSUpdates: true,
            configDataInstall: true,
            criticalUpdateInstall: true,
            writeSecurityDataKeys: includingSecurityData
        )
    }

    public static let suppressed = SoftwareUpdatePolicy(
        automaticCheckEnabled: false,
        automaticDownload: false,
        automaticallyInstallMacOSUpdates: false,
        clearRecommendedUpdates: true
    )

    public static func suppressed(includingSecurityData: Bool) -> SoftwareUpdatePolicy {
        SoftwareUpdatePolicy(
            automaticCheckEnabled: false,
            automaticDownload: false,
            automaticallyInstallMacOSUpdates: false,
            configDataInstall: !includingSecurityData,
            criticalUpdateInstall: !includingSecurityData,
            writeSecurityDataKeys: includingSecurityData,
            clearRecommendedUpdates: true
        )
    }
}

public enum SoftwareUpdatePolicyError: LocalizedError, Equatable {
    case unsupportedKey(String)

    public var errorDescription: String? {
        switch self {
        case let .unsupportedKey(key):
            return L("softwareupdate.error.unsupportedKey", key)
        }
    }
}

/// 读写系统 Software Update 偏好。读不必提权；写走 `AdminRunner` 白名单。
public enum SoftwareUpdatePolicyService {
    public static let domainPath = "/Library/Preferences/com.apple.SoftwareUpdate"
    public static let plistURL = URL(fileURLWithPath: domainPath + ".plist")

    public static let writableKeys: Set<String> = [
        "AutomaticCheckEnabled",
        "AutomaticDownload",
        "AutomaticallyInstallMacOSUpdates",
        "ConfigDataInstall",
        "CriticalUpdateInstall",
        "RecommendedUpdates"
    ]

    /// Ventura+ 的「系统设置 → 通用 → 软件更新」，旧版作后备。
    public static let settingsURLs = [
        "x-apple.systempreferences:com.apple.Software-Update-Settings.extension",
        "x-apple.systempreferences:com.apple.preferences.softwareupdate"
    ]

    public static func policy(from plist: [String: Any]) -> SoftwareUpdatePolicy {
        SoftwareUpdatePolicy(
            automaticCheckEnabled: bool(plist["AutomaticCheckEnabled"], default: true),
            automaticDownload: bool(plist["AutomaticDownload"], default: true),
            automaticallyInstallMacOSUpdates: bool(plist["AutomaticallyInstallMacOSUpdates"], default: true),
            configDataInstall: bool(plist["ConfigDataInstall"], default: true),
            criticalUpdateInstall: bool(plist["CriticalUpdateInstall"], default: true)
        )
    }

    /// 读不到 plist 时按苹果默认（自动更新开着）处理，不把权限不足伪装成「已关闭」。
    public static func read(from plist: [String: Any]? = nil) -> SoftwareUpdatePolicy {
        if let plist {
            return policy(from: plist)
        }
        guard let values = NSDictionary(contentsOf: plistURL) as? [String: Any] else {
            return .automatic
        }
        return policy(from: values)
    }

    public static func shellLines(for policy: SoftwareUpdatePolicy) -> [String] {
        var lines = [
            "softwareupdate --schedule \(policy.automaticCheckEnabled ? "on" : "off")",
            defaultsWriteBoolLine("AutomaticCheckEnabled", policy.automaticCheckEnabled),
            defaultsWriteBoolLine("AutomaticDownload", policy.automaticDownload),
            defaultsWriteBoolLine("AutomaticallyInstallMacOSUpdates", policy.automaticallyInstallMacOSUpdates)
        ]
        if policy.writeSecurityDataKeys {
            lines.append(defaultsWriteBoolLine("ConfigDataInstall", policy.configDataInstall))
            lines.append(defaultsWriteBoolLine("CriticalUpdateInstall", policy.criticalUpdateInstall))
        }
        if policy.clearRecommendedUpdates {
            lines.append("defaults write \(domainPath) RecommendedUpdates -array")
        }
        return lines
    }

    public static func commandPreview(
        _ policy: SoftwareUpdatePolicy,
        includeSudo: Bool = true
    ) -> String {
        let lines = shellLines(for: policy)
        if includeSudo {
            return lines.map { "sudo \($0)" }.joined(separator: "\n")
        }
        return lines.joined(separator: "\n")
    }

    public static func privilegedCommands(
        for policy: SoftwareUpdatePolicy
    ) throws -> [AdminRunner.PrivilegedCommand] {
        var commands = [
            try AdminRunner.PrivilegedCommand(
                executable: "/usr/sbin/softwareupdate",
                arguments: ["--schedule", policy.automaticCheckEnabled ? "on" : "off"]
            ),
            try defaultsWriteBool("AutomaticCheckEnabled", policy.automaticCheckEnabled),
            try defaultsWriteBool("AutomaticDownload", policy.automaticDownload),
            try defaultsWriteBool("AutomaticallyInstallMacOSUpdates", policy.automaticallyInstallMacOSUpdates)
        ]
        if policy.writeSecurityDataKeys {
            commands.append(try defaultsWriteBool("ConfigDataInstall", policy.configDataInstall))
            commands.append(try defaultsWriteBool("CriticalUpdateInstall", policy.criticalUpdateInstall))
        }
        if policy.clearRecommendedUpdates {
            commands.append(try defaultsWriteArray("RecommendedUpdates"))
        }
        return commands
    }

    @discardableResult
    public static func apply(_ policy: SoftwareUpdatePolicy) throws -> CommandResult {
        try AdminRunner.runSequence(try privilegedCommands(for: policy))
    }

    public static func defaultsWriteBool(_ key: String, _ value: Bool) throws -> AdminRunner.PrivilegedCommand {
        guard writableKeys.contains(key), key != "RecommendedUpdates" else {
            throw SoftwareUpdatePolicyError.unsupportedKey(key)
        }
        return try AdminRunner.PrivilegedCommand(
            executable: "/usr/bin/defaults",
            arguments: ["write", domainPath, key, "-bool", value ? "true" : "false"]
        )
    }

    public static func defaultsWriteArray(_ key: String) throws -> AdminRunner.PrivilegedCommand {
        guard key == "RecommendedUpdates" else {
            throw SoftwareUpdatePolicyError.unsupportedKey(key)
        }
        return try AdminRunner.PrivilegedCommand(
            executable: "/usr/bin/defaults",
            arguments: ["write", domainPath, key, "-array"]
        )
    }

    private static func defaultsWriteBoolLine(_ key: String, _ value: Bool) -> String {
        "defaults write \(domainPath) \(key) -bool \(value ? "true" : "false")"
    }

    public static func bool(_ value: Any?, default defaultValue: Bool) -> Bool {
        switch value {
        case let flag as Bool:
            return flag
        case let number as NSNumber:
            return number.boolValue
        case let text as String:
            switch text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "1", "true", "yes": return true
            case "0", "false", "no": return false
            default: return defaultValue
            }
        default:
            return defaultValue
        }
    }
}
