import AppKit
import SwiftUI
import UniformTypeIdentifiers
import MacAssistantKit

/// 插件注入页的两种进入方式:拖入式工作台(主入口)与既有 6 步向导(高级模式)。
///
/// 保留向导是为了不丢失它已有的细调能力(自定义目标路径、load command 策略、元数据编辑、
/// 组件移除确认)。工作台面向「一次拖入 → 计划 → 预检 → 执行 → 交接」的主流程,
/// 需要细调时切到高级模式即可。
struct TweakInjectionContainer: View {
    @ObservedObject var job: IpaInjectionJob
    @ObservedObject var workspace: WorkspaceStore

    private enum Mode: String, CaseIterable, Identifiable {
        case workbench, advanced
        var id: String { rawValue }
        var title: String {
            switch self {
            case .workbench: return L("ipaview.mode.workbench")
            case .advanced: return L("ipaview.mode.advanced")
            }
        }
        var icon: String {
            switch self {
            case .workbench: return "square.and.arrow.down.on.square"
            case .advanced: return "slider.horizontal.3"
            }
        }
    }

    @State private var mode: Mode = .workbench

    init(job: IpaInjectionJob, workspace: WorkspaceStore) {
        _job = ObservedObject(wrappedValue: job)
        _workspace = ObservedObject(wrappedValue: workspace)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: IpaLayout.sectionSpacing) {
            Card {
                VStack(alignment: .leading, spacing: 10) {
                    Text(L("ipaview.mode.picker")).font(.headline)
                    Picker(L("ipaview.mode.picker"), selection: $mode) {
                        ForEach(Mode.allCases) { mode in
                            Label(mode.title, systemImage: mode.icon).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
            }

            switch mode {
            case .workbench: IpaWorkbenchTab()
            case .advanced: InjectDylibTab(job: job, workspace: workspace)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 拖入式 IPA 工作台。核心判断逻辑全在 Kit 的 `IpaWorkbenchController` 及其纯函数里,
/// 这里只做拖入路由、后台 I/O 编排与状态渲染。
struct IpaWorkbenchTab: View {
    @StateObject private var controller = IpaWorkbenchController()

    @State private var dropTargeted = false
    @State private var busy = false
    @State private var log = ""
    @State private var ok: Bool?
    @State private var identities: [SigningIdentity] = []
    @State private var appleID = ""
    @State private var appleIDPassword = ""
    @State private var appleIDTwoFactor = ""
    @State private var workbenchDevices: [ConnectedDevice] = []
    @State private var workbenchManualUDID = ""
    @State private var workbenchManualName = ""
    @State private var appleIDBusy = false
    @State private var appleIDMessage = ""

    private var toolVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? AppVersionSource.fallbackVersion
    }

    var body: some View {
        VStack(alignment: .leading, spacing: IpaLayout.sectionSpacing) {
            dropZone
            if controller.snapshot != nil { targetCard }
            if !controller.blockedDebs.isEmpty { blockedDebsCard }
            if !controller.unrecognized.isEmpty { unrecognizedCard }
            if !controller.plugins.isEmpty { pluginsCard }
            if !controller.frameworks.isEmpty || !controller.bundles.isEmpty { resourcesCard }
            if controller.snapshot != nil { fileAccessCard; recipeCard; signingCard }
            if controller.preflightReport != nil { preflightCard }
            if controller.snapshot != nil { executeCard }
            if controller.artifactState != nil { resultCard }
            if busy || !log.isEmpty {
                Card {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(L("ipaview.progressLog")).font(.headline)
                            if busy { ProgressView().controlSize(.small) }
                            Spacer()
                            StatusBadge(ok: ok)
                        }
                        ConsoleView(text: log, minHeight: 140)
                    }
                }
            }
            Text(L("ipaview.betaNotice"))
                .font(.footnote).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task {
            if identities.isEmpty { identities = SigningService.identities() }
            restoreWorkbenchAppleID()
            refreshWorkbenchDevices()
        }
    }

    // MARK: - 拖入区

    private var dropZone: some View {
        VStack(spacing: 8) {
            Image(systemName: "square.and.arrow.down").font(.largeTitle)
            Text(L("workbench.dropZone.title")).font(.headline)
            Text(L("workbench.dropZone.hint"))
                .font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 120)
        .foregroundStyle(dropTargeted ? Color.accentColor : .primary)
        .contentShape(Rectangle())
        .insetSurfaceBackground(
            RoundedRectangle(cornerRadius: 12),
            legacyFill: Color.primary.opacity(dropTargeted ? 0.10 : 0.04)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(
                    dropTargeted ? Color.accentColor : Color.secondary.opacity(0.35),
                    style: StrokeStyle(lineWidth: 1.5, dash: [7])
                )
        }
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: $dropTargeted) { providers in
            for provider in providers {
                provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
                    guard let data, let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                    Task { @MainActor in route([url]) }
                }
            }
            return true
        }
    }

    /// 把拖入的一批 URL 分类并路由:目标包建快照、DEB 后台扫描并过适格性、其余同步分桶。
    private func route(_ urls: [URL]) {
        let (targets, debs) = controller.ingestSimpleInputs(urls)
        for target in targets { ingestTarget(target) }
        for deb in debs { ingestDeb(deb) }
    }

    private func ingestTarget(_ url: URL) {
        busy = true
        ok = nil
        log = L("workbench.ingest.snapshotting", url.lastPathComponent)
        Task {
            do {
                let snapshot = try await Task.detached {
                    try FileSystemHelper.withSecurityScopedAccess(to: [url]) {
                        try ImmutableSourceSnapshot.make(of: url)
                    }
                }.value
                controller.adoptSnapshot(snapshot)
                let context = try await Task.detached { () -> (TweakFilterTargetIdentity?, [String]) in
                    let session = try InjectionTargetDiscovery.open(snapshot.injectionInput)
                    let identity = try? TweakFilterService.targetIdentity(forAppAt: session.appURL)
                    let required = (try? SigningService.profileBundleIDs(in: session.appURL)) ?? []
                    return (identity, required)
                }.value
                controller.applyTargetContext(identity: context.0, requiredBundleIDs: context.1)
                ok = true
                log = L("workbench.ingest.snapshotDone")
            } catch {
                ok = false
                log = "❌ \(operationError(error, paths: [url]))"
            }
            busy = false
        }
    }

    private func ingestDeb(_ url: URL) {
        busy = true
        ok = nil
        log = L("ipaview.deb.extracting")
        Task {
            do {
                let session = try await Task.detached {
                    try FileSystemHelper.withSecurityScopedAccess(to: [url]) {
                        try TweakInjectService.candidateSession(inDebAt: url)
                    }
                }.value
                controller.attachDeb(session: session, sourceName: url.lastPathComponent)
                ok = true
                log = session.pluginEligibility.isEligibleAsIpaPlugin
                    ? L("workbench.deb.attached", url.lastPathComponent)
                    : L("workbench.deb.blocked", url.lastPathComponent)
            } catch {
                ok = false
                log = "❌ \(operationError(error, paths: [url]))"
            }
            busy = false
        }
    }

    // MARK: - 目标卡

    private var targetCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Text(L("workbench.section.target")).font(.headline)
                PathBadge(url: controller.snapshot?.originalURL, placeholder: L("ipaview.noInput"))
                Label(L("workbench.target.immutable"), systemImage: "lock.shield")
                    .font(.footnote).foregroundStyle(.secondary)
                if let identity = controller.targetIdentity {
                    Text(L("workbench.target.identity", identity.mainBundleID))
                        .font(.footnote).foregroundStyle(.secondary).textSelection(.enabled)
                }
                if !controller.requiredProfileBundleIDs.isEmpty {
                    Text(L("workbench.target.requiredProfiles", controller.requiredProfileBundleIDs.count))
                        .font(.caption).foregroundStyle(.secondary)
                }
                macOSAccessGuidance
            }
        }
    }

    /// macOS 侧文件访问引导。与 iOS 产物能力(由 profile / entitlements 决定)是两码事。
    private var macOSAccessGuidance: some View {
        DisclosureGroup(L("ipaview.access.title")) {
            VStack(alignment: .leading, spacing: 8) {
                Text(L("ipaview.access.detail"))
                HStack {
                    Button(L("ipaview.access.filesAndFolders")) {
                        openPrivacySettings(anchor: "Privacy_FilesAndFolders")
                    }
                    Button(L("ipaview.access.fullDisk")) {
                        openPrivacySettings(anchor: "Privacy_AllFiles")
                    }
                }
                Text(L("workbench.permission.iosNote"))
            }
            .font(.caption).foregroundStyle(.secondary).padding(.top, 4)
        }
    }

    // MARK: - 被阻止的 DEB

    private var blockedDebsCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Label(L("workbench.section.blockedDebs"), systemImage: "hand.raised")
                    .font(.headline).foregroundStyle(.orange)
                Text(L("workbench.blockedDebs.note")).font(.caption).foregroundStyle(.secondary)
                ForEach(controller.blockedDebs) { deb in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(deb.name).font(.subheadline.weight(.medium))
                        ForEach(deb.factors) { factor in
                            Text("• \(factor.explanation)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(8)
                    .insetSurfaceBackground(RoundedRectangle(cornerRadius: 8), legacyFill: .orange.opacity(0.08))
                }
            }
        }
    }

    private var unrecognizedCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 6) {
                Label(L("workbench.section.unrecognized"), systemImage: "questionmark.folder")
                    .font(.headline)
                Text(L("workbench.unrecognized.note")).font(.caption).foregroundStyle(.secondary)
                ForEach(controller.unrecognized, id: \.self) { url in
                    Text("• \(url.lastPathComponent)").font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - 插件与主 tweak 选择

    private var pluginsCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Text(L("workbench.section.plugins")).font(.headline)
                Text(L("workbench.plugins.selectMain")).font(.caption).foregroundStyle(.secondary)
                ForEach(controller.plugins) { plugin in
                    pluginRow(plugin)
                }
                if controller.selectedMainPlugin != nil { filterEvaluationView }
            }
        }
    }

    private func pluginRow(_ plugin: WorkbenchPlugin) -> some View {
        let isMain = controller.selectedMainPluginID == plugin.id
        return HStack(spacing: 8) {
            Button {
                controller.selectedMainPluginID = plugin.id
                controller.acknowledgedFilterMismatch = false
            } label: {
                Image(systemName: isMain ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(isMain ? Color.accentColor : .secondary)
            }
            .buttonStyle(.borderless)
            VStack(alignment: .leading, spacing: 1) {
                Text(plugin.displayName).font(.footnote)
                    .lineLimit(1).truncationMode(.middle)
                if let deb = plugin.sourceDebName {
                    Text(L("workbench.plugin.source", deb)).font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if isMain { Text(L("workbench.plugin.main")).font(.caption2).foregroundStyle(Color.accentColor) }
        }
        .padding(8)
        .insetSurfaceBackground(RoundedRectangle(cornerRadius: 8), legacyFill: .primary.opacity(isMain ? 0.08 : 0.03))
    }

    @ViewBuilder
    private var filterEvaluationView: some View {
        if let choice = controller.mainTweakChoice {
            Divider()
            switch choice.overall {
            case .match:
                Label(L("workbench.filter.match"), systemImage: "checkmark.seal")
                    .font(.footnote).foregroundStyle(.green)
            case .indeterminate:
                Label(L("workbench.filter.indeterminate"), systemImage: "questionmark.circle")
                    .font(.footnote).foregroundStyle(.secondary)
            case .mismatch:
                VStack(alignment: .leading, spacing: 6) {
                    Label(L("workbench.filter.mismatch"), systemImage: "exclamationmark.triangle")
                        .font(.footnote).foregroundStyle(.orange)
                    Toggle(isOn: $controller.acknowledgedFilterMismatch) {
                        Text(L("workbench.filter.ackDetail")).font(.caption)
                    }
                    .toggleStyle(.checkbox)
                    .foregroundStyle(.orange)
                }
            }
        } else {
            Text(L("workbench.filter.pendingTarget")).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var resourcesCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 6) {
                Text(L("workbench.section.frameworks")).font(.headline)
                ForEach(controller.frameworks + controller.bundles, id: \.self) { url in
                    Text("• \(url.lastPathComponent)").font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - 文件访问行为(macOS 侧,recipe 的一部分)

    private var fileAccessCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 6) {
                Text(L("workbench.section.fileAccess")).font(.headline)
                Picker(L("workbench.section.fileAccess"), selection: $controller.recipe.fileAccessBehavior) {
                    Text(L("workbench.fileAccess.prompt")).tag(FileAccessBehavior.prompt)
                    Text(L("workbench.fileAccess.require")).tag(FileAccessBehavior.require)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 320)
                Text(L("workbench.fileAccess.note")).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Recipe 保存 / 载入(工作项 3)

    private var recipeCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Text(L("workbench.section.recipe")).font(.headline)
                Text(L("workbench.recipe.note")).font(.caption).foregroundStyle(.secondary)
                TextField(L("ipaview.shortVersion"), text: Binding(
                    get: { controller.recipe.metadata.shortVersion ?? "" },
                    set: { controller.recipe.metadata.shortVersion = $0.nilIfBlank }
                ))
                .textFieldStyle(.roundedBorder)
                TextField(L("ipaview.minimumOS"), text: Binding(
                    get: { controller.recipe.metadata.minimumOSVersion ?? "" },
                    set: { controller.recipe.metadata.minimumOSVersion = $0.nilIfBlank }
                ))
                .textFieldStyle(.roundedBorder)
                Toggle(L("ipaview.ppqRandomize"), isOn: Binding(
                    get: { controller.recipe.metadata.randomizeBundleIDForPPQ },
                    set: { controller.recipe.metadata.randomizeBundleIDForPPQ = $0 }
                ))
                HStack {
                    Button {
                        saveRecipe()
                    } label: {
                        Label(L("workbench.recipe.save"), systemImage: "square.and.arrow.down")
                    }
                    Button {
                        loadRecipe()
                    } label: {
                        Label(L("workbench.recipe.load"), systemImage: "square.and.arrow.up")
                    }
                }
            }
        }
    }

    private func saveRecipe() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "recipe-\(controller.snapshot?.originalURL.deletingPathExtension().lastPathComponent ?? "injection").json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try controller.saveRecipe(to: url)
            log = L("workbench.recipe.saved", url.path)
            ok = true
            revealInFinder(url)
        } catch {
            ok = false
            log = "❌ \(error.localizedDescription)"
        }
    }

    private func loadRecipe() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try controller.loadRecipe(from: url)
            log = L("workbench.recipe.loaded", url.lastPathComponent)
            ok = true
        } catch {
            // schema 不认识时明确报错,不猜、不静默按当前版本解析。
            ok = false
            log = "❌ \(L("workbench.recipe.loadFailed", error.localizedDescription))"
        }
    }

    // MARK: - 签名三态

    private var signingCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Text(L("workbench.section.signing")).font(.headline)
                Picker(L("workbench.signing.identity"), selection: $controller.selectedIdentity) {
                    Text(L("workbench.signing.none")).tag(SigningIdentity?.none)
                    ForEach(identities) { identity in
                        Text(identityExpiryTitle(identity)).tag(SigningIdentity?.some(identity))
                    }
                }
                .frame(maxWidth: 420)
                if let selected = controller.selectedIdentity {
                    expiryCaption(selected.expiryStatus)
                    CertificateDetailsDisclosure(identity: selected)
                }
                if !controller.provisioningProfiles.isEmpty {
                    Text(L("workbench.signing.profilesCount",
                           controller.provisioningProfiles.count,
                           controller.profilesByBundleID.count))
                        .font(.caption).foregroundStyle(.secondary)
                }
                workbenchProfileCapabilities
                Divider()
                workbenchAppleIDSection
                signingStateBadge
            }
        }
    }

    @ViewBuilder
    private var workbenchProfileCapabilities: some View {
        if !controller.profilesByBundleID.isEmpty {
            ForEach(controller.profilesByBundleID.keys.sorted(), id: \.self) { bundleID in
                if let url = controller.profilesByBundleID[bundleID] {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(bundleID).font(.caption.monospaced())
                        ProfileCapabilitiesLoader(profileURL: url)
                    }
                }
            }
        } else if !controller.provisioningProfiles.isEmpty {
            ForEach(controller.provisioningProfiles, id: \.path) { url in
                ProfileCapabilitiesLoader(profileURL: url)
            }
        }
    }

    private var workbenchAppleIDSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("workbench.signing.appleID")).font(.subheadline.weight(.medium))
            HStack {
                TextField(L("signingtab.appleID.account"), text: $appleID)
                    .textFieldStyle(.roundedBorder)
                SecureField(L("signingtab.appleID.password"), text: $appleIDPassword)
                    .textFieldStyle(.roundedBorder)
            }
            TextField(L("signingtab.appleID.twoFactor"), text: $appleIDTwoFactor)
                .textFieldStyle(.roundedBorder)
            HStack {
                Button {
                    loginWorkbenchAppleID()
                } label: {
                    Label(L("signingtab.appleID.login"), systemImage: "person.badge.key")
                }
                .disabled(appleIDBusy || appleID.isEmpty || appleIDPassword.isEmpty)
                if appleIDBusy { ProgressView().controlSize(.small) }
            }
            if let recipe = controller.appleIDRecipe, !recipe.teamID.isEmpty {
                Text(L("workbench.signing.appleID.team", recipe.teamName, recipe.teamID))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !workbenchDevices.isEmpty {
                Picker(L("signingtab.appleID.devices"), selection: Binding(
                    get: { controller.appleIDRecipe?.deviceUDID },
                    set: { updateWorkbenchDevice(udid: $0) }
                )) {
                    Text(L("signingtab.chooseIdentity")).tag(String?.none)
                    ForEach(workbenchDevices) { device in
                        Text(device.summary).tag(Optional(device.udid))
                    }
                }
                .labelsHidden()
            }
            HStack {
                TextField(L("signingtab.appleID.manualUDID.placeholder"), text: $workbenchManualUDID)
                    .textFieldStyle(.roundedBorder)
                TextField(L("signingtab.appleID.manualName.placeholder"), text: $workbenchManualName)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 160)
                Button(L("workbench.signing.useManualUDID")) {
                    applyWorkbenchManualUDID()
                }
            }
            if !appleIDMessage.isEmpty {
                Text(appleIDMessage).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var signingStateBadge: some View {
        switch controller.signingDecision {
        case .unsigned:
            Label(L("workbench.signing.state.unsigned"), systemImage: "seal")
                .font(.footnote).foregroundStyle(.orange)
            Text(L("workbench.signing.state.unsigned.detail")).font(.caption).foregroundStyle(.secondary)
        case let .waitingForAssets(missingIdentity, missingProfiles):
            Label(L("workbench.signing.state.waiting"), systemImage: "hourglass")
                .font(.footnote).foregroundStyle(.orange)
            if missingIdentity {
                Text(L("workbench.signing.state.waiting.missingIdentity"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !missingProfiles.isEmpty {
                Text(L("workbench.signing.state.waiting.missingProfiles", missingProfiles.joined(separator: ", ")))
                    .font(.caption).foregroundStyle(.secondary)
            }
        case .readyToSign:
            Label(L("workbench.signing.state.ready"), systemImage: "checkmark.seal")
                .font(.footnote).foregroundStyle(.green)
        case let .readyToSignWithAppleID(recipe):
            Label(L("workbench.signing.state.readyAppleID"), systemImage: "checkmark.seal")
                .font(.footnote).foregroundStyle(.green)
            Text(L("workbench.signing.state.readyAppleID.detail", recipe.teamName, recipe.deviceName))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: - 预检(工作项 2:执行前独立可见)

    /// 预检报告:把计划、findings 按 blocker / warning / info 分级展示,并入 filter 比对与 DEB 适格性原因。
    /// 让用户在执行前把所有阻止/告警看全,而不是点了执行才被抛错拦住。
    private var preflightCard: some View {
        let findings = controller.combinedPreflightFindings
        let blockers = findings.filter { $0.severity == .blocker }
        let warnings = findings.filter { $0.severity == .warning }
        let infos = findings.filter { $0.severity == .info }
        return Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(L("workbench.section.preflight")).font(.headline)
                    Spacer()
                    if blockers.isEmpty {
                        Label(L("workbench.preflight.noBlockers"), systemImage: "checkmark.circle")
                            .font(.caption).foregroundStyle(.green)
                    } else {
                        Label(L("workbench.preflight.hasBlockers", blockers.count), systemImage: "xmark.octagon")
                            .font(.caption).foregroundStyle(.red)
                    }
                }
                if findings.isEmpty {
                    Text(L("workbench.preflight.empty")).font(.caption).foregroundStyle(.secondary)
                }
                findingGroup(L("workbench.preflight.blockers"), findings: blockers, color: .red, icon: "xmark.octagon")
                findingGroup(L("workbench.preflight.warnings"), findings: warnings, color: .orange, icon: "exclamationmark.triangle")
                findingGroup(L("workbench.preflight.infos"), findings: infos, color: .secondary, icon: "info.circle")
            }
        }
    }

    @ViewBuilder
    private func findingGroup(
        _ title: String,
        findings: [IpaPreflightFinding],
        color: Color,
        icon: String
    ) -> some View {
        if !findings.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Label(title, systemImage: icon).font(.subheadline.weight(.medium)).foregroundStyle(color)
                ForEach(findings) { finding in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(finding.message).font(.caption).foregroundStyle(.primary)
                        Text(finding.code).font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    .padding(.leading, 4)
                }
            }
        }
    }

    // MARK: - 执行

    private var executeCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                runPreflight()
            } label: {
                Label(L("workbench.preflight.run"), systemImage: "checklist")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(busy || controller.snapshot == nil || controller.selectedMainPlugin == nil)
            Button {
                run()
            } label: {
                Label(busy ? L("workbench.running") : L("workbench.execute"), systemImage: "syringe.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(busy || !controller.canExecute)
            if !controller.canExecute && !busy {
                Text(cannotExecuteReason).font(.caption).foregroundStyle(.secondary)
            }
            Button(role: .destructive) { controller.reset(); log = ""; ok = nil } label: {
                Label(L("workbench.reset"), systemImage: "arrow.counterclockwise")
            }
            .buttonStyle(.borderless)
        }
    }

    private var cannotExecuteReason: String {
        if controller.selectedMainPlugin == nil { return L("workbench.cannot.noPlugin") }
        if controller.isFilterBlocked { return L("workbench.cannot.filterBlocked") }
        if controller.signingDecision.isWaiting { return L("workbench.cannot.waitingSigning") }
        if controller.preflightHasBlockers { return L("workbench.cannot.preflightBlocked") }
        return ""
    }

    /// 只预检、不执行:组装计划 → 预检 → 分级展示 findings → 进入 .preflighted 阶段。
    private func runPreflight() {
        busy = true
        ok = nil
        log = L("workbench.preflight.running")
        Task {
            do {
                let plan = try controller.buildPlan()
                let urls = controller.accessURLs
                let report = try await Task.detached {
                    try FileSystemHelper.withSecurityScopedAccess(to: urls) {
                        try IpaInjectionWorkflow.preflight(plan)
                    }
                }.value
                controller.applyPreflight(report)
                ok = !report.hasBlockers
                log = report.hasBlockers ? L("workbench.preflight.blocked") : L("workbench.preflight.ok")
            } catch {
                ok = false
                log = "❌ \(operationError(error, paths: controller.accessURLs))"
            }
            busy = false
        }
    }

    private func run() {
        busy = true
        ok = nil
        log = L("ipaview.creatingWorkspace")
        Task {
            do {
                let plan = try controller.buildPlan()
                controller.markPhase(.planned)
                let urls = controller.accessURLs
                let result = try await Task.detached {
                    try FileSystemHelper.withSecurityScopedAccess(to: urls) {
                        try IpaInjectionWorkflow.execute(plan)
                    }
                }.value
                controller.recordExecution(result, toolVersion: toolVersion)
                ok = result.audit.passed
                var lines = [
                    L("ipaview.result.done"),
                    L("ipaview.result.output", result.outputURL.path),
                    L("ipaview.result.audit", result.audit.entries.count)
                ]
                if !result.audit.unconfirmedDependencies.isEmpty {
                    lines.append(L("workbench.result.unconfirmed.logLine", result.audit.unconfirmedDependencies.count))
                }
                log = (lines + result.log).joined(separator: "\n")
                revealInFinder(result.outputURL)
            } catch {
                ok = false
                log = "❌ \(operationError(error, paths: controller.accessURLs))"
            }
            busy = false
        }
    }

    // MARK: - 结果与交接

    @ViewBuilder
    private var resultCard: some View {
        if let state = controller.artifactState {
            Card {
                VStack(alignment: .leading, spacing: 10) {
                    verificationStatusHeader
                    Divider()
                    artifactStateView(state)
                    if let position = controller.audit?.finalInjectedDylibPosition {
                        Text(L("workbench.result.finalDylib", position))
                            .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    unconfirmedDependenciesView
                    diffSummaryView
                    if controller.audit != nil {
                        Button { exportAudit() } label: {
                            Label(L("workbench.audit.export"), systemImage: "doc.badge.arrow.up")
                        }
                    }
                }
            }
        }
    }

    /// 结果状态头:严格区分「本机静态检查通过」与「设备已验证」——后者本工具永远给不出。
    /// 有未确认依赖时不显示单一绿勾,以免把「本机检查通过」误读成「设备上能跑」。
    @ViewBuilder
    private var verificationStatusHeader: some View {
        let result = controller.executionResult
        let passed = result?.audit.passed ?? false
        let unconfirmedCount = result?.audit.unconfirmedDependencies.count ?? 0
        VStack(alignment: .leading, spacing: 4) {
            if passed {
                if unconfirmedCount > 0 {
                    // 本机结构完整、但有本机无法确认的依赖:用中性图标而非绿勾。
                    Label(L("workbench.result.localPassedWithUnconfirmed", unconfirmedCount),
                          systemImage: "checkmark.circle.trianglebadge.exclamationmark")
                        .font(.headline).foregroundStyle(.orange)
                } else {
                    Label(L("workbench.result.localPassed"), systemImage: "checkmark.circle")
                        .font(.headline).foregroundStyle(.green)
                }
            } else {
                Label(L("workbench.result.localFailed"), systemImage: "xmark.octagon")
                    .font(.headline).foregroundStyle(.red)
            }
            // 无论本机结果如何,都要明确「设备验证」这一步本工具给不出。
            Label(L("workbench.result.deviceUnverified"), systemImage: "iphone.slash")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func artifactStateView(_ state: WorkspaceArtifactState) -> some View {
        switch state {
        case let .modifiedUnsigned(output):
            Label(L("workbench.result.modifiedUnsigned"), systemImage: "exclamationmark.seal")
                .font(.subheadline.weight(.medium)).foregroundStyle(.orange)
            Text(L("workbench.result.modifiedUnsigned.detail")).font(.footnote).foregroundStyle(.secondary)
            PathBadge(url: output)
        case let .signedForHandoff(output):
            Label(L("workbench.result.signedHandoff"), systemImage: "arrow.up.forward.app")
                .font(.subheadline.weight(.medium)).foregroundStyle(.primary)
            Text(L("workbench.result.handoffSteps")).font(.footnote).foregroundStyle(.secondary)
            PathBadge(url: output)
        case .waitingForSigningAssets:
            Label(L("workbench.signing.state.waiting"), systemImage: "hourglass")
                .font(.subheadline.weight(.medium)).foregroundStyle(.orange)
        }
    }

    /// 未确认依赖:第二期把「乐观当系统库」改成如实的「未确认」,这里必须把它显示出来,
    /// 明确告诉用户「本机无法确认,需在已授权设备上验证」,而不是吞掉。
    @ViewBuilder
    private var unconfirmedDependenciesView: some View {
        if let deps = controller.executionResult?.audit.unconfirmedDependencies, !deps.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Label(L("workbench.result.unconfirmed.title", deps.count), systemImage: "questionmark.circle")
                    .font(.subheadline.weight(.medium)).foregroundStyle(.orange)
                Text(L("workbench.result.unconfirmed.note")).font(.caption).foregroundStyle(.secondary)
                ForEach(deps, id: \.self) { dep in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(dep.fileName).font(.footnote.weight(.medium))
                        Text(L("workbench.result.unconfirmed.installPath", dep.installPath))
                            .font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
                        Text(L("workbench.result.unconfirmed.referencedBy", dep.referencedBy))
                            .font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
                        Text(L("workbench.result.unconfirmed.classification",
                               classificationLabel(dep.classification)))
                            .font(.caption2).foregroundStyle(.secondary)
                        Text(L("workbench.result.unconfirmed.evidence", dep.evidence))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .insetSurfaceBackground(RoundedRectangle(cornerRadius: 8), legacyFill: .orange.opacity(0.08))
                }
            }
        }
    }

    /// 注入后重新读盘得到的前后 diff。默认折叠,展开可看 load command / rpath / 签名 / SHA-256 的实际变化。
    @ViewBuilder
    private var diffSummaryView: some View {
        if let diff = controller.executionResult?.diff, diff.hasChanges {
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 8) {
                    if !diff.changedPaths.isEmpty {
                        Text(L("workbench.result.diff.changedPaths")).font(.caption.weight(.medium))
                        ForEach(diff.changedPaths, id: \.self) { path in
                            Text("• \(path)").font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                    }
                    ForEach(diff.diffs.filter { $0.change != .unchanged }, id: \.relativePath) { d in
                        machODiffRow(d)
                    }
                }
                .padding(.top, 4)
            } label: {
                Label(L("workbench.result.diff.title", diff.changedPaths.count), systemImage: "arrow.left.arrow.right")
                    .font(.subheadline.weight(.medium))
            }
        }
    }

    @ViewBuilder
    private func machODiffRow(_ d: MachOArtifactDiff) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(d.relativePath).font(.caption.weight(.medium)).textSelection(.enabled)
                Spacer()
                Text(changeKindLabel(d.change)).font(.caption2).foregroundStyle(.secondary)
            }
            ForEach(d.addedLoadCommands, id: \.self) { cmd in
                Text(L("workbench.result.diff.addedLoad", cmd)).font(.caption2).foregroundStyle(.green)
            }
            ForEach(d.removedLoadCommands, id: \.self) { cmd in
                Text(L("workbench.result.diff.removedLoad", cmd)).font(.caption2).foregroundStyle(.red)
            }
            ForEach(d.addedRPaths, id: \.self) { rp in
                Text(L("workbench.result.diff.addedRpath", rp)).font(.caption2).foregroundStyle(.green)
            }
            ForEach(d.removedRPaths, id: \.self) { rp in
                Text(L("workbench.result.diff.removedRpath", rp)).font(.caption2).foregroundStyle(.red)
            }
            if d.signatureChanged {
                Text(L("workbench.result.diff.signature",
                       signatureLabel(d.before?.signature), signatureLabel(d.after?.signature)))
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if d.sha256Changed {
                Text(L("workbench.result.diff.sha",
                       shortHash(d.before?.sha256), shortHash(d.after?.sha256)))
                    .font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .insetSurfaceBackground(RoundedRectangle(cornerRadius: 8), legacyFill: .primary.opacity(0.03))
    }

    private func classificationLabel(_ classification: DependencyClassification) -> String {
        switch classification {
        case .systemLibrary: return L("workbench.dep.systemLibrary")
        case .appEmbedded: return L("workbench.dep.appEmbedded")
        case .deviceProvided: return L("workbench.dep.deviceProvided")
        case .pluginProvided: return L("workbench.dep.pluginProvided")
        case .unknown: return L("workbench.dep.unknown")
        }
    }

    private func changeKindLabel(_ kind: MachOArtifactChangeKind) -> String {
        switch kind {
        case .added: return L("workbench.result.diff.kind.added")
        case .removed: return L("workbench.result.diff.kind.removed")
        case .modified: return L("workbench.result.diff.kind.modified")
        case .unchanged: return L("workbench.result.diff.kind.unchanged")
        }
    }

    private func signatureLabel(_ state: DylibSignatureState?) -> String {
        switch state {
        case .valid: return L("workbench.sig.valid")
        case .invalid: return L("workbench.sig.invalid")
        case .unsigned: return L("workbench.sig.unsigned")
        case .unavailable, .none: return L("workbench.sig.unavailable")
        }
    }

    private func shortHash(_ hash: String?) -> String {
        guard let hash, !hash.isEmpty else { return "—" }
        return String(hash.prefix(12))
    }

    private func exportAudit() {
        guard let audit = controller.audit else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "audit-\(controller.snapshot?.originalURL.deletingPathExtension().lastPathComponent ?? "report").json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try audit.jsonData(redacted: true).write(to: url, options: .atomic)
            log = L("workbench.audit.exported", url.path)
            ok = true
            revealInFinder(url)
        } catch {
            ok = false
            log = "❌ \(error.localizedDescription)"
        }
    }

    private func identityExpiryTitle(_ identity: SigningIdentity) -> String {
        switch identity.expiryStatus {
        case .unknown: return identity.name
        case let .valid(days): return "\(identity.name) · \(L("signingtab.certificateValid", days))"
        case let .expiringSoon(days): return "\(identity.name) · \(L("signingtab.certificateExpiring", days))"
        case .expired: return "\(identity.name) · \(L("signingtab.certificateExpired"))"
        }
    }

    @ViewBuilder
    private func expiryCaption(_ status: CertificateExpiryStatus) -> some View {
        switch status {
        case .unknown:
            EmptyView()
        case let .valid(days):
            Text(L("signingtab.certificateValid", days)).font(.caption).foregroundStyle(.secondary)
        case let .expiringSoon(days):
            Text(L("signingtab.certificateExpiring", days)).font(.caption).foregroundStyle(.orange)
        case .expired:
            Text(L("signingtab.certificateExpired")).font(.caption).foregroundStyle(.red)
        }
    }

    private func restoreWorkbenchAppleID() {
        guard let account = AppleIDSigningService.rememberedAccount() else { return }
        appleID = account.appleID
        appleIDPassword = AppleIDSigningService.rememberedPassword(for: account.appleID) ?? ""
        if let session = AppleIDSigningService.currentSession(for: account.appleID) {
            var recipe = controller.appleIDRecipe ?? AppleIDSigningRecipe(appleID: account.appleID)
            recipe.appleID = account.appleID
            recipe.teamID = session.teamID
            recipe.teamName = session.teamName
            controller.appleIDRecipe = recipe
        }
    }

    private func refreshWorkbenchDevices() {
        Task {
            workbenchDevices = await Task.detached {
                (try? ConnectedDeviceService.listDevices()) ?? []
            }.value
        }
    }

    private func loginWorkbenchAppleID() {
        let account = appleID.trimmingCharacters(in: .whitespacesAndNewlines)
        let password = appleIDPassword
        let code = appleIDTwoFactor.trimmingCharacters(in: .whitespacesAndNewlines)
        appleIDBusy = true
        appleIDMessage = L("signingtab.appleID.loggingIn")
        Task {
            do {
                let token = try await Task.detached {
                    try AppleIDSigningService.login(
                        appleID: account,
                        password: password,
                        twoFactorCode: code.isEmpty ? nil : code,
                        remember: true
                    )
                }.value
                var recipe = controller.appleIDRecipe ?? AppleIDSigningRecipe(appleID: account)
                recipe.appleID = account
                recipe.teamID = token.teamID
                recipe.teamName = token.teamName
                controller.appleIDRecipe = recipe
                appleIDMessage = L("signingtab.appleID.loggedIn", token.teamName, token.teamID)
            } catch {
                appleIDMessage = error.localizedDescription
            }
            appleIDBusy = false
        }
    }

    private func updateWorkbenchDevice(udid: String?) {
        guard let udid, let device = workbenchDevices.first(where: { $0.udid == udid }) else { return }
        var recipe = controller.appleIDRecipe ?? AppleIDSigningRecipe(appleID: appleID)
        recipe.deviceUDID = device.udid
        recipe.deviceName = device.name
        if recipe.appleID.isEmpty { recipe.appleID = appleID }
        controller.appleIDRecipe = recipe
    }

    private func applyWorkbenchManualUDID() {
        let udid = workbenchManualUDID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard ConnectedDeviceService.isLikelyUDID(udid) else {
            appleIDMessage = L("workbench.signing.invalidUDID")
            return
        }
        let name = workbenchManualName.trimmingCharacters(in: .whitespacesAndNewlines)
        var recipe = controller.appleIDRecipe ?? AppleIDSigningRecipe(appleID: appleID)
        recipe.deviceUDID = udid
        recipe.deviceName = name.isEmpty ? udid : name
        if recipe.appleID.isEmpty { recipe.appleID = appleID }
        controller.appleIDRecipe = recipe
        appleIDMessage = L("workbench.signing.manualUDIDApplied", recipe.deviceName)
    }

    // MARK: - 工具

    private func operationError(_ error: Error, paths: [URL]) -> String {
        if FileSystemHelper.isAccessPermissionError(error) {
            return FileSystemHelper.userFacingAccessError(error, paths: paths)
        }
        return error.localizedDescription
    }

    private func openPrivacySettings(anchor: String) {
        let candidates = [
            "x-apple.systempreferences:com.apple.preference.security?\(anchor)",
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?\(anchor)"
        ]
        for value in candidates {
            if let url = URL(string: value), NSWorkspace.shared.open(url) { return }
        }
    }
}

private extension String {
    var nilIfBlank: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
