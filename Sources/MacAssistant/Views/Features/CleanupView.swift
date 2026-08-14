import SwiftUI
import AppKit
import MacAssistantKit

struct CleanupView: View {
    /// 共享模型：切换侧边栏页面后扫描结果、选择与进行中的任务全部保留。
    @ObservedObject private var model = CleanupViewModel.shared
    @State private var showCleanConfirmation = false
    @State private var showPermanentConfirmation = false

    var body: some View {
        FeatureScaffold(title: "系统清理", subtitle: "扫描用户级可再生数据；普通项目优先移入废纸篓") {
            summaryCard
            targetsCard

            if let summary = model.summary {
                CleanupSummaryView(summary: summary)
            }

            footnote
        } trailing: {
            Button {
                model.scan()
            } label: {
                Label(scanButtonTitle, systemImage: model.hasScanned ? "arrow.clockwise" : "magnifyingglass")
            }
            .disabled(!model.session.canScan)
            .keyboardShortcut("r", modifiers: [.command])
            .accessibilityHint("只扫描，不会删除文件")
            .glassActionButtonStyle()
        }
        .confirmationDialog("确认处理所选项目？", isPresented: $showCleanConfirmation, titleVisibility: .visible) {
            Button("继续") {
                if model.hasPermanentSelection {
                    showPermanentConfirmation = true
                } else {
                    model.clean(allowPermanentTrash: false)
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将按当前扫描结果执行，并在每项操作前重新检查路径、权限与文件身份。普通项目移入废纸篓。")
        }
        .confirmationDialog("永久清空废纸篓？", isPresented: $showPermanentConfirmation, titleVisibility: .visible) {
            Button("永久清空并处理其他所选项", role: .destructive) {
                model.clean(allowPermanentTrash: true)
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("废纸篓内容无法恢复。这是独立的永久操作确认。")
        }
        .task { model.scanIfNeeded() }
    }

    private var scanButtonTitle: String {
        if model.session.phase == .scanning { return "扫描中…" }
        return model.hasScanned ? "重新扫描" : "扫描占用"
    }

    // MARK: 概览与主操作

    private var summaryCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .center, spacing: 20) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("预计可释放")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(model.estimatedFreeText)
                            .font(.system(size: 34, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                        Text(model.selectionSummary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("cleanup.selectionSummary")
                    }

                    Spacer(minLength: 0)

                    VStack(alignment: .trailing, spacing: 8) {
                        Button(role: .destructive) {
                            showCleanConfirmation = true
                        } label: {
                            Label("清理所选", systemImage: "trash")
                                .frame(minWidth: 84)
                        }
                        .controlSize(.large)
                        .glassActionButtonStyle(prominent: model.session.canClean)
                        .disabled(!model.session.canClean)
                        // 不绑定 .defaultAction：回车会一路穿过确认框直接执行删除，
                        // 破坏性操作必须要求用户明确点击。
                        .accessibilityHint("先确认，再处理当前所选项目")

                        if model.session.isBusy {
                            Button("取消", role: .cancel) { model.cancel() }
                                .keyboardShortcut(.cancelAction)
                                .accessibilityHint("已完成的清理操作不会回滚")
                        }
                    }
                }

                if model.session.isBusy {
                    Divider()
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text(model.progressText)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(model.progressText)
                }
            }
        }
    }

    // MARK: 目标列表

    private var targetsCard: some View {
        Card(padding: 0) {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Text("扫描结果")
                        .font(.callout.weight(.semibold))
                    Spacer()
                    Button("清理记录") { model.revealHistory() }
                        .disabled(!model.hasHistory)
                    Button("全选") { model.selectAll() }
                        .disabled(model.session.isBusy)
                    Button("全不选") { model.selectNone() }
                        .disabled(model.session.isBusy)
                }
                .buttonStyle(.borderless)
                .font(.callout)
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 10)

                ForEach(model.groups) { group in
                    groupSection(group)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .accessibilityIdentifier("cleanup.targetList")
        }
    }

    @ViewBuilder
    private func groupSection(_ group: CleanupItemGroup) -> some View {
        Divider()

        HStack(spacing: 6) {
            Image(systemName: group.category.systemImage)
            Text(group.category.label)
            Spacer()
            if let total = group.totalText {
                Text(total).monospacedDigit()
            }
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 6)
        .accessibilityElement(children: .combine)

        ForEach(Array(group.items.enumerated()), id: \.element.id) { index, item in
            if index > 0, showsDivider(before: index, in: group) {
                Divider()
                    .padding(.leading, 52)
                    .padding(.trailing, 16)
            }
            CleanupRow(
                item: item,
                isSelected: model.selectionBinding(for: item.id),
                selectionEnabled: model.selectionEnabled(for: item),
                reveal: { model.reveal(item) },
                requestAccess: { model.requestFullDiskAccess() }
            )
        }
    }

    /// 相邻两行只要有一行被选中就不画分隔线，否则高亮块之间会夹出斑马纹。
    private func showsDivider(before index: Int, in group: CleanupItemGroup) -> Bool {
        let selected = model.session.selectedIDs
        return !selected.contains(group.items[index - 1].id)
            && !selected.contains(group.items[index].id)
    }

    private var footnote: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("普通项目逐项移入废纸篓，可在 Finder 中恢复。", systemImage: "arrow.uturn.backward")
            Label("废纸篓清空是永久操作，需要独立的二次确认。", systemImage: "exclamationmark.triangle")
            Label("Homebrew 等外部命令单独预览与执行，不与普通缓存混跑。", systemImage: "terminal")
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .padding(.top, 2)
    }
}

// MARK: - 行

private struct CleanupRow: View {
    let item: CleanupScanItem
    @Binding var isSelected: Bool
    let selectionEnabled: Bool
    let reveal: () -> Void
    let requestAccess: () -> Void

    @State private var isHovering = false

    var body: some View {
        Group {
            if let highlight {
                rowContent.insetSurfaceBackground(
                    RoundedRectangle(cornerRadius: 8, style: .continuous),
                    legacyFill: highlight.legacyFill,
                    glassFill: AnyShapeStyle(highlight.glassFill),
                    stroke: highlight.stroke
                )
            } else {
                rowContent
            }
        }
        // 高亮块左右各留 8pt，不贴卡片边缘；上下 2pt 让相邻选中行之间留出缝，不糊成一片。
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture {
            guard selectionEnabled else { return }
            isSelected.toggle()
        }
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovering)
    }

    private var rowContent: some View {
        HStack(spacing: 12) {
            Toggle(item.definition.name, isOn: $isSelected)
                .labelsHidden()
                .toggleStyle(.checkbox)
                .disabled(!selectionEnabled)
                .accessibilityLabel(Text(item.definition.name))
                .accessibilityValue(
                    Text(
                        "\(isSelected ? "已选择" : "未选择")，"
                        + "\(item.definition.risk.label)，\(statusText)"
                    )
                )
                .accessibilityHint(Text(item.definition.detail))

            Image(systemName: item.definition.systemImage)
                .font(.system(size: 15))
                .foregroundStyle(selectionEnabled ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
                .frame(width: 20)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    // 选中时靠字重再补一层提示，底色就可以压得很淡。
                    Text(item.definition.name)
                        .font(.callout.weight(isSelected ? .semibold : .medium))
                    CleanupRiskBadge(risk: item.definition.risk)
                }
                Text(item.definition.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .accessibilityHidden(true)

            Spacer(minLength: 12)

            if item.definition.action == .viewOnly {
                Button("在 Finder 中查看", action: reveal)
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .accessibilityLabel("在 Finder 中查看 \(item.definition.name)")
            }

            if case .permissionDenied = item.status {
                Button("去授权", action: requestAccess)
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .help(
                        "该目录受 macOS 保护，无法在 App 内直接申请。"
                        + "点击后会打开“系统设置 > 隐私与安全性 > 完全磁盘访问”，"
                        + "启用本 App 后切回来会自动重新扫描。"
                    )
                    .accessibilityLabel("为 \(item.definition.name) 前往系统设置授权")
            }

            statusColumn
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
    }

    /// 尺寸单独占一列并固定宽度，右侧数字才不会被「在 Finder 中查看」按钮挤歪。
    private var statusColumn: some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(sizeText)
                .font(.callout.monospacedDigit().weight(.medium))
                .foregroundStyle(hasSize ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
            if let note = statusNote {
                Text(note.text)
                    .font(.caption2)
                    .foregroundStyle(note.isWarning ? Color.orange : Color.secondary)
            }
        }
        .frame(width: 96, alignment: .trailing)
        .accessibilityHidden(true)
    }

    /// 选中与 hover 用同一套内缩圆角块，只在浓度上分层级；两者都用能随外观自适应的语义色。
    private struct RowHighlight {
        let legacyFill: Color
        let glassFill: Color
        let stroke: Color?
    }

    private var highlight: RowHighlight? {
        if isSelected {
            return RowHighlight(
                legacyFill: .primary.opacity(0.035),
                glassFill: .primary.opacity(0.055),
                stroke: .appAccent.opacity(0.22)
            )
        }
        if isHovering && selectionEnabled {
            return RowHighlight(
                legacyFill: .primary.opacity(0.05),
                glassFill: .primary.opacity(0.07),
                stroke: nil
            )
        }
        return nil
    }

    private var hasSize: Bool { item.status.measuredBytes != nil }

    private var sizeText: String {
        guard let bytes = item.status.measuredBytes else { return "—" }
        // ByteCountFormatter 对 0 会给出英文写法，中文界面直接换成「空」。
        return bytes == 0 ? "空" : FileSystemHelper.humanReadableSize(bytes)
    }

    private var statusNote: (text: String, isWarning: Bool)? {
        switch item.status {
        case .notScanned, .measured:
            return nil
        case .missing:
            return ("不存在", false)
        case .permissionDenied:
            return ("无权限", true)
        case .partial:
            return ("部分可读", true)
        case .excluded:
            return ("独立操作", false)
        case .cancelled:
            return ("已取消", true)
        }
    }

    /// 读屏用的完整状态描述，把分成两行显示的尺寸与备注重新合并。
    private var statusText: String {
        switch (sizeText, statusNote) {
        case let (size, .some(note)) where item.status.measuredBytes != nil:
            return "\(size)，\(note.text)"
        case let (_, .some(note)):
            return note.text
        case let (size, .none):
            return size
        }
    }
}

private struct CleanupRiskBadge: View {
    let risk: CleanupRisk

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .semibold))
            Text(risk.label)
                .font(.caption2)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        // 徽章嵌在卡片里，走内嵌层；玻璃背景更花，着色需要再重一点才读得出来。
        .insetSurfaceBackground(
            Capsule(),
            legacyFill: color.opacity(0.12),
            glassFill: AnyShapeStyle(color.opacity(0.22)),
            stroke: color.opacity(0.28)
        )
        .accessibilityHidden(true)
    }

    private var icon: String {
        switch risk {
        case .safe: return "checkmark.shield"
        case .caution: return "exclamationmark.triangle"
        case .permanent: return "trash.slash"
        case .viewOnly: return "eye"
        case .external: return "terminal"
        }
    }

    private var color: Color {
        switch risk {
        case .safe: return .green
        case .caution: return .orange
        case .permanent: return .red
        case .viewOnly: return .blue
        case .external: return .purple
        }
    }
}

// MARK: - 执行结果

private struct CleanupSummaryView: View {
    let summary: CleanupExecutionSummary

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label(summaryTitle, systemImage: summaryIcon)
                        .font(.headline)
                        .foregroundStyle(summary.failureCount > 0 ? .orange : .green)
                    Spacer()
                    Text("实际处理 \(FileSystemHelper.humanReadableSize(summary.processedBytes))")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 8) {
                    statChip("成功", summary.successCount, .green)
                    statChip("跳过", summary.skippedCount, .secondary)
                    statChip("失败 / 部分失败", summary.failureCount, summary.failureCount > 0 ? .orange : .secondary)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityIdentifier("cleanup.resultSummary")
                .accessibilityLabel(
                    "成功 \(summary.successCount) 项，跳过 \(summary.skippedCount) 项，"
                    + "失败/部分失败 \(summary.failureCount) 项；实际处理 "
                    + FileSystemHelper.humanReadableSize(summary.processedBytes)
                )

                ForEach(summary.results) { result in
                    DisclosureGroup("\(result.targetName)：\(outcomeLabel(result.outcome))") {
                        VStack(alignment: .leading, spacing: 3) {
                            if result.messages.isEmpty {
                                Text("无额外信息")
                            } else {
                                ForEach(Array(result.messages.enumerated()), id: \.offset) { _, message in
                                    Text(message)
                                }
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 4)
                    }
                    .font(.callout)
                }
            }
        }
    }

    private func statChip(_ title: String, _ count: Int, _ tint: Color) -> some View {
        HStack(spacing: 5) {
            Text(title)
                .foregroundStyle(.secondary)
            Text("\(count)")
                .monospacedDigit()
                .foregroundStyle(tint)
        }
        .font(.caption.weight(.medium))
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .insetSurfaceBackground(
            Capsule(),
            legacyFill: Color.primary.opacity(0.05)
        )
    }

    private var summaryTitle: String {
        if summary.cancelled { return "操作已取消，结果已保留" }
        if summary.failureCount > 0 { return "操作完成，但有项目未成功" }
        return "操作完成"
    }

    private var summaryIcon: String {
        summary.failureCount > 0 ? "exclamationmark.triangle.fill" : "checkmark.seal.fill"
    }

    private func outcomeLabel(_ outcome: CleanupItemOutcome) -> String {
        switch outcome {
        case .success: return "成功"
        case .partial: return "部分成功"
        case .skipped: return "已跳过"
        case .failed: return "失败"
        case .cancelled: return "已取消"
        }
    }
}

// MARK: - 分组

/// 按 `CleanupCategory` 归并后的展示单元。
struct CleanupItemGroup: Identifiable {
    let category: CleanupCategory
    let items: [CleanupScanItem]

    var id: String { category.rawValue }

    /// 组内已量出大小的合计；一项都没量出来时不显示，避免把「未扫描」说成 0。
    var totalText: String? {
        let measured = items.compactMap(\.status.measuredBytes)
        guard !measured.isEmpty else { return nil }
        let total = measured.reduce(0, +)
        return total == 0 ? "空" : FileSystemHelper.humanReadableSize(total)
    }
}

@MainActor
private final class CleanupViewModel: ObservableObject {
    /// 单例：页面切换不丢状态，后台任务持续运行。
    static let shared = CleanupViewModel()

    @Published private(set) var session: CleanupSessionState
    @Published private(set) var items: [CleanupScanItem]
    @Published private(set) var summary: CleanupExecutionSummary?
    @Published private(set) var progressText = ""

    private let definitions: [CleanupTargetDefinition]
    private let policy: CleanupPathPolicy
    private var report: CleanupScanReport?
    private var operation: Task<Void, Never>?
    private var activationObserver: NSObjectProtocol?

    init() {
        let definitions = CleanupService.definitions()
        self.definitions = definitions
        policy = CleanupService.makePolicy(definitions: definitions)
        let selectableIDs = Set(definitions.filter(\.isSelectable).map(\.id))
        session = CleanupSessionState(
            targetIDs: selectableIDs,
            defaultSelectedIDs: Set(
                definitions.filter { $0.isSelectable && $0.defaultSelected }.map(\.id)
            )
        )
        items = definitions.map {
            CleanupScanItem(definition: $0, status: .notScanned, validatedPaths: [])
        }
    }

    var groups: [CleanupItemGroup] {
        CleanupCategory.allCases.compactMap { category in
            let matched = items.filter { $0.definition.category == category }
            return matched.isEmpty ? nil : CleanupItemGroup(category: category, items: matched)
        }
    }

    var estimatedFreeText: String {
        let bytes = items
            .filter { session.selectedIDs.contains($0.id) }
            .compactMap(\.status.measuredBytes)
            .reduce(0, +)
        return bytes > 0 ? FileSystemHelper.humanReadableSize(bytes) : "—"
    }

    var selectionSummary: String {
        guard hasScanned else { return "尚未扫描" }
        let actionable = actionableSelectableIDs.count
        if session.selectedCount == 0 { return "未选择项目 · 共 \(actionable) 项可清理" }
        return "已选 \(session.selectedCount) 项 · 共 \(actionable) 项可清理"
    }

    var hasPermanentSelection: Bool {
        items.contains {
            session.selectedIDs.contains($0.id) && $0.definition.action == .emptyTrashPermanently
        }
    }

    var hasScanned: Bool { report != nil }
    var hasHistory: Bool { FileManager.default.fileExists(atPath: CleanupService.historyURL.path) }

    func selectionBinding(for id: String) -> Binding<Bool> {
        Binding(
            get: { self.session.selectedIDs.contains(id) },
            set: { self.session.setSelected(id, $0) }
        )
    }

    func selectionEnabled(for item: CleanupScanItem) -> Bool {
        item.definition.isSelectable && session.phase == .ready && item.status.isActionable
    }

    func selectAll() {
        if report != nil {
            session.replaceSelection(with: actionableSelectableIDs)
        } else {
            session.selectAll()
        }
    }

    func selectNone() {
        session.selectNone()
    }

    func reveal(_ item: CleanupScanItem) {
        if let path = item.definition.paths.first(where: {
            FileManager.default.fileExists(atPath: $0.path)
        }) {
            NSWorkspace.shared.activateFileViewerSelecting([path])
        }
    }

    func revealHistory() {
        guard hasHistory else { return }
        NSWorkspace.shared.activateFileViewerSelecting([CleanupService.historyURL])
    }

    /// 「完全磁盘访问」属于 TCC 权限，系统没有可编程的申请弹窗，
    /// 只能打开设置面板引导用户手动启用；用户切回 App 后自动重新扫描。
    func requestFullDiskAccess() {
        let candidates = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles",
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles"
        ]
        for value in candidates {
            if let url = URL(string: value), NSWorkspace.shared.open(url) { break }
        }
        armRescanOnActivation()
    }

    /// 等待用户从系统设置切回本 App，回来后重扫一次并解除监听。
    private func armRescanOnActivation() {
        guard activationObserver == nil else { return }
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                let model = CleanupViewModel.shared
                if let observer = model.activationObserver {
                    NotificationCenter.default.removeObserver(observer)
                    model.activationObserver = nil
                }
                if model.session.canScan {
                    model.scan()
                }
            }
        }
    }

    /// 页面出现时自动扫描一次；已有结果或正在运行则不重复。
    func scanIfNeeded() {
        guard session.phase == .idle else { return }
        scan()
    }

    func scan() {
        guard session.startScanning() else { return }
        progressText = "正在扫描允许范围内的文件…"
        items = definitions.map {
            CleanupScanItem(definition: $0, status: .notScanned, validatedPaths: [])
        }
        let definitions = self.definitions
        let policy = self.policy

        operation = Task { [weak self] in
            let report = await Self.scanOffMain(
                definitions: definitions,
                policy: policy,
                onProgress: Self.progressUpdater(verb: "扫描")
            )
            guard let self else { return }
            self.applyScanReport(report)
            self.progressText = report.cancelled ? "扫描已取消" : "扫描完成"
            self.operation = nil
        }
    }

    func clean(allowPermanentTrash: Bool) {
        guard let report, session.startCleaning() else { return }
        progressText = "正在逐项检查并处理所选内容…"
        summary = nil
        let selectedIDs = session.selectedIDs
        let policy = self.policy

        operation = Task { [weak self] in
            let summary = await Self.executeOffMain(
                report: report,
                selectedIDs: selectedIDs,
                policy: policy,
                allowPermanentTrash: allowPermanentTrash,
                onProgress: Self.progressUpdater(verb: "处理")
            )
            guard let self else { return }
            self.summary = summary
            _ = try? CleanupService.appendHistory(summary)
            self.objectWillChange.send()
            self.session.finishCleaning(cancelled: summary.cancelled || Task.isCancelled)
            self.progressText = summary.cancelled ? "清理已取消，正在重新扫描…" : "清理完成，正在重新扫描…"
            self.beginRequiredRescan()
        }
    }

    func cancel() {
        operation?.cancel()
    }

    private func applyScanReport(_ report: CleanupScanReport) {
        self.report = report
        items = report.items
        session.finishScanning(cancelled: report.cancelled || Task.isCancelled)
        // 扫描成功后收敛选择：不存在/无权限的项目勾着也清不了东西。
        if !report.cancelled {
            session.replaceSelection(
                with: session.selectedIDs.intersection(actionableSelectableIDs)
            )
        }
    }

    private var actionableSelectableIDs: Set<String> {
        Set(
            items
                .filter { $0.definition.isSelectable && $0.status.isActionable }
                .map(\.id)
        )
    }

    private func beginRequiredRescan() {
        guard session.startRequiredRescan() else {
            operation = nil
            return
        }
        let definitions = self.definitions
        let policy = self.policy
        operation = Task { [weak self] in
            let report = await Self.scanOffMain(
                definitions: definitions,
                policy: policy,
                onProgress: Self.progressUpdater(verb: "重新扫描")
            )
            guard let self else { return }
            self.applyScanReport(report)
            self.progressText = report.cancelled ? "重新扫描已取消" : "已按最新文件状态重新扫描"
            self.operation = nil
        }
    }

    /// 生成把逐项进度回传到主线程的回调（在后台线程被调用）。
    nonisolated private static func progressUpdater(
        verb: String
    ) -> @Sendable (CleanupProgress) -> Void {
        { event in
            Task { @MainActor in
                let model = CleanupViewModel.shared
                guard model.session.isBusy else { return }
                model.progressText = "正在\(verb) \(event.targetName)（\(event.index)/\(event.total)）…"
            }
        }
    }

    nonisolated private static func scanOffMain(
        definitions: [CleanupTargetDefinition],
        policy: CleanupPathPolicy,
        onProgress: @escaping @Sendable (CleanupProgress) -> Void
    ) async -> CleanupScanReport {
        let worker = Task.detached(priority: .userInitiated) {
            CleanupService.scan(
                definitions: definitions,
                policy: policy,
                cancellation: { Task.isCancelled },
                progress: onProgress
            )
        }
        return await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    nonisolated private static func executeOffMain(
        report: CleanupScanReport,
        selectedIDs: Set<String>,
        policy: CleanupPathPolicy,
        allowPermanentTrash: Bool,
        onProgress: @escaping @Sendable (CleanupProgress) -> Void
    ) async -> CleanupExecutionSummary {
        let worker = Task.detached(priority: .userInitiated) {
            CleanupService.execute(
                report: report,
                selectedIDs: selectedIDs,
                policy: policy,
                allowPermanentTrash: allowPermanentTrash,
                cancellation: { Task.isCancelled },
                progress: onProgress
            )
        }
        return await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            worker.cancel()
        }
    }
}
