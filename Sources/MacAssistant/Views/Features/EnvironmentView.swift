import SwiftUI
import AppKit
import MacAssistantKit

struct EnvironmentView: View {
    /// 检测要为缺失工具逐个起 `which` 子进程，必须在后台做；
    /// 放在 @State 初始值里会在每次视图构造时同步重跑，直接卡死主线程。
    @State private var tools: [ToolAvailability] = []
    @State private var isChecking = false
    @State private var pendingTool: ExternalTool?
    @State private var commandPreview = ""
    @State private var showConfirmation = false
    @State private var installing: Set<String> = []
    @State private var installLogs: [String: String] = [:]
    @State private var installSuccess: [String: Bool] = [:]
    @State private var theos: TheosEnvironmentSnapshot?
    @State private var selectedTheosRoot: URL?
    @State private var showTheosConfirmation = false
    @State private var theosInstalling = false
    @State private var theosInstallLog = ""
    @State private var managedTheosCommands: [InstallCommand] = []

    private var availableCount: Int {
        tools.filter(\.isAvailable).count
    }

    /// 用快照里的结果判断 brew 是否可用，避免渲染时再起进程探测。
    private var brewAvailable: Bool {
        tools.first { $0.tool == .brew }?.isAvailable ?? false
    }

    var body: some View {
        FeatureScaffold(
            title: L("env.title"),
            subtitle: tools.isEmpty
                ? L("env.checking")
                : L("env.subtitle", availableCount, tools.count)
        ) {
            theosCard

            Card {
                if tools.isEmpty {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text(L("env.checking"))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 8)
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(tools) { tool in
                            toolRow(tool)
                            if tool.id != tools.last?.id { Divider() }
                        }
                    }
                }
            }

            if !installLogs.isEmpty {
                Card {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(L("env.installStatus")).font(.headline)
                        ForEach(installLogs.keys.sorted(), id: \.self) { id in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(id).font(.callout.weight(.medium))
                                    Spacer()
                                    if installing.contains(id) {
                                        ProgressView().controlSize(.small)
                                    } else if let success = installSuccess[id] {
                                        StatusBadge(ok: success)
                                    }
                                }
                                Text(installLogs[id] ?? "")
                                    .font(.footnote.monospaced())
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                }
            }

            Label(
                L("env.builtInNote"),
                systemImage: "checkmark.shield"
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
            Text(EnvironmentInstaller.homebrewGuidance(
                macOSMajorVersion: ProcessInfo.processInfo.operatingSystemVersion.majorVersion
            ))
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        .task {
            if tools.isEmpty { await refresh() }
        }
        .toolbar {
            Button {
                Task { await refresh() }
            } label: {
                Label(L("env.refresh"), systemImage: "arrow.clockwise")
            }
            .disabled(isChecking)
            .help(L("env.refresh.help"))
            .accessibilityIdentifier("environment.refresh")
        }
        .alert(L("env.confirmInstall"), isPresented: $showConfirmation) {
            Button(L("common.cancel"), role: .cancel) {
                pendingTool = nil
            }
            Button(L("env.install")) {
                executePendingInstallation()
            }
        } message: {
            Text(confirmationMessage)
        }
    }

    private var theosCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Label("Theos 制作环境", systemImage: "hammer.fill")
                        .font(.callout.weight(.semibold))
                    Spacer(minLength: 8)
                    if let theos {
                        StatusBadge(ok: theos.isReadyToBuild)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
                if let theos {
                    Text(theos.root?.path ?? "未找到 THEOS；选择目录或按官方说明安装。")
                        .font(.footnote.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    if theos.isReadyToBuild {
                        Text("已检测到 nic.pl、模板、SDK 与构建工具，可用于后续 Theos 制作页。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("缺少：\(theos.missingRequirements.joined(separator: "、"))")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    if !theos.availableSDKs.isEmpty {
                        Text("SDK：\(theos.availableSDKs.joined(separator: "、"))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 10) {
                    FilePickerButton(title: "选择 Theos 目录", systemImage: "folder", chooseDirectory: true) {
                        selectedTheosRoot = $0
                        Task { await refresh() }
                    }
                    Button("安装说明") {
                        NSWorkspace.shared.open(TheosEnvironmentService.officialInstallationURL)
                    }
                    Button(managedTheosExists ? "更新内置 Theos" : "安装内置 Theos") {
                        showTheosConfirmation = true
                    }
                    .disabled(theosInstalling)
                    Spacer(minLength: 0)
                }
                if theosInstalling {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("正在拉取官方 Theos…").font(.footnote)
                    }
                }
                if !theosInstallLog.isEmpty {
                    Text(theosInstallLog)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        }
        .confirmationDialog(
            managedTheosExists ? "确认更新内置 Theos？" : "确认安装内置 Theos？",
            isPresented: $showTheosConfirmation,
            titleVisibility: .visible
        ) {
            Button(managedTheosExists ? "拉取更新" : "开始安装") {
                installOrUpdateTheos()
            }
        } message: {
            Text("来源：\(TheosEnvironmentService.officialRepositoryURL)\n目录：\(TheosEnvironmentService.managedRoot.path)\n\(managedTheosCommandPreview)")
        }
    }

    private var managedTheosExists: Bool {
        FileManager.default.fileExists(atPath: TheosEnvironmentService.managedRoot.appendingPathComponent(".git").path)
    }

    private var managedTheosCommandPreview: String {
        managedTheosCommands.map(\.preview).joined(separator: "\n")
    }

    private func installOrUpdateTheos() {
        theosInstalling = true
        theosInstallLog = ""
        Task {
            do {
                let results = try await Task.detached {
                    try TheosEnvironmentService.installOrUpdateManagedCopy()
                }.value
                theosInstallLog = results.map(\.combinedOutput)
                    .filter { !$0.isEmpty }
                    .joined(separator: "\n")
                selectedTheosRoot = TheosEnvironmentService.managedRoot
                await refresh()
            } catch {
                theosInstallLog = error.localizedDescription
            }
            theosInstalling = false
        }
    }

    @ViewBuilder
    private func toolRow(_ availability: ToolAvailability) -> some View {
        HStack(spacing: 10) {
            Image(systemName: statusIcon(for: availability))
                .foregroundStyle(statusColor(for: availability))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(availability.tool.commandName)
                    .font(.callout.weight(.medium))
                Text(toolDetail(availability))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 10)
            if installing.contains(availability.id) {
                ProgressView().controlSize(.small)
            } else {
                actionButton(for: availability)
            }
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L(
            "env.tool.accessibility",
            availability.tool.commandName,
            availability.isAvailable ? L("env.installed") : L("env.notInstalled")
        ))
        .accessibilityIdentifier("environment.tool.\(availability.id)")
    }

    @ViewBuilder
    private func actionButton(for availability: ToolAvailability) -> some View {
        if availability.isAvailable {
            Text(L("env.ready"))
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            switch availability.installStrategy {
            case .homebrewFormula:
                Button(brewAvailable ? L("env.install") : L("env.viewHomebrew")) {
                    if brewAvailable {
                        requestInstallation(availability.tool)
                    } else {
                        NSWorkspace.shared.open(EnvironmentInstaller.homebrewInstructionsURL)
                    }
                }
            case .xcodeCommandLineTools:
                Button(L("env.installCLT")) {
                    requestInstallation(availability.tool)
                }
            case let .openProjectPage(url):
                Button(L("env.openSite")) { NSWorkspace.shared.open(url) }
            case let .builtInFallback(_, projectURL):
                if let projectURL {
                    Button(L("env.viewExternal")) { NSWorkspace.shared.open(projectURL) }
                }
            case .systemProvided:
                Text(L("env.systemMissing"))
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private var confirmationMessage: String {
        guard pendingTool != nil else { return commandPreview }
        return commandPreview + L("env.install.source")
    }

    private func requestInstallation(_ tool: ExternalTool) {
        do {
            let command = try EnvironmentInstaller.makeCommand(for: tool.installStrategy)
            pendingTool = tool
            commandPreview = command.preview
            showConfirmation = true
        } catch {
            installLogs[tool.commandName] = error.localizedDescription
            installSuccess[tool.commandName] = false
        }
    }

    private func executePendingInstallation() {
        guard let tool = pendingTool else { return }
        pendingTool = nil
        let id = tool.commandName
        installing.insert(id)
        installSuccess[id] = nil
        installLogs[id] = L("env.install.preparing", commandPreview)

        Task {
            do {
                let command = try EnvironmentInstaller.makeCommand(for: tool.installStrategy)
                let result = try await Task.detached {
                    try EnvironmentInstaller.run(command)
                }.value
                var output = result.combinedOutput
                if case let .homebrewFormula(formula) = tool.installStrategy,
                   let brewPath = ExternalTool.brew.path {
                    let version = try Shell.run(brewPath, ["list", "--versions", formula])
                    if version.succeeded {
                        output += L(
                            "env.install.version",
                            version.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                        )
                    }
                }
                installLogs[id] = output.isEmpty ? L("env.install.finished") : output
                installSuccess[id] = true
                installing.remove(id)
                await refresh()
            } catch {
                installing.remove(id)
                installSuccess[id] = false
                installLogs[id] = error.localizedDescription
            }
        }
    }

    @MainActor
    private func refresh() async {
        guard !isChecking else { return }
        isChecking = true
        let preferredRoot = selectedTheosRoot
        // Task.detached：探测缺失工具会逐个 spawn `which`，不能占用主线程。
        async let toolSnapshot = Task.detached(priority: .userInitiated) {
            Environment.toolAvailabilities()
        }.value
        async let theosSnapshot = Task.detached(priority: .userInitiated) {
            TheosEnvironmentService.inspect(preferredRoot: preferredRoot)
        }.value
        async let commandSnapshot = Task.detached(priority: .userInitiated) {
            (try? TheosEnvironmentService.managedCommands()) ?? []
        }.value
        tools = await toolSnapshot
        theos = await theosSnapshot
        managedTheosCommands = await commandSnapshot
        isChecking = false
    }

    private func toolDetail(_ availability: ToolAvailability) -> String {
        if let path = availability.path { return path }
        if case let .homebrewFormula(formula) = availability.installStrategy {
            return L("env.missing.formula", formula)
        }
        return availability.installHint.map { L("env.missing.hint", $0) } ?? L("env.missing")
    }

    private func statusIcon(for availability: ToolAvailability) -> String {
        if availability.isAvailable { return "checkmark.circle.fill" }
        if case .builtInFallback = availability.installStrategy { return "info.circle.fill" }
        return "xmark.circle.fill"
    }

    private func statusColor(for availability: ToolAvailability) -> Color {
        if availability.isAvailable { return .green }
        if case .builtInFallback = availability.installStrategy { return .orange }
        return .red
    }
}
