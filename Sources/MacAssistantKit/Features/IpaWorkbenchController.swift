import Combine
import Foundation

/// 工作台里一个可被选为「主插件」的候选。可能来自直接拖入的 dylib,也可能来自 .deb 里的候选。
public struct WorkbenchPlugin: Identifiable, Sendable {
    public let id: UUID
    public let dylibURL: URL
    public let displayName: String
    /// 来自 .deb 时的包内相对路径;直接 dylib 为 nil。
    public let relativePath: String?
    public let filterTargets: TweakFilterTargets
    /// 来自哪个 .deb(文件名);直接 dylib 为 nil。
    public let sourceDebName: String?

    public init(
        id: UUID = UUID(),
        dylibURL: URL,
        displayName: String,
        relativePath: String? = nil,
        filterTargets: TweakFilterTargets = .init(),
        sourceDebName: String? = nil
    ) {
        self.id = id
        self.dylibURL = dylibURL
        self.displayName = displayName
        self.relativePath = relativePath
        self.filterTargets = filterTargets
        self.sourceDebName = sourceDebName
    }
}

/// 一个被判定为「不适合当 IPA 内插件」的 .deb 及其原因。
public struct BlockedWorkbenchDeb: Identifiable, Sendable {
    public let id = UUID()
    public let name: String
    public let factors: [DebPluginBlockFactor]
}

/// 拖入式 IPA 工作台的状态机与编排器。判断逻辑委托给 Kit 层的纯函数
/// (`WorkspaceInputClassifier` / `WorkspaceSigningPlanner` / `WorkbenchTweakEvaluator` /
/// `WorkspacePlanAssembler`),这里只负责持有状态、分桶输入,并把三态串起来。
@MainActor
public final class IpaWorkbenchController: ObservableObject {

    // MARK: 输入分桶(工作项 1)
    @Published public private(set) var target: WorkspaceInputClassification?
    @Published public private(set) var snapshot: ImmutableSourceSnapshot?
    @Published public private(set) var plugins: [WorkbenchPlugin] = []
    @Published public private(set) var directDylibs: [URL] = []
    @Published public private(set) var frameworks: [URL] = []
    @Published public private(set) var bundles: [URL] = []
    @Published public private(set) var provisioningProfiles: [URL] = []
    @Published public private(set) var blockedDebs: [BlockedWorkbenchDeb] = []
    @Published public private(set) var unrecognized: [URL] = []

    // MARK: 主 tweak 选择(工作项 2)
    @Published public var selectedMainPluginID: WorkbenchPlugin.ID?
    @Published public var acknowledgedFilterMismatch = false

    // MARK: 目标上下文
    @Published public private(set) var targetIdentity: TweakFilterTargetIdentity?
    @Published public private(set) var requiredProfileBundleIDs: [String] = []

    // MARK: 签名材料(工作项 4)
    @Published public var selectedIdentity: SigningIdentity?
    @Published public private(set) var profilesByBundleID: [String: URL] = [:]
    @Published public var appleIDRecipe: AppleIDSigningRecipe?

    // MARK: 预设(工作项 3)
    @Published public var recipe: InjectionRecipe

    // MARK: 预检(工作项 2:执行前独立可见)
    @Published public private(set) var preflightReport: IpaPreflightReport?

    // MARK: 结果
    @Published public private(set) var phase: WorkspaceRunPhase = .sourceSnapshot
    @Published public private(set) var artifactState: WorkspaceArtifactState?
    @Published public private(set) var audit: WorkspaceAuditReport?
    /// 执行结果原件,供 UI 展示「未确认依赖」与「前后 diff」——这些是第二期诚实报告的核心,不能吞。
    @Published public private(set) var executionResult: IpaInjectionExecutionResult?

    /// 持有 DEB 扫描会话,保证其私有解包目录在计划执行前不被释放。
    private var candidateSessions: [DebTweakCandidateSession] = []

    public init(recipe: InjectionRecipe = InjectionRecipe(name: "")) {
        self.recipe = recipe
    }

    // MARK: - 分类入口

    public func classify(_ urls: [URL]) -> [WorkspaceInputClassification] {
        WorkspaceInputClassifier.classify(urls)
    }

    /// 同步把一批 URL 按角色分桶。DEB 与目标包需要额外异步处理,返回给调用方在任务里跟进。
    /// - Returns: 需要异步处理的目标包与 DEB。
    @discardableResult
    public func ingestSimpleInputs(_ urls: [URL]) -> (targets: [URL], debs: [URL]) {
        var pendingTargets: [URL] = []
        var pendingDebs: [URL] = []
        for classification in classify(urls) {
            switch classification.role {
            case .ipa, .app:
                pendingTargets.append(classification.url)
            case .deb:
                pendingDebs.append(classification.url)
            case .dylib:
                addDirectDylib(classification.url)
            case .framework:
                if !frameworks.contains(classification.url) { frameworks.append(classification.url) }
            case .bundle:
                if !bundles.contains(classification.url) { bundles.append(classification.url) }
            case .provisioningProfile:
                addProvisioningProfile(classification.url)
            case .unrecognized:
                if !unrecognized.contains(classification.url) { unrecognized.append(classification.url) }
            }
        }
        return (pendingTargets, pendingDebs)
    }

    private func addDirectDylib(_ url: URL) {
        guard !directDylibs.contains(url) else { return }
        directDylibs.append(url)
        let plugin = WorkbenchPlugin(
            dylibURL: url,
            displayName: url.lastPathComponent,
            filterTargets: TweakFilterService.parseFilter(
                at: url.deletingPathExtension().appendingPathExtension("plist")
            )
        )
        plugins.append(plugin)
        if selectedMainPluginID == nil { selectedMainPluginID = plugin.id }
    }

    // MARK: - 目标包(工作项 6:不可变源快照)

    /// 建立目标包的不可变源快照(同步版,便于测试)。原始文件被复制进只读私有目录,
    /// 后续一切操作都在副本上做。UI 里因快照复制可能很大,改用 `adoptSnapshot` 在后台做完再登记。
    public func setTarget(_ url: URL) throws {
        let classification = WorkspaceInputClassifier.classify(url)
        guard classification.isTarget else { return }
        adoptSnapshot(try ImmutableSourceSnapshot.make(of: url))
    }

    /// 登记一个已在后台建立好的源快照。仅做主线程状态赋值,不含 I/O。
    public func adoptSnapshot(_ snapshot: ImmutableSourceSnapshot) {
        self.target = WorkspaceInputClassifier.classify(snapshot.originalURL)
        self.snapshot = snapshot
        self.phase = .sourceSnapshot
        self.artifactState = nil
        self.audit = nil
    }

    /// 从源快照读取目标身份与需覆盖的 profile bundle ID(同步版,便于测试)。
    public func loadTargetContext() throws {
        guard let snapshot else { return }
        let session = try InjectionTargetDiscovery.open(snapshot.injectionInput)
        let identity = try TweakFilterService.targetIdentity(forAppAt: session.appURL, components: session.components)
        let required = (try? SigningService.profileBundleIDs(in: session.appURL)) ?? []
        applyTargetContext(identity: identity, requiredBundleIDs: required)
    }

    /// 登记后台读到的目标上下文。仅做赋值。
    public func applyTargetContext(identity: TweakFilterTargetIdentity?, requiredBundleIDs: [String]) {
        self.targetIdentity = identity
        self.requiredProfileBundleIDs = requiredBundleIDs
        recomputeProfileMapping()
    }

    // MARK: - DEB 摄取(工作项 1:适格性阻止)

    /// 扫描并摄取一个 .deb。设备级包(daemon / 命令行工具 / setuid / 内核级)默认阻止,
    /// 列出原因,不静默抽 dylib。适格的包保留其候选(带 filter),供用户选主插件。
    public func ingestDeb(_ url: URL) throws {
        let session = try TweakInjectService.candidateSession(inDebAt: url)
        attachDeb(session: session, sourceName: url.lastPathComponent)
    }

    /// 登记后台扫描好的 .deb 会话。设备级包默认阻止并列出原因,不静默抽 dylib。
    public func attachDeb(session: DebTweakCandidateSession, sourceName: String) {
        guard session.pluginEligibility.isEligibleAsIpaPlugin else {
            let blocked = BlockedWorkbenchDeb(name: sourceName, factors: session.pluginEligibility.factors)
            if !blockedDebs.contains(where: { $0.name == blocked.name }) {
                blockedDebs.append(blocked)
            }
            return
        }
        candidateSessions.append(session)
        for candidate in session.candidates {
            plugins.append(WorkbenchPlugin(
                id: candidate.id,
                dylibURL: candidate.dylibURL,
                displayName: candidate.dylibURL.lastPathComponent,
                relativePath: candidate.relativePath,
                filterTargets: candidate.filterTargets,
                sourceDebName: sourceName
            ))
        }
        if selectedMainPluginID == nil { selectedMainPluginID = plugins.first?.id }
    }

    // MARK: - 签名材料

    /// 加入一个 provisioning profile,读取其 appID 后按需覆盖的 bundle ID 建立映射。
    public func addProvisioningProfile(_ url: URL) {
        guard !provisioningProfiles.contains(url) else { return }
        provisioningProfiles.append(url)
        recomputeProfileMapping()
    }

    /// 按 profile 的 appID 与目标需要的 bundle ID 逐一匹配(支持通配 `*`)。
    private func recomputeProfileMapping() {
        var mapping: [String: URL] = [:]
        let profiles = provisioningProfiles.compactMap { url -> (URL, String)? in
            guard let info = try? SigningService.readProfile(at: url), let appID = info.appID else { return nil }
            return (url, appID)
        }
        for bundleID in requiredProfileBundleIDs {
            if let match = profiles.first(where: { Self.appID($0.1, matches: bundleID) }) {
                mapping[bundleID] = match.0
            }
        }
        profilesByBundleID = mapping
    }

    /// appID 形如 `TEAMID.com.foo.bar` 或 `TEAMID.com.foo.*`;去掉 team 前缀后与 bundleID 比对。
    nonisolated static func appID(_ appID: String, matches bundleID: String) -> Bool {
        guard let dot = appID.firstIndex(of: ".") else { return false }
        let allowed = String(appID[appID.index(after: dot)...])
        if allowed.hasSuffix(".*") { return bundleID.hasPrefix(String(allowed.dropLast())) }
        if allowed == "*" { return true }
        return bundleID == allowed
    }

    // MARK: - 派生决策(全部委托纯函数)

    /// 当前签名三态。
    public var signingDecision: WorkspaceSigningDecision {
        WorkspaceSigningPlanner.decide(
            identity: selectedIdentity,
            profilesByBundleID: profilesByBundleID,
            requiredBundleIDs: requiredProfileBundleIDs,
            appleID: appleIDRecipe
        )
    }

    public var selectedMainPlugin: WorkbenchPlugin? {
        guard let selectedMainPluginID else { return nil }
        return plugins.first { $0.id == selectedMainPluginID }
    }

    /// 主插件与目标 filter 的比对结论。目标身份未载入时为 nil(尚不能判定)。
    public var mainTweakChoice: WorkbenchTweakChoice? {
        guard let plugin = selectedMainPlugin, let identity = targetIdentity else { return nil }
        return WorkbenchTweakEvaluator.evaluate(
            filter: plugin.filterTargets,
            against: identity,
            acknowledgedMismatch: acknowledgedFilterMismatch
        )
    }

    /// 是否被 filter 不匹配阻止(未知情确认)。
    public var isFilterBlocked: Bool { mainTweakChoice?.isBlocked ?? false }

    /// 现在是否允许执行:有源快照、选了主插件、未被 filter 阻断、签名三态允许执行,
    /// 且(若已跑过预检)预检无 blocker。
    public var canExecute: Bool {
        snapshot != nil
            && selectedMainPlugin != nil
            && !isFilterBlocked
            && signingDecision.canExecute
            && !preflightHasBlockers
    }

    /// 按注入顺序排好的 dylib:主插件在前,其余按加入顺序。
    public var orderedDylibs: [URL] {
        guard let main = selectedMainPlugin else { return plugins.map(\.dylibURL) }
        let rest = plugins.filter { $0.id != main.id }.map(\.dylibURL)
        return [main.dylibURL] + rest
    }

    // MARK: - 预检(工作项 2)

    /// 登记后台跑出的预检报告,进入 `.preflighted` 阶段。让用户在执行前先看到问题。
    public func applyPreflight(_ report: IpaPreflightReport) {
        preflightReport = report
        phase = .preflighted
    }

    /// 一份汇总的阻止/告警清单:预检 findings + 主 tweak filter 比对 + 被阻止 DEB 的适格性原因。
    /// 用户应在一处看到所有原因,而不是散落在各卡片或点了执行才被抛错拦住。
    public var combinedPreflightFindings: [IpaPreflightFinding] {
        var findings = preflightReport?.findings ?? []
        if let evaluation = mainTweakChoice?.evaluation { findings += evaluation.findings }
        for deb in blockedDebs {
            findings += deb.factors.map {
                IpaPreflightFinding(
                    severity: .blocker,
                    code: "deb.plugin.\($0.reason.rawValue)",
                    message: "\(deb.name): \($0.explanation)"
                )
            }
        }
        return findings
    }

    /// 预检是否发现 blocker。仅在已跑过预检时据此拦执行(未跑预检不因此拦,execute 仍会兜底)。
    public var preflightHasBlockers: Bool { preflightReport?.hasBlockers ?? false }

    /// 组装可执行的 `InjectionPlan`。会把当前注入顺序写回 recipe。
    public func buildPlan() throws -> InjectionPlan {
        guard let snapshot else { throw InjectionPlanError.validation([]) }
        let ordered = orderedDylibs
        recipe.injectionOrder = ordered.map(\.lastPathComponent)
        let inputs = WorkspacePlanAssembler.Inputs(
            input: snapshot.injectionInput,
            orderedDylibs: ordered,
            frameworks: frameworks,
            recipe: recipe,
            signing: WorkspaceSigningPlanner.signingMode(for: signingDecision)
        )
        return try WorkspacePlanAssembler.makePlan(inputs)
    }

    /// 计划执行需要授予安全作用域访问的全部 URL(原始输入 + 各资源)。
    public var accessURLs: [URL] {
        (snapshot.map { [$0.originalURL, $0.snapshotURL] } ?? [])
            + plugins.map(\.dylibURL)
            + frameworks
            + bundles
            + Array(profilesByBundleID.values)
    }

    // MARK: - 结果录入(工作项 3、6)

    /// 执行成功后录入结果:推导产物三态,并生成默认脱敏的审计报告。
    public func recordExecution(
        _ result: IpaInjectionExecutionResult,
        toolVersion: String
    ) {
        let decision = signingDecision
        artifactState = decision.artifactState(outputURL: result.outputURL)
        executionResult = result
        // 执行内部会重跑预检,取其结果让预检卡在执行后仍反映真实 findings。
        preflightReport = result.preflight
        phase = .handoff

        var pluginHashes: [String: String] = [:]
        for plugin in plugins {
            pluginHashes[plugin.displayName] = (try? DylibService.sha256(fileAt: plugin.dylibURL)) ?? ""
        }
        audit = WorkspaceAuditReport(
            toolVersion: toolVersion,
            inputName: snapshot?.originalURL.lastPathComponent ?? "",
            inputSHA256: snapshot?.sha256 ?? "",
            outputName: result.outputURL.lastPathComponent,
            outputSHA256: (try? DylibService.sha256(fileAt: result.outputURL)),
            pluginHashes: pluginHashes,
            targetProfileBundleIDs: requiredProfileBundleIDs,
            finalInjectedDylibPosition: WorkspacePlanAssembler.finalDylibPosition(from: result),
            findings: result.preflight.findings,
            changedPaths: result.diff.changedPaths,
            unconfirmedDependencies: result.audit.unconfirmedDependencies,
            signingOutcome: Self.signingOutcomeDescription(decision)
        )
    }

    // MARK: - Recipe 落盘(工作项 3)

    /// 保存当前 recipe 到文件。先把当前注入顺序写回,保证保存的是「所见即所存」。
    /// recipe 只含设置、不含文件 URL,因此这份文件能复用到不同拖入来源。
    public func saveRecipe(to url: URL) throws {
        recipe.injectionOrder = orderedDylibs.map(\.lastPathComponent)
        try recipe.save(to: url)
    }

    /// 从文件载入 recipe 并应用。schema 不认识时 `InjectionRecipe.load` 会抛错,这里不吞、不猜。
    public func loadRecipe(from url: URL) throws {
        recipe = try InjectionRecipe.load(from: url)
    }

    static func signingOutcomeDescription(_ decision: WorkspaceSigningDecision) -> String {
        switch decision {
        case .unsigned: return "modified-unsigned"
        case .readyToSign: return "signed-for-handoff (pending on-device verification)"
        case .readyToSignWithAppleID: return "signed-for-handoff-appleid (pending on-device verification)"
        case .waitingForAssets: return "waiting-for-signing-assets"
        }
    }

    public func markPhase(_ phase: WorkspaceRunPhase) {
        self.phase = phase
    }

    public func reset() {
        target = nil
        snapshot = nil
        plugins = []
        directDylibs = []
        frameworks = []
        bundles = []
        provisioningProfiles = []
        blockedDebs = []
        unrecognized = []
        selectedMainPluginID = nil
        acknowledgedFilterMismatch = false
        targetIdentity = nil
        requiredProfileBundleIDs = []
        selectedIdentity = nil
        profilesByBundleID = [:]
        appleIDRecipe = nil
        candidateSessions = []
        preflightReport = nil
        phase = .sourceSnapshot
        artifactState = nil
        audit = nil
        executionResult = nil
    }
}
