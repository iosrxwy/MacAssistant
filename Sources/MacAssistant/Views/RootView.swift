import SwiftUI
import AppKit
import MacAssistantKit

struct RootView: View {
    @State private var selection: SidebarItem?
    @StateObject private var workspace: WorkspaceStore
    @StateObject private var updates = UpdateCoordinator()
    @StateObject private var ipaInjectionJob = IpaInjectionJob()
    /// 语言一变就换掉整棵子树的 identity,让所有 `L(...)` 重新取词条。
    @AppStorage(LocalizationSettings.defaultsKey) private var language = AppLanguage.system.rawValue

    init(initialSelection: SidebarItem = .dashboard) {
        _selection = State(initialValue: initialSelection)
        _workspace = StateObject(wrappedValue: WorkspaceStore())
    }

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "wrench.and.screwdriver.fill")
                        .font(.title2)
                        .foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(L("root.appName")).font(.headline)
                        Text(L("root.tagline"))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 8)

                // 原生 selection 支持非活动窗口首击切换；颜色由 List 自己的 accentColor 覆盖。
                List(selection: $selection) {
                    sidebarSection(
                        L("root.section.daily"),
                        items: [.dashboard, .repair, .cleanup, .memory, .network, .cheatsheet, .recipes]
                    )
                    sidebarSection(
                        L("root.section.developer"),
                        items: [.deb, .dylib, .ipa, .macApp, .binary]
                    )
                    sidebarSection(
                        L("root.section.support"),
                        items: [.environment, .about]
                    )
                }
                .listStyle(.sidebar)
            }
            .navigationSplitViewColumnWidth(min: 210, ideal: 228, max: 280)
        } detail: {
            detail
        }
        .onReceive(workspace.$requestedDestination) { destination in
            guard let destination else { return }
            selection = destination.sidebarItem
            workspace.acknowledgeNavigation()
        }
        // 启动后台静默检查:被节流拦住、失败或无更新时什么都不会发生。
        .task { await updates.runAutomaticCheckIfDue() }
        .alert(
            "发现新版本",
            isPresented: $updates.isShowingUpdateAlert,
            presenting: updates.pendingUpdate
        ) { _ in
            Button("查看更新") { updates.openPendingRelease() }
            Button("跳过此版本") { updates.skipPendingVersion() }
            Button("稍后提醒", role: .cancel) { updates.remindLater() }
        } message: { info in
            Text(updates.alertMessage(for: info))
        }
        .id(language)
    }

    private func row(_ item: SidebarItem) -> some View {
        let selected = (selection ?? .dashboard) == item
        return HStack(spacing: 6) {
            Label(item.title, systemImage: item.icon)
                .foregroundStyle(selected ? AnyShapeStyle(Color.appAccent) : AnyShapeStyle(.primary))
            Spacer(minLength: 4)
            if item.isBeta {
                BetaTag()
            }
        }
        .font(.body.weight(selected ? .medium : .regular))
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .background(SidebarSelectionAppearance())
        .background {
            if selected {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.appAccent.opacity(0.12))
                    .overlay {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .strokeBorder(Color.appAccent.opacity(0.18))
                    }
            }
        }
        .tag(item)
        .accessibilityLabel(item.isBeta ? L("root.accessibility.beta", item.title) : item.title)
        .accessibilityHint(L("root.accessibility.open", item.title))
        .accessibilityValue(selected ? L("root.accessibility.selected") : "")
        .accessibilityIdentifier("sidebar.\(item.rawValue)")
    }

    /// List 继续负责首击选择和键盘导航，只关掉 AppKit 强制绘制的系统蓝色底。
    private struct SidebarSelectionAppearance: NSViewRepresentable {
        func makeNSView(context: Context) -> NSView { NSView() }

        func updateNSView(_ view: NSView, context: Context) {
            DispatchQueue.main.async {
                var ancestor = view.superview
                while let current = ancestor {
                    if let table = current as? NSTableView {
                        table.selectionHighlightStyle = .none
                        return
                    }
                    ancestor = current.superview
                }
            }
        }
    }

    private func sidebarSection(_ title: String, items: [SidebarItem]) -> some View {
        Section(title) {
            ForEach(items) { item in
                row(item)
            }
        }
    }

    private struct BetaTag: View {
        var body: some View {
            Text("Beta")
                .font(.system(size: 9, weight: .semibold))
                .textCase(.uppercase)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .insetSurfaceBackground(Capsule(), legacyFill: .secondary.opacity(0.16))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch (selection ?? .dashboard).destination {
        case .dashboard: DashboardView()
        case .repair: RepairView()
        case .cleanup: CleanupView()
        case .memory: MemoryView()
        case .network: NetworkView()
        case .cheatsheet: CheatsheetView()
        case .recipes: RecipesView()
        case .deb: DebView(workspace: workspace)
        case .dylib: DylibView(workspace: workspace)
        case .ipa: IpaView(injectionJob: ipaInjectionJob, workspace: workspace)
        case .macApp: MacAppView()
        case .binary: BinaryView()
        case .environment: EnvironmentView()
        case .about: AboutView(updates: updates)
        }
    }
}
