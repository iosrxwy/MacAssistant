import Foundation

/// IPA 与设备已装应用的版本关系。比较优先用 CFBundleVersion（iOS 安装检查看这个）。
public enum AppVersionRelation: String, Equatable, Sendable {
    case fresh
    case upgrade
    case same
    case downgrade
    case unknown
}

public enum AppDowngradeStrategy: Equatable, Sendable {
    /// 提高 CFBundleVersion 后覆盖安装，应用数据容器保留。改 plist 后需要重签。
    case keepData(signMethod: SignMethod)
    /// 先卸载再安装，应用数据丢失。
    case uninstallFirst
}

public struct IpaIdentity: Equatable, Sendable {
    public var appName: String
    public var bundleIdentifier: String
    public var executableName: String
    public var shortVersion: String?
    public var buildVersion: String?

    public init(
        appName: String,
        bundleIdentifier: String,
        executableName: String,
        shortVersion: String? = nil,
        buildVersion: String? = nil
    ) {
        self.appName = appName
        self.bundleIdentifier = bundleIdentifier
        self.executableName = executableName
        self.shortVersion = shortVersion
        self.buildVersion = buildVersion
    }

    public var versionLabel: String {
        AppVersionOrdering.label(short: shortVersion, build: buildVersion)
    }
}

public struct AppInstallPlan: Equatable, Sendable {
    public var identity: IpaIdentity
    public var installed: InstalledApp?
    public var relation: AppVersionRelation

    public init(identity: IpaIdentity, installed: InstalledApp?, relation: AppVersionRelation) {
        self.identity = identity
        self.installed = installed
        self.relation = relation
    }

    public var requiresReplaceConfirmation: Bool { relation == .downgrade }

    public var installedBuild: String? { installed?.version }

    public static func make(identity: IpaIdentity, installed: InstalledApp?) -> AppInstallPlan {
        AppInstallPlan(
            identity: identity,
            installed: installed,
            relation: AppVersionOrdering.relation(
                ipaShort: identity.shortVersion,
                ipaBuild: identity.buildVersion,
                installed: installed
            )
        )
    }
}

public enum AppVersionOrdering {
    public static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let left = components(lhs)
        let right = components(rhs)
        let count = max(left.count, right.count)
        for index in 0..<count {
            let a = index < left.count ? left[index] : 0
            let b = index < right.count ? right[index] : 0
            if a < b { return .orderedAscending }
            if a > b { return .orderedDescending }
        }
        return .orderedSame
    }

    public static func relation(
        ipaShort: String?,
        ipaBuild: String?,
        installed: InstalledApp?
    ) -> AppVersionRelation {
        guard let installed else { return .fresh }
        if let ipaBuild, let deviceBuild = installed.version,
           !ipaBuild.isEmpty, !deviceBuild.isEmpty {
            return relation(compare(ipaBuild, deviceBuild))
        }
        if let ipaShort, let deviceShort = installed.shortVersion,
           !ipaShort.isEmpty, !deviceShort.isEmpty {
            return relation(compare(ipaShort, deviceShort))
        }
        let ipa = firstNonEmpty(ipaBuild, ipaShort)
        let device = firstNonEmpty(installed.version, installed.shortVersion)
        guard let ipa, let device else { return .unknown }
        return relation(compare(ipa, device))
    }

    public static func label(short: String?, build: String?) -> String {
        switch (firstNonEmpty(short), firstNonEmpty(build)) {
        case let (short?, build?) where short != build:
            return "\(short) (\(build))"
        case let (short?, _):
            return short
        case let (_, build?):
            return build
        default:
            return "—"
        }
    }

    private static func relation(_ result: ComparisonResult) -> AppVersionRelation {
        switch result {
        case .orderedAscending: return .downgrade
        case .orderedSame: return .same
        case .orderedDescending: return .upgrade
        }
    }

    private static func components(_ value: String) -> [Int] {
        value.split(whereSeparator: { $0 == "." || $0 == "-" }).map { part in
            Int(part.prefix { $0.isNumber }) ?? 0
        }
    }

    private static func firstNonEmpty(_ values: String?...) -> String? {
        for value in values {
            guard let value else { continue }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }

    /// 生成一个比已装 Build 更高的 CFBundleVersion，让 iOS 把旧包当升级覆盖。
    public static func buildNumberAbove(_ installed: String) -> String {
        let trimmed = installed.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "2" }
        let parts = components(trimmed)
        guard !parts.isEmpty else { return trimmed + ".1" }
        var bumped = parts
        bumped[bumped.count - 1] += 1
        let candidate = bumped.map(String.init).joined(separator: ".")
        if compare(candidate, trimmed) == .orderedDescending {
            return candidate
        }
        return trimmed + ".1"
    }

    public static func buildNumberForInPlaceDowngrade(ipaBuild: String?, installedBuild: String?) -> String {
        var candidate = buildNumberAbove(firstNonEmpty(installedBuild, ipaBuild) ?? "1")
        if let ipaBuild, !ipaBuild.isEmpty, compare(candidate, ipaBuild) != .orderedDescending {
            candidate = buildNumberAbove(ipaBuild)
        }
        if let installedBuild, !installedBuild.isEmpty, compare(candidate, installedBuild) != .orderedDescending {
            candidate = buildNumberAbove(installedBuild)
        }
        return candidate
    }
}
