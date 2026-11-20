import SwiftUI
import AppKit
import MacAssistantKit

struct CleanupView: View {
    /// 共享模型：切换侧边栏页面后扫描结果、选择与进行中的任务全部保留。
    @ObservedObject private var model = CleanupViewModel.shared
    @State private var showCleanConfirmation = false
    @State private var showPermanentConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            pinnedChrome
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if model.showsPermissionBanner {
                        permissionBanner
                    }

                    if let summary = model.summary {
                        CleanupSummaryView(summary: summary)
                    }

                    targetsCard

                    CleanupStandaloneActionsView(model: model)

                    footnote
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .softScrollEdgeEffect()
            .defaultScrollAnchorTopIfAvailable()
        }
        .featureSurfaceBackground()
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
        if model.session.phase == .scanning { return L("cleanupview.scanning") }
        return model.hasScanned ? L("cleanupview.rescan") : L("cleanupview.scan")
    }

    // MARK: 固定页头

    private var pinnedChrome: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(SidebarItem.cleanup.title).font(.largeTitle.bold())
                        Text(L("cleanupview.subtitle"))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 16)
                    headerActions
                }
                selectionBar
                if model.session.isBusy {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text(model.progressText)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                        Button(L("common.cancel"), role: .cancel) { model.cancel() }
                            .keyboardShortcut(.cancelAction)
                            .accessibilityHint("已完成的清理操作不会回滚")
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(model.progressText)
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 24)
            .padding(.bottom, 12)
            Divider().opacity(0.45)
        }
    }

    private var headerActions: some View {
        HStack(spacing: 8) {
            scanButton
            cleanButton
        }
        .labelStyle(.titleAndIcon)
    }

    private var scanButton: some View {
        Button {
            model.scan()
        } label: {
            Label(scanButtonTitle, systemImage: model.hasScanned ? "arrow.clockwise" : "magnifyingglass")
        }
        .disabled(!model.session.canScan)
        .keyboardShortcut("r", modifiers: [.command])
        .help(L("cleanupview.scan.help"))
        .accessibilityHint("只扫描，不会删除文件")
        .accessibilityIdentifier("cleanup.scan")
        .glassActionButtonStyle()
    }

    private var cleanButton: some View {
        Button(role: .destructive) {
            showCleanConfirmation = true
        } label: {
            Label(L("cleanupview.clean"), systemImage: "trash")
        }
        .disabled(!model.session.canClean)
        .help(L("cleanupview.clean.help"))
        .accessibilityHint("先确认，再处理当前所选项目")
        .accessibilityIdentifier("cleanup.clean")
        .glassActionButtonStyle(prominent: model.session.canClean)
    }

    private var selectionBar: some View {
        Card {
            HStack(alignment: .center, spacing: 14) {
                Button {
                    model.toggleSelectSafe()
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: selectSafeSymbol)
                            .font(.title2)
                            .foregroundStyle(Color.appAccent)
                            .symbolRenderingMode(.hierarchical)
                            .frame(width: 28)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(selectSafeTitle)
                                .font(.callout.weight(.semibold))
                            Text(L("cleanupview.selectSafe.caption"))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(model.session.isBusy || model.safeSelectableIDs.isEmpty)
                .accessibilityIdentifier("cleanup.selectSafe")
                .accessibilityLabel(selectSafeTitle)
                .accessibilityValue(selectSafeAccessibilityValue)
                .accessibilityHint(L("cleanupview.selectSafe.caption"))

                Spacer(minLength: 12)

                VStack(alignment: .trailing, spacing: 2) {
                    Text(L("cleanupview.estimated"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(model.estimatedFreeText)
                        .font(.title2.weight(.semibold).monospacedDigit())
                        .accessibilityIdentifier("cleanup.estimatedFree")
                    Text(model.headerSelectionSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("cleanup.selectionSummary")
                }

                Divider()
                    .frame(height: 36)

                VStack(alignment: .trailing, spacing: 6) {
                    Button(L("cleanupview.selectVisible")) { model.selectAll() }
                        .disabled(model.session.isBusy)
                        .help(L("cleanupview.selectVisible.help"))
                        .accessibilityIdentifier("cleanup.selectVisible")
                    Button(L("cleanupview.deselectAll")) { model.selectNone() }
                        .disabled(model.session.isBusy || model.session.selectedCount == 0)
                        .accessibilityIdentifier("cleanup.selectNone")
                }
                .buttonStyle(.borderless)
                .font(.callout)
            }
        }
    }

    private var selectSafeTitle: String {
        model.safeSelectionState == .all
            ? L("cleanupview.deselectAll")
            : L("cleanupview.selectSafe")
    }

    private var selectSafeSymbol: String {
        switch model.safeSelectionState {
        case .empty: return "square"
        case .mixed: return "minus.square.fill"
        case .all: return "checkmark.square.fill"
        }
    }

    private var selectSafeAccessibilityValue: String {
        switch model.safeSelectionState {
        case .empty: return L("cleanupview.selectSafe.value.off")
        case .mixed: return L("cleanupview.selectSafe.value.mixed")
        case .all: return L("cleanupview.selectSafe.value.on")
        }
    }

    private var permissionBanner: some View {
        Card {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "lock.trianglebadge.exclamationmark")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 6) {
                    Text("没有读取权限，不是空目录")
                        .font(.callout.weight(.semibold))
                    Text(model.fullDiskAccessSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("macOS 挡住了部分用户目录。未授权时不会显示成 0 B 或「空」。打开「完全磁盘访问」后，Finder 会露出本 App，勾选后回来会自动重新扫描。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("打开完全磁盘访问") {
                        model.requestFullDiskAccess()
                    }
                    .buttonStyle(.borderless)
                }
                Spacer(minLength: 0)
            }
        }
    }

    // MARK: 目标列表

    private var targetsCard: some View {
        Card(padding: 0) {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Text(L("cleanupview.results"))
                        .font(.headline)
                    Spacer()
                    Button(L("cleanupview.history")) { model.revealHistory() }
                        .disabled(!model.hasHistory)
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
        let expanded = model.isGroupExpanded(group)
        Divider()
        CleanupGroupHeader(
            group: group,
            expanded: expanded,
            selectionState: model.groupSelectionState(for: group),
            selectableCount: model.selectableIDs(in: group).count,
            selectedCount: model.selectedCount(in: group),
            isBusy: model.session.isBusy,
            toggleExpanded: { model.toggleGroupExpanded(group) },
            toggleSelection: { model.toggleGroupSelection(group) }
        )
        if expanded {
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
                    requestAccess: { model.requestFullDiskAccess() },
                    runExternal: model.externalRunner(for: item),
                    externalEnabled: model.canRunStandalone
                )
            }
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
            Label("「系统数据」只列访达会算进这一栏的用户目录，不扫系统分区，也不 sudo。", systemImage: "internaldrive.fill")
            Label("Homebrew、模拟器 runtime、Docker 与 Time Machine 快照单独预览与执行，不与普通缓存混跑。", systemImage: "terminal")
            if model.fullDiskAccess == .granted {
                Label("已授予完全磁盘访问。", systemImage: "checkmark.shield")
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .padding(.top, 2)
    }
}

// MARK: - 分组标题

/// 每组独立折叠。不用嵌套 Button，避免 macOS 上只有文字能点中。
private struct CleanupGroupHeader: View {
    let group: CleanupItemGroup
    let expanded: Bool
    let selectionState: CleanupBulkSelectionState
    let selectableCount: Int
    let selectedCount: Int
    let isBusy: Bool
    let toggleExpanded: () -> Void
    let toggleSelection: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Color.appAccent)
                    .frame(width: 22, height: 22)
                    .insetSurfaceBackground(
                        RoundedRectangle(cornerRadius: 6, style: .continuous),
                        legacyFill: Color.appAccent.opacity(isHovering ? 0.16 : 0.10),
                        glassFill: AnyShapeStyle(Color.appAccent.opacity(isHovering ? 0.22 : 0.14))
                    )
                Image(systemName: group.category.systemImage)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                Text(group.category.label)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Text("\(group.items.count)")
                    .font(.caption.monospacedDigit().weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .insetSurfaceBackground(
                        Capsule(),
                        legacyFill: Color.primary.opacity(0.06)
                    )
                if selectedCount > 0 {
                    Text(L("cleanupview.group.selected", selectedCount))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if let total = group.totalText {
                    Text(total)
                        .font(.callout.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.primary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture(perform: toggleExpanded)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityIdentifier("cleanup.group.\(group.id).toggle")
            .accessibilityLabel(
                expanded
                    ? L("cleanupview.group.collapse", group.category.label)
                    : L("cleanupview.group.expand", group.category.label)
            )
            if selectableCount > 0 {
                Button(action: toggleSelection) {
                    HStack(spacing: 5) {
                        Image(systemName: selectSymbol)
                            .font(.body)
                            .foregroundStyle(Color.appAccent)
                            .symbolRenderingMode(.hierarchical)
                        Text(
                            selectionState == .all
                                ? L("cleanupview.group.deselect")
                                : L("cleanupview.group.select")
                        )
                        .font(.caption.weight(.semibold))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .insetSurfaceBackground(
                        Capsule(),
                        legacyFill: Color.appAccent.opacity(0.08),
                        glassFill: AnyShapeStyle(Color.appAccent.opacity(0.14))
                    )
                }
                .buttonStyle(.plain)
                .disabled(isBusy)
                .help(L("cleanupview.group.select.help"))
                .accessibilityIdentifier("cleanup.group.\(group.id).select")
                .accessibilityLabel(
                    selectionState == .all
                        ? L("cleanupview.group.deselect")
                        : L("cleanupview.group.select")
                )
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .insetSurfaceBackground(
            Rectangle(),
            legacyFill: Color.primary.opacity(isHovering ? 0.055 : 0.035),
            glassFill: AnyShapeStyle(Color.primary.opacity(isHovering ? 0.07 : 0.04))
        )
    }

    private var selectSymbol: String {
        switch selectionState {
        case .empty: return "square"
        case .mixed: return "minus.square.fill"
        case .all: return "checkmark.square.fill"
        }
    }
}

// MARK: - 行

private struct CleanupRow: View {
    let item: CleanupScanItem
    @Binding var isSelected: Bool
    let selectionEnabled: Bool
    let reveal: () -> Void
    let requestAccess: () -> Void
    var runExternal: (() -> Void)? = nil
    var externalEnabled: Bool = false

    @State private var isHovering = false
    @State private var confirmExternal = false
    @State private var isExpanded = false
    @State private var breakdown: [CleanupBreakdownEntry]?

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
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Toggle(item.definition.name, isOn: $isSelected)
                    .labelsHidden()
                    .toggleStyle(.checkbox)
                    .controlSize(.large)
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
                    .font(.system(size: 16))
                    .foregroundStyle(selectionEnabled ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
                    .frame(width: 22)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        // 选中时靠字重再补一层提示，底色就可以压得很淡。
                        Text(item.definition.name)
                            .font(.body.weight(isSelected ? .semibold : .medium))
                            .lineLimit(1)
                        if item.definition.risk != .safe {
                            CleanupRiskBadge(risk: item.definition.risk)
                        }
                    }
                    Text(item.definition.detail)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .accessibilityHidden(true)

                Spacer(minLength: 12)

                if canExpand {
                    Button {
                        isExpanded.toggle()
                    } label: {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(isExpanded ? "收起详情" : "展开详情")
                }

                if item.definition.action == .viewOnly {
                    Button("在 Finder 中查看", action: reveal)
                        .buttonStyle(.borderless)
                        .font(.caption)
                        .accessibilityLabel("在 Finder 中查看 \(item.definition.name)")
                }

                if let runExternal {
                    Button(L("cleanupview.external.run")) { confirmExternal = true }
                        .buttonStyle(.borderless)
                        .font(.caption)
                        .disabled(!externalEnabled)
                        .accessibilityLabel(L("cleanupview.external.run.accessibility", item.definition.name))
                        .confirmationDialog(
                            L("cleanupview.external.confirm.title", item.definition.name),
                            isPresented: $confirmExternal,
                            titleVisibility: .visible
                        ) {
                            Button(L("cleanupview.external.run"), role: .destructive, action: runExternal)
                            Button(L("common.cancel"), role: .cancel) {}
                        } message: {
                            Text(CleanupExternalTool(targetID: item.id)?.commandPreview ?? item.definition.detail)
                        }
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
            .padding(.vertical, 9)

            if isExpanded {
                expandedDetails
                    .padding(.leading, 52)
                    .padding(.trailing, 16)
                    .padding(.bottom, 10)
                    .task(id: item.id) {
                        let scanItem = item
                        breakdown = await Task.detached(priority: .utility) {
                            CleanupService.largestChildren(of: scanItem)
                        }.value
                    }
            }
        }
    }

    private var canExpand: Bool {
        item.status.isActionable || item.definition.safetyDetails != nil
    }

    @ViewBuilder
    private var expandedDetails: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let safety = item.definition.safetyDetails {
                Text("会去掉：\(safety.removes)")
                Text("会留下：\(safety.keeps)")
                Text(safety.note)
                    .foregroundStyle(.tertiary)
            }
            if let breakdown {
                if breakdown.isEmpty {
                    Text("没有可展示的子项")
                        .foregroundStyle(.tertiary)
                } else {
                    ForEach(breakdown) { entry in
                        HStack {
                            Text(entry.name)
                                .lineLimit(1)
                            Spacer()
                            Text(FileSystemHelper.humanReadableSize(entry.bytes))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } else if item.status.isActionable {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("正在量最大的几个子项…")
                }
                .foregroundStyle(.secondary)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    /// 尺寸单独占一列并固定宽度，右侧数字才不会被「在 Finder 中查看」按钮挤歪。
    private var statusColumn: some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(sizeText)
                .font(.body.monospacedDigit().weight(.semibold))
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

/// 页头全选与分组全选共用的三态。
enum CleanupBulkSelectionState: Equatable {
    case empty
    case mixed
    case all
}

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
    @Published private(set) var fullDiskAccess: CleanupFullDiskAccessStatus = .unknown
    @Published private(set) var standaloneLog = ""
    @Published private(set) var standaloneOK: Bool?
    @Published private(set) var standaloneRunning = false
    /// 外部工具是否在 PATH 里。渲染期只读这份快照，绝不现场 `which`。
    @Published private(set) var availableExternalToolIDs: Set<String>
    /// 已折叠的分组。切页仍保留；写入 UserDefaults 以便下次启动还在。
    @Published private(set) var collapsedCategoryIDs: Set<String>

    private let seedDefinitions: [CleanupTargetDefinition]
    private var activePolicy: CleanupPathPolicy
    private var report: CleanupScanReport?
    private var operation: Task<Void, Never>?
    private var activationObserver: NSObjectProtocol?

    init() {
        let definitions = CleanupService.definitions()
        self.seedDefinitions = definitions
        activePolicy = CleanupService.makePolicy(definitions: definitions)
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
        // Homebrew / 模拟器不查 PATH，可先露出按钮；其余等后台探测。
        availableExternalToolIDs = Set(
            CleanupExternalTool.allCases.compactMap { tool in
                switch tool {
                case .homebrew, .simulatorRuntimes: return tool.targetID
                default: return nil
                }
            }
        )
        collapsedCategoryIDs = Set(
            UserDefaults.standard.stringArray(forKey: Self.collapsedDefaultsKey) ?? []
        )
        Task { await self.probeExternalTools() }
    }

    private static let collapsedDefaultsKey = "cleanup.collapsedCategories"

    func isGroupExpanded(_ group: CleanupItemGroup) -> Bool {
        !collapsedCategoryIDs.contains(group.id)
    }

    func toggleGroupExpanded(_ group: CleanupItemGroup) {
        if collapsedCategoryIDs.contains(group.id) {
            collapsedCategoryIDs.remove(group.id)
        } else {
            collapsedCategoryIDs.insert(group.id)
        }
        UserDefaults.standard.set(
            Array(collapsedCategoryIDs).sorted(),
            forKey: Self.collapsedDefaultsKey
        )
    }

    func selectableIDs(in group: CleanupItemGroup) -> Set<String> {
        Set(
            group.items
                .filter {
                    $0.definition.isSelectable
                        && (report == nil || $0.status.isActionable)
                }
                .map(\.id)
        )
    }

    func selectedCount(in group: CleanupItemGroup) -> Int {
        session.selectedIDs.intersection(Set(group.items.map(\.id))).count
    }

    func groupSelectionState(for group: CleanupItemGroup) -> CleanupBulkSelectionState {
        let ids = selectableIDs(in: group)
        guard !ids.isEmpty else { return .empty }
        let selected = session.selectedIDs.intersection(ids)
        if selected.isEmpty { return .empty }
        if selected == ids { return .all }
        return .mixed
    }

    func toggleGroupSelection(_ group: CleanupItemGroup) {
        let ids = selectableIDs(in: group)
        guard !ids.isEmpty else { return }
        if session.selectedIDs.intersection(ids) == ids {
            session.replaceSelection(with: session.selectedIDs.subtracting(ids))
        } else {
            session.replaceSelection(with: session.selectedIDs.union(ids))
        }
    }

    /// 行上的「单独执行」。只认已探测到的工具，避免 ForEach 渲染时跑 `which`。
    func externalRunner(for item: CleanupScanItem) -> (() -> Void)? {
        guard let tool = CleanupExternalTool(targetID: item.id),
              availableExternalToolIDs.contains(tool.targetID)
        else {
            return nil
        }
        return { self.runStandalone { try tool.run() } }
    }

    private func probeExternalTools() async {
        let ids = await Task.detached(priority: .utility) {
            Set(CleanupExternalTool.allCases.filter(\.isAvailable).map(\.rawValue))
        }.value
        availableExternalToolIDs = ids
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

    var selectionSummary: String { headerSelectionSummary }

    var headerSelectionSummary: String {
        guard hasScanned else { return L("cleanupview.notScanned") }
        let actionable = actionableSelectableIDs.count
        if session.selectedCount == 0 {
            return L("cleanupview.selection.none", actionable)
        }
        return L(
            "cleanupview.selection.summary",
            session.selectedCount,
            estimatedFreeText,
            actionable
        )
    }

    var safeSelectableIDs: Set<String> {
        Set(
            items
                .filter {
                    $0.definition.risk == .safe
                        && $0.definition.isSelectable
                        && (report == nil || $0.status.isActionable)
                }
                .map(\.id)
        )
    }

    var safeSelectionState: CleanupBulkSelectionState {
        let safe = safeSelectableIDs
        guard !safe.isEmpty else { return .empty }
        let selectedSafe = session.selectedIDs.intersection(safe)
        if selectedSafe.isEmpty { return .empty }
        if selectedSafe == safe { return .all }
        return .mixed
    }

    func toggleSelectSafe() {
        if safeSelectionState == .all {
            selectNone()
        } else {
            selectSafe()
        }
    }

    var hasPermanentSelection: Bool {
        items.contains {
            session.selectedIDs.contains($0.id) && $0.definition.action == .emptyTrashPermanently
        }
    }

    var hasScanned: Bool { report != nil }
    var hasHistory: Bool { FileManager.default.fileExists(atPath: CleanupService.historyURL.path) }
    var hasPermissionDeniedItems: Bool {
        items.contains {
            if case .permissionDenied = $0.status { return true }
            return false
        }
    }

    var showsPermissionBanner: Bool {
        hasPermissionDeniedItems || fullDiskAccess == .denied
    }

    var fullDiskAccessSummary: String {
        switch fullDiskAccess {
        case .granted:
            return "完全磁盘访问：已授予"
        case .denied:
            return "完全磁盘访问：未授予。容器缓存不会显示成空目录。"
        case .unknown:
            return "完全磁盘访问：未能确认。未授权时不会把受保护目录显示成空。"
        }
    }

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

    func selectSafe() {
        let ids = Set(
            items
                .filter {
                    $0.definition.risk == .safe
                        && $0.definition.isSelectable
                        && (report == nil || $0.status.isActionable)
                }
                .map(\.id)
        )
        session.selectSafe(ids)
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
        let appURL = Bundle.main.bundleURL
        if FileManager.default.fileExists(atPath: appURL.path) {
            NSWorkspace.shared.activateFileViewerSelecting([appURL])
        }
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
        items = seedDefinitions.map {
            CleanupScanItem(definition: $0, status: .notScanned, validatedPaths: [])
        }
        let seedDefinitions = self.seedDefinitions

        operation = Task { [weak self] in
            let (plan, report) = await Self.scanOffMain(
                seedDefinitions: seedDefinitions,
                onProgress: Self.progressUpdater(verb: "扫描")
            )
            guard let self else { return }
            self.applyScanReport(report, plan: plan)
            self.progressText = report.cancelled ? "扫描已取消" : "扫描完成"
            self.operation = nil
        }
    }

    func clean(allowPermanentTrash: Bool) {
        guard let report, session.startCleaning() else { return }
        progressText = "正在逐项检查并处理所选内容…"
        summary = nil
        let selectedIDs = session.selectedIDs
        let policy = self.activePolicy

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

    var canRunStandalone: Bool { !standaloneRunning && !session.isBusy }

    func resetStandaloneLog() {
        standaloneLog = ""
        standaloneOK = nil
    }

    func runStandalone(_ work: @escaping @Sendable () throws -> CommandResult) {
        guard canRunStandalone else { return }
        standaloneRunning = true
        standaloneOK = nil
        Task {
            do {
                let r = try await Task.detached(priority: .userInitiated) { try work() }.value
                var text = r.combinedOutput.trimmingCharacters(in: .whitespacesAndNewlines)
                if text.isEmpty {
                    text = r.succeeded
                        ? L("cleanupview.doneNoOutput")
                        : L("cleanupview.exitCode", Int(r.exitCode))
                }
                if !r.succeeded {
                    throw NSError(
                        domain: "Cleanup",
                        code: Int(r.exitCode),
                        userInfo: [NSLocalizedDescriptionKey: text]
                    )
                }
                standaloneLog = text
                standaloneOK = true
            } catch {
                standaloneLog = error.localizedDescription
                standaloneOK = false
            }
            standaloneRunning = false
        }
    }

    private func applyScanReport(_ report: CleanupScanReport, plan: CleanupScanPlan) {
        self.report = report
        items = report.items
        activePolicy = plan.policy
        fullDiskAccess = plan.fullDiskAccess
        session.finishScanning(cancelled: report.cancelled || Task.isCancelled)
        session.updateKnownTargets(Set(report.items.filter(\.definition.isSelectable).map(\.id)))
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
        let seedDefinitions = self.seedDefinitions
        operation = Task { [weak self] in
            let (plan, report) = await Self.scanOffMain(
                seedDefinitions: seedDefinitions,
                onProgress: Self.progressUpdater(verb: "重新扫描")
            )
            guard let self else { return }
            self.applyScanReport(report, plan: plan)
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
        seedDefinitions: [CleanupTargetDefinition],
        onProgress: @escaping @Sendable (CleanupProgress) -> Void
    ) async -> (CleanupScanPlan, CleanupScanReport) {
        let worker = Task.detached(priority: .userInitiated) {
            let plan = CleanupService.makeScanPlan(seedDefinitions: seedDefinitions)
            let report = CleanupService.scan(
                plan: plan,
                cancellation: { Task.isCancelled },
                progress: onProgress
            )
            return (plan, report)
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

// MARK: - Docker / Time Machine（不走废纸篓）

private struct CleanupStandaloneActionsView: View {
    @ObservedObject var model: CleanupViewModel
    @State private var snapshots: [SnapshotEntry] = []
    @State private var snapshotQuerying = false
    @State private var confirmDocker = false
    @State private var confirmThin = false
    @State private var confirmHomebrew = false
    @State private var confirmSimulator = false
    @State private var dockerReclaimable: String?
    @State private var simulatorListing = CleanupSimulatorListing.empty

    private var snapshotRetention: SnapshotRetentionPlan {
        RepairService.retentionPlan(for: snapshots)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(L("cleanupview.standalone.title"))
                    .font(.title3.bold())
                    .foregroundStyle(.tint)
                Text(L("cleanupview.standalone.detail"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 6)

            homebrewCard
            simulatorCard
            dockerCard
            snapshotsCard

            if !model.standaloneLog.isEmpty || model.standaloneRunning {
                Card {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Label(L("cleanupview.console"), systemImage: "terminal")
                                .font(.callout.weight(.semibold))
                            if model.standaloneRunning { ProgressView().controlSize(.small) }
                            Spacer()
                            StatusBadge(ok: model.standaloneOK)
                            if !model.standaloneLog.isEmpty {
                                Button { model.resetStandaloneLog() } label: { Image(systemName: "trash") }
                                    .buttonStyle(.borderless)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        ConsoleView(text: model.standaloneLog, minHeight: 72)
                    }
                }
            }
        }
        .task {
            let listing = await Task.detached(priority: .utility) {
                CleanupSimulatorListing.load()
            }.value
            simulatorListing = listing
            let bytes = await Task.detached(priority: .utility) {
                RepairService.queryDockerReclaimable()
            }.value
            if let bytes, bytes > 0 {
                dockerReclaimable = FileSystemHelper.humanReadableSize(bytes)
            }
        }
    }

    private var homebrewCard: some View {
        standaloneCommandCard(
            title: L("cleanupview.homebrew.title"),
            detail: L("cleanupview.homebrew.detail"),
            risk: .caution,
            command: CleanupExternalTool.homebrew.commandPreview,
            actionTitle: L("cleanupview.homebrew.action"),
            confirming: $confirmHomebrew,
            confirmTitle: L("cleanupview.homebrew.confirm.title")
        ) {
            model.runStandalone { try CleanupExternalTool.homebrew.run() }
        }
    }

    private var simulatorCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(L("cleanupview.simulator.title")).font(.callout.weight(.semibold))
                    RiskBadge(risk: .caution)
                    Spacer()
                    Button { confirmSimulator = true } label: {
                        Label(L("cleanupview.simulator.action"), systemImage: "play.fill")
                    }
                    .disabled(!model.canRunStandalone)
                    .confirmationDialog(
                        L("cleanupview.simulator.confirm.title"),
                        isPresented: $confirmSimulator,
                        titleVisibility: .visible
                    ) {
                        Button(L("cleanupview.simulator.action"), role: .destructive) {
                            model.runStandalone { try CleanupExternalTool.simulatorRuntimes.run() }
                        }
                        Button(L("common.cancel"), role: .cancel) {}
                    } message: {
                        Text(L("cleanupview.simulator.detail"))
                    }
                }
                Text(L("cleanupview.simulator.detail"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if simulatorListing.unavailableRuntimeCount > 0 || !simulatorListing.unavailableDeviceNames.isEmpty {
                    Text(
                        L(
                            "cleanupview.simulator.inventory",
                            simulatorListing.unavailableRuntimeCount,
                            simulatorListing.unavailableDeviceNames.count
                        )
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    if !simulatorListing.unavailableDeviceNames.isEmpty {
                        Text(simulatorListing.unavailableDeviceNames.prefix(5).joined(separator: " · "))
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .lineLimit(2)
                    }
                }
                commandPreview(CleanupExternalTool.simulatorRuntimes.commandPreview)
            }
        }
    }

    private func standaloneCommandCard(
        title: String,
        detail: String,
        risk: RiskLevel,
        command: String,
        actionTitle: String,
        confirming: Binding<Bool>,
        confirmTitle: String,
        run: @escaping () -> Void
    ) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(title).font(.callout.weight(.semibold))
                    RiskBadge(risk: risk)
                    Spacer()
                    Button { confirming.wrappedValue = true } label: {
                        Label(actionTitle, systemImage: "play.fill")
                    }
                    .disabled(!model.canRunStandalone)
                    .confirmationDialog(confirmTitle, isPresented: confirming, titleVisibility: .visible) {
                        Button(actionTitle, role: .destructive, action: run)
                        Button(L("common.cancel"), role: .cancel) {}
                    } message: {
                        Text(detail)
                    }
                }
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                commandPreview(command)
            }
        }
    }

    private var dockerCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(L("cleanupview.docker.title")).font(.callout.weight(.semibold))
                    RiskBadge(risk: .danger)
                    Spacer()
                    Button(role: .destructive) { confirmDocker = true } label: {
                        Label(L("cleanupview.docker.action"), systemImage: "shippingbox")
                    }
                    .disabled(!model.canRunStandalone)
                    .confirmationDialog(
                        L("cleanupview.docker.confirm.title"),
                        isPresented: $confirmDocker,
                        titleVisibility: .visible
                    ) {
                        Button(L("cleanupview.docker.confirm.run"), role: .destructive) { runDockerPrune() }
                        Button(L("common.cancel"), role: .cancel) {}
                    } message: {
                        Text(L("cleanupview.docker.detail"))
                    }
                }
                Text(L("cleanupview.docker.detail"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let dockerReclaimable {
                    Text(L("cleanupview.docker.reclaimable", dockerReclaimable))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                commandPreview(RepairService.dockerPruneCommand)
            }
        }
    }

    private var snapshotsCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(L("cleanupview.snapshots.title")).font(.callout.weight(.semibold))
                    RiskBadge(risk: .caution)
                    Spacer()
                    Button { querySnapshots() } label: {
                        Label(
                            snapshotQuerying ? L("cleanupview.snapshots.querying") : L("cleanupview.snapshots.list"),
                            systemImage: "clock.arrow.circlepath"
                        )
                    }
                    .disabled(snapshotQuerying)
                }
                Text(L("cleanupview.snapshots.detail"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if snapshots.isEmpty {
                    Text(L("cleanupview.snapshots.empty"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(snapshots) { snap in
                        HStack {
                            Image(systemName: "camera.aperture").foregroundStyle(.secondary)
                            Text(snap.date).font(.system(.caption, design: .monospaced))
                            if snapshotRetention.keptDates.contains(snap.date) {
                                Text(L("cleanupview.snapshots.kept"))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button(role: .destructive) { deleteSnapshot(snap.date) } label: {
                                Text(L("cleanupview.snapshots.delete"))
                            }
                            .buttonStyle(.borderless)
                            .disabled(!model.canRunStandalone)
                        }
                        .padding(8)
                        .insetSurfaceBackground(RoundedRectangle(cornerRadius: 8), legacyFill: .black.opacity(0.04))
                    }
                }
                commandPreview(RepairService.thinSnapshotsPreview(for: snapshots))
                Button(role: .destructive) { confirmThin = true } label: {
                    Label(L("cleanupview.snapshots.thin"), systemImage: "arrow.down.circle")
                }
                .disabled(!model.canRunStandalone || (!snapshots.isEmpty && snapshotRetention.removableDates.isEmpty))
                .confirmationDialog(
                    L("cleanupview.snapshots.thin.confirm.title"),
                    isPresented: $confirmThin,
                    titleVisibility: .visible
                ) {
                    Button(L("cleanupview.snapshots.thin"), role: .destructive) { runThinSnapshots() }
                    Button(L("common.cancel"), role: .cancel) {}
                } message: {
                    Text(L("cleanupview.snapshots.detail"))
                }
            }
        }
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

    private func runDockerPrune() {
        model.runStandalone { try RepairService.dockerPrune() }
    }

    private func runThinSnapshots() {
        model.runStandalone { try RepairService.thinSnapshots() }
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
        model.runStandalone { try RepairService.deleteSnapshot(date: date) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { querySnapshots() }
    }
}
