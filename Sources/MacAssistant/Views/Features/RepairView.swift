import AppKit
import SwiftUI
import UniformTypeIdentifiers
import MacAssistantKit

struct RepairView: View {
    @ObservedObject var workspace: WorkspaceStore
    @StateObject private var task = TaskState()

    @State private var selectedApp: URL?
    @State private var removeSignatureFirst = false
    @State private var softwareUpdatePolicy = SoftwareUpdatePolicyService.read()
    @State private var includeSecurityDataUpdates = false

    var body: some View {
        FeatureScaffold(title: L("repairview.title"),
                        subtitle: L("repairview.subtitle")) {
            ToolFinderCard(workspace: workspace)
            PermissionGuideCard(needs: PermissionGuide.repair)
            console
            signingSection
            interfaceSection
            footnote
        }
        .onAppear {
            refreshSoftwareUpdatePolicy()
        }
    }

    // MARK: 顶部控制台

    private var console: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label(L("repairview.console"), systemImage: "terminal")
                        .font(.callout.weight(.semibold))
                    if task.running { ProgressView().controlSize(.small) }
                    Spacer()
                    StatusBadge(ok: task.ok)
                    if !task.log.isEmpty {
                        Button { task.reset() } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless).foregroundStyle(.secondary)
                    }
                }
                ConsoleView(text: task.log, minHeight: 80)
            }
        }
    }

    // MARK: 1-3 签名与隔离

    private var signingSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle(L("repairview.section.signing"), L("repairview.section.signing.detail"))

            Card {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        FilePickerButton(title: L("repairview.chooseApp"), systemImage: "app.dashed",
                                         types: [.applicationBundle, .application]) { url in
                            selectedApp = url
                        }
                        Spacer()
                        if selectedApp != nil {
                            Button(L("repairview.clear")) { selectedApp = nil }.buttonStyle(.borderless)
                        }
                    }
                    PathBadge(url: selectedApp, placeholder: L("repairview.noApp")) { urls in
                        if let url = urls.first { selectedApp = url }
                    }
                }
            }

            RepairActionCard(
                title: L("repairview.dequarantine.title"),
                detail: L("repairview.dequarantine.detail"),
                risk: .caution,
                command: RepairService.dequarantineCommand(appPath: selectedApp?.path ?? L("repairview.samplePath"), fullReset: false),
                actionTitle: L("repairview.dequarantine.action"),
                disabled: selectedApp == nil || task.running
            ) { runRemoveQuarantine(fullReset: false) }

            RepairActionCard(
                title: L("repairview.clearXattr.title"),
                detail: L("repairview.clearXattr.detail"),
                risk: .caution,
                command: RepairService.dequarantineCommand(appPath: selectedApp?.path ?? L("repairview.samplePath"), fullReset: true),
                actionTitle: L("repairview.clearXattr.action"),
                disabled: selectedApp == nil || task.running
            ) { runRemoveQuarantine(fullReset: true) }

            Card {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(L("repairview.resign.title")).font(.callout.weight(.semibold))
                        RiskBadge(risk: .caution)
                        Spacer()
                        Button {
                            runResign()
                        } label: { Label(L("repairview.resign.action"), systemImage: "signature") }
                        .disabled(selectedApp == nil || task.running)
                    }
                    Toggle(L("repairview.removeSignatureFirst"), isOn: $removeSignatureFirst)
                        .font(.caption)
                    Text(L("repairview.resign.detail"))
                        .font(.caption).foregroundStyle(.secondary)
                    commandPreview(RepairService.resignCommandPreview(
                        appPath: selectedApp?.path ?? L("repairview.samplePath"),
                        removeSignatureFirst: removeSignatureFirst))
                }
            }

            let gatekeeperPlan = RepairService.gatekeeperPlan(
                appPath: selectedApp?.path ?? L("repairview.samplePath")
            )
            Card {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(L("repairview.gatekeeper.title")).font(.callout.weight(.semibold))
                        RiskBadge(risk: .safe)
                        Spacer()
                        Button { openSystemSettings() } label: {
                            Label(L("repairview.openPrivacySettings"), systemImage: "gearshape")
                        }
                    }
                    Text(gatekeeperPlan.guidance)
                        .font(.caption).foregroundStyle(.secondary)
                    commandPreview(gatekeeperPlan.commandPreview)
                    Text(L("repairview.gatekeeper.note"))
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: 界面与系统

    private var interfaceSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle(L("repairview.section.interface"), HostArchitecture.isAppleSiliconHardware
                         ? L("repairview.section.interface.detail.arm")
                         : L("repairview.section.interface.detail"))

            softwareUpdateCard

            Card {
                VStack(alignment: .leading, spacing: 8) {
                    Text(L("repairview.restart.title")).font(.callout.weight(.semibold))
                    HStack {
                        Button { performResult { try RepairService.restart("Finder") } } label: {
                            Label(L("repairview.restart.finder"), systemImage: "arrow.clockwise")
                        }
                        Button { performResult { try RepairService.restart("Dock") } } label: {
                            Label(L("repairview.restart.dock"), systemImage: "arrow.clockwise")
                        }
                        Button { performResult { try RepairService.restart("SystemUIServer") } } label: {
                            Label(L("repairview.restart.menubar"), systemImage: "arrow.clockwise")
                        }
                    }
                    Text(L("repairview.restart.detail"))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            // Intel 机器本身就跑 x86_64,不存在可安装的转译层,整张卡片不显示。
            if HostArchitecture.isAppleSiliconHardware {
                RepairActionCard(
                    title: L("repairview.rosetta.title"),
                    detail: RepairService.rosettaRuntimePresent
                        ? L("repairview.rosetta.detail.present")
                        : L("repairview.rosetta.detail"),
                    risk: .caution,
                    command: RepairService.rosettaCommand,
                    actionTitle: L("repairview.rosetta.action"),
                    disabled: task.running
                ) { performResult { try RepairService.installRosetta() } }
            }
        }
    }

    private var softwareUpdateCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(L("repairview.softwareUpdate.title")).font(.callout.weight(.semibold))
                    RiskBadge(risk: .caution)
                    Spacer()
                    Toggle(isOn: disableAutomaticUpdatesBinding) {
                        Text(L("repairview.softwareUpdate.toggle"))
                    }
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .disabled(task.running)
                    .accessibilityLabel(L("repairview.softwareUpdate.toggle"))
                    .accessibilityIdentifier("repair.softwareUpdate.toggle")
                }
                Text(softwareUpdateStatusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(L("repairview.softwareUpdate.detail"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Toggle(isOn: $includeSecurityDataUpdates) {
                    Text(L("repairview.softwareUpdate.includeSecurity"))
                        .font(.caption)
                }
                .disabled(task.running)
                commandPreview(SoftwareUpdatePolicyService.commandPreview(softwareUpdatePreviewPolicy))
                HStack {
                    Button { openSoftwareUpdateSettings() } label: {
                        Label(L("repairview.softwareUpdate.openSettings"), systemImage: "gearshape")
                    }
                    Button { refreshSoftwareUpdatePolicy() } label: {
                        Label(L("repairview.softwareUpdate.refresh"), systemImage: "arrow.clockwise")
                    }
                    .disabled(task.running)
                }
            }
        }
    }

    private var disableAutomaticUpdatesBinding: Binding<Bool> {
        Binding(
            get: { softwareUpdatePolicy.suppressesAutomaticMacOSUpdates },
            set: { applySoftwareUpdateDisable($0) }
        )
    }

    private var softwareUpdateStatusText: String {
        if softwareUpdatePolicy.suppressesAutomaticMacOSUpdates {
            return L("repairview.softwareUpdate.status.on")
        }
        if softwareUpdatePolicy.isPartial {
            return L("repairview.softwareUpdate.status.partial")
        }
        return L("repairview.softwareUpdate.status.off")
    }

    private var footnote: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(L("repairview.footnote.password"), systemImage: "lock.shield")
            Label(L("repairview.footnote.danger"), systemImage: "exclamationmark.triangle")
            Label(L("repairview.footnote.paste"), systemImage: "info.circle")
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .padding(.top, 4)
    }

    // MARK: 复用组件

    private func sectionTitle(_ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.title3.bold()).foregroundStyle(.tint)
            Text(subtitle).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.top, 6)
    }

    private func commandPreview(_ command: String) -> some View {
        HStack(alignment: .top) {
            Text(command)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            CopyButton(text: command)
        }
        .padding(8)
        .insetSurfaceBackground(RoundedRectangle(cornerRadius: 8), legacyFill: .black.opacity(0.05))
    }

    // MARK: 动作

    private func performResult(_ work: @escaping @Sendable () throws -> CommandResult) {
        guard !task.running else { return }
        performTask(task) {
            let r = try work()
            var text = r.combinedOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty {
                text = r.succeeded ? L("repairview.doneNoOutput") : L("repairview.exitCode", Int(r.exitCode))
            }
            if !r.succeeded {
                throw NSError(domain: "Repair", code: Int(r.exitCode),
                              userInfo: [NSLocalizedDescriptionKey: text])
            }
            return text
        }
    }

    private func runRemoveQuarantine(fullReset: Bool) {
        guard let app = selectedApp else { return }
        performResult { try RepairService.removeQuarantine(app: app, fullReset: fullReset) }
    }

    private func runResign() {
        guard let app = selectedApp else { return }
        let removeFirst = removeSignatureFirst
        guard !task.running else { return }
        performTask(task) {
            let (r, _) = try RepairService.adhocResign(app: app, removeSignatureFirst: removeFirst)
            let head = L("repairview.resign.head") + "\n"
            let body = r.combinedOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            let text = head + (body.isEmpty ? "" : body)
            if !r.succeeded {
                throw NSError(domain: "Repair", code: Int(r.exitCode),
                              userInfo: [NSLocalizedDescriptionKey: text + "\n" + L("repairview.resign.failed")])
            }
            return text + "\n" + L("repairview.resign.done")
        }
    }

    private func openSystemSettings() {
        if let url = URL(string: RepairService.privacySecurityURL) {
            NSWorkspace.shared.open(url)
        }
    }

    private func openSoftwareUpdateSettings() {
        for raw in SoftwareUpdatePolicyService.settingsURLs {
            if let url = URL(string: raw), NSWorkspace.shared.open(url) {
                return
            }
        }
    }

    private func refreshSoftwareUpdatePolicy() {
        softwareUpdatePolicy = SoftwareUpdatePolicyService.read()
    }

    private var softwareUpdatePreviewPolicy: SoftwareUpdatePolicy {
        softwareUpdatePolicy.suppressesAutomaticMacOSUpdates
            ? .automatic(includingSecurityData: includeSecurityDataUpdates)
            : .suppressed(includingSecurityData: includeSecurityDataUpdates)
    }

    private func applySoftwareUpdateDisable(_ disable: Bool) {
        guard !task.running else { return }
        let policy: SoftwareUpdatePolicy = disable
            ? .suppressed(includingSecurityData: includeSecurityDataUpdates)
            : .automatic(includingSecurityData: includeSecurityDataUpdates)
        task.running = true
        task.ok = nil
        Task {
            do {
                let text = try await Task.detached(priority: .userInitiated) {
                    let result = try SoftwareUpdatePolicyService.apply(policy)
                    if AdminRunner.isCancelled(result) {
                        throw NSError(
                            domain: "Repair",
                            code: 128,
                            userInfo: [NSLocalizedDescriptionKey: L("repairview.softwareUpdate.cancelled")]
                        )
                    }
                    if !result.succeeded {
                        let output = result.combinedOutput.trimmingCharacters(in: .whitespacesAndNewlines)
                        throw NSError(
                            domain: "Repair",
                            code: Int(result.exitCode),
                            userInfo: [
                                NSLocalizedDescriptionKey: output.isEmpty
                                    ? L("repairview.exitCode", Int(result.exitCode))
                                    : output
                            ]
                        )
                    }
                    let output = result.combinedOutput.trimmingCharacters(in: .whitespacesAndNewlines)
                    return output.isEmpty ? L("repairview.doneNoOutput") : output
                }.value
                task.log = text
                task.ok = true
            } catch {
                task.log = error.localizedDescription
                task.ok = false
            }
            refreshSoftwareUpdatePolicy()
            task.running = false
        }
    }

}

// MARK: - 子组件

private struct RepairActionCard: View {
    let title: String
    let detail: String
    let risk: RiskLevel
    let command: String
    var actionTitle: String = L("repairview.run")
    var disabled: Bool = false
    let run: () -> Void

    @State private var confirming = false

    var body: some View {
        Card(padding: 12) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(title).font(.callout.weight(.semibold))
                    RiskBadge(risk: risk)
                    Spacer()
                    Button(role: risk == .danger ? .destructive : nil) {
                        if risk == .danger { confirming = true } else { run() }
                    } label: {
                        Label(actionTitle, systemImage: "play.fill")
                    }
                    .disabled(disabled)
                    .confirmationDialog(L("repairview.confirm.title", title), isPresented: $confirming, titleVisibility: .visible) {
                        Button(L("repairview.confirm.run"), role: .destructive) { run() }
                        Button(L("common.cancel"), role: .cancel) {}
                    } message: {
                        Text(L("repairview.confirm.message", detail))
                    }
                }
                Text(detail).font(.caption).foregroundStyle(.secondary)
                if !command.isEmpty {
                    HStack(alignment: .top) {
                        Text(command)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        CopyButton(text: command)
                    }
                    .padding(8)
                    .insetSurfaceBackground(RoundedRectangle(cornerRadius: 8), legacyFill: .black.opacity(0.05))
                }
            }
        }
    }
}
