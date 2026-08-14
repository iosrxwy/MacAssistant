import SwiftUI
import AppKit
import UniformTypeIdentifiers
import MacAssistantKit

struct DebView: View {
    @ObservedObject private var workspace: WorkspaceStore
    private enum Mode: String, CaseIterable {
        case make = "制作"
        case convert = "转换"
        case inspect = "查看 / 解包"

        var icon: String {
            switch self {
            case .make: return "hammer"
            case .convert: return "arrow.triangle.2.circlepath"
            case .inspect: return "doc.text.magnifyingglass"
            }
        }
    }

    @State private var mode: Mode = .make

    init(workspace: WorkspaceStore) {
        self.workspace = workspace
    }

    var body: some View {
        FeatureScaffold(
            title: "DEB 工具",
            subtitle: "可靠地把 dylib / Framework / tweak 打包，并支持 rootful、rootless、roothide 转换"
        ) {
            Picker("模式", selection: $mode) {
                ForEach(Mode.allCases, id: \.self) {
                    Label($0.rawValue, systemImage: $0.icon).tag($0)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 320)
            .accessibilityLabel("模式")

            switch mode {
            case .make: DebMaker(workspace: workspace)
            case .convert: DebConverter()
            case .inspect: DebInspector(workspace: workspace)
            }
        }
    }
}

// MARK: - 制作

private struct DebMaker: View {
    @ObservedObject var workspace: WorkspaceStore
    private enum Mode: String, CaseIterable {
        case theos = "Theos 插件"
        case quick = "快速封装"
    }
    @State private var mode: Mode = .theos

    var body: some View {
        Picker("制作方式", selection: $mode) {
            ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
        .frame(maxWidth: 320)
        .labelsHidden()

        if mode == .theos {
            TheosProjectMaker()
        } else {
            DebPackageWizard(workspace: workspace)
        }
    }
}

private struct TheosProjectMaker: View {
    @State private var projectURL: URL?
    @State private var newProjectDirectory: URL?
    @State private var files: [URL] = []
    @State private var selectedFile: URL?
    @State private var sourceText = ""
    @State private var dirty = false
    @State private var cleanBuild = false
    @State private var busy = false
    @State private var log = ""
    @State private var ok: Bool?
    @State private var theosRoot: URL?
    @State private var projectName = "MyTweak"
    @State private var packageID = "com.example.mytweak"
    @State private var author = NSFullUserName()
    @State private var projectDescription = "A Theos tweak"
    @State private var targetBundleID = "com.apple.springboard"
    @State private var minimumIOS = "15.0"
    @State private var projectLayout: DebPackageLayout = .rootless
    @State private var theosEnvironment: TheosEnvironmentSnapshot?
    @State private var brewAvailable = false
    @State private var pendingDependency: ExternalTool?
    @State private var dependencyCommand = ""
    @State private var showDependencyConfirmation = false
    @State private var dependencyInstalling = false

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Theos 插件制作").font(.headline)
                        Text("选择项目、编辑 tweak 源码，然后执行 make package。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    FilePickerButton(title: "选择项目", systemImage: "folder", chooseDirectory: true) {
                        openProject($0)
                    }
                    FilePickerButton(title: "新建项目", systemImage: "folder.badge.plus", chooseDirectory: true) {
                        newProjectDirectory = $0
                        if projectName == "MyTweak", !$0.lastPathComponent.isEmpty {
                            projectName = $0.lastPathComponent
                        }
                    }
                    Button("构建 DEB") { build() }
                        .disabled(projectURL == nil || busy || dirty)
                        .glassActionButtonStyle(prominent: true)
                }
                PathBadge(url: projectURL, placeholder: "尚未选择包含 Makefile 的 Theos 项目")
                HStack {
                    Toggle("构建前 clean", isOn: $cleanBuild).toggleStyle(.checkbox)
                    Picker("构建布局", selection: $projectLayout) {
                        ForEach(DebPackageLayout.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 180)
                    if let root = theosRoot {
                        Text("THEOS：\(root.path)").font(.caption.monospaced()).foregroundStyle(.secondary)
                    } else {
                        Text("请先在环境检测页安装内置 Theos").font(.caption).foregroundStyle(.orange)
                    }
                    Spacer()
                }
                if let environment = theosEnvironment,
                   !environment.hasLdid || !environment.hasDpkgDeb {
                    HStack(spacing: 10) {
                        Text("缺少构建依赖：\(missingBuildDependencies(in: environment))")
                            .font(.caption)
                            .foregroundStyle(.orange)
                        if !environment.hasLdid { dependencyButton(.ldid) }
                        if !environment.hasDpkgDeb { dependencyButton(.dpkgDeb) }
                        Spacer()
                    }
                }
            }
        }
        .task {
            await refreshEnvironment()
        }
        .confirmationDialog("安装 Theos 构建依赖？", isPresented: $showDependencyConfirmation) {
            Button("执行安装") { installPendingDependency() }
        } message: {
            Text("来源：Homebrew Core\n命令：\(dependencyCommand)")
        }

        if let newProjectDirectory {
            Card {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("生成基础 tweak 文件").font(.headline)
                            Text("将在所选目录生成 Makefile、control、Tweak.xm 和 filter plist。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("生成并打开") { createProject() }
                            .glassActionButtonStyle(prominent: true)
                    }
                    PathBadge(url: newProjectDirectory)
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 9) {
                        GridRow {
                            Text("名称").foregroundStyle(.secondary)
                            TextField("MyTweak", text: $projectName)
                            Text("Package ID").foregroundStyle(.secondary)
                            TextField("com.example.mytweak", text: $packageID)
                        }
                        GridRow {
                            Text("作者").foregroundStyle(.secondary)
                            TextField("Name", text: $author)
                            Text("目标 Bundle").foregroundStyle(.secondary)
                            TextField("com.apple.springboard", text: $targetBundleID)
                        }
                        GridRow {
                            Text("最低 iOS").foregroundStyle(.secondary)
                            TextField("15.0", text: $minimumIOS)
                            Text("布局").foregroundStyle(.secondary)
                            Picker("布局", selection: $projectLayout) {
                                ForEach(DebPackageLayout.allCases, id: \.self) { Text($0.label).tag($0) }
                            }.labelsHidden()
                        }
                        GridRow {
                            Text("描述").foregroundStyle(.secondary)
                            TextField("A Theos tweak", text: $projectDescription)
                                .gridCellColumns(3)
                        }
                    }
                    .textFieldStyle(.roundedBorder)
                }
            }
        }

        if let projectURL {
            Card {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Picker("源码文件", selection: $selectedFile) {
                            Text("选择文件").tag(URL?.none)
                            ForEach(files, id: \.path) { file in
                                Text(relative(file, to: projectURL)).tag(Optional(file))
                            }
                        }
                        .onChange(of: selectedFile) { file in load(file) }
                        Spacer()
                        if dirty { Text("未保存").font(.caption).foregroundStyle(.orange) }
                        Button("保存") { save() }.disabled(selectedFile == nil || !dirty)
                    }
                    SyntaxCodeEditor(text: Binding(
                        get: { sourceText },
                        set: { sourceText = $0; dirty = true }
                    ), language: .detect(file: selectedFile))
                    .frame(minHeight: 360)
                    .insetSurfaceBackground(
                        RoundedRectangle(cornerRadius: 10),
                        legacyFill: Color.black.opacity(0.04),
                        stroke: Color.primary.opacity(0.08)
                    )
                    .disabled(selectedFile == nil || busy)
                }
            }
        }

        if busy || !log.isEmpty {
            Card {
                HStack(alignment: .top, spacing: 10) {
                    if busy { ProgressView().controlSize(.small) }
                    Text(log.isEmpty ? "正在构建…" : log)
                        .font(.footnote.monospaced()).textSelection(.enabled)
                    Spacer()
                    StatusBadge(ok: ok)
                }
            }
        }
    }

    private func openProject(_ url: URL) {
        do {
            files = try TheosProjectService.editableFiles(in: url)
            projectURL = url
            selectedFile = files.first { $0.lastPathComponent == "Tweak.xm" } ?? files.first
            load(selectedFile)
            ok = nil
            log = ""
        } catch {
            ok = false
            log = error.localizedDescription
        }
    }

    private func createProject() {
        guard let newProjectDirectory else { return }
        do {
            _ = try TheosProjectService.createTweakProject(
                in: newProjectDirectory,
                request: TheosTweakTemplateRequest(
                    name: projectName,
                    packageID: packageID,
                    author: author,
                    description: projectDescription,
                    targetBundleID: targetBundleID,
                    minimumIOS: minimumIOS,
                    layout: projectLayout
                )
            )
            self.newProjectDirectory = nil
            openProject(newProjectDirectory)
        } catch {
            ok = false
            log = error.localizedDescription
        }
    }

    private func load(_ file: URL?) {
        guard let file, let projectURL else { sourceText = ""; dirty = false; return }
        do {
            sourceText = try TheosProjectService.read(file, in: projectURL)
            dirty = false
        } catch {
            ok = false
            log = error.localizedDescription
        }
    }

    private func save() {
        guard let selectedFile, let projectURL else { return }
        do {
            try TheosProjectService.save(sourceText, to: selectedFile, in: projectURL)
            dirty = false
        } catch {
            ok = false
            log = error.localizedDescription
        }
    }

    private func build() {
        guard let projectURL, let theosRoot else {
            ok = false
            log = "请先在环境检测页安装内置 Theos"
            return
        }
        busy = true
        ok = nil
        log = "正在执行 make package…"
        let clean = cleanBuild
        let layout = projectLayout
        Task {
            do {
                let result = try await Task.detached {
                    try TheosProjectService.build(
                        project: projectURL,
                        theosRoot: theosRoot,
                        layout: layout,
                        clean: clean
                    )
                }.value
                log = "✅ \(result.command)\n\(result.log)\n产物：\(result.package.path)"
                ok = true
                revealInFinder(result.package)
            } catch {
                log = error.localizedDescription
                ok = false
            }
            busy = false
        }
    }

    @ViewBuilder
    private func dependencyButton(_ tool: ExternalTool) -> some View {
        if brewAvailable {
            Button("一键安装 \(tool.commandName)") { requestDependencyInstall(tool) }
                .disabled(dependencyInstalling)
        } else {
            Button("先安装 Homebrew") {
                NSWorkspace.shared.open(EnvironmentInstaller.homebrewInstructionsURL)
            }
        }
    }

    private func requestDependencyInstall(_ tool: ExternalTool) {
        do {
            let command = try EnvironmentInstaller.makeCommand(for: tool.installStrategy)
            pendingDependency = tool
            dependencyCommand = command.preview
            showDependencyConfirmation = true
        } catch {
            ok = false
            log = error.localizedDescription
        }
    }

    private func missingBuildDependencies(in environment: TheosEnvironmentSnapshot) -> String {
        environment.missingRequirements
            .filter { ["ldid", "dpkg-deb"].contains($0) }
            .joined(separator: "、")
    }

    private func installPendingDependency() {
        guard let tool = pendingDependency else { return }
        pendingDependency = nil
        dependencyInstalling = true
        log = "正在执行 \(dependencyCommand)…"
        Task {
            do {
                let command = try EnvironmentInstaller.makeCommand(for: tool.installStrategy)
                let result = try await Task.detached { try EnvironmentInstaller.run(command) }.value
                log = result.combinedOutput.isEmpty ? "✅ \(tool.commandName) 安装完成" : result.combinedOutput
                ok = true
                await refreshEnvironment()
            } catch {
                log = error.localizedDescription
                ok = false
            }
            dependencyInstalling = false
        }
    }

    @MainActor
    private func refreshEnvironment() async {
        let snapshot = await Task.detached { TheosEnvironmentService.inspect() }.value
        theosEnvironment = snapshot
        theosRoot = snapshot.root
        brewAvailable = await Task.detached { ExternalTool.brew.isAvailable }.value
    }

    private func relative(_ file: URL, to root: URL) -> String {
        String(file.path.dropFirst(min(file.path.count, root.path.count + 1)))
    }
}

// MARK: - 转换

private struct DebConverter: View {
    @State private var sourceURL: URL?
    @State private var outputURL: URL?
    @State private var sourceLayout: DebPackageLayout = .rootless
    @State private var targetLayout: DebPackageLayout = .rootful
    @State private var busy = false
    @State private var log = ""
    @State private var ok: Bool?

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("已有 DEB 布局转换").font(.headline)
                        Text("源包保持不动，输出 rootful、rootless 或 roothide 转换副本。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    FilePickerButton(title: "选择 .deb", systemImage: "shippingbox", types: [.debPackage, .data]) {
                        sourceURL = $0
                        outputURL = nil
                        log = ""
                        ok = nil
                    }
                }
                PathBadge(url: sourceURL, placeholder: "尚未选择源 DEB")

                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                    GridRow {
                        Text("来源布局").foregroundStyle(.secondary)
                        Picker("来源布局", selection: $sourceLayout) {
                            ForEach(DebPackageLayout.allCases, id: \.self) { Text($0.label).tag($0) }
                        }.labelsHidden()
                    }
                    GridRow {
                        Text("目标布局").foregroundStyle(.secondary)
                        Picker("目标布局", selection: $targetLayout) {
                            ForEach(DebPackageLayout.allCases, id: \.self) { Text($0.label).tag($0) }
                        }.labelsHidden()
                    }
                    GridRow {
                        Text("目标 Architecture").foregroundStyle(.secondary)
                        Text(targetLayout.defaultArchitecture).font(.system(.callout, design: .monospaced))
                    }
                }

                HStack {
                    Button("选择输出 .deb") { chooseOutput() }
                    PathBadge(url: outputURL, placeholder: "尚未选择输出文件")
                    Spacer()
                    Button("创建转换副本") { convert() }
                        .disabled(sourceURL == nil || outputURL == nil || sourceLayout == targetLayout || busy)
                        .glassActionButtonStyle(prominent: true)
                }
            }
        }

        if busy || !log.isEmpty {
            Card {
                HStack(alignment: .top, spacing: 10) {
                    if busy { ProgressView().controlSize(.small) }
                    Text(log.isEmpty ? "正在转换…" : log)
                        .font(.footnote.monospaced()).textSelection(.enabled)
                    Spacer()
                    StatusBadge(ok: ok)
                }
            }
        }

        Label("转换会改写 payload 路径、control Architecture 和 Mach-O 越狱路径；输出后重新执行 DEB 校验。", systemImage: "checkmark.shield")
            .font(.caption).foregroundStyle(.secondary)
    }

    private func chooseOutput() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.debPackage]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = sourceURL.map {
            "\($0.deletingPathExtension().lastPathComponent)-\(targetLayout.rawValue).deb"
        } ?? "converted.deb"
        if panel.runModal() == .OK { outputURL = panel.url }
    }

    private func convert() {
        guard let sourceURL, let outputURL else { return }
        let from = sourceLayout
        let to = targetLayout
        busy = true
        ok = nil
        log = "正在创建私有工作区并转换…"
        Task {
            do {
                let result = try await Task.detached {
                    try DebService.convert(debAt: sourceURL, from: from, to: to, output: outputURL)
                }.value
                log = "✅ 转换并校验通过\n输出：\(result.output.path)\n变更：\(result.changes.count) 项\nSHA-256：\(result.sha256)"
                ok = true
                revealInFinder(result.output)
            } catch {
                log = error.localizedDescription
                ok = false
            }
            busy = false
        }
    }
}

// MARK: - 快速封装

private struct DebPackageWizard: View {
    @ObservedObject var workspace: WorkspaceStore
    @State private var dylibs: [URL] = []
    @State private var companionPlists: [String: URL] = [:]
    @State private var resources: [URL] = []
    @State private var layout: DebPackageLayout = .rootless
    @State private var sourceLayout: DebPackageLayout?
    @State private var packageID = "com.example.tweak"
    @State private var name = "My Tweak"
    @State private var version = "1.0.0"
    @State private var architecture = "iphoneos-arm64"
    @State private var packageDescription = "A MobileSubstrate tweak"
    @State private var maintainer = ""
    @State private var author = ""
    @State private var depends = ""
    @State private var section = "Tweaks"
    @State private var dependencySuggestions: [DebDependencySuggestion] = []
    @State private var confirmedDependencyInstallNames: Set<String> = []
    @State private var autoFilter = true
    @State private var filterBundles = ""
    @State private var filterExecutables = "SpringBoard"
    @State private var filterClasses = ""
    @State private var filterCFVersions = ""
    @State private var enabledScripts: Set<DebMaintainerScript> = []
    @State private var scripts: [DebMaintainerScript: String] = [:]
    @State private var expandedScript: DebMaintainerScript?
    @State private var plan: DebBuildPlan?
    @State private var outputURL: URL?
    @State private var busy = false
    @State private var ok: Bool?
    @State private var log = ""

    var body: some View {
        Group {
            summaryCard
            inputCard
            metadataCard
            filterCard
            scriptsCard
            if let plan {
                previewCard(plan)
            }
            if !log.isEmpty {
                logCard
            }
            footnote
        }
        .onChange(of: packageID) { _ in invalidatePlan() }
        .onChange(of: name) { _ in invalidatePlan() }
        .onChange(of: version) { _ in invalidatePlan() }
        .onChange(of: architecture) { _ in invalidatePlan() }
        .onChange(of: packageDescription) { _ in invalidatePlan() }
        .onChange(of: maintainer) { _ in invalidatePlan() }
        .onChange(of: author) { _ in invalidatePlan() }
        .onChange(of: depends) { _ in invalidatePlan() }
        .onChange(of: section) { _ in invalidatePlan() }
        .onChange(of: sourceLayout) { _ in invalidatePlan() }
        .onChange(of: autoFilter) { _ in invalidatePlan() }
        .onChange(of: filterBundles) { _ in invalidatePlan() }
        .onChange(of: filterExecutables) { _ in invalidatePlan() }
        .onChange(of: filterClasses) { _ in invalidatePlan() }
        .onChange(of: filterCFVersions) { _ in invalidatePlan() }
        .onAppear { acceptWorkspaceDraft() }
        .onReceive(workspace.$pendingDebDraft) { draft in
            if draft != nil { acceptWorkspaceDraft() }
        }
    }

    // MARK: 概览与主操作

    private var summaryCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .center, spacing: 20) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("预计内容体积")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(estimatedSizeText)
                            .font(.system(size: 34, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(plan == nil ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
                        Text(selectionSummary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 0)

                    VStack(alignment: .trailing, spacing: 8) {
                        Button {
                            build()
                        } label: {
                            Label(busy ? "正在打包…" : "构建 DEB", systemImage: "shippingbox.fill")
                                .frame(minWidth: 84)
                        }
                        .controlSize(.large)
                        .glassActionButtonStyle(prominent: true)
                        .disabled(busy || outputURL == nil || !hasPayload)
                        .accessibilityIdentifier("deb.build")
                        .accessibilityHint("完成后用 dpkg-deb --info 与 --contents 校验")

                        Button {
                            updatePreview()
                        } label: {
                            Label("生成预览", systemImage: "eye")
                        }
                        .disabled(busy || !hasPayload)
                        .accessibilityIdentifier("deb.preview")
                        .accessibilityHint("只在本地规划目录与 control，不写出文件")
                    }
                }

                Divider()

                HStack(spacing: 10) {
                    Button {
                        chooseOutput()
                    } label: {
                        Label("选择输出 .deb", systemImage: "square.and.arrow.down")
                    }
                    .disabled(busy)
                    PathBadge(url: outputURL, placeholder: "尚未选择输出文件")
                }

                if busy {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text(busyText)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(busyText)
                }
            }
        }
    }

    private var estimatedSizeText: String {
        guard let plan else { return "—" }
        return FileSystemHelper.humanReadableSize(plan.estimatedSize)
    }

    private var selectionSummary: String {
        guard hasPayload else { return "尚未选择 dylib 或 Framework" }
        var parts: [String] = []
        if !dylibs.isEmpty { parts.append("\(dylibs.count) 个 dylib") }
        if !resources.isEmpty { parts.append("\(resources.count) 个资源") }
        parts.append(plan.map { "\($0.entries.count) 个条目" } ?? "尚未生成预览")
        return parts.joined(separator: " · ")
    }

    private var hasPayload: Bool {
        !dylibs.isEmpty || !resources.isEmpty
    }

    private var busyText: String {
        let first = log.split(separator: "\n").first.map(String.init) ?? ""
        return first.isEmpty ? "正在处理…" : first
    }

    // MARK: 输入文件

    private var inputCard: some View {
        Card(padding: 0) {
            VStack(spacing: 0) {
                HStack(spacing: 14) {
                    Text("输入文件")
                        .font(.callout.weight(.semibold))
                    Spacer(minLength: 12)
                    MultiFilePickerButton(
                        title: "dylib",
                        systemImage: "plus.rectangle.on.folder",
                        types: [.dylibFile]
                    ) { urls in
                        dylibs = unique(dylibs + urls.filter { $0.pathExtension.lowercased() == "dylib" })
                        invalidatePlan()
                    }
                    .help("可一次选择多个 .dylib")
                    MultiFilePickerButton(
                        title: "filter plist",
                        systemImage: "line.3.horizontal.decrease.circle",
                        types: [.propertyList, .xml]
                    ) { urls in
                        for url in urls {
                            companionPlists[url.deletingPathExtension().lastPathComponent] = url
                        }
                        invalidatePlan()
                    }
                    .help("与 dylib 同名的 filter plist 会自动配对")
                    MultiFilePickerButton(
                        title: "资源",
                        systemImage: "shippingbox",
                        types: [.item]
                    ) { urls in
                        resources = unique(resources + urls)
                        invalidatePlan()
                    }
                    .help("bundle、framework 或任意随包资源")
                    MultiFilePickerButton(
                        title: "Framework",
                        systemImage: "shippingbox",
                        types: [.item]
                    ) { urls in
                        resources = unique(resources + urls.filter { $0.pathExtension.lowercased() == "framework" })
                        invalidatePlan()
                    }
                    .help("将 Framework 放入 Library/Frameworks")
                }
                .buttonStyle(.borderless)
                .font(.callout)
                .lineLimit(1)
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 10)

                dylibSection
                resourceSection
                dependencySection
            }
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    @ViewBuilder
    private var dylibSection: some View {
        Divider()
        DebGroupHeader(title: "dylib", systemImage: "doc", count: dylibs.count) {
            Button("分析依赖建议") { analyzeDependencySuggestions() }
                .buttonStyle(.borderless)
                .font(.caption)
                .disabled(dylibs.isEmpty || busy)
                .help("读取 Mach-O 依赖并给出 Depends 候选")
        }

        if dylibs.isEmpty {
            DebEmptyRow(text: "可只添加 Framework，也可同时添加 dylib")
        } else {
            ForEach(Array(dylibs.enumerated()), id: \.element.path) { index, url in
                if index > 0 { Divider().padding(.leading, DebLayout.dividerInset) }
                DebFileRow(
                    url: url,
                    systemImage: "doc",
                    detail: companionPlists[url.deletingPathExtension().lastPathComponent] == nil
                        ? "将使用内置 filter 编辑器（若启用）"
                        : "已匹配同名 plist"
                ) {
                    dylibs.removeAll { $0 == url }
                    companionPlists.removeValue(forKey: url.deletingPathExtension().lastPathComponent)
                    invalidatePlan()
                }
            }
        }
    }

    @ViewBuilder
    private var resourceSection: some View {
        if !resources.isEmpty {
            Divider()
            DebGroupHeader(title: "随包资源", systemImage: "shippingbox", count: resources.count)
            ForEach(Array(resources.enumerated()), id: \.element.path) { index, url in
                if index > 0 { Divider().padding(.leading, DebLayout.dividerInset) }
                DebFileRow(url: url, systemImage: "folder", detail: "原样复制进包内") {
                    resources.removeAll { $0 == url }
                    invalidatePlan()
                }
            }
        }
    }

    @ViewBuilder
    private var dependencySection: some View {
        if !dependencySuggestions.isEmpty {
            Divider()
            DebGroupHeader(
                title: "依赖候选",
                systemImage: "link",
                count: dependencySuggestions.count
            ) {
                Text("勾选后写入 Depends")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(Array(dependencySuggestions.enumerated()), id: \.element.id) { index, suggestion in
                if index > 0 { Divider().padding(.leading, DebLayout.dividerInset) }
                dependencyRow(suggestion)
            }
        }
    }

    private func dependencyRow(_ suggestion: DebDependencySuggestion) -> some View {
        let title = suggestion.suggestedPackageID ?? "未解析"
        return HStack(alignment: .top, spacing: 12) {
            Toggle(
                title,
                isOn: Binding(
                    get: { confirmedDependencyInstallNames.contains(suggestion.installName) },
                    set: { confirmed in
                        if confirmed {
                            confirmedDependencyInstallNames.insert(suggestion.installName)
                        } else {
                            confirmedDependencyInstallNames.remove(suggestion.installName)
                        }
                        invalidatePlan()
                    }
                )
            )
            .labelsHidden()
            .toggleStyle(.checkbox)
            .disabled(suggestion.suggestedPackageID == nil)
            .accessibilityLabel(Text(title))
            .accessibilityValue(Text(suggestion.installName))
            .accessibilityHint(Text(suggestion.reason))

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(
                        suggestion.suggestedPackageID == nil
                            ? AnyShapeStyle(.secondary)
                            : AnyShapeStyle(.primary)
                    )
                Text(suggestion.installName)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(suggestion.reason)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .accessibilityHidden(true)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
    }

    // MARK: 包信息与布局

    private var metadataCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                Text("包信息")
                    .font(.callout.weight(.semibold))

                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 9) {
                    GridRow(alignment: .firstTextBaseline) {
                        formLabel("Package ID")
                        TextField("com.example.tweak", text: $packageID)
                        formLabel("Version")
                        TextField("1.0.0", text: $version)
                    }
                    GridRow(alignment: .firstTextBaseline) {
                        formLabel("Name")
                        TextField("显示名称", text: $name)
                        formLabel("Section")
                        TextField("Tweaks", text: $section)
                    }
                    GridRow(alignment: .firstTextBaseline) {
                        formLabel("Maintainer")
                        TextField("Name <email@example.com>", text: $maintainer)
                        formLabel("Author")
                        TextField("可选", text: $author)
                    }
                    GridRow(alignment: .firstTextBaseline) {
                        formLabel("Depends")
                        TextField("逗号分隔，可选", text: $depends)
                            .gridCellColumns(3)
                    }
                    GridRow(alignment: .top) {
                        formLabel("Description", topAligned: true)
                        BoxedTextEditor(text: $packageDescription, minHeight: 54)
                            .gridCellColumns(3)
                    }
                }
                .textFieldStyle(.roundedBorder)

                Divider()

                Text("安装布局")
                    .font(.callout.weight(.semibold))

                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 9) {
                    GridRow(alignment: .firstTextBaseline) {
                        formLabel("布局")
                        Picker("布局", selection: $layout) {
                            ForEach(DebPackageLayout.allCases, id: \.self) {
                                Text($0.label).tag($0)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        formLabel("Architecture")
                        Picker("Architecture", selection: $architecture) {
                            ForEach(DebService.supportedArchitectures, id: \.self) { Text($0).tag($0) }
                        }
                        .labelsHidden()
                    }
                    GridRow(alignment: .firstTextBaseline) {
                        formLabel("转换来源")
                        Picker("转换来源", selection: $sourceLayout) {
                            Text("自动识别").tag(DebPackageLayout?.none)
                            ForEach(DebPackageLayout.allCases, id: \.self) {
                                Text($0.label).tag(Optional($0))
                            }
                        }
                        .labelsHidden()
                        formLabel("目标架构")
                        Text(architecture).font(.system(.callout, design: .monospaced))
                    }
                }
                .onChange(of: layout) { newLayout in
                    architecture = newLayout.defaultArchitecture
                    invalidatePlan()
                }

                installPathHint
            }
        }
    }

    private var installPathHint: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("包内路径")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(layout.dynamicLibrariesPath)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
            Spacer(minLength: 12)
            Text("安装后映射为 \(layout.pathHint)")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .insetSurfaceBackground(RoundedRectangle(cornerRadius: 8), legacyFill: .black.opacity(0.05))
    }

    private func formLabel(_ text: String, topAligned: Bool = false) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(width: DebLayout.labelWidth, alignment: .trailing)
            .padding(.top, topAligned ? 5 : 0)
    }

    // MARK: Tweak Filter

    private var filterCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 16) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Tweak Filter")
                            .font(.callout.weight(.semibold))
                        Text("多个值用逗号分隔；不会覆盖你选择的同名 plist。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Toggle("自动生成", isOn: $autoFilter)
                        .toggleStyle(.checkbox)
                        .accessibilityLabel("为缺少同名 plist 的 dylib 自动生成 filter")
                        .help("为缺少同名 plist 的 dylib 自动生成 filter")
                }

                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 9) {
                    GridRow(alignment: .firstTextBaseline) {
                        formLabel("Bundles")
                        TextField("com.apple.springboard", text: $filterBundles)
                        formLabel("Executables")
                        TextField("SpringBoard", text: $filterExecutables)
                    }
                    GridRow(alignment: .firstTextBaseline) {
                        formLabel("Classes")
                        TextField("SBIconController", text: $filterClasses)
                        formLabel("CF Version")
                        TextField("如 1854.0, 3000.0", text: $filterCFVersions)
                    }
                }
                .textFieldStyle(.roundedBorder)
                .disabled(!autoFilter)
            }
        }
    }

    // MARK: 维护脚本

    private var scriptsCard: some View {
        Card(padding: 0) {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("维护脚本")
                        .font(.callout.weight(.semibold))
                    Text("启用后写入 DEBIAN/ 并设置 0755；缺少 shebang 时自动补 #!/bin/sh。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 10)

                ForEach(Array(DebMaintainerScript.allCases.enumerated()), id: \.element.rawValue) { index, script in
                    if index == 0 {
                        Divider()
                    } else {
                        Divider().padding(.leading, DebLayout.dividerInset)
                    }
                    scriptRow(script)
                    if expandedScript == script {
                        BoxedTextEditor(text: scriptBinding(script), minHeight: 92, monospaced: true)
                            .disabled(!enabledScripts.contains(script))
                            .padding(.horizontal, 16)
                            .padding(.bottom, 12)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    private func scriptRow(_ script: DebMaintainerScript) -> some View {
        let enabled = enabledScripts.contains(script)
        return HStack(spacing: 12) {
            Toggle(script.rawValue, isOn: enabledScriptBinding(script))
                .labelsHidden()
                .toggleStyle(.checkbox)
                .accessibilityLabel(Text(script.rawValue))
                .accessibilityValue(Text(enabled ? "已启用" : "未启用"))

            VStack(alignment: .leading, spacing: 2) {
                Text(script.rawValue)
                    .font(.system(.callout, design: .monospaced).weight(.medium))
                Text(scriptDetail(script))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .accessibilityHidden(true)

            Spacer(minLength: 12)

            Button(expandedScript == script ? "收起" : "编辑") {
                expandedScript = expandedScript == script ? nil : script
            }
            .buttonStyle(.borderless)
            .font(.caption)
            .accessibilityLabel("编辑 \(script.rawValue) 脚本内容")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
    }

    private func scriptDetail(_ script: DebMaintainerScript) -> String {
        switch script {
        case .preinst: return "解包前执行"
        case .postinst: return "解包后执行，常用于 respring"
        case .prerm: return "卸载前执行"
        case .postrm: return "卸载后执行，清理残留"
        }
    }

    // MARK: 预览与日志

    private func previewCard(_ plan: DebBuildPlan) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text("打包预览")
                        .font(.callout.weight(.semibold))
                    Spacer(minLength: 12)
                    Text("\(plan.entries.count) 个条目 · \(FileSystemHelper.humanReadableSize(plan.estimatedSize))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Text("最终压缩包大小以构建结果为准。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(alignment: .top, spacing: 12) {
                    previewPane("目录树", plan.tree)
                    previewPane("DEBIAN/control", plan.controlText)
                }
            }
        }
    }

    private func previewPane(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                CopyButton(text: text)
                    .font(.caption)
            }
            ConsoleView(text: text, minHeight: 168)
        }
        .frame(maxWidth: .infinity)
    }

    private var logCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("打包与校验", systemImage: "terminal")
                        .font(.callout.weight(.semibold))
                    Spacer()
                    StatusBadge(ok: ok)
                }
                ConsoleView(text: log, minHeight: 96)
            }
        }
    }

    private var footnote: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("优先使用 dpkg-deb --build --root-owner-group 打包。", systemImage: "terminal")
            Label("完成后必须通过 --info 与 --contents 校验才会报告成功。", systemImage: "checkmark.shield")
            Label("转换会改写包内 Mach-O 的越狱根路径；roothide 使用随机 jbroot。", systemImage: "arrow.triangle.2.circlepath")
            Label("只有勾选的候选才会写入 Depends；未解析项不会自动添加。", systemImage: "info.circle")
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .padding(.top, 2)
    }

    // MARK: 数据

    private func metadata() -> DebPackageMetadata {
        let confirmed = DebDependencyAdvisor.confirmedPackageIDs(
            from: dependencySuggestions,
            confirmedInstallNames: confirmedDependencyInstallNames
        )
        let manual = depends.split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
        let finalDepends = Array(Set(manual + confirmed)).sorted().joined(separator: ", ")
        return DebPackageMetadata(
            packageID: packageID.trimmingCharacters(in: .whitespacesAndNewlines),
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            version: version.trimmingCharacters(in: .whitespacesAndNewlines),
            architecture: architecture,
            description: packageDescription,
            maintainer: maintainer.trimmingCharacters(in: .whitespacesAndNewlines),
            author: author.trimmingCharacters(in: .whitespacesAndNewlines),
            depends: finalDepends,
            section: section.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    private func request() -> DebPackageRequest {
        let enabled = scripts.filter { enabledScripts.contains($0.key) }
        return DebPackageRequest(
            metadata: metadata(),
            layout: layout,
            sourceLayout: sourceLayout,
            dylibs: dylibs,
            companionPlists: companionPlists,
            extraResources: resources,
            generatedFilter: autoFilter ? TweakFilter(
                bundles: csv(filterBundles),
                executables: csv(filterExecutables),
                classes: csv(filterClasses),
                coreFoundationVersion: csv(filterCFVersions).compactMap(Double.init)
            ) : nil,
            scripts: enabled
        )
    }

    private func updatePreview() {
        do {
            plan = try DebService.plan(request())
            ok = nil
            log = ""
        } catch {
            plan = nil
            ok = false
            log = error.localizedDescription
        }
    }

    private func chooseOutput() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.debPackage]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "\(packageID)_\(version)_\(architecture).deb"
        if panel.runModal() == .OK {
            outputURL = panel.url
        }
    }

    private func build() {
        guard let outputURL else { return }
        let request = request()
        busy = true
        ok = nil
        log = "正在规划目录并生成 control…"
        Task {
            do {
                let result = try await Task.detached {
                    try DebService.build(request, to: outputURL)
                }.value
                plan = result.plan
                ok = true
                log = """
                ✅ 构建和校验均通过
                输出：\(result.output.path)
                条目：\(result.plan.entries.count)
                预计内容体积：\(FileSystemHelper.humanReadableSize(result.plan.estimatedSize))

                dpkg-deb --info
                \(result.infoOutput)
                """
                revealInFinder(result.output)
            } catch {
                ok = false
                log = "❌ \(error.localizedDescription)"
            }
            busy = false
        }
    }

    private func enabledScriptBinding(_ script: DebMaintainerScript) -> Binding<Bool> {
        Binding {
            enabledScripts.contains(script)
        } set: { enabled in
            if enabled {
                enabledScripts.insert(script)
                if scripts[script] == nil { scripts[script] = "#!/bin/sh\nexit 0\n" }
                expandedScript = script
            } else {
                enabledScripts.remove(script)
            }
            invalidatePlan()
        }
    }

    private func scriptBinding(_ script: DebMaintainerScript) -> Binding<String> {
        Binding {
            scripts[script] ?? ""
        } set: {
            scripts[script] = $0
            invalidatePlan()
        }
    }

    private func csv(_ text: String) -> [String] {
        text.split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
    }

    private func unique(_ urls: [URL]) -> [URL] {
        var seen: Set<String> = []
        return urls.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    private func invalidatePlan() {
        plan = nil
    }

    private func analyzeDependencySuggestions() {
        let selectedDylibs = dylibs
        busy = true
        log = "正在分析 Mach-O 依赖；结果只作为候选…"
        Task {
            do {
                let value = try await Task.detached {
                    try DebDependencyAdvisor.suggestions(for: selectedDylibs)
                }.value
                dependencySuggestions = value
                confirmedDependencyInstallNames = []
                ok = true
                log = "已生成 \(value.count) 条依赖候选，尚未自动写入 control"
            } catch {
                ok = false
                log = error.localizedDescription
            }
            busy = false
        }
    }

    private func acceptWorkspaceDraft() {
        let items = workspace.consumePendingDebDraft()
        guard !items.isEmpty else { return }
        dylibs = unique(dylibs + items.map(\.fileURL).filter {
            $0.pathExtension.lowercased() == "dylib"
        })
        resources = unique(resources + items.map(\.fileURL).filter {
            ["framework", "bundle"].contains($0.pathExtension.lowercased())
        })
        for item in items {
            for plist in item.companionURLs where plist.pathExtension.lowercased() == "plist" {
                companionPlists[plist.deletingPathExtension().lastPathComponent] = plist
            }
        }
        let automatic = DebService.autoCompanionPlists(for: dylibs)
        companionPlists = automatic.merging(companionPlists) { _, explicit in explicit }
        invalidatePlan()
    }
}

// MARK: - 查看 / 解包

private struct DebInspector: View {
    @ObservedObject var workspace: WorkspaceStore
    @State private var debURL: URL?
    @State private var info: DebInfo?
    @State private var scanSession: DebScanSession?
    @State private var selectedArtifacts: Set<DebMachOArtifact.ID> = []
    @State private var extractionMode: DebExtractionMode = .preserveRelativePaths
    @State private var includeFrameworkDylibs = false
    @State private var repackDirectory: URL?
    @State private var busy = false
    @State private var ok: Bool?
    @State private var log = ""

    var body: some View {
        Group {
            sourceCard
            if let info {
                infoCard(info)
            }
            if let session = scanSession {
                artifactsCard(session)
            }
            repackCard
            if busy || !log.isEmpty {
                logCard
            }
            footnote
        }
    }

    // MARK: 概览与主操作

    private var sourceCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .center, spacing: 20) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("待检查的包")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(debURL?.lastPathComponent ?? "尚未选择")
                            .font(.system(size: 22, weight: .semibold, design: .rounded))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(
                                debURL == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary)
                            )
                        Text(sourceSummary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 0)

                    VStack(alignment: .trailing, spacing: 8) {
                        FilePickerButton(
                            title: "选择 .deb",
                            systemImage: "shippingbox",
                            types: [.debPackage, .data]
                        ) {
                            debURL = $0
                            info = nil
                            scanSession = nil
                            selectedArtifacts = []
                            log = ""
                            inspect()
                        }
                        .controlSize(.large)
                        .glassActionButtonStyle(prominent: true)
                        .accessibilityHint("选择后立即执行只读安全扫描")

                        Button("重新安全扫描") { inspect() }
                            .disabled(debURL == nil || busy)
                    }
                }

                PathBadge(url: debURL, placeholder: "选择后这里显示完整路径")

                Divider()

                HStack(spacing: 10) {
                    Button { extract(dataOnly: false) } label: {
                        Label("解包全部", systemImage: "square.and.arrow.down")
                    }
                    Button { extract(dataOnly: true) } label: {
                        Label("仅解包 data", systemImage: "folder")
                    }
                    Button { extractMachO() } label: {
                        Label("提取全部 Mach-O", systemImage: "doc.on.doc")
                    }
                    Spacer(minLength: 0)
                }
                .disabled(debURL == nil || busy)
            }
        }
    }

    private var sourceSummary: String {
        guard let session = scanSession else {
            return debURL == nil ? "选择一个 .deb 开始只读安全扫描" : "已选择，等待扫描"
        }
        return "\(session.result.safety.entryCount) 个条目 · \(session.result.artifacts.count) 个 Mach-O"
    }

    // MARK: 包信息

    private func infoCard(_ info: DebInfo) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Text("包信息")
                    .font(.callout.weight(.semibold))
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 7) {
                    GridRow(alignment: .firstTextBaseline) {
                        infoLabel("Package")
                        infoValue(info.control.package)
                        infoLabel("Version")
                        infoValue(info.control.version)
                    }
                    GridRow(alignment: .firstTextBaseline) {
                        infoLabel("Architecture")
                        infoValue(info.control.architecture)
                        infoLabel("Maintainer")
                        infoValue(info.control.maintainer)
                    }
                    GridRow(alignment: .top) {
                        infoLabel("Description")
                        infoValue(info.control.descriptionText)
                            .gridCellColumns(3)
                    }
                }
            }
        }
    }

    private func infoLabel(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(width: DebLayout.labelWidth, alignment: .trailing)
    }

    private func infoValue(_ value: String?) -> some View {
        Text(value ?? "—")
            .font(.callout)
            .foregroundStyle(value == nil ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Mach-O 列表

    private func artifactsCard(_ session: DebScanSession) -> some View {
        Card(padding: 0) {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Text("安全扫描结果")
                        .font(.callout.weight(.semibold))
                    Spacer()
                    Button("全选") {
                        selectedArtifacts = Set(session.result.artifacts.map(\.id))
                    }
                    .disabled(busy)
                    Button("全不选") { selectedArtifacts = [] }
                        .disabled(busy)
                }
                .buttonStyle(.borderless)
                .font(.callout)
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 10)

                extractionModeRow

                Divider()
                DebGroupHeader(
                    title: "Mach-O",
                    systemImage: "doc",
                    count: session.result.artifacts.count
                ) {
                    Text("已选 \(selectedArtifacts.count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                if session.result.artifacts.isEmpty {
                    DebEmptyRow(text: "包内没有可分析的 Mach-O")
                } else {
                    ForEach(Array(session.result.artifacts.enumerated()), id: \.element.id) { index, artifact in
                        if index > 0 { Divider().padding(.leading, DebLayout.dividerInset) }
                        DebArtifactRow(
                            artifact: artifact,
                            isSelected: selectionBinding(for: artifact.id),
                            openInDylib: { openInDylib(artifact) }
                        )
                    }
                }

                Divider()
                artifactActions
            }
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    private var extractionModeRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("提取模式", selection: $extractionMode) {
                Text("保留相对目录").tag(DebExtractionMode.preserveRelativePaths)
                Text("扁平输出（稳定重命名）").tag(DebExtractionMode.flat)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 380)
            .accessibilityLabel("提取模式")
            Text("“解包”保留完整目录结构；“汇总”只把动态库及其同名 filter plist 放进一个单层文件夹。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }

    private var artifactActions: some View {
        HStack(spacing: 12) {
            Button("提取选中…") { extractArtifacts(selectedArtifacts) }
                .disabled(selectedArtifacts.isEmpty || busy)
            Button("一键汇总全部 dylib…") { summarizeAllDylibs() }
                .disabled(summaryDylibArtifacts.isEmpty || busy)
            Toggle("包含 Framework 动态库", isOn: $includeFrameworkDylibs)
                .toggleStyle(.checkbox)
                .disabled(busy)
            Spacer(minLength: 12)
            if summaryDylibArtifacts.isEmpty {
                Text("未找到可汇总的 dylib")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func selectionBinding(for id: DebMachOArtifact.ID) -> Binding<Bool> {
        Binding(
            get: { selectedArtifacts.contains(id) },
            set: { selected in
                if selected { selectedArtifacts.insert(id) } else { selectedArtifacts.remove(id) }
            }
        )
    }

    // MARK: 重新打包与日志

    private var repackCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Text("重新打包已有目录")
                    .font(.callout.weight(.semibold))
                Text("目录必须包含 DEBIAN/control；同样会优先使用 root-owner-group。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    FilePickerButton(title: "选择目录", systemImage: "folder", chooseDirectory: true) {
                        repackDirectory = $0
                    }
                    Button("重新打包") { repack() }
                        .disabled(repackDirectory == nil || busy)
                    Spacer(minLength: 0)
                }
                PathBadge(url: repackDirectory, placeholder: "尚未选择目录")
            }
        }
    }

    private var logCard: some View {
        Card {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                if busy { ProgressView().controlSize(.small) }
                Text(log.isEmpty ? "正在执行…" : log)
                    .font(.footnote)
                    .textSelection(.enabled)
                Spacer(minLength: 12)
                StatusBadge(ok: ok)
            }
        }
    }

    private var footnote: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("扫描是只读操作，不会改动原始 .deb。", systemImage: "lock.shield")
            Label("提取结果写入新建的空目录，并附带 manifest 清单。", systemImage: "doc.text")
            Label("重新打包后会再走一次 control 校验，失败即报错。", systemImage: "checkmark.shield")
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .padding(.top, 2)
    }

    // MARK: 动作

    private func inspect() {
        guard let debURL else { return }
        run {
            let session = try DebArchiveWorkflow.scan(debAt: debURL)
            await MainActor.run {
                scanSession = session
                info = session.result.info
                selectedArtifacts = Set(session.result.artifacts.map(\.id))
            }
            return "安全预检通过；已解析 \(session.result.info.entries.count) 个条目与 \(session.result.artifacts.count) 个 Mach-O"
        }
    }

    private func extract(dataOnly: Bool) {
        guard let debURL else { return }
        let destination = debURL.deletingPathExtension().appendingPathExtension(dataOnly ? "data" : "full")
        run {
            let output = try DebService.extract(debAt: debURL, to: destination, dataOnly: dataOnly)
            await MainActor.run { revealInFinder(output) }
            return "已解包到 \(output.path)"
        }
    }

    private func extractMachO() {
        guard let session = scanSession else {
            inspect()
            return
        }
        extractArtifacts(Set(session.result.artifacts.map(\.id)))
    }

    private func repack() {
        guard let repackDirectory else { return }
        let output = repackDirectory.deletingLastPathComponent()
            .appendingPathComponent(repackDirectory.lastPathComponent + ".deb")
        run {
            let result = try DebService.repack(directory: repackDirectory, to: output)
            let verified = try DebService.inspect(debAt: result)
            guard verified.control.package != nil else {
                throw DebError.commandFailed("重新打包后未通过 control 校验")
            }
            await MainActor.run { revealInFinder(result) }
            return "已重新打包并验证：\(result.path)"
        }
    }

    private func run(_ operation: @escaping @Sendable () async throws -> String) {
        busy = true
        ok = nil
        log = ""
        Task {
            do {
                log = try await Task.detached { try await operation() }.value
                ok = true
            } catch {
                log = error.localizedDescription
                ok = false
            }
            busy = false
        }
    }

    private func chooseOutputParentDirectory() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "选择输出位置"
        panel.message = "选择一个文件夹，提取结果会放进其中自动新建的子目录"
        panel.directoryURL = debURL?.deletingLastPathComponent()
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// 依据包名生成文件系统安全的子目录名。
    private func extractionFolderName(for session: DebScanSession) -> String {
        let raw = session.result.info.control.package
            ?? session.result.archiveURL.deletingPathExtension().lastPathComponent
        let invalid = CharacterSet(charactersIn: "/\\:")
        let safe = raw.components(separatedBy: invalid).joined(separator: "-")
            .trimmingCharacters(in: .whitespaces)
        return safe.isEmpty ? "dylibs" : "\(safe)-dylibs"
    }

    /// 在所选父目录内找到第一个不存在的子目录名(base、base-2、base-3…),始终返回全新空目标。
    private func uniqueChildDirectory(in parent: URL, base: String) -> URL {
        let fm = FileManager.default
        var candidate = parent.appendingPathComponent(base, isDirectory: true)
        var n = 2
        while fm.fileExists(atPath: candidate.path) {
            candidate = parent.appendingPathComponent("\(base)-\(n)", isDirectory: true)
            n += 1
        }
        return candidate
    }

    private func extractArtifacts(_ ids: Set<DebMachOArtifact.ID>) {
        guard let session = scanSession, !ids.isEmpty,
              let parent = chooseOutputParentDirectory() else { return }
        let destination = uniqueChildDirectory(in: parent, base: extractionFolderName(for: session))
        let mode = extractionMode
        run {
            let result = try DebArchiveWorkflow.extract(
                from: session,
                artifactIDs: ids,
                mode: mode,
                to: destination
            )
            await MainActor.run { revealInFinder(result.outputDirectory) }
            return "已提取 \(result.manifest.entries.count) 个文件到 \(result.outputDirectory.lastPathComponent)/，并生成 \(result.manifestURL.lastPathComponent)"
        }
    }

    private var summaryDylibArtifacts: [DebMachOArtifact] {
        guard let session = scanSession else { return [] }
        return DebArchiveWorkflow.dylibArtifacts(
            in: session,
            includeFrameworks: includeFrameworkDylibs
        )
    }

    private func summarizeAllDylibs() {
        guard let session = scanSession else { return }
        guard !summaryDylibArtifacts.isEmpty else {
            ok = false
            log = "未找到可汇总的 dylib"
            return
        }
        guard let parent = chooseOutputParentDirectory() else { return }
        let destination = uniqueChildDirectory(in: parent, base: extractionFolderName(for: session))
        let includeFrameworks = includeFrameworkDylibs
        run {
            let result = try DebArchiveWorkflow.summarizeDylibs(
                from: session,
                includeFrameworks: includeFrameworks,
                to: destination
            )
            let dylibCount = result.manifest.entries.filter {
                $0.companionForArtifactID == nil
            }.count
            let plistCount = result.manifest.entries.filter {
                $0.companionForArtifactID != nil
            }.count
            await MainActor.run { revealInFinder(result.outputDirectory) }
            return "已汇总 \(dylibCount) 个 dylib + \(plistCount) 个 plist 到 \(result.outputDirectory.lastPathComponent)/，并生成 \(result.manifestURL.lastPathComponent)"
        }
    }

    private func openInDylib(_ artifact: DebMachOArtifact) {
        guard let session = scanSession else { return }
        do {
            _ = try workspace.importForDylib(
                fileURL: artifact.localURL,
                companionURLs: [artifact.companionPlistURL].compactMap { $0 },
                origin: WorkspaceOrigin(
                    archiveID: session.result.archiveID,
                    archiveURL: session.result.archiveURL,
                    relativePath: artifact.relativePath
                )
            )
        } catch {
            ok = false
            log = error.localizedDescription
        }
    }
}

// MARK: - 列表构件

/// DEB 页的统一度量：标签列宽、行内缩进与分隔线缩进。
private enum DebLayout {
    static let labelWidth: CGFloat = 92
    /// 让分隔线从行内文字一侧起画，与系统清理页保持同一缩进。
    static let dividerInset: CGFloat = 52
    static let statusColumnWidth: CGFloat = 84
}

/// 卡片内自绘列表的分组小标题（淡色底 + 计数 + 可选右侧内容）。
private struct DebGroupHeader<Trailing: View>: View {
    let title: String
    let systemImage: String
    var count: Int?
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
            Text(title)
            if let count {
                Text("\(count)").monospacedDigit()
            }
            Spacer()
            trailing()
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
        .insetSurfaceBackground(
            Rectangle(),
            legacyFill: Color.primary.opacity(0.035),
            glassFill: AnyShapeStyle(Color.primary.opacity(0.05))
        )
    }
}

extension DebGroupHeader where Trailing == EmptyView {
    init(title: String, systemImage: String, count: Int? = nil) {
        self.init(title: title, systemImage: systemImage, count: count, trailing: { EmptyView() })
    }
}

private struct DebEmptyRow: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
    }
}

private struct DebFileRow: View {
    let url: URL
    let systemImage: String
    let detail: String
    let onRemove: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .frame(width: 20)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(url.lastPathComponent)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 12)

            Button(action: onRemove) {
                Image(systemName: "xmark.circle")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .accessibilityLabel("移除 \(url.lastPathComponent)")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(isHovering ? AnyShapeStyle(Color.primary.opacity(0.045)) : AnyShapeStyle(Color.clear))
        .onHover { isHovering = $0 }
    }
}

private struct DebArtifactRow: View {
    let artifact: DebMachOArtifact
    @Binding var isSelected: Bool
    let openInDylib: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 12) {
            Toggle(artifact.relativePath, isOn: $isSelected)
                .labelsHidden()
                .toggleStyle(.checkbox)
                .accessibilityLabel(Text(artifact.relativePath))
                .accessibilityValue(Text("\(isSelected ? "已选择" : "未选择")，\(detailText)"))

            Image(systemName: artifact.kind.debSystemImage)
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .frame(width: 20)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(artifact.relativePath)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(detailText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let installName = artifact.analysis.installName {
                    Text("ID \(installName) · rpath \(artifact.analysis.rpaths.count) · 依赖 \(artifact.analysis.dependencies.count)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .accessibilityHidden(true)

            Spacer(minLength: 12)

            Button("在 DYLIB 工具中打开", action: openInDylib)
                .buttonStyle(.borderless)
                .font(.caption)
                .accessibilityLabel("在 DYLIB 工具中打开 \(artifact.relativePath)")

            statusColumn
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(rowBackground)
        .contentShape(Rectangle())
        .onTapGesture { isSelected.toggle() }
        .onHover { isHovering = $0 }
    }

    /// 大小固定占一列，右缘才不会被长短不一的类型标签推歪。
    private var statusColumn: some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(FileSystemHelper.humanReadableSize(artifact.analysis.fileSize))
                .font(.callout.monospacedDigit().weight(.medium))
            Text(artifact.kind.debLabel)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(width: DebLayout.statusColumnWidth, alignment: .trailing)
        .accessibilityHidden(true)
    }

    private var detailText: String {
        var parts = [
            FileSystemHelper.humanReadableSize(artifact.analysis.fileSize),
            artifact.analysis.architectures.joined(separator: ", "),
            "签名 \(artifact.analysis.signature.rawValue)"
        ]
        if artifact.companionPlistURL != nil {
            parts.append("已配对 filter plist")
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var rowBackground: some View {
        if isSelected {
            Rectangle().fill(Color.accentColor.opacity(0.10))
        } else if isHovering {
            Rectangle().fill(Color.primary.opacity(0.045))
        } else {
            Color.clear
        }
    }
}

private extension DebArtifactKind {
    var debLabel: String {
        switch self {
        case .dylib: return "动态库"
        case .frameworkExecutable: return "Framework"
        case .bundleExecutable: return "Bundle"
        case .executable: return "可执行"
        case .machO: return "Mach-O"
        }
    }

    var debSystemImage: String {
        switch self {
        case .dylib: return "link"
        case .frameworkExecutable: return "shippingbox"
        case .bundleExecutable: return "cube"
        case .executable: return "terminal"
        case .machO: return "doc"
        }
    }
}

// MARK: - 输入构件

/// 带内边距与边框的多行输入框；TextEditor 默认贴边且自带背景，需要手动收拾。
private struct BoxedTextEditor: View {
    @Binding var text: String
    var minHeight: CGFloat = 64
    var monospaced = false

    var body: some View {
        TextEditor(text: $text)
            .font(monospaced ? .system(.footnote, design: .monospaced) : .body)
            .scrollContentBackground(.hidden)
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
            .frame(minHeight: minHeight)
            .insetSurfaceBackground(
                RoundedRectangle(cornerRadius: 8),
                legacyFill: Color(nsColor: .textBackgroundColor),
                stroke: Color.primary.opacity(0.12)
            )
    }
}

private struct MultiFilePickerButton: View {
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
