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
    @State private var appleID = ""
    @State private var appleIDPassword = ""
    @State private var appleIDTwoFactor = ""
    @State private var workbenchDevices: [ConnectedDevice] = []
    @State private var workbenchManualUDID = ""
    @State private var workbenchManualName = ""
    @State private var appleIDBusy = false
    @State private var appleIDMessage = ""
    @State private var workbenchCertificateMessage = ""

    private var toolVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? AppVersionSource.fallbackVersion
    }

    var body: some View {
        VStack(alignment: .leading, spacing: IpaLayout.sectionSpacing) {
            dropZone
            if controller.snapshot != nil { targetCard }
            if !controller.unrecognized.isEmpty { unrecognizedCard }
            if !controller.plugins.isEmpty { pluginsCard }
            if !controller.frameworks.isEmpty || !controller.bundles.isEmpty { resourcesCard }
            if controller.snapshot != nil {
                recipeCard
                signingCard
            }
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
        .fileURLsDropTarget(isTargeted: $dropTargeted, onDrop: route)
        .onTapGesture { pickFiles() }
        .onHover { hovering in
            if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
        .help(L("workbench.dropZone.help"))
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(L("workbench.dropZone.title"))
        .accessibilityHint(L("workbench.dropZone.help"))
        .accessibilityAction { pickFiles() }
    }

    /// 点击虚线框时弹出访达选择器。可多选，目录型包(.app / .framework / .bundle)也能选。
    private func pickFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowedContentTypes = [.item]
        panel.allowsOtherFileTypes = true
        panel.prompt = L("theme.chooseFile")
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        route(panel.urls)
    }

    /// 把拖入的一批 URL 分类并路由:目标包建快照、DEB 后台扫描抽 dylib、其余同步分桶。
    /// 凑齐 p12 + 描述文件后密码空着就预填 1，可改。
    private func route(_ urls: [URL]) {
        let (targets, debs) = controller.ingestSimpleInputs(urls)
        if controller.hasCertificateSideloadPair,
           controller.developerCertificatePassword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            controller.developerCertificatePassword = SigningService.defaultDeveloperCertificatePassword
        }
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
                let context = try await Task.detached { () -> (TweakFilterTargetIdentity?, [String], AppBundleMetadataSummary?) in
                    let session = try InjectionTargetDiscovery.open(snapshot.injectionInput)
                    let identity = try? TweakFilterService.targetIdentity(forAppAt: session.appURL)
                    let required = (try? SigningService.profileBundleIDs(in: session.appURL)) ?? []
                    let summary = try? AppBundleMetadataSummary.read(from: session.appURL)
                    return (identity, required, summary)
                }.value
                controller.applyTargetContext(identity: context.0, requiredBundleIDs: context.1)
                if let summary = context.2 {
                    controller.applySourceMetadata(summary)
                }
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
                log = L("workbench.deb.attached", url.lastPathComponent)
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
            }
        }
    }

    private func hostLabel(_ choice: PreferredInjectionHost.Choice) -> String {
        switch choice {
        case .automatic: return L("workbench.host.automatic")
        case .preferredFramework: return L("workbench.host.preferredFramework")
        case .protobufLite3: return "ProtobufLite3"
        case .protobufLite2: return "ProtobufLite2"
        case .protobufLite: return "ProtobufLite"
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

    // MARK: - 插件(默认全部注入)

    private var pluginsCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Text(L("workbench.section.plugins")).font(.headline)
                Text(L("workbench.plugins.injectAll")).font(.caption).foregroundStyle(.secondary)
                Text(L("workbench.host.note")).font(.caption).foregroundStyle(.secondary)
                ForEach(controller.plugins) { plugin in
                    pluginRow(plugin)
                }
                if controller.targetIdentity == nil {
                    Text(L("workbench.filter.pendingTarget")).font(.caption).foregroundStyle(.secondary)
                } else if controller.pluginChoices.contains(where: { $0.choice.overall == .mismatch }) {
                    Divider()
                    Toggle(isOn: $controller.acknowledgedFilterMismatch) {
                        Text(L("workbench.filter.ackDetail")).font(.caption)
                    }
                    .toggleStyle(.checkbox)
                    .foregroundStyle(.orange)
                }
            }
        }
    }

    private func pluginRow(_ plugin: WorkbenchPlugin) -> some View {
        let enabled = !controller.disabledPluginIDs.contains(plugin.id)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Toggle("", isOn: Binding(
                    get: { enabled },
                    set: { controller.setPluginEnabled(plugin.id, $0) }
                ))
                .toggleStyle(.checkbox)
                .labelsHidden()
                VStack(alignment: .leading, spacing: 1) {
                    Text(plugin.displayName).font(.footnote)
                        .lineLimit(1).truncationMode(.middle)
                    if let deb = plugin.sourceDebName {
                        Text(L("workbench.plugin.source", deb)).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                pluginFilterBadge(plugin)
            }
            Picker(L("workbench.host.title"), selection: Binding(
                get: { controller.injectionHost(for: plugin) },
                set: { controller.setPluginInjectionHost(plugin.id, $0) }
            )) {
                ForEach(PreferredInjectionHost.Choice.allCases, id: \.self) { choice in
                    Text(hostLabel(choice)).tag(choice)
                }
            }
            .pickerStyle(.menu)
            .disabled(!enabled)
            .font(.caption)
        }
        .padding(8)
        .opacity(enabled ? 1 : 0.45)
        .insetSurfaceBackground(RoundedRectangle(cornerRadius: 8), legacyFill: .primary.opacity(enabled ? 0.06 : 0.03))
    }

    @ViewBuilder
    private func pluginFilterBadge(_ plugin: WorkbenchPlugin) -> some View {
        if let choice = controller.choice(for: plugin) {
            switch choice.overall {
            case .match:
                Text(L("workbench.filter.matchShort")).font(.caption2).foregroundStyle(.green)
            case .indeterminate:
                Text(L("workbench.filter.indeterminateShort")).font(.caption2).foregroundStyle(.secondary)
            case .mismatch:
                Text(L("workbench.filter.mismatchShort")).font(.caption2).foregroundStyle(.orange)
            }
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

    // MARK: - 预设开关(写入 recipe,可保存 / 载入)

    private var recipeCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Text(L("workbench.section.recipe")).font(.headline)
                Text(L("workbench.recipe.note")).font(.caption).foregroundStyle(.secondary)

                TextField(L("ipaview.displayName"), text: metadataBinding(\.displayName, fallback: \.displayName))
                .textFieldStyle(.soft)
                TextField(L("ipaview.bundleID"), text: metadataBinding(\.bundleID, fallback: \.bundleID))
                .textFieldStyle(.soft)
                Text(L("workbench.recipe.bundleID.note"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    TextField(L("ipaview.shortVersion"), text: metadataBinding(\.shortVersion, fallback: \.shortVersion))
                    .textFieldStyle(.soft)
                    TextField(L("ipaview.minimumOS"), text: minimumOSBinding)
                    .textFieldStyle(.soft)
                }
                Text(L("workbench.recipe.minimumOS.note"))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Divider()

                Toggle(L("ipaview.enableFileSharing"), isOn: Binding(
                    get: { controller.recipe.metadata.enableFileSharing },
                    set: { controller.recipe.metadata.enableFileSharing = $0 }
                ))
                Toggle(L("ipaview.removeURLSchemes"), isOn: Binding(
                    get: { controller.recipe.metadata.removeURLSchemes },
                    set: { controller.recipe.metadata.removeURLSchemes = $0 }
                ))
                if controller.isWeChatTarget {
                    Toggle(L("workbench.recipe.repairNightIcon"), isOn: Binding(
                        get: { controller.recipe.metadata.repairWhiteIcon },
                        set: { controller.recipe.metadata.repairWhiteIcon = $0 }
                    ))
                }

                Divider()

                Toggle(L("ipaview.removeWatch"), isOn: componentBinding(\.watch))
                Toggle(L("ipaview.removePlugIns"), isOn: componentBinding(\.plugIns))
                Toggle(L("ipaview.removeAppClips"), isOn: componentBinding(\.appClips))
                if controller.recipe.components.removesAnything {
                    Toggle(isOn: Binding(
                        get: { controller.recipe.components.destructiveRemovalConfirmed },
                        set: { controller.recipe.components.destructiveRemovalConfirmed = $0 }
                    )) {
                        Text(L("workbench.recipe.confirmRemoval")).font(.caption)
                    }
                    .toggleStyle(.checkbox)
                    .foregroundStyle(.orange)
                }

                Toggle(L("workbench.recipe.rewriteJailbreakDeps"), isOn: Binding(
                    get: { controller.recipe.rewriteJailbreakDependencies },
                    set: { controller.recipe.rewriteJailbreakDependencies = $0 }
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
                    .filePickerDrop { urls in
                        if let url = urls.first { applyRecipe(url) }
                    }
                }
            }
        }
    }

    private func componentBinding(
        _ keyPath: WritableKeyPath<InjectionComponentPolicy, ComponentDisposition>
    ) -> Binding<Bool> {
        Binding(
            get: { controller.recipe.components[keyPath: keyPath] == .remove },
            set: { on in
                controller.recipe.components[keyPath: keyPath] = on ? .remove : .preserve
                if !controller.recipe.components.removesAnything {
                    controller.recipe.components.destructiveRemovalConfirmed = false
                }
            }
        )
    }

    /// 输入框显示当前包的 Info.plist 值；只有用户改过的才写入预设。
    private func metadataBinding(
        _ recipeKey: WritableKeyPath<InjectionMetadataChanges, String?>,
        fallback sourceKey: KeyPath<AppBundleMetadataSummary, String>
    ) -> Binding<String> {
        Binding(
            get: {
                controller.recipe.metadata[keyPath: recipeKey]
                    ?? controller.sourceAppMetadata?[keyPath: sourceKey]
                    ?? ""
            },
            set: { newValue in
                let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                let original = controller.sourceAppMetadata?[keyPath: sourceKey] ?? ""
                controller.recipe.metadata[keyPath: recipeKey] =
                    (trimmed.isEmpty || trimmed == original) ? nil : trimmed
            }
        )
    }

    /// 最低系统不跟 IPA 走。空着就不改，和 injectipa 一样。
    private var minimumOSBinding: Binding<String> {
        Binding(
            get: {
                controller.recipe.metadata.minimumOSVersion?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            },
            set: { newValue in
                let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                controller.recipe.metadata.minimumOSVersion = trimmed.isEmpty ? nil : trimmed
            }
        )
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
        applyRecipe(url)
    }

    private func applyRecipe(_ url: URL) {
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
                Text(L("workbench.signing.choice.note"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("", selection: Binding(
                    get: { controller.recipe.sideloadSigning },
                    set: { controller.recipe.sideloadSigning = $0 }
                )) {
                    Text(L("workbench.signing.choice.none")).tag(SideloadSigningChoice.none)
                    Text(L("workbench.signing.choice.appleID")).tag(SideloadSigningChoice.appleID)
                    Text(L("workbench.signing.choice.p12")).tag(SideloadSigningChoice.p12)
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                switch controller.recipe.sideloadSigning {
                case .none:
                    signingStateBadge
                case .appleID:
                    workbenchAppleIDSection
                    signingStateBadge
                case .p12:
                    workbenchP12Section
                    signingStateBadge
                }
            }
        }
    }

    private var workbenchP12Section: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("workbench.signing.certificate.note"))
                .font(.caption)
                .foregroundStyle(.secondary)
            workbenchP12Import
            if !controller.provisioningProfiles.isEmpty {
                Text(L("workbench.signing.profilesCount",
                       controller.provisioningProfiles.count,
                       controller.profilesByBundleID.count))
                    .font(.caption).foregroundStyle(.secondary)
            }
            workbenchProfileCapabilities
        }
    }

    private var workbenchP12Import: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                MultiFilePickerButton(
                    title: workbenchP12PickerTitle,
                    systemImage: "key.fill",
                    types: certificateMaterialTypes
                ) { urls in
                    adoptWorkbenchCertificateMaterials(urls)
                }
                TextField(L("signingtab.p12Password"), text: $controller.developerCertificatePassword)
                    .textFieldStyle(.soft)
                    .frame(maxWidth: 220)
            }
            if !workbenchCertificateMessage.isEmpty {
                Text(workbenchCertificateMessage)
                    .font(.caption)
                    .foregroundStyle(workbenchCertificateMessage.hasPrefix("❌") ? .red : .secondary)
            }
        }
    }

    private var certificateMaterialTypes: [UTType] {
        [.item]
    }

    private var workbenchP12PickerTitle: String {
        let cert = controller.pendingCertificateURL?.lastPathComponent
        let profile = controller.provisioningProfiles.last?.lastPathComponent
        switch (cert, profile) {
        case let (c?, p?):
            return L("workbench.signing.pair.ready", c, p)
        case let (c?, nil):
            return c
        case let (nil, p?):
            return p
        default:
            return L("signingtab.chooseP12AndProfile")
        }
    }

    private func adoptWorkbenchCertificateMaterials(_ urls: [URL]) {
        _ = controller.ingestSimpleInputs(urls)
        if controller.developerCertificatePassword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            controller.developerCertificatePassword = SigningService.defaultDeveloperCertificatePassword
        }
        workbenchCertificateMessage = ""
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
            Text(L("workbench.signing.appleID.note"))
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                TextField(L("signingtab.appleID.account"), text: $appleID)
                    .textFieldStyle(.soft)
                SecureField(L("signingtab.appleID.password"), text: $appleIDPassword)
                    .textFieldStyle(.soft)
            }
            TextField(L("signingtab.appleID.twoFactor"), text: $appleIDTwoFactor)
                .textFieldStyle(.soft)
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
                    .textFieldStyle(.soft)
                TextField(L("signingtab.appleID.manualName.placeholder"), text: $workbenchManualName)
                    .textFieldStyle(.soft)
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
            switch controller.recipe.sideloadSigning {
            case .appleID:
                if missingIdentity {
                    Text(L("workbench.signing.state.waiting.missingAppleID"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                if !missingProfiles.isEmpty {
                    Text(L("workbench.signing.state.waiting.missingDevice"))
                        .font(.caption).foregroundStyle(.secondary)
                }
            case .p12:
                if missingIdentity {
                    Text(L("workbench.signing.state.waiting.missingIdentity"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                if !missingProfiles.isEmpty {
                    Text(L("workbench.signing.state.waiting.missingProfiles"))
                        .font(.caption).foregroundStyle(.secondary)
                }
            case .none:
                EmptyView()
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
            .disabled(busy || controller.snapshot == nil || controller.enabledPlugins.isEmpty)
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
            Button(role: .destructive) {
                controller.reset()
                workbenchCertificateMessage = ""
                log = ""
                ok = nil
            } label: {
                Label(L("workbench.reset"), systemImage: "arrow.counterclockwise")
            }
            .buttonStyle(.borderless)
        }
    }

    private var cannotExecuteReason: String {
        if controller.enabledPlugins.isEmpty { return L("workbench.cannot.noPlugin") }
        if controller.isComponentRemovalBlocked { return L("workbench.cannot.removalUnconfirmed") }
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
                let gate = ProgressLogGate()
                let progress: @Sendable (String) -> Void = { line in
                    Task { @MainActor in
                        guard !gate.isStopped else { return }
                        if log.isEmpty {
                            log = line
                        } else {
                            log += "\n" + line
                        }
                    }
                }
                let outputURL = controller.proposedOutputURL
                let result = try await Task.detached {
                    try FileSystemHelper.withSecurityScopedAccess(to: urls) {
                        try IpaInjectionWorkflow.execute(plan, outputURL: outputURL, progress: progress)
                    }
                }.value
                gate.stop()
                controller.recordExecution(result, toolVersion: toolVersion)
                ok = result.audit.passed
                var lines = result.log
                if !result.audit.unconfirmedDependencies.isEmpty {
                    lines.append(L("workbench.result.unconfirmed.logLine", result.audit.unconfirmedDependencies.count))
                }
                log = lines.joined(separator: "\n")
                revealInFinder(result.outputURL)
            } catch {
                ok = false
                let detail = operationError(error, paths: controller.accessURLs)
                if log.isEmpty {
                    log = "❌ \(detail)"
                } else {
                    log += "\n❌ \(detail)"
                }
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

    /// 未确认依赖保留数量摘要,避免把「本机无法确认」静默吞掉;逐条证据默认折叠,
    /// 由需要排查的用户主动展开,避免几十条依赖把结果区撑得过长。
    @ViewBuilder
    private var unconfirmedDependenciesView: some View {
        if let deps = controller.executionResult?.audit.unconfirmedDependencies, !deps.isEmpty {
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L("workbench.result.unconfirmed.note"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
                .padding(.top, 4)
            } label: {
                Label(L("workbench.result.unconfirmed.title", deps.count), systemImage: "questionmark.circle")
                    .font(.subheadline.weight(.medium)).foregroundStyle(.orange)
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
}

/// 执行结束后挡住尚未落地的进度 Task,避免把已定稿的完整日志再追加一行。
private final class ProgressLogGate: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false

    var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    func stop() {
        lock.lock()
        stopped = true
        lock.unlock()
    }
}

private extension String {
    var nilIfBlank: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
