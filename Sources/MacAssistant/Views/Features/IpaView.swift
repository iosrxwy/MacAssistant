import AppKit
import SwiftUI
import UniformTypeIdentifiers
import MacAssistantKit

private enum IpaLayout {
    static let sectionSpacing: CGFloat = 16
    static let formSpacing: CGFloat = 12
    static let featurePickerMinimumWidth: CGFloat = 520
    static let stepPickerMinimumWidth: CGFloat = 660
    /// 进度轨比同样内容的分段控件紧凑，阈值沿用 660 会让默认窗口宽度直接退化成下拉菜单。
    static let stepRailMinimumWidth: CGFloat = 560
    static let navigationButtonWidth: CGFloat = 88
}

/// IPA 工具箱:插件注入 / 瘦身 / 提取头文件 / 签名。
@MainActor
final class IpaInjectionJob: ObservableObject {
    @Published private(set) var running = false
    @Published private(set) var ok: Bool?
    @Published private(set) var log = ""

    private var task: Task<Void, Never>?

    func start(plan: InjectionPlan, urls: [URL]) {
        guard !running else { return }
        running = true
        ok = nil
        log = L("ipaview.creatingWorkspace")
        let progress: @Sendable (String) -> Void = { [weak self] line in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.log += "\n" + line
            }
        }
        task = Task { [weak self] in
            do {
                let result = try await Task.detached {
                    try FileSystemHelper.withSecurityScopedAccess(to: urls) {
                        try IpaInjectionWorkflow.execute(plan, progress: progress)
                    }
                }.value
                self?.log = ([
                    L("ipaview.result.done"),
                    L("ipaview.result.output", result.outputURL.path),
                    L("ipaview.result.audit", result.audit.entries.count),
                    "———"
                ] + result.log).joined(separator: "\n")
                self?.ok = true
                revealInFinder(result.outputURL)
            } catch {
                self?.ok = false
                self?.log += "\n❌ " + error.localizedDescription
            }
            self?.running = false
        }
    }

    deinit { task?.cancel() }
}

enum InjectionInputMode: Equatable {
    case ipa
    case macOSApp
}

struct IpaView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case tweak = "插件注入"
        case slim = "瘦身"
        case headers = "提取头文件"
        case sign = "签名"
        var id: String { rawValue }

        /// rawValue 同时是选中态的标识,展示一律走这里。
        var title: String {
            switch self {
            case .tweak: return L("ipaview.tab.tweak")
            case .slim: return L("ipaview.tab.slim")
            case .headers: return L("ipaview.tab.headers")
            case .sign: return L("ipaview.tab.sign")
            }
        }

        var icon: String {
            switch self {
            case .tweak: return "puzzlepiece.extension"
            case .slim: return "scissors"
            case .headers: return "doc.text.magnifyingglass"
            case .sign: return "signature"
            }
        }
    }

    @State private var tab: Tab = .tweak
    @ObservedObject var injectionJob: IpaInjectionJob
    @ObservedObject var workspace: WorkspaceStore

    @MainActor init(injectionJob: IpaInjectionJob, workspace: WorkspaceStore) {
        _injectionJob = ObservedObject(wrappedValue: injectionJob)
        _workspace = ObservedObject(wrappedValue: workspace)
    }

    var body: some View {
        FeatureScaffold(title: L("ipaview.title"),
                        subtitle: L("ipaview.subtitle")) {
            VStack(alignment: .leading, spacing: IpaLayout.sectionSpacing) {
                AdaptiveSegmentedPicker(
                    title: L("ipaview.featurePicker"),
                    selection: $tab,
                    minimumSegmentedWidth: IpaLayout.featurePickerMinimumWidth
                ) {
                    ForEach(Tab.allCases) { tab in
                        Label(tab.title, systemImage: tab.icon).tag(tab)
                    }
                }
                .accessibilityIdentifier("ipa.featurePicker")

                Group {
                    switch tab {
                    case .tweak: InjectDylibTab(job: injectionJob, workspace: workspace)
                    case .slim: SlimTab()
                    case .headers: ClassDumpTab()
                    case .sign: SigningTab()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - 注入计划向导

struct InjectDylibTab: View {
    @ObservedObject var job: IpaInjectionJob
    @ObservedObject var workspace: WorkspaceStore
    let inputMode: InjectionInputMode

    init(
        job: IpaInjectionJob,
        workspace: WorkspaceStore,
        inputMode: InjectionInputMode = .ipa
    ) {
        _job = ObservedObject(wrappedValue: job)
        _workspace = ObservedObject(wrappedValue: workspace)
        self.inputMode = inputMode
    }

    private enum Step: String, CaseIterable, Identifiable {
        case input = "输入"
        case payloads = "插件 / 资源"
        case targets = "目标映射"
        case metadata = "App 元数据"
        case signing = "签名"
        case preflight = "预检 / 执行"
        var id: String { rawValue }

        /// rawValue 同时是选中态的标识,展示一律走这里。
        var title: String {
            switch self {
            case .input: return L("ipaview.step.input")
            case .payloads: return L("ipaview.step.payloads")
            case .targets: return L("ipaview.step.targets")
            case .metadata: return L("ipaview.step.metadata")
            case .signing: return L("ipaview.step.signing")
            case .preflight: return L("ipaview.step.execute")
            }
        }
    }

    private struct DylibDraft: Identifiable {
        let id = UUID()
        var url: URL
        var targetID: String?
        var usesCustomTarget = false
        var customTargetPath = ""
        var loadKind: InjectionLoadKind = .required
        var existingPolicy: ExistingLoadCommandPolicy = .replace
    }

    private struct ResourceDraft: Identifiable {
        let id = UUID()
        var url: URL
        var destination: String
        var replaceExisting = false
    }

    @State private var step: Step = .input
    @State private var inputURL: URL?
    @State private var targetSession: InjectionTargetSession?
    @State private var dylibs: [DylibDraft] = []
    @State private var debSessions: [DebTweakCandidateSession] = []
    @State private var resources: [ResourceDraft] = []
    @State private var protobufLite: URL?
    @State private var protobufLite2: URL?
    @State private var protobufLite3: URL?
    @State private var icons: [URL] = []
    @State private var displayName = ""
    @State private var bundleID = ""
    @State private var outputName = ""
    @State private var enableFileSharing = false
    @State private var repairWhiteIcon = false
    @State private var removeVOIPBackgroundMode = false
    @State private var removeURLSchemes = false
    @State private var removeWatch = false
    @State private var removePlugIns = false
    @State private var removeAppClips = false
    @State private var confirmWatchRemoval = false
    @State private var confirmPlugInsRemoval = false
    @State private var confirmAppClipsRemoval = false
    @State private var stripSignature = true
    @State private var signMethod: SignMethod = .codesignAdhoc
    @State private var developerSigning = false
    @State private var identities: [SigningIdentity] = []
    @State private var selectedIdentity: SigningIdentity?
    @State private var profilesByBundleID: [String: URL] = [:]
    @State private var busy = false
    @State private var log = ""
    @State private var ok: Bool?
    @State private var showWeakHelp = false

    var body: some View {
        VStack(alignment: .leading, spacing: IpaLayout.sectionSpacing) {
            stepSelector
            currentStep
            workflowFooter

            if busy || !log.isEmpty || job.running || !job.log.isEmpty {
                Card {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(L("ipaview.progressLog")).font(.headline)
                            if busy || job.running { ProgressView().controlSize(.small) }
                            Spacer()
                            StatusBadge(ok: job.ok ?? ok)
                        }
                        ConsoleView(text: job.log.isEmpty ? log : job.log, minHeight: 180)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var stepSelector: some View {
        ViewThatFits(in: .horizontal) {
            StepRail(
                titles: Step.allCases.map(\.title),
                currentIndex: Step.allCases.firstIndex(of: step) ?? 0
            ) { index in
                step = Step.allCases[index]
            }
            .frame(minWidth: IpaLayout.stepRailMinimumWidth, maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 0) {
                Picker(L("ipaview.stepNavigation"), selection: $step) {
                    ForEach(Step.allCases) { step in
                        Text(step.title).tag(step)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize(horizontal: true, vertical: false)
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityLabel(L("ipaview.stepNavigation"))
        .accessibilityIdentifier("ipa.inject.stepPicker")
    }

    @ViewBuilder
    private var currentStep: some View {
        switch step {
        case .input: inputStep
        case .payloads: payloadStep
        case .targets: targetStep
        case .metadata: metadataStep
        case .signing: signingStep
        case .preflight: preflightStep
        }
    }

    private var workflowFooter: some View {
        VStack(alignment: .leading, spacing: 12) {
            // 这对导航按钮浮在卡片之外，是页面里唯一适合直接上玻璃按钮的控件组。
            GlassGroup(spacing: 12) {
                HStack(spacing: 12) {
                    Button {
                        moveStep(-1)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "chevron.left")
                            Text(L("ipaview.previous"))
                        }
                        .frame(minWidth: IpaLayout.navigationButtonWidth)
                    }
                    .glassActionButtonStyle()
                    .disabled(step == Step.allCases.first || busy || job.running)

                    Spacer(minLength: 16)

                    Button {
                        moveStep(1)
                    } label: {
                        HStack(spacing: 6) {
                            Text(L("ipaview.next"))
                            Image(systemName: "chevron.right")
                        }
                        .frame(minWidth: IpaLayout.navigationButtonWidth)
                    }
                    .glassActionButtonStyle(prominent: true)
                    .disabled(step == Step.allCases.last || busy || job.running)
                }
                .controlSize(.large)
                .frame(maxWidth: .infinity)
            }

            Text(L("ipaview.betaNotice"))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var inputStep: some View {
        Card {
            VStack(alignment: .leading, spacing: IpaLayout.formSpacing) {
                Text(L(inputMode == .ipa ? "ipaview.section.input" : "macappview.section.input")).font(.headline)
                Group {
                    if inputMode == .ipa {
                        inputIPAButton
                    } else {
                        inputAppButton
                    }
                }
                .controlSize(.regular)
                PathBadge(url: inputURL, placeholder: L("ipaview.noInput"))
                Text(L("ipaview.input.note"))
                    .font(.footnote).foregroundStyle(.secondary)
                if let targetSession {
                    Label(
                        L("ipaview.targetsFound", targetSession.targets.count),
                        systemImage: "checkmark.circle"
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
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
                        Text(L("ipaview.access.note"))
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
                }
            }
        }
    }

    private var inputIPAButton: some View {
        FilePickerButton(
            title: L("ipaview.chooseIPA"),
            systemImage: "app.gift",
            types: [.ipaPackage, .data]
        ) {
            inputURL = $0
            invalidate()
            discoverTargets()
        }
    }

    private var inputAppButton: some View {
        FilePickerButton(
            title: L("ipaview.chooseApp"),
            systemImage: "app",
            chooseDirectory: true
        ) {
            guard $0.pathExtension.lowercased() == "app" else {
                ok = false
                log = L("ipaview.needAppDirectory")
                return
            }
            inputURL = $0
            invalidate()
            discoverTargets()
        }
    }

    private var payloadStep: some View {
        Card {
            VStack(alignment: .leading, spacing: IpaLayout.formSpacing) {
                Text(L("ipaview.section.payloads")).font(.headline)
                HStack {
                    IpaMultiFilePickerButton(
                        title: L("ipaview.addDylibs"),
                        systemImage: "syringe",
                        types: [.dylibFile, .debPackage, .item]
                    ) { urls in
                        addPayloads(urls)
                    }
                    IpaMultiFilePickerButton(
                        title: L("ipaview.addResources"),
                        systemImage: "folder.badge.plus",
                        types: [.item]
                    ) { urls in
                        resources += urls.map {
                            ResourceDraft(url: $0, destination: "Resources/\($0.lastPathComponent)")
                        }
                        invalidate()
                    }
                    if inputMode == .ipa && (!dylibs.isEmpty || !dependencyFrameworks.isEmpty) {
                        Button {
                            workspace.createDebDraft(fileURLs: dylibs.map(\.url) + dependencyFrameworks)
                        } label: {
                            Label("打包为 DEB", systemImage: "shippingbox")
                        }
                    }
                    Spacer()
                }
                ForEach(dylibs) { draft in
                    HStack {
                        Text(draft.url.lastPathComponent)
                        Spacer()
                        Button(role: .destructive) {
                            dylibs.removeAll { $0.id == draft.id }
                            invalidate()
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                    }
                }
                ForEach($resources) { resource in
                    resourceRow(resource)
                }
            }
        }
    }

    private func frameworkDependencyPicker(title: String, value: Binding<URL?>) -> some View {
        HStack {
            FilePickerButton(
                title: value.wrappedValue?.lastPathComponent ?? title,
                systemImage: "shippingbox",
                chooseDirectory: true
            ) { url in
                guard url.pathExtension.lowercased() == "framework" else { return }
                value.wrappedValue = url
                invalidate()
            }
            if value.wrappedValue != nil {
                Button(L("tweaktab.clear")) {
                    value.wrappedValue = nil
                    invalidate()
                }
                .buttonStyle(.borderless)
            }
        }
    }

    private func addPayloads(_ urls: [URL]) {
        urls.filter { $0.pathExtension.lowercased() == "dylib" }.forEach(addDylib)
        let archives = urls.filter { $0.pathExtension.lowercased() == "deb" }
        invalidate()
        guard !archives.isEmpty else { return }

        busy = true
        log = L("ipaview.deb.extracting")
        Task {
            do {
                let sessions = try await Task.detached {
                    try FileSystemHelper.withSecurityScopedAccess(to: archives) {
                        try archives.map(TweakInjectService.candidateSession(inDebAt:))
                    }
                }.value
                debSessions += sessions
                let candidates = sessions.flatMap(\.candidates)
                candidates.map(\.dylibURL).forEach(addDylib)
                log = L("ipaview.deb.extracted", archives.count, candidates.count)
                ok = true
            } catch {
                ok = false
                log = "❌ \(operationError(error, paths: archives))"
            }
            busy = false
        }
    }

    private func addDylib(_ url: URL) {
        if let index = dylibs.firstIndex(where: {
            $0.url.lastPathComponent.caseInsensitiveCompare(url.lastPathComponent) == .orderedSame
        }) {
            dylibs[index].url = url
        } else {
            dylibs.append(DylibDraft(
                url: url,
                targetID: targetSession?.targets.first(where: \.isRecommended)?.id
            ))
        }
    }

    private func resourceRow(_ resource: Binding<ResourceDraft>) -> some View {
        let value = resource.wrappedValue
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                Text(value.url.lastPathComponent)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(minWidth: 140, idealWidth: 180, maxWidth: 180, alignment: .leading)
                TextField(L("ipaview.resourceDestination"), text: resource.destination)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 180)
                Toggle(L("ipaview.replaceExisting"), isOn: resource.replaceExisting)
                    .toggleStyle(.checkbox)
                resourceDeleteButton(id: value.id)
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(value.url.lastPathComponent)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 8)
                    resourceDeleteButton(id: value.id)
                }
                TextField(L("ipaview.resourceDestination"), text: resource.destination)
                    .textFieldStyle(.roundedBorder)
                Toggle(L("ipaview.replaceExisting"), isOn: resource.replaceExisting)
                    .toggleStyle(.checkbox)
            }
        }
    }

    private func resourceDeleteButton(id: UUID) -> some View {
        Button(role: .destructive) {
            resources.removeAll { $0.id == id }
            invalidate()
        } label: {
            Image(systemName: "trash")
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(L("ipaview.removeResource"))
    }

    private var targetStep: some View {
        Card {
            VStack(alignment: .leading, spacing: IpaLayout.formSpacing) {
                Text(L("ipaview.section.targets")).font(.headline)
                Text(L("ipaview.targets.note"))
                    .font(.footnote).foregroundStyle(.secondary)
                if !dylibs.isEmpty {
                    Text(L("ipaview.frameworkDependencies")).font(.subheadline.weight(.semibold))
                    frameworkDependencyPicker(title: L("tweaktab.protobufLite"), value: $protobufLite)
                    frameworkDependencyPicker(title: L("tweaktab.protobufLite2"), value: $protobufLite2)
                    frameworkDependencyPicker(title: L("tweaktab.protobufLite3"), value: $protobufLite3)
                    Divider()
                }
                ForEach($dylibs) { $draft in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(draft.url.lastPathComponent).font(.subheadline.weight(.medium))
                        if let targetSession, !targetSession.targets.isEmpty {
                            Picker(L("ipaview.injectionTarget"), selection: $draft.targetID) {
                                ForEach(targetSession.targets) { target in
                                    Text(targetPickerLabel(target))
                                        .tag(Optional(target.id))
                                }
                            }
                            .disabled(draft.usesCustomTarget)
                            if let target = selectedTarget(for: draft) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(target.relativePath)
                                    Text(
                                        "\(target.architectures.joined(separator: ", ")) · cryptid=\(target.cryptid)"
                                            + (target.bundleID.map { " · \($0)" } ?? "")
                                    )
                                    if let point = target.extensionPointIdentifier {
                                        Text("Extension Point：\(point)")
                                    }
                                    if let note = target.restrictionNote {
                                        Text(note).foregroundStyle(.orange)
                                    }
                                }
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                            }
                        } else {
                            Text(L("ipaview.targets.empty"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        DisclosureGroup(
                            L("ipaview.customTarget"),
                            isExpanded: $draft.usesCustomTarget
                        ) {
                            TextField(
                                L("ipaview.customTarget.placeholder"),
                                text: $draft.customTargetPath
                            )
                            .textFieldStyle(.roundedBorder)
                            .padding(.top, 4)
                        }
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 10) {
                                loadKindPicker(selection: $draft.loadKind)
                                    .frame(minWidth: 220, maxWidth: .infinity, alignment: .leading)
                                weakLoadHelpButton
                                existingCommandPicker(selection: $draft.existingPolicy)
                                    .frame(minWidth: 240, maxWidth: .infinity, alignment: .leading)
                            }

                            VStack(alignment: .leading, spacing: 8) {
                                HStack(spacing: 8) {
                                    loadKindPicker(selection: $draft.loadKind)
                                    weakLoadHelpButton
                                }
                                existingCommandPicker(selection: $draft.existingPolicy)
                            }
                        }
                    }
                    Divider()
                }
                if inputMode == .ipa && !packageablePluginURLs.isEmpty {
                    Button {
                        workspace.createDebDraft(fileURLs: packageablePluginURLs)
                    } label: {
                        Label("将已选插件 / Framework 打包为 DEB", systemImage: "shippingbox")
                    }
                }
            }
        }
    }

    private func loadKindPicker(selection: Binding<InjectionLoadKind>) -> some View {
        Picker(L("ipaview.loadKind"), selection: selection) {
            ForEach(InjectionLoadKind.allCases, id: \.self) {
                Text($0.displayName).tag($0)
            }
        }
    }

    private func existingCommandPicker(
        selection: Binding<ExistingLoadCommandPolicy>
    ) -> some View {
        Picker(L("ipaview.existingCommand"), selection: selection) {
            Text(L("ipaview.existing.fail")).tag(ExistingLoadCommandPolicy.fail)
            Text(L("ipaview.existing.skip")).tag(ExistingLoadCommandPolicy.skip)
            Text(L("ipaview.existing.replace")).tag(ExistingLoadCommandPolicy.replace)
        }
    }

    private var weakLoadHelpButton: some View {
        Button {
            showWeakHelp.toggle()
        } label: {
            Image(systemName: "questionmark.circle")
        }
        .buttonStyle(.borderless)
        .help(L("ipaview.loadKind.help"))
        .popover(isPresented: $showWeakHelp, arrowEdge: .bottom) {
            Text(L("ipaview.loadKind.detail"))
                .font(.callout)
                .frame(width: 360, alignment: .leading)
                .padding()
        }
    }

    private var metadataStep: some View {
        Card {
            VStack(alignment: .leading, spacing: IpaLayout.formSpacing) {
                Text(L("ipaview.section.metadata")).font(.headline)
                TextField(L("ipaview.displayName"), text: $displayName).textFieldStyle(.roundedBorder)
                TextField(L("ipaview.bundleID"), text: $bundleID).textFieldStyle(.roundedBorder)
                TextField(L("ipaview.outputName"), text: $outputName).textFieldStyle(.roundedBorder)
                IpaMultiFilePickerButton(
                    title: L("ipaview.replaceIcon"),
                    systemImage: "photo",
                    types: inputMode == .ipa ? [.png] : [.png, .icns]
                ) {
                    icons = $0
                    invalidate()
                }
                Text(icons.map(\.lastPathComponent).joined(separator: "、"))
                    .font(.caption).foregroundStyle(.secondary)
                if inputMode == .ipa {
                    Toggle(L("ipaview.enableFileSharing"), isOn: $enableFileSharing)
                    Toggle(L("ipaview.repairWhiteIcon"), isOn: $repairWhiteIcon)
                    Toggle(L("ipaview.removeVOIP"), isOn: $removeVOIPBackgroundMode)
                    Toggle(L("ipaview.removeURLSchemes"), isOn: $removeURLSchemes)
                }
                componentPolicyRow(
                    title: L("ipaview.removeWatch"),
                    explanation: L("ipaview.removeWatch.detail"),
                    kind: .watch,
                    enabled: $removeWatch,
                    confirmed: $confirmWatchRemoval
                )
                componentPolicyRow(
                    title: L("ipaview.removePlugIns"),
                    explanation: L("ipaview.removePlugIns.detail"),
                    kind: .appExtension,
                    enabled: $removePlugIns,
                    confirmed: $confirmPlugInsRemoval
                )
                componentPolicyRow(
                    title: L("ipaview.removeAppClips"),
                    explanation: L("ipaview.removeAppClips.detail"),
                    kind: .appClip,
                    enabled: $removeAppClips,
                    confirmed: $confirmAppClipsRemoval
                )
                Button {
                    chooseComponentExport()
                } label: {
                    Label(L("ipaview.extractComponents"), systemImage: "archivebox")
                }
                .disabled(busy || targetSession?.components.isEmpty != false)
                Text(L("ipaview.extractComponents.detail"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var signingStep: some View {
        Card {
            VStack(alignment: .leading, spacing: IpaLayout.formSpacing) {
                Text(L("ipaview.section.signing")).font(.headline)
                Picker(L("ipaview.signMethod"), selection: $signMethod) {
                    ForEach(SignMethod.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .frame(maxWidth: 320)
                if inputMode == .ipa {
                    Toggle(L("ipaview.developerSigning"), isOn: $developerSigning)
                    if developerSigning {
                        DeveloperSigningPicker(
                            bundleIDs: signingBundleIDs,
                            identities: $identities,
                            selectedIdentity: $selectedIdentity,
                            profilesByBundleID: $profilesByBundleID
                        )
                    }
                } else {
                    Text(L("macappview.signingNote"))
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Toggle(L("ipaview.stripSignature"), isOn: $stripSignature)
                Text(L("ipaview.signing.note"))
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private var preflightStep: some View {
        VStack(alignment: .leading, spacing: IpaLayout.formSpacing) {
            Card {
                VStack(alignment: .leading, spacing: IpaLayout.formSpacing) {
                    Text(L("ipaview.section.execute")).font(.headline)
                    Text(L("ipaview.execute.note"))
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            Button {
                execute()
            } label: {
                Label(busy ? L("ipaview.running") : L("ipaview.executeDirectly"), systemImage: "syringe.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(busy || job.running || inputURL == nil || dylibs.isEmpty)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func makePlan() throws -> InjectionPlan {
        guard let inputURL else { throw InjectionPlanError.validation([L("ipaview.error.noInput")]) }
        let input: InjectionInput = inputMode == .macOSApp ? .app(inputURL) : .ipa(inputURL)
        let items = try dylibs.map { draft -> InjectionItem in
            let target: InjectionTarget
            if draft.usesCustomTarget {
                let value = draft.customTargetPath.trimmingCharacters(in: .whitespacesAndNewlines)
                target = value.isEmpty ? .mainExecutable : .relativeMachO(try ValidatedRelativePath(value))
            } else if let selected = selectedTarget(for: draft) {
                target = selected.kind == .mainExecutable
                    ? .mainExecutable
                    : .relativeMachO(try ValidatedRelativePath(selected.relativePath))
            } else {
                target = .mainExecutable
            }
            return InjectionItem(
                id: draft.id,
                dylibURL: draft.url,
                target: target,
                loadKind: draft.loadKind,
                existingCommandPolicy: draft.existingPolicy
            )
        }
        var resourcePlans = try resources.map {
            InjectionResource(
                id: $0.id,
                sourceURL: $0.url,
                destination: try ValidatedRelativePath($0.destination),
                replaceExisting: $0.replaceExisting
            )
        }
        for framework in dependencyFrameworks {
            let frameworkDirectory = inputMode == .ipa ? "Frameworks" : "Contents/Frameworks"
            let destination = try ValidatedRelativePath(
                "\(frameworkDirectory)/\(framework.lastPathComponent)"
            )
            guard !resourcePlans.contains(where: { $0.destination == destination }) else { continue }
            resourcePlans.append(InjectionResource(
                sourceURL: framework,
                destination: destination,
                replaceExisting: true
            ))
        }
        let signing: InjectionSigningMode
        if developerSigning {
            guard let identity = selectedIdentity else { throw SigningError.noIdentitySelected }
            let bundleIDs = signingBundleIDs
            let missing = bundleIDs.filter { profilesByBundleID[$0] == nil }
            guard !bundleIDs.isEmpty, missing.isEmpty else {
                throw SigningError.missingProfileMappings(missing.isEmpty ? bundleIDs : missing)
            }
            let activeProfiles = profilesByBundleID.filter { bundleIDs.contains($0.key) }
            signing = .realDevice(RealDeviceSigningRecipe(
                identityID: identity.id,
                identityName: identity.name,
                profilesByBundleID: activeProfiles
            ))
        } else {
            switch signMethod {
            case .none: signing = .none
            case .codesignAdhoc: signing = .adHoc
            case .ldid: signing = .ldid
            }
        }
        return InjectionPlan(
            input: input,
            items: items,
            resources: resourcePlans,
            metadata: InjectionMetadataChanges(
                displayName: displayName.nilIfBlank,
                bundleID: bundleID.nilIfBlank,
                iconFiles: icons,
                enableFileSharing: enableFileSharing,
                repairWhiteIcon: repairWhiteIcon,
                removeVOIPBackgroundMode: removeVOIPBackgroundMode,
                removeURLSchemes: removeURLSchemes
            ),
            components: InjectionComponentPolicy(
                watch: removeWatch ? .remove : .preserve,
                plugIns: removePlugIns ? .remove : .preserve,
                appClips: removeAppClips ? .remove : .preserve,
                destructiveRemovalConfirmed:
                    (!removeWatch || confirmWatchRemoval)
                    && (!removePlugIns || confirmPlugInsRemoval)
                    && (!removeAppClips || confirmAppClipsRemoval)
            ),
            signing: signing,
            customOutputName: outputName.nilIfBlank,
            stripCodeSignatureIfNeeded: stripSignature
        )
    }

    private func execute() {
        do {
            let plan = try makePlan()
            job.start(plan: plan, urls: inputAndAssetURLs(for: plan))
        } catch {
            ok = false
            log = "❌ \(operationError(error, paths: inputAndAssetURLs()))"
        }
    }

    private func chooseComponentExport() {
        guard let inputURL, let targetSession, !targetSession.components.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = L("ipaview.extractComponents.choose")
        guard panel.runModal() == .OK, let parent = panel.url else { return }

        let input: InjectionInput = inputMode == .macOSApp ? .app(inputURL) : .ipa(inputURL)
        busy = true
        ok = nil
        log = L("ipaview.extractComponents.running")
        Task {
            do {
                let paths = try await Task.detached {
                    try FileSystemHelper.withSecurityScopedAccess(to: [inputURL, parent]) {
                        try InjectionTargetDiscovery.extractComponents(from: input, to: parent)
                    }
                }.value
                log = L(
                    "ipaview.extractComponents.done",
                    paths.count,
                    paths.first?.deletingLastPathComponent().path ?? parent.path
                )
                ok = true
                if let first = paths.first { revealInFinder(first.deletingLastPathComponent()) }
            } catch {
                ok = false
                log = "❌ \(operationError(error, paths: [inputURL, parent]))"
            }
            busy = false
        }
    }

    @ViewBuilder
    private func componentPolicyRow(
        title: String,
        explanation: String,
        kind: EmbeddedComponentKind,
        enabled: Binding<Bool>,
        confirmed: Binding<Bool>
    ) -> some View {
        let matches = targetSession?.components.filter { $0.kind == kind } ?? []
        VStack(alignment: .leading, spacing: 5) {
            Toggle(title, isOn: enabled)
                .disabled(matches.isEmpty)
            Text(matches.isEmpty ? L("ipaview.notDetected") : explanation)
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(matches) { component in
                Text(
                    "• \(component.name)"
                        + (component.bundleID.map { " · \($0)" } ?? "")
                        + " · \(FileSystemHelper.humanReadableSize(component.size))"
                )
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            if enabled.wrappedValue {
                Toggle(L("ipaview.removeConsent", title), isOn: confirmed)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(.vertical, 3)
    }

    private func discoverTargets() {
        guard let inputURL else { return }
            let input: InjectionInput = inputMode == .macOSApp ? .app(inputURL) : .ipa(inputURL)
        targetSession = nil
        displayName = ""
        bundleID = ""
        outputName = ""
        enableFileSharing = false
        repairWhiteIcon = false
        removeVOIPBackgroundMode = false
        removeURLSchemes = false
        removeWatch = false
        removePlugIns = false
        removeAppClips = false
        profilesByBundleID = [:]
        confirmWatchRemoval = false
        confirmPlugInsRemoval = false
        confirmAppClipsRemoval = false
        busy = true
        ok = nil
        log = L("ipaview.scanning")
        Task {
            do {
                let session = try await Task.detached {
                    try FileSystemHelper.withSecurityScopedAccess(to: [inputURL]) {
                        try InjectionTargetDiscovery.open(input)
                    }
                }.value
                targetSession = session
                fillMetadataDefaults(from: session.appURL)
                let defaultID = session.targets.first(where: \.isRecommended)?.id ?? session.targets.first?.id
                for index in dylibs.indices where !dylibs[index].usesCustomTarget {
                    dylibs[index].targetID = defaultID
                }
                ok = true
                log = L("ipaview.scanned", session.targets.count)
            } catch {
                targetSession = nil
                ok = false
                log = "❌ \(operationError(error, paths: [inputURL]))"
            }
            busy = false
        }
    }

    private func selectedTarget(for draft: DylibDraft) -> BundleMachOTarget? {
        guard let id = draft.targetID else {
            return targetSession?.targets.first(where: \.isRecommended)
        }
        return targetSession?.targets.first { $0.id == id }
    }

    private var dependencyFrameworks: [URL] {
        [protobufLite, protobufLite2, protobufLite3].compactMap { $0 }
    }

    private var packageablePluginURLs: [URL] {
        Array(Set(dylibs.map(\.url) + dependencyFrameworks))
    }

    private func fillMetadataDefaults(from app: URL) {
        guard let plist = try? IpaService.infoPlist(appBundle: app) else { return }
        if displayName.nilIfBlank == nil {
            displayName = (plist["CFBundleDisplayName"] as? String)
                ?? (plist["CFBundleName"] as? String)
                ?? app.deletingPathExtension().lastPathComponent
        }
        if bundleID.nilIfBlank == nil {
            bundleID = plist["CFBundleIdentifier"] as? String ?? ""
        }
        if outputName.nilIfBlank == nil, let inputURL {
            let suffix = inputMode == .macOSApp ? "app" : "ipa"
            outputName = "\(inputURL.deletingPathExtension().lastPathComponent)-modified.\(suffix)"
        }
    }

    private func targetPickerLabel(_ target: BundleMachOTarget) -> String {
        let recommended = target.isRecommended ? L("ipaview.recommendedSuffix") : ""
        return "\(target.kind.displayName)\(recommended) · \(target.name)"
    }

    private func inputAndAssetURLs() -> [URL] {
        (inputURL.map { [$0] } ?? [])
            + dylibs.map(\.url)
            + resources.map(\.url)
            + dependencyFrameworks
            + icons
    }

    private func inputAndAssetURLs(for plan: InjectionPlan) -> [URL] {
        var urls = [plan.input.url]
            + plan.items.map(\.dylibURL)
            + plan.resources.map(\.sourceURL)
            + plan.metadata.iconFiles
        if case let .realDevice(recipe) = plan.signing {
            urls += recipe.profilesByBundleID.values
        }
        return urls
    }

    private var signingBundleIDs: [String] {
        guard let app = targetSession?.appURL else { return [] }
        let override = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        return (try? SigningService.profileBundleIDs(
            in: app,
            overridingRootBundleID: override.isEmpty ? nil : override,
            excludingRelativePaths: removedComponentPaths
        )) ?? []
    }

    private var removedComponentPaths: Set<String> {
        Set((targetSession?.components ?? []).compactMap { component in
            switch component.kind {
            case .watch where removeWatch: return component.relativePath
            case .appExtension where removePlugIns: return component.relativePath
            case .appClip where removeAppClips: return component.relativePath
            default: return nil
            }
        })
    }

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
        ok = false
        log = L("ipaview.access.openFailed")
    }

    private func moveStep(_ delta: Int) {
        guard let index = Step.allCases.firstIndex(of: step) else { return }
        let next = min(max(0, index + delta), Step.allCases.count - 1)
        step = Step.allCases[next]
    }

    private func invalidate() {
        ok = nil
    }
}

/// 多步向导的进度轨。
///
/// 顶部功能切换已经占用了一整条分段控件，步骤导航再用一条同样的控件，会在同一屏叠出
/// 两块高饱和选中色，且看不出「已完成 / 当前 / 未开始」的差别。这里用更轻的标记表达进度，
/// 把强调色留给唯一的主操作按钮。
private struct StepRail: View {
    let titles: [String]
    let currentIndex: Int
    let onSelect: (Int) -> Void

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(titles.enumerated()), id: \.offset) { index, title in
                if index > 0 {
                    connector(isPassed: index <= currentIndex)
                }
                stepButton(index: index, title: title)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func connector(isPassed: Bool) -> some View {
        Rectangle()
            .fill(Color.primary.opacity(isPassed ? 0.22 : 0.10))
            .frame(height: 1)
            .frame(minWidth: 10)
            .accessibilityHidden(true)
    }

    private func stepButton(index: Int, title: String) -> some View {
        Button {
            onSelect(index)
        } label: {
            HStack(spacing: 6) {
                marker(for: index)
                Text(title)
                    .font(.callout.weight(index == currentIndex ? .semibold : .regular))
                    .foregroundStyle(index == currentIndex ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                    .fixedSize()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background {
                if index == currentIndex {
                    Capsule().fill(Color.appAccent.opacity(0.14))
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L("ipaview.stepAccessibility", index + 1, title))
        .accessibilityAddTraits(index == currentIndex ? [.isSelected] : [])
    }

    @ViewBuilder
    private func marker(for index: Int) -> some View {
        ZStack {
            if index < currentIndex {
                Circle().fill(Color.appAccent.opacity(0.22))
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Color.appAccent)
            } else if index == currentIndex {
                Circle().fill(Color.appAccent)
                Text("\(index + 1)")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.white)
            } else {
                Circle().strokeBorder(Color.primary.opacity(0.20), lineWidth: 1)
                Text("\(index + 1)")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 18, height: 18)
        .accessibilityHidden(true)
    }
}

private struct AdaptiveSegmentedPicker<SelectionValue: Hashable, Content: View>: View {
    let title: String
    @Binding var selection: SelectionValue
    let minimumSegmentedWidth: CGFloat
    @ViewBuilder let content: () -> Content

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 0) {
                Picker(title, selection: $selection) {
                    content()
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Spacer(minLength: 0)
            }
            .frame(minWidth: minimumSegmentedWidth, maxWidth: .infinity)

            HStack(spacing: 0) {
                Picker(title, selection: $selection) {
                    content()
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize(horizontal: true, vertical: false)
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityLabel(title)
    }
}

private struct IpaMultiFilePickerButton: View {
    let title: String
    let systemImage: String
    let types: [UTType]
    let onPick: ([URL]) -> Void
    @State private var presented = false

    var body: some View {
        Button {
            presented = true
        } label: {
            Label(title, systemImage: systemImage)
        }
        .fileImporter(
            isPresented: $presented,
            allowedContentTypes: types,
            allowsMultipleSelection: true
        ) { result in
            guard case let .success(urls) = result else { return }
            FileSystemHelper.withSecurityScopedAccess(to: urls) {
                onPick(urls)
            }
        }
    }
}

private extension String {
    var nilIfBlank: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
