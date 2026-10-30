import SwiftUI
import AppKit
import MacAssistantKit

struct RootView: View {
    @State private var selection: SidebarItem?
    @FocusState private var sidebarFocused: Bool
    @StateObject private var workspace: WorkspaceStore
    @StateObject private var updates = UpdateCoordinator()
    @StateObject private var ipaInjectionJob = IpaInjectionJob()
    @StateObject private var classDumpSession = ClassDumpSession()
    @State private var ipaTab: IpaView.Tab = .transfer
    /// 语言一变就换掉整棵子树的 identity,让所有 `L(...)` 重新取词条。
    @AppStorage(LocalizationSettings.defaultsKey) private var language = AppLanguage.system.rawValue
    @AppStorage(SceneBackdropSettings.defaultsKey) private var sceneRaw = SceneBackdropID.system.rawValue
    @AppStorage(SceneBackdropSettings.motionDefaultsKey) private var sceneMotion = true
    @AppStorage(AppearancePreference.defaultsKey) private var appearanceRaw = AppearancePreference.system.rawValue
    @AppStorage(SidebarAppearance.defaultsKey) private var sidebarRaw = SidebarAppearance.material.rawValue
    @AppStorage(IconAppearance.defaultsKey) private var iconRaw = IconAppearance.monochrome.rawValue
    @AppStorage(IconAppearance.colorSeedDefaultsKey) private var iconColorSeed = 0
    @SwiftUI.Environment(\.colorScheme) private var colorScheme
    @SwiftUI.Environment(\.openWindow) private var openWindow
    @SwiftUI.Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @SwiftUI.Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var scene: SceneBackdropID {
        SceneBackdropID.resolved(sceneRaw)
    }

    private var sidebarAppearance: SidebarAppearance {
        SidebarAppearance.resolved(sidebarRaw)
    }

    private var iconAppearance: IconAppearance {
        IconAppearance.resolved(iconRaw)
    }

    private var recipe: SceneBackdropRecipe {
        scene.recipe(dark: colorScheme == .dark || scene.prefersDarkAppearance)
    }

    private var sceneAnimated: Bool {
        sceneMotion && scene.isDecorative && !reduceMotion && !reduceTransparency
    }

    private var preferredScheme: ColorScheme? {
        if scene.prefersDarkAppearance { return .dark }
        switch AppearancePreference.resolved(appearanceRaw).prefersDark {
        case .none: return nil
        case .some(true): return .dark
        case .some(false): return .light
        }
    }

    private var sidebarChrome: SidebarChromePolicy {
        sidebarAppearance.chrome(
            decorativeScene: scene.isDecorative,
            reduceTransparency: reduceTransparency
        )
    }

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
                // 交通灯叠在侧栏左上角，名字要让开这一截。
                .padding(.top, 36)
                .padding(.bottom, 8)

                // 不用 List：即使关掉 selection，源列表点下去仍会跟手铺一层非圆角系统蓝。
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        sidebarSection(
                            L("root.section.daily"),
                            items: [.dashboard, .menuBar, .repair, .cleanup, .appUninstall, .desktopIcons, .appClone, .memory, .network, .cheatsheet, .recipes]
                        )
                        sidebarSection(
                            L("root.section.developer"),
                            items: [.deb, .dylib, .ipa, .macApp, .binary]
                        )
                        sidebarSection(
                            L("root.section.support"),
                            items: [.environment, .about, .opensource]
                        )
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .focused($sidebarFocused)
                .onMoveCommand(perform: moveSidebarSelection)
                .modifier(SidebarFocusChrome())
            }
            .background {
                if scene.isDecorative {
                    windowScene.ignoresSafeArea()
                }
            }
            .navigationSplitViewColumnWidth(min: 210, ideal: 228, max: 280)
        } detail: {
            detail
        }
        .background {
            WindowSceneChrome(
                immersive: scene.isDecorative,
                chrome: sidebarChrome,
                recipe: scene.isDecorative ? recipe : nil,
                // 侧栏和当前页已经各有一层窗口对齐的背景。底层再开时间线等于整窗多画一份。
                animated: false,
                reduceTransparency: reduceTransparency
            )
        }
        .toolbarBackground(.hidden, for: .windowToolbar)
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
            Button("下载更新") { updates.downloadPendingUpdate() }
            Button("跳过此版本") { updates.skipPendingVersion() }
            Button("稍后提醒", role: .cancel) { updates.remindLater() }
        } message: { info in
            Text(updates.alertMessage(for: info))
        }
        .environment(\.sceneBackdrop, scene)
        .preferredColorScheme(preferredScheme)
        .onAppear {
            let opener = openWindow
            DuoStatusBarController.shared.openMainWindow = {
                opener(id: "main")
            }
            pullDuoDestination()
        }
        .onReceive(NotificationCenter.default.publisher(for: .duoOpenDestination)) { _ in
            pullDuoDestination()
        }
        .id(language)
    }

    @ViewBuilder
    private var windowScene: some View {
        if scene.isDecorative {
            WindowAlignedBackdrop(
                recipe: scene.recipe(dark: colorScheme == .dark || scene.prefersDarkAppearance),
                animated: sceneAnimated,
                reduceTransparency: reduceTransparency,
                showsVeil: false
            )
        }
    }

    private func pullDuoDestination() {
        guard let destination = DuoNavigation.pending else { return }
        DuoNavigation.pending = nil
        selection = destination.sidebarItem
    }

    private func row(_ item: SidebarItem) -> some View {
        let selected = (selection ?? .dashboard) == item
        let iconTint: Color = {
            if let rgb = iconAppearance.rgb {
                return Color(red: rgb.0, green: rgb.1, blue: rgb.2)
            }
            if iconAppearance == .color {
                let rgb = SidebarIconShuffle.rgb(for: item, seed: iconColorSeed)
                return Color(red: rgb.0, green: rgb.1, blue: rgb.2)
            }
            return Color.primary
        }()
        return Button {
            selection = item
            sidebarFocused = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: item.icon)
                    .symbolRenderingMode(iconAppearance.usesHierarchicalColor ? .hierarchical : .monochrome)
                    .foregroundStyle(iconTint)
                    .frame(width: 18, alignment: .center)
                Text(item.title)
                    .foregroundStyle(Color.primary)
                Spacer(minLength: 4)
            }
            .font(.body)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(QuietRowButtonStyle(selected: selected))
        .accessibilityLabel(item.title)
        .accessibilityHint(L("root.accessibility.open", item.title))
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .accessibilityValue(selected ? L("root.accessibility.selected") : "")
        .accessibilityIdentifier("sidebar.\(item.rawValue)")
    }

    private func moveSidebarSelection(_ direction: MoveCommandDirection) {
        let items = SidebarItem.allCases
        let current = selection ?? .dashboard
        guard let index = items.firstIndex(of: current) else { return }
        switch direction {
        case .up where index > 0:
            selection = items[index - 1]
        case .down where index + 1 < items.count:
            selection = items[index + 1]
        default:
            break
        }
    }

    private func sidebarSection(_ title: String, items: [SidebarItem]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.top, 4)
                .padding(.bottom, 2)
            ForEach(items) { item in
                row(item)
            }
            .animation(nil, value: selection)
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch (selection ?? .dashboard).destination {
        case .dashboard: DashboardView(workspace: workspace)
        case .menuBar: MenuBarStatusView()
        case .repair: RepairView(workspace: workspace)
        case .cleanup: CleanupView()
        case .appUninstall: AppUninstallView()
        case .desktopIcons: DesktopIconView()
        case .appClone: AppCloneView(workspace: workspace)
        case .memory: MemoryView()
        case .network: NetworkView()
        case .cheatsheet: CheatsheetView(workspace: workspace)
        case .recipes: RecipesView(workspace: workspace)
        case .deb: DebView(workspace: workspace)
        case .dylib: DylibView(workspace: workspace)
        case .ipa: IpaView(
            injectionJob: ipaInjectionJob,
            classDumpSession: classDumpSession,
            workspace: workspace,
            tab: $ipaTab
        )
        case .macApp: MacAppView(workspace: workspace)
        case .binary: BinaryView()
        case .environment: EnvironmentView()
        case .about: AboutView(updates: updates)
        case .opensource: OpenSourceView()
        }
    }
}
