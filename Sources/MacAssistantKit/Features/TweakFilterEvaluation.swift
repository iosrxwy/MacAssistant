import Foundation

/// filter 的三态比对结论。刻意区分「不匹配(本机可判定为不该加载)」与「无法判定
/// (依赖运行时/设备状态)」,不把后者伪装成前者或直接当匹配。
public enum TweakFilterMatch: String, Codable, Hashable, Sendable {
    case match
    case mismatch
    case indeterminate
}

public enum TweakFilterConditionKind: String, Codable, Hashable, Sendable {
    case bundles
    case executables
    case classes
    case coreFoundationVersion
}

/// 单个 filter 条件的比对结果。
///
/// `locallyDecidable` 为 false 表示该条件本质上要到运行时/设备才能判定(Classes 要看
/// 运行时有没有这个类,CoreFoundationVersion 要看设备 iOS 版本),本机只能给 indeterminate。
public struct TweakFilterConditionResult: Codable, Hashable, Sendable {
    public let kind: TweakFilterConditionKind
    public let present: Bool
    public let locallyDecidable: Bool
    public let result: TweakFilterMatch
    /// 命中的具体值(仅 bundles/executables 有意义),便于向用户解释「因为哪一项而匹配」。
    public let matchedValues: [String]

    public init(
        kind: TweakFilterConditionKind,
        present: Bool,
        locallyDecidable: Bool,
        result: TweakFilterMatch,
        matchedValues: [String]
    ) {
        self.kind = kind
        self.present = present
        self.locallyDecidable = locallyDecidable
        self.result = result
        self.matchedValues = matchedValues
    }
}

/// 目标 IPA/App 的身份信息,用于与 filter 比对。
///
/// MobileSubstrate 的 `Bundles` 语义是「目标进程加载了其中任一 bundle identifier 就注入」,
/// 而进程加载的 bundle 不止 App 自身:还包括各 appex、以及 App 内嵌的 framework/.bundle。
/// 因此这里把这些「本机能静态读到、必然随 App 一起加载」的 bundle ID 都收进来,作为可判定的
/// 匹配依据;系统框架那类本机无法确认是否加载的,不在此列(留给比对时归 indeterminate)。
public struct TweakFilterTargetIdentity: Codable, Hashable, Sendable {
    public let mainBundleID: String
    public let mainExecutableName: String
    /// 各 App Extension(appex)的 bundle ID。
    public let extensionBundleIDs: [String]
    /// App 内嵌的 framework / .bundle 的 bundle ID(静态可读,必随宿主进程加载)。
    public let embeddedBundleIDs: [String]

    public init(
        mainBundleID: String,
        mainExecutableName: String,
        extensionBundleIDs: [String] = [],
        embeddedBundleIDs: [String] = []
    ) {
        self.mainBundleID = mainBundleID
        self.mainExecutableName = mainExecutableName
        self.extensionBundleIDs = extensionBundleIDs
        self.embeddedBundleIDs = embeddedBundleIDs
    }

    /// 本机可判定「必然随 App 一起加载」的全部 bundle ID:主体 + appex + 内嵌 framework/.bundle。
    public var locallyLoadedBundleIDs: [String] {
        [mainBundleID] + extensionBundleIDs + embeddedBundleIDs
    }
}

/// 一次 filter 比对的完整结论。
///
/// 解读方式:
/// - `overall == .match`:本机可判定 filter 指向该目标(或 filter 为空,加载进所有进程)。
/// - `overall == .mismatch`:本机可判定 filter 不指向该目标。默认产出 blocker,
///   仅当传入 `userAcknowledgedMismatch` 时降级为 warning。
/// - `overall == .indeterminate`:剩下的决定项只有 Classes/CoreFoundationVersion 这类
///   本机无法判定的条件,无法给出匹配与否的结论,产出 warning。
/// - `findings` 复用 IpaPreflightFinding;`isBlocked` 表示是否含 blocker。
public struct TweakFilterEvaluation: Codable, Hashable, Sendable {
    public let overall: TweakFilterMatch
    public let effectiveMode: TweakFilterMode
    /// filter 里是否显式写了 Mode(未写时按 All 处理,但要让调用方知道这是默认值)。
    public let modeExplicit: Bool
    /// Mode 是否是已知语义(All/Any)。未知 Mode 会按 All 保守处理并给出 warning。
    public let modeRecognized: Bool
    public let conditions: [TweakFilterConditionResult]
    public let acknowledgedMismatch: Bool
    public let findings: [IpaPreflightFinding]

    public init(
        overall: TweakFilterMatch,
        effectiveMode: TweakFilterMode,
        modeExplicit: Bool,
        modeRecognized: Bool,
        conditions: [TweakFilterConditionResult],
        acknowledgedMismatch: Bool,
        findings: [IpaPreflightFinding]
    ) {
        self.overall = overall
        self.effectiveMode = effectiveMode
        self.modeExplicit = modeExplicit
        self.modeRecognized = modeRecognized
        self.conditions = conditions
        self.acknowledgedMismatch = acknowledgedMismatch
        self.findings = findings
    }

    public var isBlocked: Bool { findings.contains { $0.severity == .blocker } }

    public func condition(_ kind: TweakFilterConditionKind) -> TweakFilterConditionResult? {
        conditions.first { $0.kind == kind }
    }
}

/// filter 的「读进来 + 比对」入口。解析沿用 TweakInjectService 的 plist 解析,比对逻辑在此。
public enum TweakFilterService {

    /// 从 filter plist 文件解析。UI/调用方可直接用来展示 filter 内容(含未知字段)。
    public static func parseFilter(at url: URL) -> TweakFilterTargets {
        TweakInjectService.parseFilterTargets(at: url)
    }

    /// 从 plist 顶层字典解析(便于不落盘的场景)。
    public static func parseFilter(from dictionary: [String: Any]) -> TweakFilterTargets {
        TweakInjectService.parseFilter(from: dictionary)
    }

    /// 读取 App bundle 的身份信息(主 bundle ID / 主 executable 名 / 各 appex 的 bundle ID)。
    public static func targetIdentity(forAppAt app: URL) throws -> TweakFilterTargetIdentity {
        let components = try InjectionTargetDiscovery.components(in: app)
        return try targetIdentity(forAppAt: app, components: components)
    }

    /// 读取 IPA 或 App 的身份信息。IPA 会在临时目录展开后读取,读完即清理。
    public static func targetIdentity(for input: InjectionInput) throws -> TweakFilterTargetIdentity {
        let session = try InjectionTargetDiscovery.open(input)
        return try targetIdentity(forAppAt: session.appURL, components: session.components)
    }

    static func targetIdentity(
        forAppAt app: URL,
        components: [EmbeddedComponent]
    ) throws -> TweakFilterTargetIdentity {
        let plist = try IpaService.infoPlist(appBundle: app)
        let bundleID = (plist["CFBundleIdentifier"] as? String) ?? ""
        let executable = (plist["CFBundleExecutable"] as? String)
            ?? app.deletingPathExtension().lastPathComponent
        let extensionBundleIDs = components
            .filter { $0.kind == .appExtension }
            .compactMap(\.bundleID)
        return TweakFilterTargetIdentity(
            mainBundleID: bundleID,
            mainExecutableName: executable,
            extensionBundleIDs: extensionBundleIDs,
            embeddedBundleIDs: embeddedBundleIDs(in: app, excluding: Set([bundleID] + extensionBundleIDs))
        )
    }

    /// 遍历 App 内所有 .framework / .bundle,读取它们的 CFBundleIdentifier。
    /// 这些是「本机静态可读、且必随宿主进程一起加载」的 bundle,可作为 Bundles 命中的确凿依据。
    /// 去重并排除已计入主体/appex 的 ID,避免重复。
    static func embeddedBundleIDs(in app: URL, excluding: Set<String> = []) -> [String] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: app,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var seen = excluding
        var result: [String] = []
        for case let url as URL in enumerator {
            let ext = url.pathExtension.lowercased()
            guard ext == "framework" || ext == "bundle", FileSystemHelper.isDirectory(url) else { continue }
            guard let plist = try? IpaService.infoPlist(appBundle: url),
                  let id = plist["CFBundleIdentifier"] as? String,
                  !id.isEmpty else { continue }
            if seen.insert(id).inserted { result.append(id) }
        }
        return result
    }

    /// 把 filter 与目标身份逐项比对,给出三态结论与 preflight findings。
    ///
    /// - Parameter userAcknowledgedMismatch: 调用方显式传入「用户已知情确认」时,
    ///   不匹配从 blocker 降级为 warning,并在提示里说清:把 dylib 直接写进 IPA 会改变原
    ///   filter 语义——此时决定加载的是 load command 而非 loader,原 filter 不再起作用。
    public static func evaluate(
        _ filter: TweakFilterTargets,
        against identity: TweakFilterTargetIdentity,
        userAcknowledgedMismatch: Bool = false
    ) -> TweakFilterEvaluation {
        // Bundles 是三类而非两类:命中 App 相关 bundle(主体/appex/内嵌 framework/.bundle)→
        // 可判定匹配;都没命中但存在 Apple/系统 bundle → 本机无法确认目标进程是否加载 →
        // indeterminate;剩下全是别的第三方 App 的 bundle → 可判定 mismatch。
        let locallyLoaded = identity.locallyLoadedBundleIDs
        let bundleMatches = filter.bundles.filter { locallyLoaded.contains($0) }
        var bundleIndeterminateValues: [String] = []
        let bundlesResult: TweakFilterMatch
        let bundlesDecidable: Bool
        if filter.bundles.isEmpty || !bundleMatches.isEmpty {
            bundlesResult = .match
            bundlesDecidable = true
        } else {
            bundleIndeterminateValues = filter.bundles.filter { isSystemProvidedBundleID($0) }
            if bundleIndeterminateValues.isEmpty {
                bundlesResult = .mismatch
                bundlesDecidable = true
            } else {
                bundlesResult = .indeterminate
                bundlesDecidable = false
            }
        }
        let bundles = TweakFilterConditionResult(
            kind: .bundles,
            present: !filter.bundles.isEmpty,
            locallyDecidable: bundlesDecidable,
            result: bundlesResult,
            matchedValues: bundleMatches
        )

        let executableMatches = filter.executables.filter { $0 == identity.mainExecutableName }
        let executables = TweakFilterConditionResult(
            kind: .executables,
            present: !filter.executables.isEmpty,
            locallyDecidable: true,
            result: filter.executables.isEmpty
                ? .match
                : (executableMatches.isEmpty ? .mismatch : .match),
            matchedValues: executableMatches
        )

        let classes = TweakFilterConditionResult(
            kind: .classes,
            present: !filter.classes.isEmpty,
            locallyDecidable: false,
            result: filter.classes.isEmpty ? .match : .indeterminate,
            matchedValues: []
        )

        let cfVersion = TweakFilterConditionResult(
            kind: .coreFoundationVersion,
            present: !filter.coreFoundationVersion.isEmpty,
            locallyDecidable: false,
            result: filter.coreFoundationVersion.isEmpty ? .match : .indeterminate,
            matchedValues: []
        )

        let conditions = [bundles, executables, classes, cfVersion]
        let present = conditions.filter(\.present)
        let mode = filter.effectiveMode
        let modeRecognized = filter.mode?.isRecognized ?? true

        let overall: TweakFilterMatch
        if present.isEmpty {
            // 空 filter:MobileSubstrate 会把 dylib 加载进所有进程,对该目标必然加载。
            overall = .match
        } else if mode.isAny {
            if present.contains(where: { $0.result == .match }) {
                overall = .match
            } else if present.contains(where: { $0.result == .indeterminate }) {
                overall = .indeterminate
            } else {
                overall = .mismatch
            }
        } else {
            // All(默认)以及未识别的 Mode 都按「所有条件都需满足」保守处理:
            // 任一可判定条件不匹配即 mismatch;否则若还有无法判定的条件则 indeterminate。
            if present.contains(where: { $0.result == .mismatch }) {
                overall = .mismatch
            } else if present.contains(where: { $0.result == .indeterminate }) {
                overall = .indeterminate
            } else {
                overall = .match
            }
        }

        var findings: [IpaPreflightFinding] = []

        if let explicitMode = filter.mode, !explicitMode.isRecognized {
            findings.append(.init(
                severity: .warning,
                code: "filter.mode-unknown",
                message: L("filter.finding.modeUnknown", explicitMode.rawValue)
            ))
        }
        if bundles.result == .indeterminate {
            findings.append(.init(
                severity: .warning,
                code: "filter.bundles-indeterminate",
                message: L(
                    "filter.finding.bundlesIndeterminate",
                    bundleIndeterminateValues.joined(separator: ", ")
                )
            ))
        }
        if classes.present {
            findings.append(.init(
                severity: .warning,
                code: "filter.classes-indeterminate",
                message: L("filter.finding.classesIndeterminate", filter.classes.joined(separator: ", "))
            ))
        }
        if cfVersion.present {
            findings.append(.init(
                severity: .warning,
                code: "filter.cfversion-indeterminate",
                message: L(
                    "filter.finding.cfVersionIndeterminate",
                    filter.coreFoundationVersion.map { formatVersion($0) }.joined(separator: ", ")
                )
            ))
        }
        if !filter.unknownFilterKeys.isEmpty {
            findings.append(.init(
                severity: .warning,
                code: "filter.unknown-keys",
                message: L("filter.finding.unknownFilterKeys", filter.unknownFilterKeys.joined(separator: ", "))
            ))
        }
        if !filter.unknownTopLevelKeys.isEmpty {
            findings.append(.init(
                severity: .warning,
                code: "filter.unknown-top-level-keys",
                message: L(
                    "filter.finding.unknownTopLevelKeys",
                    filter.unknownTopLevelKeys.joined(separator: ", ")
                )
            ))
        }

        let targetSummary = identity.mainExecutableName.isEmpty
            ? identity.mainBundleID
            : "\(identity.mainBundleID) (\(identity.mainExecutableName))"
        switch overall {
        case .match:
            if filter.isEmpty {
                findings.append(.init(
                    severity: .info,
                    code: "filter.empty",
                    message: L("filter.finding.empty")
                ))
            } else {
                findings.append(.init(
                    severity: .info,
                    code: "filter.match",
                    message: L("filter.finding.match", targetSummary)
                ))
            }
        case .indeterminate:
            findings.append(.init(
                severity: .warning,
                code: "filter.indeterminate",
                message: L("filter.finding.indeterminate", targetSummary)
            ))
        case .mismatch:
            let filterSummary = filterSummaryText(filter)
            if userAcknowledgedMismatch {
                findings.append(.init(
                    severity: .warning,
                    code: "filter.mismatch-overridden",
                    message: L("filter.finding.mismatchOverridden", filterSummary, targetSummary)
                ))
            } else {
                findings.append(.init(
                    severity: .blocker,
                    code: "filter.mismatch",
                    message: L("filter.finding.mismatch", filterSummary, targetSummary)
                ))
            }
        }

        return TweakFilterEvaluation(
            overall: overall,
            effectiveMode: mode,
            modeExplicit: filter.mode != nil,
            modeRecognized: modeRecognized,
            conditions: conditions,
            acknowledgedMismatch: userAcknowledgedMismatch,
            findings: findings
        )
    }

    /// 是否为 Apple/系统提供的 bundle identifier。
    ///
    /// 只用 `com.apple.` 前缀作为「这是 Apple 提供的 bundle」的**来源**依据——与 WI4 里
    /// 「前缀只能证明来源、不能证明存在/加载」的原则一致。绝不据此断定目标进程一定加载它:
    /// `com.apple.UIKit` 几乎人人加载,`com.apple.springboard` 第三方 App 永不加载,本机无从
    /// 可靠区分,因此命中者一律归 indeterminate,而不是硬编码一张「谁都加载」的表来假装判定。
    private static func isSystemProvidedBundleID(_ identifier: String) -> Bool {
        identifier.lowercased().hasPrefix("com.apple.")
    }

    private static func filterSummaryText(_ filter: TweakFilterTargets) -> String {
        var parts: [String] = []
        if !filter.bundles.isEmpty {
            parts.append("Bundles=[\(filter.bundles.joined(separator: ", "))]")
        }
        if !filter.executables.isEmpty {
            parts.append("Executables=[\(filter.executables.joined(separator: ", "))]")
        }
        return parts.isEmpty ? "—" : parts.joined(separator: " ")
    }

    /// CoreFoundationVersion 常是整数值(如 1600),避免显示成 "1600.0"。
    private static func formatVersion(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(value)
    }
}
