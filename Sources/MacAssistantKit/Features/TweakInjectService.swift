import Foundation

/// 一条 install_name 改写(把越狱绝对路径改成 @rpath)。
public struct InstallNameChange: Sendable, Hashable {
    public let from: String
    public let to: String
    public init(from: String, to: String) { self.from = from; self.to = to }
}

public struct TweakInjectOptions: Sendable {
    public var tweaks: [URL]              // .dylib 或 .deb,可多选
    public var elleKitFramework: URL?     // 可选:ElleKit 版 CydiaSubstrate.framework
    public var frameworks: [URL]         // 可选:额外 Framework,例如 ProtobufLite2/3
    public var weak: Bool
    public var stripCodeSignature: Bool
    public var signMethod: SignMethod
    public var deviceSigning: RealDeviceSigningRecipe?

    public init(tweaks: [URL], elleKitFramework: URL? = nil, frameworks: [URL] = [], weak: Bool = false,
                stripCodeSignature: Bool = true, signMethod: SignMethod = .codesignAdhoc,
                deviceSigning: RealDeviceSigningRecipe? = nil) {
        self.tweaks = tweaks
        self.elleKitFramework = elleKitFramework
        self.frameworks = frameworks
        self.weak = weak
        self.stripCodeSignature = stripCodeSignature
        self.signMethod = signMethod
        self.deviceSigning = deviceSigning
    }
}

public struct TweakInjectResult: Sendable {
    public var output: URL
    public var injected: [String]
    public var rewrites: [InstallNameChange]
    public var warnings: [String]
    public var log: [String]
}

/// 一个 tweak filter 的 Mode。用 RawRepresentable 保留原始写法,未知值不丢失也能报告。
public struct TweakFilterMode: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let all = TweakFilterMode(rawValue: "All")
    public static let any = TweakFilterMode(rawValue: "Any")

    public var isAny: Bool { rawValue.caseInsensitiveCompare("Any") == .orderedSame }
    public var isAll: Bool { rawValue.caseInsensitiveCompare("All") == .orderedSame }
    /// 既非 Any 也非 All:无法用已知语义判定,需报告。
    public var isRecognized: Bool { isAny || isAll }
}

/// 从既有 tweak 的 filter plist「读进来」的解析结果。
///
/// 与 `DebService.TweakFilter` 是相反方向的两个类型:后者是 DEB 打包侧「写出去」的
/// 生成模型(只承载能有意义地生成的字段);本类型是解析真实世界任意 plist 的模型,
/// 因此额外建模了 `Mode` 并保留未知字段。两者刻意不合并——把「保留未知字段/Mode」
/// 强塞进生成模型会让它承载无法生成的信息,而让生成模型丢弃未知字段又会破坏本类型的
/// 诚实性。二者共享的是同一组条件语义(bundles/executables/classes/cfVersion)。
public struct TweakFilterTargets: Codable, Hashable, Sendable {
    public let bundles: [String]
    public let executables: [String]
    public let classes: [String]
    public let coreFoundationVersion: [Double]
    /// nil 表示 plist 未写 Mode;MobileSubstrate 默认按「所有给定条件都需满足」(All)处理。
    public let mode: TweakFilterMode?
    /// Filter 字典内未建模的键,不静默丢弃,保留以便报告。
    public let unknownFilterKeys: [String]
    /// plist 顶层除 Filter/Mode 之外的键。
    public let unknownTopLevelKeys: [String]

    public init(
        bundles: [String] = [],
        executables: [String] = [],
        classes: [String] = [],
        coreFoundationVersion: [Double] = [],
        mode: TweakFilterMode? = nil,
        unknownFilterKeys: [String] = [],
        unknownTopLevelKeys: [String] = []
    ) {
        self.bundles = bundles
        self.executables = executables
        self.classes = classes
        self.coreFoundationVersion = coreFoundationVersion
        self.mode = mode
        self.unknownFilterKeys = unknownFilterKeys
        self.unknownTopLevelKeys = unknownTopLevelKeys
    }

    public var isEmpty: Bool {
        bundles.isEmpty && executables.isEmpty && classes.isEmpty && coreFoundationVersion.isEmpty
    }

    /// 生效 Mode:缺省按 All。
    public var effectiveMode: TweakFilterMode { mode ?? .all }

    public var hasUnknownFields: Bool {
        !unknownFilterKeys.isEmpty || !unknownTopLevelKeys.isEmpty
    }
}

public struct DebTweakCandidate: Identifiable, Sendable {
    public let id: UUID
    public let dylibURL: URL
    public let relativePath: String
    public let companionPlistURL: URL?
    public let filterTargets: TweakFilterTargets
    public let analysis: DylibAnalysisSnapshot
}

public final class DebTweakCandidateSession: @unchecked Sendable {
    public let candidates: [DebTweakCandidate]
    /// 该 .deb 作为 IPA 内插件的适用性。不适用时 candidates 仍会列出,由调用方决定是否阻止,
    /// 从而既能复用分类结果,又不影响它在 DEB 打包页面作为合法输入。
    public let pluginEligibility: DebPluginEligibility
    fileprivate let scanSession: DebScanSession

    fileprivate init(
        candidates: [DebTweakCandidate],
        pluginEligibility: DebPluginEligibility,
        scanSession: DebScanSession
    ) {
        self.candidates = candidates
        self.pluginEligibility = pluginEligibility
        self.scanSession = scanSession
    }
}

public enum TweakInjectError: LocalizedError {
    case noTweakFound
    case commandFailed(String)
    case architectureMismatch(String)
    case unresolvedDependency(String)
    case outputExists(String)
    case deviceLevelPackage(String)
    public var errorDescription: String? {
        switch self {
        case .noTweakFound: return L("tweak.error.noTweakFound")
        case let .commandFailed(o): return L("tweak.error.commandFailed", o)
        case let .architectureMismatch(message): return L("tweak.error.architectureMismatch", message)
        case let .unresolvedDependency(message): return L("tweak.error.unresolvedDependency", message)
        case let .outputExists(path): return L("tweak.error.outputExists", path)
        case let .deviceLevelPackage(message): return message
        }
    }
}

/// 插件 / tweak 注入:DEB → 提取 tweak → @rpath 改写 → 原生注入 → 补 rpath → 重签 → 重打包。
public enum TweakInjectService {

    /// 已知需重定向到 ElleKit 的依赖关键字,复用全项目唯一的关键字表。
    private static var tweakLibKeywords: [String] { DependencyClassifier.jailbreakRuntimeKeywords }

    // MARK: 纯逻辑:@rpath 改写规划

    /// 依据依赖列表生成 install_name 改写计划(把越狱绝对路径统一改成 @rpath)。
    public static func planRewrites(for dependencies: [String]) -> [InstallNameChange] {
        var seen = Set<String>()
        var result: [InstallNameChange] = []
        for dep in dependencies {
            guard let to = rewriteTarget(for: dep), to != dep, !seen.contains(dep) else { continue }
            seen.insert(dep)
            result.append(InstallNameChange(from: dep, to: to))
        }
        return result
    }

    /// 计算单条依赖的 @rpath 目标;返回 nil 表示无需改写(系统库 / 已是 @rpath)。
    static func rewriteTarget(for dependency: String) -> String? {
        if dependency.hasPrefix("@") { return nil }
        // 去掉 rootless 前缀 /var/jb
        var path = dependency
        if path.hasPrefix("/var/jb") { path = String(path.dropFirst("/var/jb".count)) }

        // CydiaSubstrate → ElleKit 替身
        if path.contains("CydiaSubstrate.framework") {
            return "@rpath/CydiaSubstrate.framework/CydiaSubstrate"
        }
        // /Library/Frameworks/X.framework/... → @rpath/X.framework/...
        if let r = path.range(of: "/Library/Frameworks/") {
            return "@rpath/" + String(path[r.upperBound...])
        }
        // MobileSubstrate 动态库
        if path.contains("/Library/MobileSubstrate/DynamicLibraries/") {
            return "@rpath/" + (path as NSString).lastPathComponent
        }
        // 其它 /Library/*.dylib
        if path.hasPrefix("/Library/"), path.hasSuffix(".dylib") {
            return "@rpath/" + (path as NSString).lastPathComponent
        }
        // /usr/lib 下:仅改写已知 tweak 相关库,系统库不动
        if path.hasPrefix("/usr/lib/"), path.hasSuffix(".dylib") {
            let base = (path as NSString).lastPathComponent.lowercased()
            if tweakLibKeywords.contains(where: { base.contains($0) }) {
                return "@rpath/" + (path as NSString).lastPathComponent
            }
        }
        return nil
    }

    /// 改写计划里是否需要提供 CydiaSubstrate.framework(ElleKit)。
    public static func requiresSubstrateFramework(_ changes: [InstallNameChange]) -> Bool {
        changes.contains { $0.to.contains("CydiaSubstrate.framework") }
    }

    // MARK: 从 .deb 提取 tweak

    /// 从 .deb 中挑出 tweak dylib(优先 DynamicLibraries / usr/lib 下的 .dylib)。
    public static func tweakCandidates(inDebAt url: URL) throws -> [URL] {
        let result = try DebService.machOFiles(inDebAt: url)
        let dylibs = result.files.filter { $0.pathExtension == "dylib" }
        let preferred = dylibs.filter {
            $0.path.contains("/DynamicLibraries/") || $0.path.contains("/usr/lib/")
        }
        let chosen = preferred.isEmpty ? dylibs : preferred
        return chosen.isEmpty ? result.files : chosen
    }

    /// 返回带工作区生命周期的候选，避免只返回临时 URL 后目录被清理或永久泄漏。
    public static func candidateSession(inDebAt url: URL) throws -> DebTweakCandidateSession {
        let session = try DebArchiveWorkflow.scan(debAt: url)
        let dylibs = session.result.artifacts.filter {
            $0.kind == .dylib
                && ($0.relativePath.contains("/DynamicLibraries/")
                    || $0.relativePath.contains("/usr/lib/")
                    || $0.relativePath.hasSuffix(".dylib"))
        }
        let candidates = dylibs.map {
            DebTweakCandidate(
                id: $0.id,
                dylibURL: $0.localURL,
                relativePath: $0.relativePath,
                companionPlistURL: $0.companionPlistURL,
                filterTargets: parseFilterTargets(at: $0.companionPlistURL),
                analysis: $0.analysis
            )
        }
        let scripts = (try? DebService.presentMaintainerScripts(debAt: url)) ?? []
        let eligibility = DebPluginEligibilityClassifier.classify(
            entries: session.result.info.entries,
            maintainerScripts: scripts
        )
        return DebTweakCandidateSession(
            candidates: candidates,
            pluginEligibility: eligibility,
            scanSession: session
        )
    }

    static func parseFilterTargets(at url: URL?) -> TweakFilterTargets {
        guard let url,
              let data = try? Data(contentsOf: url),
              let root = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dictionary = root as? [String: Any] else {
            return TweakFilterTargets()
        }
        return parseFilter(from: dictionary)
    }

    /// 从 plist 顶层字典解析 filter。抽成独立函数便于直接测试(无需落盘)。
    ///
    /// 未知字段一律收集而非丢弃:Filter 内除已建模的四键 + Mode 之外的键进 unknownFilterKeys,
    /// 顶层除 Filter/Mode 之外的键进 unknownTopLevelKeys。CoreFoundationVersion 只取能转成
    /// 数值的项;若该键存在却全非数值,视为未知字段以免假装读懂。
    static func parseFilter(from dictionary: [String: Any]) -> TweakFilterTargets {
        let filter = dictionary["Filter"] as? [String: Any] ?? [:]

        let bundles = filter["Bundles"] as? [String] ?? []
        let executables = filter["Executables"] as? [String] ?? []
        let classes = filter["Classes"] as? [String] ?? []

        var cfVersions: [Double] = []
        var cfVersionUnreadable = false
        if let raw = filter["CoreFoundationVersion"] {
            if let numbers = raw as? [NSNumber] {
                cfVersions = numbers.map(\.doubleValue)
            } else if let single = raw as? NSNumber {
                cfVersions = [single.doubleValue]
            } else {
                cfVersionUnreadable = true
            }
        }

        // Mode 真实位置在 Filter 内,但也兼容有人写到顶层;两处都缺则 mode 为 nil。
        var mode: TweakFilterMode?
        if let raw = filter["Mode"] as? String {
            mode = TweakFilterMode(rawValue: raw)
        } else if let raw = dictionary["Mode"] as? String {
            mode = TweakFilterMode(rawValue: raw)
        }

        let knownFilterKeys: Set<String> = [
            "Bundles", "Executables", "Classes", "CoreFoundationVersion", "Mode"
        ]
        var unknownFilterKeys = filter.keys.filter { !knownFilterKeys.contains($0) }.sorted()
        if cfVersionUnreadable { unknownFilterKeys.append("CoreFoundationVersion") }

        let knownTopLevelKeys: Set<String> = ["Filter", "Mode"]
        let unknownTopLevelKeys = dictionary.keys.filter { !knownTopLevelKeys.contains($0) }.sorted()

        return TweakFilterTargets(
            bundles: bundles,
            executables: executables,
            classes: classes,
            coreFoundationVersion: cfVersions,
            mode: mode,
            unknownFilterKeys: unknownFilterKeys,
            unknownTopLevelKeys: unknownTopLevelKeys
        )
    }

    // MARK: 完整注入链路

    public static func injectTweaks(ipaAt url: URL, options: TweakInjectOptions,
                                    outputURL: URL? = nil) throws -> TweakInjectResult {
        try injectTweaks(input: .ipa(url), options: options, outputURL: outputURL)
    }

    public static func injectTweaks(input: InjectionInput, options: TweakInjectOptions,
                                    outputURL: URL? = nil) throws -> TweakInjectResult {
        var warnings: [String] = []
        var allRewrites: [InstallNameChange] = []

        let work = try FileSystemHelper.makeTemporaryDirectory(prefix: "tweak-inject")
        defer { try? FileManager.default.removeItem(at: work) }
        let staging = work.appendingPathComponent("sources", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)

        // 解析所有 tweak dylib 来源，并先复制到临时目录；后续只把经过预检的计划交给统一执行器。
        var dylibs: [URL] = []
        var candidateSessions: [DebTweakCandidateSession] = []
        for tweak in options.tweaks {
            if tweak.pathExtension.lowercased() == "deb" {
                let session = try candidateSession(inDebAt: tweak)
                candidateSessions.append(session)
                // 设备级包(LaunchDaemons / 命令行工具 / setuid / .kext 等)不该当 IPA 内插件:
                // 抽个 dylib 塞进去既不符合作者意图,又会把设备级行为带进 App。默认阻止。
                guard session.pluginEligibility.isEligibleAsIpaPlugin else {
                    let reasons = session.pluginEligibility.factors
                        .map { "• \($0.explanation)" }
                        .joined(separator: "\n")
                    throw TweakInjectError.deviceLevelPackage(
                        L("tweak.error.deviceLevelPackage", tweak.lastPathComponent, reasons)
                    )
                }
                let found = session.candidates.map(\.dylibURL)
                if found.isEmpty { warnings.append(L("tweak.warning.noDylibInDeb", tweak.lastPathComponent)) }
                dylibs.append(contentsOf: found)
            } else {
                dylibs.append(tweak)
            }
        }
        guard !dylibs.isEmpty else { throw TweakInjectError.noTweakFound }

        let stagedDylibs = try dylibs.map { dylib -> URL in
            let destination = staging
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
                .appendingPathComponent(dylib.lastPathComponent)
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try FileManager.default.copyItem(at: dylib, to: destination)

            let deps = try DylibService.dependencies(fileAt: destination).map(\.path)
            let changes = planRewrites(for: deps)
            for change in changes {
                let rewrite = try DylibService.changeDependency(
                    from: change.from,
                    to: change.to,
                    fileAt: destination
                )
                guard rewrite.succeeded else {
                    throw TweakInjectError.commandFailed(
                        L("tweak.error.rewriteFailed", change.from, change.to, rewrite.combinedOutput)
                    )
                }
            }
            allRewrites.append(contentsOf: changes)
            return destination
        }

        if requiresSubstrateFramework(allRewrites), options.elleKitFramework == nil {
            throw TweakInjectError.unresolvedDependency(L("tweak.error.missingSubstrateFramework", "tweak"))
        }

        let signing: InjectionSigningMode
        if let deviceSigning = options.deviceSigning {
            signing = .realDevice(deviceSigning)
        } else {
            switch options.signMethod {
            case .none: signing = .none
            case .codesignAdhoc: signing = .adHoc
            case .ldid: signing = .ldid
            }
        }

        let frameworks = options.frameworks + (options.elleKitFramework.map { [$0] } ?? [])
        let frameworkDirectory: String
        if case .app = input {
            frameworkDirectory = "Contents/Frameworks"
        } else {
            frameworkDirectory = "Frameworks"
        }
        let resources = try frameworks.map { framework in
            InjectionResource(
                sourceURL: framework,
                destination: try ValidatedRelativePath("\(frameworkDirectory)/\(framework.lastPathComponent)")
            )
        }
        let plan = InjectionPlan(
            input: input,
            items: stagedDylibs.map {
                InjectionItem(
                    dylibURL: $0,
                    loadKind: options.weak ? .weak : .required
                )
            },
            resources: resources,
            signing: signing,
            stripCodeSignatureIfNeeded: options.stripCodeSignature
        )
        let proposed = input.url.deletingPathExtension()
            .appendingPathExtension("injected")
            .appendingPathExtension(input.url.pathExtension.lowercased() == "app" ? "app" : "ipa")
        let output = outputURL ?? FileSystemHelper.uniqueOutputURL(basedOn: proposed)
        let execution = try IpaInjectionWorkflow.execute(plan, outputURL: output)
        _ = candidateSessions // 保持 DEB 私有解包目录直到统一执行器完成。
        return TweakInjectResult(
            output: execution.outputURL,
            injected: stagedDylibs.map(\.lastPathComponent),
            rewrites: allRewrites,
            warnings: warnings,
            log: execution.log
        )
    }
}
