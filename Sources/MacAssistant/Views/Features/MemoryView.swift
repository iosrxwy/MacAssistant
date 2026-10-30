import SwiftUI
import AppKit
import MacAssistantKit

struct MemoryView: View {
    @StateObject private var iconProvider = ProcessIconProvider()
    @State private var snapshot: MemorySnapshot?
    @State private var processes: [ProcessMemoryInfo] = []
    @State private var selectedPID: Int32?
    @State private var query = ""
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
        processes.first { $0.pid == selectedPID }
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
                .padding(14)

                Divider()

                List(selection: $selectedPID) {
                    ForEach(filteredProcesses) { process in
                        ProcessMemoryRow(
                            process: process,
                            physicalMemory: snapshot?.physical ?? 0,
                            icon: iconProvider.icon(for: process)
                        )
                            .tag(process.pid)
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
            apply(snapshot: result.0, processes: result.1)
        } catch {
            guard generation == loadGeneration, markBusy else { return }
            statusText = error.localizedDescription
        }
    }

    private func apply(snapshot newSnapshot: MemorySnapshot, processes newProcesses: [ProcessMemoryInfo]) {
        if snapshot != newSnapshot {
            snapshot = newSnapshot
        }
        if processes != newProcesses {
            iconProvider.retain(processes: newProcesses)
            processes = newProcesses
        }
        if let selectedPID, !processes.contains(where: { $0.pid == selectedPID }) {
            self.selectedPID = nil
        }
        applyTopProcessHint()
    }

    private func applyTopProcessHint() {
        guard showingTopProcessHint else { return }
        if let process = processes.first {
            selectedPID = process.pid
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

private struct ProcessMemoryRow: View {
    let process: ProcessMemoryInfo
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
                    Text(process.displayName)
                        .lineLimit(1)
                    if process.isStopped {
                        Text(L("memoryview.frozen"))
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.orange.opacity(0.15), in: Capsule())
                    }
                }
                Text(processRowSubtitle(process))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            Text(MemoryService.formatBytes(process.memoryBytes))
                .font(.callout.monospacedDigit())
            if physicalMemory > 0 {
                Text(String(format: "%.1f%%", Double(process.memoryBytes) / Double(physicalMemory) * 100))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 48, alignment: .trailing)
            }
        }
        .padding(.vertical, 3)
        .opacity(process.isStopped ? 0.72 : 1)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(L(
            "memoryview.row.accessibility",
            rowAccessibilityName(process),
            Int(process.pid),
            MemoryService.formatBytes(process.memoryBytes)
        ))
    }

    private func rowAccessibilityName(_ process: ProcessMemoryInfo) -> String {
        let spoken = process.remark.map { "\(process.displayName)，\($0)" } ?? process.displayName
        guard process.isStopped else { return spoken }
        return "\(spoken)，\(L("memoryview.frozen"))"
    }

    private func processRowSubtitle(_ process: ProcessMemoryInfo) -> String {
        let pid = "PID \(process.pid)"
        if let remark = process.remark, !remark.isEmpty {
            return "\(remark) · \(pid)"
        }
        if process.displayName.compare(process.name, options: [.caseInsensitive, .diacriticInsensitive]) != .orderedSame {
            return "\(process.name) · \(pid)"
        }
        return pid
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
