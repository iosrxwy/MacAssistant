import Combine
import Foundation

// MARK: - 输入分类(工作项 1)

/// 一次拖入里,单个文件被自动归到的角色。
///
/// 分类只看扩展名与是否目录这类**本机可确定的事实**;拿不准的一律 `.unrecognized`,
/// 绝不猜。DEB 是否真能当插件由 `DebPluginEligibilityClassifier` 另行判定,这里只认「它是个 deb」。
public enum WorkspaceInputRole: String, Codable, Hashable, Sendable {
    /// 目标 IPA。
    case ipa
    /// 目标 .app 目录。
    case app
    /// 插件来源包,需先过适格性判定。
    case deb
    /// 直接提供的动态库。
    case dylib
    /// Framework 依赖 / 资源。
    case framework
    /// .bundle 资源。
    case bundle
    /// provisioning profile。
    case provisioningProfile
    /// 本机无法识别的输入,如实标注,不塞进任何角色。
    case unrecognized
}

public struct WorkspaceInputClassification: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let url: URL
    public let role: WorkspaceInputRole

    public init(id: UUID = UUID(), url: URL, role: WorkspaceInputRole) {
        self.id = id
        self.url = url
        self.role = role
    }

    /// 是否可作为「目标包」(IPA / App)。
    public var isTarget: Bool { role == .ipa || role == .app }
}

public enum WorkspaceInputClassifier {

    /// 判定单个 URL 的角色。只依赖扩展名与目录性质,不读文件内容(避免对未授权路径做额外 I/O)。
    public static func role(for url: URL) -> WorkspaceInputRole {
        switch url.pathExtension.lowercased() {
        case "ipa": return .ipa
        case "app": return .app
        case "deb": return .deb
        case "dylib": return .dylib
        case "framework": return .framework
        case "bundle": return .bundle
        case "mobileprovision", "provisionprofile": return .provisioningProfile
        default: return .unrecognized
        }
    }

    public static func classify(_ url: URL) -> WorkspaceInputClassification {
        WorkspaceInputClassification(url: url, role: role(for: url))
    }

    public static func classify(_ urls: [URL]) -> [WorkspaceInputClassification] {
        urls.map(classify)
    }
}

// MARK: - 主 tweak 选择 + filter 比对(工作项 2)

/// 单个候选插件与目标 IPA filter 比对后的结论。仅是对 `TweakFilterService.evaluate` 的一层
/// 归纳,便于 UI 直接渲染,并把「是否默认阻止」这条判断放在 Kit 层可测。
public struct WorkbenchTweakChoice: Sendable {
    public let evaluation: TweakFilterEvaluation
    /// 在当前(是否已知情确认)前提下,是否应阻止放行。
    public var isBlocked: Bool { evaluation.isBlocked }
    /// 三态结论,UI 据此显示「正常 / 需设备验证 / 不匹配」。
    public var overall: TweakFilterMatch { evaluation.overall }

    public init(evaluation: TweakFilterEvaluation) {
        self.evaluation = evaluation
    }
}

public enum WorkbenchTweakEvaluator {
    /// 把候选的 filter 与目标身份比对。`acknowledgedMismatch` 为 true 时不匹配从 blocker 降为 warning。
    public static func evaluate(
        filter: TweakFilterTargets,
        against identity: TweakFilterTargetIdentity,
        acknowledgedMismatch: Bool
    ) -> WorkbenchTweakChoice {
        WorkbenchTweakChoice(
            evaluation: TweakFilterService.evaluate(
                filter,
                against: identity,
                userAcknowledgedMismatch: acknowledgedMismatch
            )
        )
    }
}

// MARK: - 签名三态(工作项 4)

/// 拖入产物的签名分支。四态是状态机里的真实状态而非提示文案:
/// - `.unsigned`:完全没有签名材料 → 产出「已修改 / 未签名」产物。
/// - `.waitingForAssets`:身份或某个最终 bundle 的 profile 不完整 → 停下,不发布误标记结果。
/// - `.readyToSign`:完整 p12 身份 + 各最终 bundle ID 的 profile 齐备 → 由内向外签名后进入交接。
/// - `.readyToSignWithAppleID`:已登录 + 已选团队/设备 + 已知最终 bundle ID → 执行时向 Apple 取 profile 再签。
public enum WorkspaceSigningDecision: Hashable, Sendable {
    case unsigned
    case waitingForAssets(missingIdentity: Bool, missingProfileBundleIDs: [String])
    case readyToSign(RealDeviceSigningRecipe)
    case readyToSignWithAppleID(AppleIDSigningRecipe)

    public var isReadyToSign: Bool {
        switch self {
        case .readyToSign, .readyToSignWithAppleID: return true
        default: return false
        }
    }

    public var isWaiting: Bool {
        if case .waitingForAssets = self { return true }
        return false
    }
}

public enum WorkspaceSigningPlanner {

    /// 依据当前掌握的签名材料决定落在三态的哪一态。
    ///
    /// - Parameters:
    ///   - identity: 选定的开发者身份;nil 表示未选。
    ///   - profilesByBundleID: 已按最终 bundle ID 建好的 profile 映射。
    ///   - requiredBundleIDs: 目标包(含主 App / appex / Watch / AppClip)需要覆盖的全部 bundle ID。
    public static func decide(
        identity: SigningIdentity?,
        profilesByBundleID: [String: URL],
        requiredBundleIDs: [String],
        appleID: AppleIDSigningRecipe? = nil
    ) -> WorkspaceSigningDecision {
        let p12 = decideP12(
            identity: identity,
            profilesByBundleID: profilesByBundleID,
            requiredBundleIDs: requiredBundleIDs
        )
        if case .readyToSign = p12 { return p12 }

        if let appleID, appleID.isComplete, !requiredBundleIDs.isEmpty {
            return .readyToSignWithAppleID(appleID)
        }
        if let appleID, appleID.isPartial {
            return .waitingForAssets(
                missingIdentity: appleID.teamID.isEmpty,
                missingProfileBundleIDs: appleID.deviceUDID.isEmpty ? requiredBundleIDs : []
            )
        }
        return p12
    }

    private static func decideP12(
        identity: SigningIdentity?,
        profilesByBundleID: [String: URL],
        requiredBundleIDs: [String]
    ) -> WorkspaceSigningDecision {
        let hasAnyAsset = identity != nil || !profilesByBundleID.isEmpty
        // 完全没有签名材料:如实产出未签名产物,交后续签名。
        guard hasAnyAsset else { return .unsigned }

        let missingProfiles = requiredBundleIDs
            .filter { profilesByBundleID[$0] == nil }
            .sorted()
        let missingIdentity = identity == nil

        // 只要身份缺失、或还有最终 bundle 没匹配到 profile,就停在「等待签名材料」,不冒进签名。
        guard let identity, missingProfiles.isEmpty, !requiredBundleIDs.isEmpty else {
            return .waitingForAssets(
                missingIdentity: missingIdentity,
                missingProfileBundleIDs: missingProfiles
            )
        }

        let active = profilesByBundleID.filter { requiredBundleIDs.contains($0.key) }
        return .readyToSign(RealDeviceSigningRecipe(
            identityID: identity.id,
            identityName: identity.name,
            profilesByBundleID: active
        ))
    }

    /// 把 `WorkspaceSigningDecision` 转成执行层需要的 `InjectionSigningMode`。
    /// 未就绪的两态由调用方在决策阶段拦下,不应走到这里;为安全起见退化为不签名。
    public static func signingMode(
        for decision: WorkspaceSigningDecision,
        fallback: InjectionSigningMode = .adHoc
    ) -> InjectionSigningMode {
        switch decision {
        case let .readyToSign(recipe): return .realDevice(recipe)
        case let .readyToSignWithAppleID(recipe): return .appleID(recipe)
        case .unsigned: return fallback
        case .waitingForAssets: return fallback
        }
    }
}

/// 一次工作台运行结束后,产物落在的最终状态。这三态与 `WorkspaceSigningDecision` 对齐,
/// 但携带产物 URL,是给 UI 交接用的真实状态,而不是「兼容 / 成功」这类越界结论。
public enum WorkspaceArtifactState: Hashable, Sendable {
    /// 已修改但未签名的产物。必须醒目标记,不能让用户误以为可直接安装。
    case modifiedUnsigned(outputURL: URL)
    /// 已由内向外签名、可进入设备安装交接的产物。仍处于「待上机验证」语义。
    case signedForHandoff(outputURL: URL)
    /// 停在等待签名材料,未产出任何可能被误读的结果。
    case waitingForSigningAssets(missingIdentity: Bool, missingProfileBundleIDs: [String])
}

extension WorkspaceSigningDecision {
    /// 三态是否允许真正执行并发布产物:等待签名材料时**不**执行,避免发布误标记结果。
    public var canExecute: Bool { !isWaiting }

    /// 把签名决策映射到执行产物状态。`waitingForAssets` 时忽略 outputURL——它本就不该产出产物。
    public func artifactState(outputURL: URL) -> WorkspaceArtifactState {
        switch self {
        case .unsigned:
            return .modifiedUnsigned(outputURL: outputURL)
        case .readyToSign, .readyToSignWithAppleID:
            return .signedForHandoff(outputURL: outputURL)
        case let .waitingForAssets(missingIdentity, missingProfiles):
            return .waitingForSigningAssets(
                missingIdentity: missingIdentity,
                missingProfileBundleIDs: missingProfiles
            )
        }
    }
}

// MARK: - 生命周期状态机

/// 一次拖入运行的生命周期阶段:源快照 → 计划 → 预检 → 执行 → 结果 → 交接。
/// UI 只渲染阶段,判断逻辑留在 Kit。
public enum WorkspaceRunPhase: String, Codable, Hashable, Sendable, CaseIterable {
    case sourceSnapshot
    case planned
    case preflighted
    case executed
    case resultReady
    case handoff
}

// MARK: - 不可变源快照(工作项 6)

/// 一次拖入建立的不可变源快照。
///
/// 硬要求:原始输入永不被覆盖。这里不只是「我们不去改它」,而是把副本落进 Store 自持有的
/// 0700 目录后,把副本本身设为只读(文件 0o444、目录 0o555),让后续代码在文件系统层面
/// **无法**原地改写这份快照;真正的注入始终在执行器另建的临时目录里进行,输出走独立路径。
public final class ImmutableSourceSnapshot: @unchecked Sendable {
    public let originalURL: URL
    public let snapshotURL: URL
    public let sha256: String
    private let root: URL

    private init(originalURL: URL, snapshotURL: URL, sha256: String, root: URL) {
        self.originalURL = originalURL
        self.snapshotURL = snapshotURL
        self.sha256 = sha256
        self.root = root
    }

    deinit {
        // 清理前先恢复可写,否则只读目录会挡住删除。
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        restoreWritable(root)
        try? FileManager.default.removeItem(at: root)
    }

    /// 复制原始输入到 0700 私有目录,记录原始 hash。
    ///
    /// 原始输入的「永不被覆盖」由**只操作副本、绝不把原始 URL 交给任何会写盘的代码**来保证。
    /// 在此基础上,对**文件型**快照(IPA/dylib)再额外锁只读(文件 0o444、根目录 0o555),
    /// 让代码在文件系统层面也无法原地改写这份快照;执行器解压 IPA 会另建可写临时目录,不受影响。
    /// 目录型快照(.app/.framework)不锁只读:执行器会 `copyItem` 保留权限后就地改写它那份拷贝,
    /// 只读会导致其失败;而原始 .app 依旧安全——我们从不向原始路径写入。
    public static func make(of originalURL: URL) throws -> ImmutableSourceSnapshot {
        let root = try FileSystemHelper.makeTemporaryDirectory(prefix: "workspace-source")
        do {
            let snapshot = root.appendingPathComponent(originalURL.lastPathComponent)
            try FileManager.default.copyItem(at: originalURL, to: snapshot)
            let isDirectory = FileSystemHelper.isDirectory(originalURL)
            let hash = isDirectory ? "" : (try? DylibService.sha256(fileAt: originalURL)) ?? ""
            if !isDirectory {
                lockReadOnly(snapshot)
                // 根目录设 0o555:阻止在其中新增 / 替换条目,进一步防止原地改写文件快照。
                try? FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: root.path)
            }
            return ImmutableSourceSnapshot(
                originalURL: originalURL,
                snapshotURL: snapshot,
                sha256: hash,
                root: root
            )
        } catch {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }

    /// 快照对应的注入输入。IPA/App 分别包装。
    public var injectionInput: InjectionInput {
        snapshotURL.pathExtension.lowercased() == "app"
            ? .app(snapshotURL)
            : .ipa(snapshotURL)
    }

    private static func lockReadOnly(_ url: URL) {
        let fm = FileManager.default
        if FileSystemHelper.isDirectory(url) {
            try? fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: url.path)
            let children = (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
            for child in children { lockReadOnly(child) }
        } else {
            try? fm.setAttributes([.posixPermissions: 0o444], ofItemAtPath: url.path)
        }
    }
}

/// 递归恢复可写,供清理只读快照时使用。文件级函数,便于 deinit 调用。
private func restoreWritable(_ url: URL) {
    let fm = FileManager.default
    if FileSystemHelper.isDirectory(url) {
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        let children = (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
        for child in children { restoreWritable(child) }
    } else {
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

// MARK: - 路径脱敏(工作项 6)

/// 把用户主目录路径统一脱敏成 `~`。审计报告默认对外用脱敏版本,避免泄漏用户名等信息。
public enum WorkspacePathRedactor {
    /// - Parameter homePath: 允许注入,便于测试(不依赖运行环境的真实 HOME)。
    public static func redact(
        _ text: String,
        homePath: String = FileManager.default.homeDirectoryForCurrentUser.path
    ) -> String {
        var result = text
        let trimmedHome = homePath.hasSuffix("/") ? String(homePath.dropLast()) : homePath
        if !trimmedHome.isEmpty {
            result = result.replacingOccurrences(of: trimmedHome, with: "~")
        }
        // 兜底:任意 /Users/<name> 前缀也脱敏,覆盖别的用户或引用来源。
        result = result.replacingOccurrences(
            of: #"/Users/[^/\s"]+"#,
            with: "~",
            options: .regularExpression
        )
        return result
    }
}

// MARK: - 预设 / Recipe(工作项 3)

/// 本地文件访问行为。这是 **macOS 侧**工作区的引导策略,与 iOS 产物能力无关。
public enum FileAccessBehavior: String, Codable, Hashable, Sendable, CaseIterable {
    /// 需要访问时再提示用户授权。
    case prompt
    /// 运行前必须已具备访问权限,否则不继续。
    case require
}

/// 单条 dylib 的目标映射与加载策略。以 dylib 文件名为键,便于同一 recipe 复用到不同来源。
public struct RecipeTargetMapping: Codable, Hashable, Sendable {
    public var dylibName: String
    /// nil 表示注入主 executable;否则为 App 内相对 Mach-O 路径。
    public var targetRelativePath: String?
    public var loadKind: InjectionLoadKind
    public var existingPolicy: ExistingLoadCommandPolicy

    public init(
        dylibName: String,
        targetRelativePath: String? = nil,
        loadKind: InjectionLoadKind = .required,
        existingPolicy: ExistingLoadCommandPolicy = .replace
    ) {
        self.dylibName = dylibName
        self.targetRelativePath = targetRelativePath
        self.loadKind = loadKind
        self.existingPolicy = existingPolicy
    }
}

/// recipe 载入失败的原因。schema 不认识时必须报错,绝不猜测或静默按当前版本解析。
public enum InjectionRecipeError: LocalizedError, Equatable {
    case unsupportedSchemaVersion(found: Int, supported: [Int])

    public var errorDescription: String? {
        switch self {
        case let .unsupportedSchemaVersion(found, supported):
            let list = supported.map(String.init).joined(separator: ", ")
            return "Unsupported recipe schema version \(found); this build understands: \(list)."
        }
    }
}

/// 可保存 / 载入的注入预设:目标映射、注入顺序、文件访问行为、组件策略、元数据处理。
///
/// recipe 只承载「设置」,不含具体文件 URL——这样一份 recipe 能复用到不同的拖入来源。
public struct InjectionRecipe: Codable, Hashable, Sendable, Identifiable {
    public static let currentSchemaVersion = 1
    /// 本构建能解析的 schema 版本集合。载入到集合外的版本一律报错,不猜。
    public static let supportedSchemaVersions: Set<Int> = [1]

    public var schemaVersion: Int
    public var id: UUID
    public var name: String
    /// 按 dylib 文件名排序的注入顺序;最后一项就是「最后注入的 dylib」。
    public var injectionOrder: [String]
    public var targetMappings: [RecipeTargetMapping]
    public var fileAccessBehavior: FileAccessBehavior
    public var components: InjectionComponentPolicy
    public var metadata: InjectionMetadataChanges
    public var stripCodeSignatureIfNeeded: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        injectionOrder: [String] = [],
        targetMappings: [RecipeTargetMapping] = [],
        fileAccessBehavior: FileAccessBehavior = .prompt,
        components: InjectionComponentPolicy = .init(),
        metadata: InjectionMetadataChanges = .init(),
        stripCodeSignatureIfNeeded: Bool = true
    ) {
        self.schemaVersion = Self.currentSchemaVersion
        self.id = id
        self.name = name
        self.injectionOrder = injectionOrder
        self.targetMappings = targetMappings
        self.fileAccessBehavior = fileAccessBehavior
        self.components = components
        self.metadata = metadata
        self.stripCodeSignatureIfNeeded = stripCodeSignatureIfNeeded
    }

    public func mapping(for dylibName: String) -> RecipeTargetMapping? {
        targetMappings.first { $0.dylibName == dylibName }
    }

    /// 最后注入的 dylib 文件名(若有)。真实写入位置由执行后审计给出,这里给出预设意图。
    public var finalDylibName: String? { injectionOrder.last }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, id, name, injectionOrder, targetMappings
        case fileAccessBehavior, components, metadata, stripCodeSignatureIfNeeded
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // 缺字段的旧文件按 v1 处理;写了版本却不在支持集合里,必须明确报错,不静默降级解析。
        let declared = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? Self.currentSchemaVersion
        guard Self.supportedSchemaVersions.contains(declared) else {
            throw InjectionRecipeError.unsupportedSchemaVersion(
                found: declared,
                supported: Self.supportedSchemaVersions.sorted()
            )
        }
        schemaVersion = declared
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decode(String.self, forKey: .name)
        injectionOrder = try c.decodeIfPresent([String].self, forKey: .injectionOrder) ?? []
        targetMappings = try c.decodeIfPresent([RecipeTargetMapping].self, forKey: .targetMappings) ?? []
        fileAccessBehavior = try c.decodeIfPresent(FileAccessBehavior.self, forKey: .fileAccessBehavior) ?? .prompt
        components = try c.decodeIfPresent(InjectionComponentPolicy.self, forKey: .components) ?? .init()
        metadata = try c.decodeIfPresent(InjectionMetadataChanges.self, forKey: .metadata) ?? .init()
        stripCodeSignatureIfNeeded = try c.decodeIfPresent(Bool.self, forKey: .stripCodeSignatureIfNeeded) ?? true
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> InjectionRecipe {
        try JSONDecoder().decode(InjectionRecipe.self, from: data)
    }

    public func save(to url: URL) throws {
        try encoded().write(to: url, options: .atomic)
    }

    public static func load(from url: URL) throws -> InjectionRecipe {
        try decode(Data(contentsOf: url))
    }
}

// MARK: - 计划装配

/// 从工作台状态装配 `InjectionPlan`。把「怎么根据 recipe + 选中的 dylib 生成计划」这段判断
/// 集中到 Kit 层可测,而不是散落在 View 里。
public enum WorkspacePlanAssembler {

    public struct Inputs: Sendable {
        public var input: InjectionInput
        /// 已按注入顺序排好的 dylib 源文件(第一项一般是用户选定的主 tweak)。
        public var orderedDylibs: [URL]
        /// 额外 Framework 依赖,复制进 Frameworks 目录。
        public var frameworks: [URL]
        public var recipe: InjectionRecipe
        public var signing: InjectionSigningMode
        public var customOutputName: String?

        public init(
            input: InjectionInput,
            orderedDylibs: [URL],
            frameworks: [URL] = [],
            recipe: InjectionRecipe,
            signing: InjectionSigningMode,
            customOutputName: String? = nil
        ) {
            self.input = input
            self.orderedDylibs = orderedDylibs
            self.frameworks = frameworks
            self.recipe = recipe
            self.signing = signing
            self.customOutputName = customOutputName
        }
    }

    public static func makePlan(_ inputs: Inputs) throws -> InjectionPlan {
        let items = try inputs.orderedDylibs.map { url -> InjectionItem in
            let mapping = inputs.recipe.mapping(for: url.lastPathComponent)
            let target: InjectionTarget
            if let relative = mapping?.targetRelativePath,
               !relative.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                target = .relativeMachO(try ValidatedRelativePath(relative))
            } else {
                target = .mainExecutable
            }
            return InjectionItem(
                dylibURL: url,
                target: target,
                loadKind: mapping?.loadKind ?? .required,
                existingCommandPolicy: mapping?.existingPolicy ?? .replace
            )
        }

        let frameworkDirectory: String
        if case .app = inputs.input {
            frameworkDirectory = "Contents/Frameworks"
        } else {
            frameworkDirectory = "Frameworks"
        }
        var resources: [InjectionResource] = []
        for framework in inputs.frameworks {
            let destination = try ValidatedRelativePath(
                "\(frameworkDirectory)/\(framework.lastPathComponent)"
            )
            guard !resources.contains(where: { $0.destination == destination }) else { continue }
            resources.append(InjectionResource(
                sourceURL: framework,
                destination: destination,
                replaceExisting: true
            ))
        }

        return InjectionPlan(
            input: inputs.input,
            items: items,
            resources: resources,
            metadata: inputs.recipe.metadata,
            components: inputs.recipe.components,
            signing: inputs.signing,
            customOutputName: inputs.customOutputName,
            stripCodeSignatureIfNeeded: inputs.recipe.stripCodeSignatureIfNeeded
        )
    }

    /// 从执行结果里取「最后注入的 dylib 位置」。plan.items 顺序即注入顺序,审计条目随之对齐。
    public static func finalDylibPosition(
        from result: IpaInjectionExecutionResult
    ) -> String? {
        guard let last = result.audit.entries.last else { return nil }
        return "\(last.targetRelativePath) ← \(last.loadPath)"
    }
}

// MARK: - 审计报告(工作项 6)

/// 可复现的审计记录:输入 / 输出 hash、插件 hash、目标 profile、计划、findings、实际变更、工具版本。
/// 默认对外用 `redactingHomePaths()` 后的版本。
public struct WorkspaceAuditReport: Codable, Hashable, Sendable {
    public var toolVersion: String
    public var createdAt: Date
    public var inputName: String
    public var inputSHA256: String
    public var outputName: String?
    public var outputSHA256: String?
    /// 插件文件名 → SHA-256。
    public var pluginHashes: [String: String]
    /// 目标包最终需要覆盖的 profile bundle ID。
    public var targetProfileBundleIDs: [String]
    /// 最后注入的 dylib 位置(TODO 明确要求写进审计)。
    public var finalInjectedDylibPosition: String?
    public var findings: [IpaPreflightFinding]
    public var changedPaths: [String]
    /// 「本机无法确认」的依赖(deviceProvided / unknown)。写进审计以如实记录「哪些要上机验证」,
    /// 不因为不确定就当成已解析或失败。
    public var unconfirmedDependencies: [IpaUnconfirmedDependency]
    /// 产物签名分支的诚实标注,不含「兼容 / 成功」这类越界结论。
    public var signingOutcome: String

    public init(
        toolVersion: String,
        createdAt: Date = Date(),
        inputName: String,
        inputSHA256: String,
        outputName: String? = nil,
        outputSHA256: String? = nil,
        pluginHashes: [String: String] = [:],
        targetProfileBundleIDs: [String] = [],
        finalInjectedDylibPosition: String? = nil,
        findings: [IpaPreflightFinding] = [],
        changedPaths: [String] = [],
        unconfirmedDependencies: [IpaUnconfirmedDependency] = [],
        signingOutcome: String
    ) {
        self.toolVersion = toolVersion
        self.createdAt = createdAt
        self.inputName = inputName
        self.inputSHA256 = inputSHA256
        self.outputName = outputName
        self.outputSHA256 = outputSHA256
        self.pluginHashes = pluginHashes
        self.targetProfileBundleIDs = targetProfileBundleIDs
        self.finalInjectedDylibPosition = finalInjectedDylibPosition
        self.findings = findings
        self.changedPaths = changedPaths
        self.unconfirmedDependencies = unconfirmedDependencies
        self.signingOutcome = signingOutcome
    }

    /// 返回把所有字符串字段里的用户主目录路径脱敏后的副本。
    public func redactingHomePaths(
        homePath: String = FileManager.default.homeDirectoryForCurrentUser.path
    ) -> WorkspaceAuditReport {
        var copy = self
        func r(_ value: String) -> String { WorkspacePathRedactor.redact(value, homePath: homePath) }
        copy.inputName = r(inputName)
        copy.outputName = outputName.map(r)
        copy.finalInjectedDylibPosition = finalInjectedDylibPosition.map(r)
        copy.changedPaths = changedPaths.map(r)
        copy.findings = findings.map {
            IpaPreflightFinding(id: $0.id, severity: $0.severity, code: $0.code, message: r($0.message))
        }
        copy.pluginHashes = Dictionary(
            uniqueKeysWithValues: pluginHashes.map { (r($0.key), $0.value) }
        )
        return copy
    }

    /// 导出为 JSON(默认脱敏)。
    public func jsonData(redacted: Bool = true) throws -> Data {
        let report = redacted ? redactingHomePaths() : self
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(report)
    }
}
