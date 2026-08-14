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
    @State private var statusText = ""
    @State private var pendingSignal: PendingSignal?
    @State private var showPurgeConfirmation = false
    @State private var developerOperationsExpanded = false

    private var filteredProcesses: [ProcessMemoryInfo] {
        guard !query.isEmpty else { return processes }
        return processes.filter {
            $0.name.localizedCaseInsensitiveContains(query)
                || String($0.pid).contains(query)
        }
    }

    private var selectedProcess: ProcessMemoryInfo? {
        processes.first { $0.pid == selectedPID }
    }

    private var totalRSS: UInt64 {
        filteredProcesses.reduce(0) { $0 + $1.rssBytes }
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
        }
        .toolbar {
            Button {
                refresh()
            } label: {
                Label(L("memoryview.refresh"), systemImage: "arrow.clockwise")
            }
            .keyboardShortcut("r", modifiers: [.command])
            .disabled(busy)
            .accessibilityIdentifier("memory.refresh")
        }
        .task { refresh() }
        .alert(item: $pendingSignal) { pending in
            let force = pending.signal == .kill
            return Alert(
                title: Text(force ? L("memoryview.alert.forceQuit") : L("memoryview.alert.quit")),
                message: Text(
                    L("memoryview.alert.process", pending.process.name, Int(pending.process.pid))
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

                    if let percent = snapshot.pressureFreePercent {
                        ProgressView(value: Double(100 - percent), total: 100)
                            .tint(pressureColor(snapshot.pressureLevel))
                            .accessibilityLabel(L("memoryview.pressure.accessibility"))
                            .accessibilityValue(L("memoryview.pressure.value", snapshot.pressureLevel.label, percent))
                    }
                }

                Text(L("memoryview.explanation"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                HStack {
                    Button {
                        selectedPID = processes.first?.pid
                        if let process = processes.first {
                            statusText = L(
                                "memoryview.topProcess",
                                process.name,
                                MemoryService.formatBytes(process.rssBytes)
                            )
                        }
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
                    Text(L("memoryview.processes.total", MemoryService.formatBytes(totalRSS)))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                    TextField(L("memoryview.search"), text: $query)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 220)
                        .accessibilityLabel(L("memoryview.search.accessibility"))
                        .accessibilityIdentifier("memory.search")
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
                    }
                }
                .listStyle(.inset)
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

    private func refresh() {
        guard !busy else { return }
        busy = true
        Task {
            do {
                let result = try await Task.detached {
                    (try MemoryService.snapshot(), try MemoryService.processes())
                }.value
                snapshot = result.0
                iconProvider.retain(processes: result.1)
                processes = result.1
                if let selectedPID, !processes.contains(where: { $0.pid == selectedPID }) {
                    self.selectedPID = nil
                }
            } catch {
                statusText = error.localizedDescription
            }
            busy = false
        }
    }

    private func send(_ signal: ProcessSignal, to process: ProcessMemoryInfo) {
        busy = true
        Task {
            do {
                try await Task.detached {
                    try MemoryService.send(signal, to: process)
                }.value
                statusText = L(
                    "memoryview.signalSent",
                    process.name,
                    Int(process.pid),
                    signal == .terminate ? "SIGTERM" : "SIGKILL"
                )
                try? await Task.sleep(nanoseconds: 600_000_000)
                busy = false
                refresh()
            } catch {
                busy = false
                statusText = error.localizedDescription
            }
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
                Text(process.name)
                    .lineLimit(1)
                Text("PID \(process.pid)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(MemoryService.formatBytes(process.rssBytes))
                .font(.callout.monospacedDigit())
            if physicalMemory > 0 {
                Text(String(format: "%.1f%%", Double(process.rssBytes) / Double(physicalMemory) * 100))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 48, alignment: .trailing)
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(L(
            "memoryview.row.accessibility",
            process.name,
            Int(process.pid),
            MemoryService.formatBytes(process.rssBytes)
        ))
    }
}

private struct PendingSignal: Identifiable {
    let process: ProcessMemoryInfo
    let signal: ProcessSignal
    var id: String { "\(process.pid)-\(signal == .terminate ? "term" : "kill")" }
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
