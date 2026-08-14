import SwiftUI
import UniformTypeIdentifiers
import MacAssistantKit

struct RepairView: View {
    @StateObject private var task = TaskState()

    @State private var selectedApp: URL?
    @State private var removeSignatureFirst = false

    @State private var portText = ""
    @State private var portProcs: [PortProcess] = []
    @State private var portQuerying = false

    @State private var snapshots: [SnapshotEntry] = []
    @State private var snapshotQuerying = false

    @State private var devTargets: [CleanupTarget] = RepairService.devCacheTargets()
    @State private var devScanning = false

    var body: some View {
        FeatureScaffold(title: L("repairview.title"),
                        subtitle: L("repairview.subtitle")) {
            console
            signingSection
            networkSection
            cleanupSection
            interfaceSection
            footnote
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
                    PathBadge(url: selectedApp, placeholder: L("repairview.noApp"))
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

    // MARK: 4-8 网络与进程 / 清理与内存

    private var networkSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle(L("repairview.section.network"), L("repairview.section.network.detail"))

            RepairActionCard(
                title: L("repairview.flushDNS.title"),
                detail: L("repairview.flushDNS.detail"),
                risk: .caution,
                command: RepairService.flushDNSCommand,
                actionTitle: L("repairview.flushDNS.action"),
                disabled: task.running
            ) { performResult { try RepairService.flushDNS() } }

            Card {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(L("repairview.port.title")).font(.callout.weight(.semibold))
                        RiskBadge(risk: .caution)
                        Spacer()
                    }
                    HStack {
                        TextField(L("repairview.port.placeholder"), text: $portText)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 200)
                        Button { queryPort() } label: {
                            Label(portQuerying ? L("repairview.port.querying") : L("repairview.port.query"), systemImage: "magnifyingglass")
                        }.disabled(portQuerying || Int(portText) == nil)
                    }
                    if !portProcs.isEmpty {
                        commandPreview(RepairService.killCommand(pids: portProcs.map(\.pid), force: false))
                        ForEach(portProcs) { proc in
                            HStack {
                                Image(systemName: "gearshape.2").foregroundStyle(.secondary)
                                Text("\(proc.command)  ").font(.callout)
                                Text("PID \(proc.pid)").font(.caption).foregroundStyle(.secondary)
                                Spacer()
                                Button(L("repairview.kill")) { killPids([proc.pid], force: false) }
                                    .buttonStyle(.borderless)
                                Button(role: .destructive) { killPids([proc.pid], force: true) } label: {
                                    Text(L("repairview.forceKill"))
                                }.buttonStyle(.borderless)
                            }
                            .padding(8)
                            .insetSurfaceBackground(RoundedRectangle(cornerRadius: 8), legacyFill: .black.opacity(0.04))
                        }
                        Button(role: .destructive) { killPids(portProcs.map(\.pid), force: true) } label: {
                            Label(L("repairview.forceKillAll"), systemImage: "xmark.octagon")
                        }
                    } else if portQuerying == false && Int(portText) != nil {
                        Text(L("repairview.port.empty"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var cleanupSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle(L("repairview.section.cleanup"), L("repairview.section.cleanup.detail"))

            Card {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(L("repairview.devCache.title")).font(.callout.weight(.semibold))
                        RiskBadge(risk: .caution)
                        Spacer()
                        Button { scanDev() } label: {
                            Label(devScanning ? L("repairview.scanning") : L("repairview.scan"), systemImage: "magnifyingglass")
                        }.disabled(devScanning)
                        Button(role: .destructive) { cleanDev() } label: {
                            Label(L("repairview.cleanSelected"), systemImage: "trash")
                        }.disabled(devTargets.filter { $0.selected }.isEmpty)
                    }
                    Text(L("repairview.devCache.detail"))
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(devTargets) { target in
                        DevCacheRow(target: target)
                    }
                    Divider()
                    HStack {
                        Text(L("repairview.docker.title")).font(.caption.weight(.semibold))
                        RiskBadge(risk: .danger)
                        Spacer()
                        Button(role: .destructive) { runDockerPrune() } label: {
                            Label("prune", systemImage: "shippingbox")
                        }.buttonStyle(.borderless).disabled(task.running)
                    }
                    Text(L("repairview.docker.detail"))
                        .font(.caption2).foregroundStyle(.secondary)
                    commandPreview(RepairService.dockerPruneCommand)
                }
            }

            Card {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(L("repairview.snapshots.title")).font(.callout.weight(.semibold))
                        RiskBadge(risk: .caution)
                        Spacer()
                        Button { querySnapshots() } label: {
                            Label(snapshotQuerying ? L("repairview.port.querying") : L("repairview.snapshots.list"), systemImage: "clock.arrow.circlepath")
                        }.disabled(snapshotQuerying)
                    }
                    Text(L("repairview.snapshots.detail"))
                        .font(.caption).foregroundStyle(.secondary)
                    if snapshots.isEmpty {
                        Text(L("repairview.snapshots.empty")).font(.caption).foregroundStyle(.secondary)
                    } else {
                        ForEach(snapshots) { snap in
                            HStack {
                                Image(systemName: "camera.aperture").foregroundStyle(.secondary)
                                Text(snap.date).font(.system(.caption, design: .monospaced))
                                Spacer()
                                Button(role: .destructive) { deleteSnapshot(snap.date) } label: { Text(L("repairview.delete")) }
                                    .buttonStyle(.borderless)
                            }
                            .padding(8)
                            .insetSurfaceBackground(RoundedRectangle(cornerRadius: 8), legacyFill: .black.opacity(0.04))
                        }
                    }
                    commandPreview(RepairService.thinSnapshotsCommand)
                    Button(role: .destructive) { runThinSnapshots() } label: {
                        Label(L("repairview.snapshots.thin"), systemImage: "arrow.down.circle")
                    }.disabled(task.running)
                }
            }
        }
    }

    // MARK: 9-12 界面与系统

    private var interfaceSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle(L("repairview.section.interface"), HostArchitecture.isAppleSiliconHardware
                         ? L("repairview.section.interface.detail.arm")
                         : L("repairview.section.interface.detail"))

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

            recipeCard(title: L("repairview.screenshots.title"), detail: L("repairview.screenshots.detail"), recipes: RecipeLibrary.screenshot)
            recipeCard(title: L("repairview.visibility.title"), detail: L("repairview.visibility.detail"),
                       recipes: RecipeLibrary.finder.filter {
                           ["finder-show-hidden-on", "finder-show-hidden-off", "finder-extensions"].contains($0.id)
                       })

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

    private func recipeCard(title: String, detail: String, recipes: [ShellRecipe]) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.callout.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary)
                ForEach(recipes) { recipe in
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(recipe.name).font(.caption.weight(.medium))
                            Text(recipe.command).font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                        CopyButton(text: recipe.command)
                        Button(L("recipesview.run")) { runRecipe(recipe) }.buttonStyle(.borderless).disabled(task.running)
                    }
                    .padding(8)
                    .insetSurfaceBackground(RoundedRectangle(cornerRadius: 8), legacyFill: .black.opacity(0.04))
                }
            }
        }
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

    private func runThinSnapshots() {
        performResult { try RepairService.thinSnapshots() }
    }

    private func runDockerPrune() {
        performResult { try RepairService.dockerPrune() }
    }

    private func runRecipe(_ recipe: ShellRecipe) {
        performResult { try RecipeLibrary.run(recipe) }
    }

    private func openSystemSettings() {
        if let url = URL(string: RepairService.privacySecurityURL) {
            NSWorkspace.shared.open(url)
        }
    }

    private func queryPort() {
        guard let port = Int(portText) else { return }
        portQuerying = true
        portProcs = []
        DispatchQueue.global(qos: .userInitiated).async {
            let procs = RepairService.processes(onPort: port)
            DispatchQueue.main.async {
                portProcs = procs
                portQuerying = false
            }
        }
    }

    private func killPids(_ pids: [String], force: Bool) {
        guard !pids.isEmpty else { return }
        let copy = pids
        performResult { try RepairService.kill(pids: copy, force: force) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { queryPort() }
    }

    private func querySnapshots() {
        snapshotQuerying = true
        DispatchQueue.global(qos: .userInitiated).async {
            let list = RepairService.localSnapshots()
            DispatchQueue.main.async {
                snapshots = list
                snapshotQuerying = false
            }
        }
    }

    private func deleteSnapshot(_ date: String) {
        performResult { try RepairService.deleteSnapshot(date: date) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { querySnapshots() }
    }

    private func scanDev() {
        devScanning = true
        let items = devTargets.map { ($0.id, $0.paths) }
        DispatchQueue.global(qos: .userInitiated).async {
            let sizes = items.map { ($0.0, CleanupService.size(ofPaths: $0.1)) }
            DispatchQueue.main.async {
                for (id, size) in sizes { devTargets.first { $0.id == id }?.size = size }
                devScanning = false
            }
        }
    }

    private func cleanDev() {
        let selected = devTargets.filter { $0.selected }
        let items = selected.map { ($0.id, $0.paths) }
        guard !items.isEmpty else { return }
        performTask(task) {
            var freed: Int64 = 0
            for (_, paths) in items { freed += CleanupService.cleanPaths(paths) }
            return L("repairview.devCache.cleaned", FileSystemHelper.humanReadableSize(freed))
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { scanDev() }
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

private struct DevCacheRow: View {
    @ObservedObject var target: CleanupTarget

    var body: some View {
        HStack(spacing: 10) {
            Toggle("", isOn: $target.selected).labelsHidden()
            VStack(alignment: .leading, spacing: 1) {
                Text(target.name).font(.caption.weight(.medium))
                Text(target.detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Text(target.size > 0 ? FileSystemHelper.humanReadableSize(target.size) : "—")
                .font(.caption.monospacedDigit())
                .foregroundStyle(target.size > 0 ? .primary : .secondary)
        }
        .padding(8)
        .insetSurfaceBackground(RoundedRectangle(cornerRadius: 8), legacyFill: .black.opacity(0.04))
    }
}
