import Foundation

/// 一个 .deb 之所以不适合当「IPA 内插件」的原因。
///
/// 这些特征说明包的性质是「装进越狱设备根文件系统」而非「随 App 沙盒一起加载」,
/// 强行抽个 dylib 塞进 IPA 既不会按包作者意图运行,也可能把设备级行为带进用户不知情的 App。
public enum DebPluginBlockReason: String, Codable, Hashable, Sendable {
    /// 含 LaunchDaemons plist:随系统以 root 常驻,和 App 生命周期无关。
    case launchDaemon
    /// 含 LaunchAgents plist:随登录会话常驻,同样不属于 App 内加载。
    case launchAgent
    /// 含命令行工具(装到 bin/sbin 下的可执行文件)。
    case commandLineTool
    /// 含 setuid 位二进制:提权行为,不应进入 App 沙盒。
    case setuidBinary
    /// 含 setgid 位二进制。
    case setgidBinary
    /// 含内核扩展 / 设备级组件(.kext 等)。
    case kernelOrDeviceLevel
    /// 含维护脚本(preinst/postinst/prerm/postrm)。本应用永不执行它们,但其存在说明包
    /// 依赖安装期副作用,不是纯粹的 App 内加载单元。
    case maintainerScript
}

/// 一条判定依据。`detail` 是触发的具体路径/脚本名,`explanation` 是可展示的本地化说明。
public struct DebPluginBlockFactor: Identifiable, Codable, Hashable, Sendable {
    public var id: String { "\(reason.rawValue):\(detail)" }
    public let reason: DebPluginBlockReason
    public let detail: String
    public let explanation: String

    public init(reason: DebPluginBlockReason, detail: String, explanation: String) {
        self.reason = reason
        self.detail = detail
        self.explanation = explanation
    }
}

/// 一个 .deb 作为「IPA 内插件」的适用性结论。
///
/// 注意:这是**可复用的分类结果**,不是硬错误。同一个包在「DEB 打包/转换」页面仍是合法输入;
/// 只有当它被当作 IPA 内插件时,`isEligibleAsIpaPlugin == false` 才应阻止流程。
public struct DebPluginEligibility: Codable, Hashable, Sendable {
    public let isEligibleAsIpaPlugin: Bool
    public let factors: [DebPluginBlockFactor]

    public init(factors: [DebPluginBlockFactor]) {
        self.isEligibleAsIpaPlugin = factors.isEmpty
        self.factors = factors
    }

    /// 转成 preflight findings(不适用时为 blocker),便于并入现有预检报告。
    public var findings: [IpaPreflightFinding] {
        factors.map {
            IpaPreflightFinding(
                severity: .blocker,
                code: "deb.plugin.\($0.reason.rawValue)",
                message: $0.explanation
            )
        }
    }
}

/// 判断一个 .deb 是否适合当作 IPA 内插件。判定只看包的**结构与元数据**,绝不执行维护脚本。
public enum DebPluginEligibilityClassifier {

    /// 基于已解析的 data.tar 条目 + 存在的维护脚本清单判定(便于测试,无需落盘)。
    public static func classify(
        entries: [DebEntry],
        maintainerScripts: [DebMaintainerScript] = []
    ) -> DebPluginEligibility {
        var factors: [DebPluginBlockFactor] = []

        for entry in entries where !entry.isDirectory {
            let normalized = normalize(entry.path)

            if isLaunchDaemon(normalized) {
                factors.append(.init(
                    reason: .launchDaemon,
                    detail: entry.path,
                    explanation: L("deb.plugin.factor.launchDaemon", entry.path)
                ))
            } else if isLaunchAgent(normalized) {
                factors.append(.init(
                    reason: .launchAgent,
                    detail: entry.path,
                    explanation: L("deb.plugin.factor.launchAgent", entry.path)
                ))
            }

            if isCommandLineToolPath(normalized) {
                factors.append(.init(
                    reason: .commandLineTool,
                    detail: entry.path,
                    explanation: L("deb.plugin.factor.commandLineTool", entry.path)
                ))
            }

            if isKernelOrDeviceLevel(normalized) {
                factors.append(.init(
                    reason: .kernelOrDeviceLevel,
                    detail: entry.path,
                    explanation: L("deb.plugin.factor.kernelOrDeviceLevel", entry.path)
                ))
            }

            switch setuidState(of: entry.mode) {
            case .setuid:
                factors.append(.init(
                    reason: .setuidBinary,
                    detail: entry.path,
                    explanation: L("deb.plugin.factor.setuid", entry.path)
                ))
            case .setgid:
                factors.append(.init(
                    reason: .setgidBinary,
                    detail: entry.path,
                    explanation: L("deb.plugin.factor.setgid", entry.path)
                ))
            case .both:
                factors.append(.init(
                    reason: .setuidBinary,
                    detail: entry.path,
                    explanation: L("deb.plugin.factor.setuid", entry.path)
                ))
                factors.append(.init(
                    reason: .setgidBinary,
                    detail: entry.path,
                    explanation: L("deb.plugin.factor.setgid", entry.path)
                ))
            case .none:
                break
            }
        }

        for script in maintainerScripts {
            factors.append(.init(
                reason: .maintainerScript,
                detail: script.rawValue,
                explanation: L("deb.plugin.factor.maintainerScript", script.rawValue)
            ))
        }

        return DebPluginEligibility(factors: factors)
    }

    /// 便捷入口:扫描 .deb(含维护脚本存在性检测,但不执行它们)后判定。
    public static func classify(debAt url: URL) throws -> DebPluginEligibility {
        let info = try DebService.inspect(debAt: url)
        let scripts = (try? DebService.presentMaintainerScripts(debAt: url)) ?? []
        return classify(entries: info.entries, maintainerScripts: scripts)
    }

    // MARK: 路径与权限判定

    /// 去掉常见越狱布局前缀,让 var/jb/usr/bin 与 usr/bin 走同一套判定。
    private static func normalize(_ path: String) -> String {
        var value = path
        for prefix in ["./", "/"] where value.hasPrefix(prefix) {
            value = String(value.dropFirst(prefix.count))
        }
        for prefix in ["var/jb/", "var/LIB/"] where value.hasPrefix(prefix) {
            value = String(value.dropFirst(prefix.count))
        }
        // roothide 的随机 jbroot 目录:.jbroot-XXXX/ 之后才是真实布局。
        if let range = value.range(of: ".jbroot", options: .caseInsensitive),
           let slash = value[range.lowerBound...].firstIndex(of: "/") {
            value = String(value[value.index(after: slash)...])
        }
        return value
    }

    private static func isLaunchDaemon(_ path: String) -> Bool {
        path.contains("LaunchDaemons/") && path.hasSuffix(".plist")
    }

    private static func isLaunchAgent(_ path: String) -> Bool {
        path.contains("LaunchAgents/") && path.hasSuffix(".plist")
    }

    private static func isCommandLineToolPath(_ path: String) -> Bool {
        let toolDirectories = ["usr/bin/", "usr/sbin/", "usr/local/bin/", "usr/local/sbin/", "bin/", "sbin/"]
        return toolDirectories.contains { path.hasPrefix($0) }
    }

    private static func isKernelOrDeviceLevel(_ path: String) -> Bool {
        path.contains(".kext/")
            || path.hasSuffix(".kext")
            || path.hasPrefix("System/Library/Extensions/")
            || path.hasPrefix("Library/Extensions/")
    }

    private enum SetuidState { case none, setuid, setgid, both }

    /// 解析 `-rwsr-xr-x` 这类权限串:第 3 位为 s/S 表示 setuid,第 6 位为 s/S 表示 setgid。
    private static func setuidState(of mode: String?) -> SetuidState {
        guard let mode, mode.count >= 10 else { return .none }
        let chars = Array(mode)
        let hasSetuid = chars[3] == "s" || chars[3] == "S"
        let hasSetgid = chars[6] == "s" || chars[6] == "S"
        switch (hasSetuid, hasSetgid) {
        case (true, true): return .both
        case (true, false): return .setuid
        case (false, true): return .setgid
        case (false, false): return .none
        }
    }
}
