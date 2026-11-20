import SwiftUI
import AppKit
import MacAssistantKit

struct MemoryView: View {
    @StateObject private var iconProvider = ProcessIconProvider()
    @State private var snapshot: MemorySnapshot?
    @State private var processes: [ProcessMemoryInfo] = []
    @State private var selectedID: String?
    @State private var query = ""
    @State private var sort: ProcessListSort = .memory
    @State private var grouped = true
    @State private var expandedGroups: Set<String> = []
    @State private var cpuHistory: [Int32: ProcessCPUSample] = [:]
    @State private var seenPIDs: Set<Int32>?
    @State private var freshUntil: [Int32: Date] = [:]
    @State private var inspection: ProcessInspection?
    @State private var detailLoading = false
    @State private var sampleSheet: SampleSheet?
    @State private var sampling = false
    @State private var busy = false
    @State private var live = true
    @State private var statusText = ""
    @State private var showingTopProcessHint = false
    @State private var pendingSignal: PendingSignal?
    @State private var showPurgeConfirmation = false
    @State private var developerOperationsExpanded = false
    @State private var loadGeneration = 0
    @State private var isLoading = false
    @State private var terminateRefreshTask: Task<Void, Never>?

    private var filteredProcesses: [ProcessMemoryInfo] {
        processes.filter { $0.matches(query) }
    }

    private var selectedProcess: ProcessMemoryInfo? {
        process(for: selectedID, among: processes)
    }

    private var searching: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var totalMemory: UInt64 {
        filteredProcesses.reduce(0) { $0 + $1.memoryBytes }
    }

    var body: some View {
        FeatureScaffold(title: L("memoryview.title"), subtitle: L("memoryview.subtitle")) {
            pressureSection
            processSection
            if !statusText.isEmpty {
                Card {
                    Text(statusText)
                        .font(.footnote)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("memory.status")
                }
            }
        } trailing: {
            Toggle(isOn: $live) {
                Label(L("dashboard.live"), systemImage: "dot.radiowaves.left.and.right")
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .help(L("memoryview.live.help"))
            .accessibilityIdentifier("memory.live")
        }
        .toolbar {
            Button {
                Task { await refresh(markBusy: true, force: true) }
            } label: {
                Label(L("memoryview.refresh"), systemImage: "arrow.clockwise")
            }
            .keyboardShortcut("r", modifiers: [.command])
            .disabled(busy)
            .accessibilityIdentifier("memory.refresh")
        }
        .task(id: live) {
            if !live {
                terminateRefreshTask?.cancel()
                terminateRefreshTask = nil
            }
            await refresh(markBusy: snapshot == nil)
            guard live else { return }
            while live, !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard live, !Task.isCancelled else { break }
                if busy { continue }
                await refresh()
            }
        }
        .onReceive(
            NSWorkspace.shared.notificationCenter.publisher(
                for: NSWorkspace.didTerminateApplicationNotification
            )
        ) { _ in
            guard live, !busy else { return }
            terminateRefreshTask?.cancel()
            terminateRefreshTask = Task {
                try? await Task.sleep(nanoseconds: 400_000_000)
                guard !Task.isCancelled else { return }
                await refresh(force: true)
            }
        }
        .onDisappear {
            terminateRefreshTask?.cancel()
            terminateRefreshTask = nil
        }
        .alert(item: $pendingSignal) { pending in
            confirmation(for: pending)
        }
        .sheet(item: $inspection) { inspection in
            ProcessDetailSheet(inspection: inspection)
        }
        .sheet(item: $sampleSheet) { sheet in
            ProcessSampleSheet(name: sheet.name, result: sheet.result)
        }
        .alert(L("memoryview.purge.confirmTitle"), isPresented: $showPurgeConfirmation) {
            if MemoryService.purgeAvailable {
                Button(L("memoryview.purge.confirm"), role: .destructive) {
                    purge()
                }
            }
            Button(L("common.cancel"), role: .cancel) {}
        } message: {
            Text(
                MemoryService.purgeOperation.explanation
                + "\n\n"
                + L("memoryview.purge.confirmDetail")
            )
        }
    }

    private var pressureSection: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label(L("memoryview.pressure"), systemImage: "memorychip")
                        .font(.headline)
                    Spacer()
                    if let snapshot {
                        Label(snapshot.pressureLevel.label, systemImage: pressureIcon(snapshot.pressureLevel))
                            .foregroundStyle(pressureColor(snapshot.pressureLevel))
                            .accessibilityIdentifier("memory.pressure")
                    } else if busy {
                        ProgressView().controlSize(.small)
                    }
                }

                if let snapshot {
                    HStack(spacing: 20) {
                        metric(L("memoryview.metric.physical"), snapshot.physical)
                        metric(L("memoryview.metric.used"), snapshot.used)
                        metric(L("memoryview.metric.cached"), snapshot.cached)
                        metric(L("memoryview.metric.compressed"), snapshot.compressed)
                        metric(L("memoryview.metric.swap"), snapshot.swapUsed)
                    }
                    .accessibilityElement(children: .contain)

                    if snapshot.physical > 0 {
                        ProgressView(value: snapshot.usedFraction, total: 1)
                            .tint(pressureColor(snapshot.pressureLevel))
                            .accessibilityLabel(L("memoryview.pressure.accessibility"))
                            .accessibilityValue(
                                L(
                                    "memoryview.pressure.value",
                                    snapshot.pressureLevel.label,
                                    snapshot.usedPercent
                                )
                            )
                    }
                }

                HStack {
                    Button {
                        showingTopProcessHint = true
                        applyTopProcessHint()
                    } label: {
                        Label(L("memoryview.showTopProcess"), systemImage: "list.number")
                    }
                    .disabled(busy || processes.isEmpty)
                    .accessibilityHint(L("memoryview.showTopProcess.hint"))
                    .accessibilityIdentifier("memory.quickRelease")
                    Spacer()
                }

                DisclosureGroup(L("memoryview.developer"), isExpanded: $developerOperationsExpanded) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(MemoryService.purgeOperation.explanation)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button(role: .destructive) {
                            showPurgeConfirmation = true
                        } label: {
                            Label(L("memoryview.runPurge"), systemImage: "externaldrive.badge.xmark")
                        }
                        .disabled(busy || !MemoryService.purgeAvailable)
                        .accessibilityIdentifier("memory.developerPurge")
                    }
                    .padding(.top, 6)
                }
                .font(.callout)
            }
        }
    }

    private var processSection: some View {
        Card(padding: 0) {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Text(L("memoryview.processes"))
                        .font(.headline)
                        .fixedSize()
                    Text("\(filteredProcesses.count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Text(L("memoryview.processes.total", MemoryService.formatBytes(totalMemory)))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                    TextField(L("memoryview.search"), text: $query)
                        .textFieldStyle(.soft)
                        .frame(width: 220)
                        .accessibilityLabel(L("memoryview.search.accessibility"))
                        .accessibilityIdentifier("memory.search")
                }
                .padding(.horizontal, 14)
                .padding(.top, 14)
                .padding(.bottom, 8)

                HStack(spacing: 8) {
                    Toggle(isOn: $grouped) {
                        Label(L("memoryview.group"), systemImage: "square.stack.3d.up")
                    }
                    .toggleStyle(.button)
                    .controlSize(.small)
                    .help(L("memoryview.group.help"))
                    .accessibilityIdentifier("memory.group")
                    Spacer()
                    processActions
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 10)

                Divider()

                processColumns
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)

                List(selection: $selectedID) {
                    ForEach(listEntries) { entry in
                        listRow(entry)
                            .tag(entry.id)
                            .sceneListRowFill()
                    }
                }
                .listStyle(.inset)
                .sceneListChrome()
                .frame(minHeight: 270, idealHeight: 360)
                .accessibilityIdentifier("memory.processList")
            }
        }
    }

    private var processActions: some View {
        HStack(spacing: 8) {
            Button {
                openDetail()
            } label: {
                Label(L("memoryview.detail"), systemImage: "info.circle")
            }
            .disabled(selectedProcess == nil || detailLoading || busy)
            .help(L("memoryview.detail.help"))
            .accessibilityIdentifier("memory.detail")
            Button {
                bringSelectionToFront()
            } label: {
                Label(L("memoryview.front"), systemImage: "macwindow.on.rectangle")
            }
            .disabled(selectedProcess == nil || busy)
            .help(L("memoryview.front.help"))
            .accessibilityIdentifier("memory.front")
            Button {
                sampleSelection()
            } label: {
                Label(L("memoryview.sample"), systemImage: "waveform.path.ecg")
            }
            .disabled(selectedProcess == nil || sampling || busy)
            .help(L("memoryview.sample.help"))
            .accessibilityIdentifier("memory.sample")
            Button(selectedProcess?.isStopped == true ? L("memoryview.resume") : L("memoryview.freeze")) {
                guard let selectedProcess else { return }
                let signal: ProcessSignal = selectedProcess.isStopped ? .resume : .suspend
                do {
                    let targets = try MemoryService.suspensionTargets(
                        for: selectedProcess,
                        among: processes,
                        action: signal
                    )
                    pendingSignal = PendingSignal(
                        process: selectedProcess,
                        signal: signal,
                        targets: targets
                    )
                } catch {
                    showingTopProcessHint = false
                    statusText = error.localizedDescription
                }
            }
            .disabled(selectedProcess == nil || busy)
            .help(selectedProcess?.isStopped == true ? L("memoryview.resume.hint") : L("memoryview.freeze.hint"))
            .accessibilityHint(selectedProcess?.isStopped == true ? L("memoryview.resume.hint") : L("memoryview.freeze.hint"))
            .accessibilityIdentifier(selectedProcess?.isStopped == true ? "memory.resume" : "memory.freeze")
            Button(L("memoryview.quit")) {
                if let selectedProcess {
                    pendingSignal = PendingSignal(process: selectedProcess, signal: .terminate)
                }
            }
            .disabled(selectedProcess == nil || busy)
            .accessibilityHint(L("memoryview.quit.hint"))
            Button(L("memoryview.forceQuit")) {
                if let selectedProcess {
                    pendingSignal = PendingSignal(process: selectedProcess, signal: .kill)
                }
            }
            .disabled(selectedProcess == nil || busy)
            .accessibilityHint(L("memoryview.forceQuit.hint"))
        }
        .controlSize(.small)
    }

    private var processColumns: some View {
        HStack(spacing: 10) {
            sortButton(.name, L("memoryview.column.name"), help: nil)
            Spacer()
            sortButton(.cpu, L("memoryview.column.cpu"), help: L("memoryview.column.cpu.help"))
                .frame(width: 72, alignment: .trailing)
            sortButton(.memory, L("memoryview.column.memory"), help: nil)
                .frame(width: 148, alignment: .trailing)
        }
    }

    private func sortButton(_ kind: ProcessListSort, _ title: String, help: String?) -> some View {
        Button {
            sort = kind
        } label: {
            Text(title)
                .font(.caption.weight(sort == kind ? .semibold : .regular))
                .foregroundStyle(sort == kind ? Color.accentColor : Color.secondary)
        }
        .buttonStyle(.borderless)
        .help(help ?? title)
        .accessibilityIdentifier(sortIdentifier(kind))
        .accessibilityAddTraits(sort == kind ? .isSelected : [])
    }

    private func rowIcon(_ entry: ProcessListEntry) -> NSImage {
        if let process = entry.iconProcess {
            return iconProvider.icon(for: process)
        }
        return NSImage(systemSymbolName: "app", accessibilityDescription: L("memoryview.icon.app"))
            ?? NSImage(size: NSSize(width: 24, height: 24))
    }

    private func listRow(_ entry: ProcessListEntry) -> some View {
        HStack(spacing: 8) {
            if let group = entry.group {
                Button {
                    toggle(group)
                } label: {
                    Image(systemName: isExpanded(group) ? "chevron.down" : "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .frame(width: 14)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(L("memoryview.group"))
            } else if entry.depth > 0 {
                Color.clear.frame(width: 14)
            }
            ProcessMemoryRow(
                title: entry.title,
                subtitle: entry.subtitle,
                stopped: entry.stopped,
                fresh: entry.fresh,
                cpuPercent: entry.cpuPercent,
                memoryBytes: entry.memoryBytes,
                physicalMemory: snapshot?.physical ?? 0,
                icon: rowIcon(entry)
            )
        }
        .padding(.vertical, 3)
    }

    private func metric(_ title: String, _ bytes: UInt64) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(MemoryService.formatBytes(bytes))
                .font(.callout.monospacedDigit().weight(.medium))
        }
    }

    private func refresh(markBusy: Bool = false, force: Bool = false) async {
        if isLoading && !force && !markBusy { return }
        if markBusy {
            busy = true
        }
        isLoading = true
        loadGeneration += 1
        let generation = loadGeneration
        defer {
            if generation == loadGeneration {
                isLoading = false
            }
            if markBusy { busy = false }
        }
        do {
            let result = try await Task.detached(priority: .utility) {
                (try MemoryService.snapshot(), try MemoryService.processes())
            }.value
            guard generation == loadGeneration else { return }
            let stamped = ProcessCPUAccounting.annotate(result.1, history: cpuHistory, now: Date())
            cpuHistory = stamped.history
            apply(snapshot: result.0, processes: stamped.processes)
        } catch {
            guard generation == loadGeneration, markBusy else { return }
            statusText = error.localizedDescription
        }
    }

    private func apply(snapshot newSnapshot: MemorySnapshot, processes newProcesses: [ProcessMemoryInfo]) {
        if snapshot != newSnapshot {
            snapshot = newSnapshot
        }
        noteArrivals(newProcesses)
        if processes.map(\.pid) != newProcesses.map(\.pid) {
            iconProvider.retain(processes: newProcesses)
        }
        if processes != newProcesses {
            processes = newProcesses
        }
        if process(for: selectedID, among: processes) == nil {
            selectedID = nil
        }
        applyTopProcessHint()
    }

    private func applyTopProcessHint() {
        guard showingTopProcessHint else { return }
        if let process = processes.first {
            selectedID = "p:\(process.pid)"
            statusText = L(
                "memoryview.topProcess",
                process.displayName,
                MemoryService.formatBytes(process.memoryBytes)
            )
        } else if !statusText.isEmpty {
            statusText = ""
        }
    }

    private func confirmation(for pending: PendingSignal) -> Alert {
        switch pending.signal {
        case .suspend:
            return Alert(
                title: Text(L("memoryview.alert.freeze")),
                message: Text(L(
                    "memoryview.alert.freeze.detail",
                    pending.process.displayName,
                    pending.targets.count
                )),
                primaryButton: .default(Text(L("memoryview.freeze"))) {
                    send(pending.signal, to: pending.process, targets: pending.targets)
                },
                secondaryButton: .cancel()
            )
        case .resume:
            return Alert(
                title: Text(L("memoryview.alert.resume")),
                message: Text(L(
                    "memoryview.alert.resume.detail",
                    pending.process.displayName,
                    pending.targets.count
                )),
                primaryButton: .default(Text(L("memoryview.resume"))) {
                    send(pending.signal, to: pending.process, targets: pending.targets)
                },
                secondaryButton: .cancel()
            )
        case .terminate, .kill:
            let force = pending.signal == .kill
            return Alert(
                title: Text(force ? L("memoryview.alert.forceQuit") : L("memoryview.alert.quit")),
                message: Text(
                    L("memoryview.alert.process", pending.process.displayName, Int(pending.process.pid))
                    + "\n"
                    + (force
                       ? L("memoryview.alert.kill.detail")
                       : L("memoryview.alert.terminate.detail"))
                ),
                primaryButton: .destructive(
                    Text(force ? L("memoryview.forceQuit") : L("memoryview.quit"))
                ) {
                    send(pending.signal, to: pending.process)
                },
                secondaryButton: .cancel()
            )
        }
    }

    private func send(
        _ signal: ProcessSignal,
        to process: ProcessMemoryInfo,
        targets: [ProcessMemoryInfo]? = nil
    ) {
        showingTopProcessHint = false
        busy = true
        let batch = targets ?? [process]
        Task {
            do {
                if signal == .suspend || signal == .resume {
                    let result = await Task.detached {
                        MemoryService.send(signal, to: batch)
                    }.value
                    if result.sent == 0 {
                        statusText = result.failure ?? L("memoryview.signal.failed")
                    } else if let failure = result.failure {
                        statusText = L("memoryview.signal.partial", result.sent, failure)
                    } else {
                        statusText = L(
                            signal == .suspend ? "memoryview.frozen.result" : "memoryview.resumed.result",
                            process.displayName,
                            result.sent
                        )
                    }
                } else {
                    try await Task.detached {
                        try MemoryService.send(signal, to: process)
                    }.value
                    statusText = L(
                        "memoryview.signalSent",
                        process.displayName,
                        Int(process.pid),
                        signal == .terminate ? "SIGTERM" : "SIGKILL"
                    )
                }
                try? await Task.sleep(nanoseconds: 600_000_000)
                await refresh(force: true)
            } catch {
                statusText = error.localizedDescription
            }
            busy = false
        }
    }

    private func purge() {
        busy = true
        let before = snapshot
        statusText = L("memoryview.waitingAuthorization")
        Task {
            do {
                _ = try await Task.detached {
                    try MemoryService.purgeFileCache()
                }.value
                try? await Task.sleep(nanoseconds: 800_000_000)
                let after = try await Task.detached { try MemoryService.snapshot() }.value
                snapshot = after
                let unknown = L("memoryview.unknown")
                let beforeUsed = before.map { MemoryService.formatBytes($0.used) } ?? unknown
                statusText = L(
                    "memoryview.purge.result",
                    beforeUsed,
                    MemoryService.formatBytes(after.used),
                    before?.pressureLevel.label ?? unknown,
                    after.pressureLevel.label
                )
            } catch {
                statusText = error.localizedDescription
            }
            busy = false
        }
    }

    private var listEntries: [ProcessListEntry] {
        let filtered = filteredProcesses
        if grouped {
            return ProcessListOrganizer.groups(from: filtered, sort: sort).flatMap { group in
                var rows = [groupEntry(group)]
                if group.processes.count > 1, isExpanded(group) {
                    rows.append(contentsOf: group.processes.map { processEntry($0, depth: 1) })
                }
                return rows
            }
        }
        return ProcessListOrganizer.sorted(filtered, by: sort).map { processEntry($0, depth: 0) }
    }

    private func groupEntry(_ group: ProcessAppGroup) -> ProcessListEntry {
        if group.processes.count == 1, let process = group.processes.first {
            return processEntry(process, depth: 0)
        }
        let iconProcess = group.primaryProcess ?? group.processes.first
        return ProcessListEntry(
            id: "g:\(group.id)",
            title: group.displayName,
            subtitle: L("memoryview.group.count", group.processes.count),
            stopped: group.isStopped,
            fresh: false,
            cpuPercent: group.cpuPercent,
            memoryBytes: group.memoryBytes,
            iconProcess: iconProcess,
            group: group,
            depth: 0
        )
    }

    private func processEntry(_ process: ProcessMemoryInfo, depth: Int) -> ProcessListEntry {
        ProcessListEntry(
            id: "p:\(process.pid)",
            title: process.displayName,
            subtitle: processSubtitle(process),
            stopped: process.isStopped,
            fresh: isFresh(process.pid),
            cpuPercent: process.cpuPercent,
            memoryBytes: process.memoryBytes,
            iconProcess: process,
            group: nil,
            depth: depth
        )
    }

    private func processSubtitle(_ process: ProcessMemoryInfo) -> String {
        let pid = "PID \(process.pid)"
        if let remark = process.remark, !remark.isEmpty {
            return "\(remark) · \(pid)"
        }
        if process.displayName.compare(process.name, options: [.caseInsensitive, .diacriticInsensitive]) != .orderedSame {
            return "\(process.name) · \(pid)"
        }
        return pid
    }

    private func isExpanded(_ group: ProcessAppGroup) -> Bool {
        searching || expandedGroups.contains(group.id)
    }

    private func toggle(_ group: ProcessAppGroup) {
        if expandedGroups.contains(group.id) {
            expandedGroups.remove(group.id)
        } else {
            expandedGroups.insert(group.id)
        }
    }

    private func process(for selection: String?, among processes: [ProcessMemoryInfo]) -> ProcessMemoryInfo? {
        guard let selection else { return nil }
        if selection.hasPrefix("p:"), let pid = Int32(selection.dropFirst(2)) {
            return processes.first { $0.pid == pid }
        }
        guard selection.hasPrefix("g:") else { return nil }
        let groupID = String(selection.dropFirst(2))
        let members = processes.filter { ($0.applicationBundlePath ?? "pid:\($0.pid)") == groupID }
        return members.first(where: MemoryService.isApplicationMainProcess) ?? members.first
    }

    private func noteArrivals(_ processes: [ProcessMemoryInfo], now: Date = Date()) {
        let fresh = ProcessArrival.freshPIDs(previous: seenPIDs, current: processes.map(\.pid))
        seenPIDs = Set(processes.map(\.pid))
        let expiry = now.addingTimeInterval(4)
        for pid in fresh {
            freshUntil[pid] = expiry
        }
        freshUntil = freshUntil.filter { seenPIDs?.contains($0.key) == true && $0.value > now }
    }

    private func isFresh(_ pid: Int32) -> Bool {
        guard let until = freshUntil[pid] else { return false }
        return until > Date()
    }

    private func sortIdentifier(_ kind: ProcessListSort) -> String {
        switch kind {
        case .name: return "memory.sort.name"
        case .cpu: return "memory.sort.cpu"
        case .memory: return "memory.sort.memory"
        }
    }

    private func openDetail() {
        guard let selectedProcess else { return }
        detailLoading = true
        let peers = processes
        Task {
            let result = await Task.detached {
                ProcessInspectionService.inspect(selectedProcess, among: peers)
            }.value
            inspection = result
            detailLoading = false
        }
    }

    private func bringSelectionToFront() {
        guard let selectedProcess else { return }
        showingTopProcessHint = false
        if bringToFront(selectedProcess) {
            statusText = ""
        } else {
            statusText = L("memoryview.front.failed")
        }
    }

    private func bringToFront(_ process: ProcessMemoryInfo) -> Bool {
        if let direct = NSRunningApplication(processIdentifier: process.pid),
           direct.activationPolicy == .regular {
            return direct.activate(options: [.activateAllWindows])
        }
        guard let bundle = process.applicationBundlePath else { return false }
        guard let app = NSWorkspace.shared.runningApplications.first(where: { running in
            running.bundleURL?.standardizedFileURL.path == bundle && running.activationPolicy == .regular
        }) else { return false }
        return app.activate(options: [.activateAllWindows])
    }

    private func sampleSelection() {
        guard let selectedProcess else { return }
        sampling = true
        showingTopProcessHint = false
        statusText = L("memoryview.sample.running")
        let name = selectedProcess.displayName
        Task {
            do {
                let result = try await Task.detached {
                    try MemoryService.sample(pid: selectedProcess.pid, processName: selectedProcess.name)
                }.value
                sampleSheet = SampleSheet(name: name, result: result)
                statusText = ""
            } catch {
                statusText = error.localizedDescription
            }
            sampling = false
        }
    }

    private func pressureColor(_ level: MemoryPressureLevel) -> Color {
        switch level {
        case .healthy: return .green
        case .warning: return .orange
        case .critical: return .red
        case .unknown: return .secondary
        }
    }

    private func pressureIcon(_ level: MemoryPressureLevel) -> String {
        switch level {
        case .healthy: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .critical: return "xmark.octagon.fill"
        case .unknown: return "questionmark.circle"
        }
    }
}

private struct ProcessListEntry: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let stopped: Bool
    let fresh: Bool
    let cpuPercent: Double?
    let memoryBytes: UInt64
    let iconProcess: ProcessMemoryInfo?
    let group: ProcessAppGroup?
    let depth: Int
}

private struct ProcessMemoryRow: View {
    let title: String
    let subtitle: String
    let stopped: Bool
    let fresh: Bool
    let cpuPercent: Double?
    let memoryBytes: UInt64
    let physicalMemory: UInt64
    let icon: NSImage

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: icon)
                .resizable()
                .frame(width: 24, height: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(title)
                        .lineLimit(1)
                    if stopped {
                        badge(L("memoryview.frozen"), color: .orange)
                    }
                    if fresh {
                        badge(L("memoryview.new"), color: .blue)
                    }
                }
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            Text(cpuText)
                .font(.callout.monospacedDigit())
                .foregroundStyle(cpuPercent == nil ? Color.secondary : Color.primary)
                .frame(width: 72, alignment: .trailing)
            Text(MemoryService.formatBytes(memoryBytes))
                .font(.callout.monospacedDigit())
                .frame(width: 88, alignment: .trailing)
            Text(memoryShare)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 48, alignment: .trailing)
        }
        .opacity(stopped ? 0.72 : 1)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    private var cpuText: String {
        guard let cpuPercent else { return "" }
        return ProcessCPUAccounting.format(cpuPercent)
    }

    private var memoryShare: String {
        guard physicalMemory > 0 else { return "" }
        return String(format: "%.1f%%", Double(memoryBytes) / Double(physicalMemory) * 100)
    }

    private var accessibilityText: String {
        var spoken = subtitle.isEmpty ? title : "\(title)，\(subtitle)"
        if stopped {
            spoken += "，\(L("memoryview.frozen"))"
        }
        if fresh {
            spoken += "，\(L("memoryview.new"))"
        }
        if let cpuPercent {
            return L(
                "memoryview.row.accessibility.cpu",
                spoken,
                ProcessCPUAccounting.format(cpuPercent),
                MemoryService.formatBytes(memoryBytes)
            )
        }
        return L(
            "memoryview.row.accessibility",
            spoken,
            MemoryService.formatBytes(memoryBytes)
        )
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .foregroundStyle(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(color.opacity(0.15), in: Capsule())
    }
}

private struct SampleSheet: Identifiable {
    let id = UUID()
    let name: String
    let result: ProcessSampleResult
}

private struct ProcessDetailSheet: View {
    let inspection: ProcessInspection
    @SwiftUI.Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(inspection.displayName)
                    .font(.title3.weight(.semibold))
                Text("PID \(inspection.pid)")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                Button(L("common.cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    detailGrid
                    commandSection
                    signatureSection
                    portSection
                    fileSection
                }
            }
        }
        .padding(20)
        .frame(width: 640, height: 560)
    }

    private var detailGrid: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
            gridRow(L("memoryview.detail.user"), inspection.userName)
            gridRow(L("memoryview.detail.parent"), parentText)
            gridRow(L("memoryview.detail.started"), startText)
            gridRow(L("memoryview.detail.path"), inspection.executablePath)
        }
    }

    private var commandSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle(L("memoryview.detail.command"))
            Text(inspection.commandLine.isEmpty ? L("memoryview.detail.none") : inspection.commandLine)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack {
                CopyButton(text: inspection.commandLine)
                Button(L("memoryview.detail.reveal")) {
                    reveal(inspection.executablePath)
                }
                .disabled(!FileManager.default.fileExists(atPath: inspection.executablePath))
            }
        }
    }

    private var signatureSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle(L("memoryview.detail.signature"))
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                gridRow(L("memoryview.detail.signature"), signatureKind)
                gridRow(L("memoryview.detail.authority"), inspection.signature.authority ?? L("memoryview.detail.none"))
                gridRow(L("memoryview.detail.team"), inspection.signature.teamID ?? L("memoryview.detail.none"))
                gridRow(L("memoryview.detail.sandbox"), yesNo(inspection.signature.isSandboxed))
                gridRow(L("memoryview.detail.notarized"), yesNo(inspection.signature.hasNotarizationTicket))
            }
        }
    }

    private var portSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle(L("memoryview.detail.ports"))
            if inspection.listeningPorts.isEmpty {
                Text(L("memoryview.detail.none")).foregroundStyle(.secondary)
            } else {
                ForEach(inspection.listeningPorts) { port in
                    Text(port.display).font(.caption.monospaced()).textSelection(.enabled)
                }
            }
        }
    }

    private var fileSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle(L("memoryview.detail.files"))
            if inspection.openFiles.isEmpty {
                Text(L("memoryview.detail.none")).foregroundStyle(.secondary)
            } else {
                ForEach(inspection.openFiles) { file in
                    Text(file.path)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .lineLimit(2)
                }
                if inspection.omittedFileCount > 0 {
                    Text(L("memoryview.detail.files.more", inspection.omittedFileCount))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var parentText: String {
        guard inspection.parentPID > 1 else { return L("memoryview.detail.none") }
        if let parentName = inspection.parentName, !parentName.isEmpty {
            return "\(parentName) · PID \(inspection.parentPID)"
        }
        return "PID \(inspection.parentPID)"
    }

    private var startText: String {
        guard let startTime = inspection.startTime else { return L("memoryview.detail.none") }
        return Self.startFormatter.string(from: startTime)
    }

    private var signatureKind: String {
        switch inspection.signature.kind {
        case .apple: return L("memoryview.signature.apple")
        case .developerID: return L("memoryview.signature.developerID")
        case .adHoc: return L("memoryview.signature.adHoc")
        case .other: return L("memoryview.signature.other")
        case .unsigned: return L("memoryview.signature.unsigned")
        case .unavailable: return L("memoryview.signature.unavailable")
        }
    }

    private func yesNo(_ value: Bool?) -> String {
        guard let value else { return L("memoryview.detail.none") }
        return value ? L("memoryview.yes") : L("memoryview.no")
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title).font(.headline)
    }

    private func gridRow(_ title: String, _ value: String) -> some View {
        GridRow {
            Text(title).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled)
        }
        .font(.callout)
    }

    private func reveal(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    private static let startFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()
}

private struct ProcessSampleSheet: View {
    let name: String
    let result: ProcessSampleResult
    @SwiftUI.Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L("memoryview.sample.title"))
                    .font(.title3.weight(.semibold))
                Text(name)
                    .foregroundStyle(.secondary)
                Spacer()
                CopyButton(text: result.text)
                Button(L("common.cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            if result.truncated {
                Text(L("memoryview.sample.truncated"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ScrollView {
                Text(result.text)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(20)
        .frame(width: 760, height: 560)
    }
}

private struct PendingSignal: Identifiable {
    let process: ProcessMemoryInfo
    let signal: ProcessSignal
    var targets: [ProcessMemoryInfo] = []
    var id: String {
        let action: String
        switch signal {
        case .terminate: action = "term"
        case .kill: action = "kill"
        case .suspend: action = "stop"
        case .resume: action = "cont"
        }
        return "\(process.pid)-\(action)"
    }
}

/// AppKit 适配层：NSImage 不进入 Sendable core model，滚动时只读取内存缓存。
@MainActor
private final class ProcessIconProvider: ObservableObject {
    private var cache: [ProcessIconCacheKey: NSImage] = [:]
    private let maximumCachedIcons = 96
    private let iconSize = NSSize(width: 32, height: 32)

    func icon(for process: ProcessMemoryInfo) -> NSImage {
        let resolution = resolutionContext(for: process)
        if let cached = cache[resolution.key] {
            return cached
        }

        let source: NSImage
        if resolution.prefersHostBundleIcon,
           let bundlePath = resolution.key.bundlePath,
           FileManager.default.fileExists(atPath: bundlePath) {
            source = NSWorkspace.shared.icon(forFile: bundlePath)
        } else if let runningIcon = resolution.runningApplication?.icon {
            source = runningIcon
        } else if let bundlePath = resolution.key.bundlePath,
                  FileManager.default.fileExists(atPath: bundlePath) {
            source = NSWorkspace.shared.icon(forFile: bundlePath)
        } else {
            // 通用符号无需按数百个 PID 缓存。
            return semanticFallback(hasApplicationBundle: resolution.key.bundlePath != nil)
        }

        let image = downsizedIcon(source)
        if cache.count >= maximumCachedIcons, let oldest = cache.keys.first {
            cache.removeValue(forKey: oldest)
        }
        cache[resolution.key] = image
        return image
    }

    func retain(processes: [ProcessMemoryInfo]) {
        let validKeys = Set(processes.map { resolutionContext(for: $0).key })
        cache = cache.filter { validKeys.contains($0.key) }
    }

    private func resolutionContext(
        for process: ProcessMemoryInfo
    ) -> (
        key: ProcessIconCacheKey,
        runningApplication: NSRunningApplication?,
        prefersHostBundleIcon: Bool
    ) {
        let runningApplication = NSRunningApplication(processIdentifier: process.pid)
        let executableBundles = ProcessApplicationResolver.applicationBundlePaths(
            forExecutablePath: process.executablePath
        )
        let runningBundlePath = runningApplication?.bundleURL?.standardizedFileURL.path
        let runningHostPath = runningBundlePath.flatMap {
            ProcessApplicationResolver.applicationBundlePath(forExecutablePath: $0)
        }
        let bundlePath = executableBundles.first ?? runningHostPath ?? runningBundlePath
        let nestedExecutable = executableBundles.count > 1
        let nestedRunningBundle = runningBundlePath != nil && runningBundlePath != bundlePath
        return (
            ProcessIconCacheKey(pid: process.pid, bundlePath: bundlePath),
            runningApplication,
            nestedExecutable || nestedRunningBundle
        )
    }

    private func semanticFallback(hasApplicationBundle: Bool) -> NSImage {
        let symbol = hasApplicationBundle ? "app" : "terminal"
        return NSImage(
            systemSymbolName: symbol,
            accessibilityDescription: hasApplicationBundle
                ? L("memoryview.icon.app")
                : L("memoryview.icon.process")
        ) ?? NSImage(size: NSSize(width: 24, height: 24))
    }

    /// NSWorkspace / NSRunningApplication 可能返回含 1024px 表示的 App 图标。
    /// 列表只显示 24pt，因此缓存前栅格化为 32px，避免数百个进程占用数百 MB。
    private func downsizedIcon(_ source: NSImage) -> NSImage {
        let result = NSImage(size: iconSize)
        result.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        source.draw(
            in: NSRect(origin: .zero, size: iconSize),
            from: NSRect(origin: .zero, size: source.size),
            operation: .copy,
            fraction: 1
        )
        result.unlockFocus()
        result.isTemplate = source.isTemplate
        return result
    }
}
