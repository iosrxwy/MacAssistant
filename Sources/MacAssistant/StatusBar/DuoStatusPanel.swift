import AppKit
import MacAssistantKit
import SwiftUI

extension Notification.Name {
    static let duoOpenDestination = Notification.Name("MacAssistant.DuoOpenDestination")
}

enum DuoNavigation {
    static var pending: AppDestination?
}

enum DuoDetailPlacement {
    case popover
    case page
}

@MainActor
final class DuoStatusPanelController: NSObject {
    private weak var model: DuoStatusBarController?
    private var panel: DuoGlassPanel?
    private var host: NSHostingView<DuoStatusDetail>?
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private weak var anchor: NSStatusBarButton?

    var isShown: Bool { panel?.isVisible == true }

    init(model: DuoStatusBarController) {
        self.model = model
    }

    func toggle(from button: NSStatusBarButton) {
        if isShown {
            close()
        } else {
            show(under: button)
        }
    }

    func close() {
        removeMonitors()
        anchor?.isHighlighted = false
        panel?.orderOut(nil)
        anchor = nil
    }

    private func show(under button: NSStatusBarButton) {
        guard let model else { return }
        model.bluetooth.refresh()
        model.refresh()
        model.actions.refreshForDisplay(onBattery: model.status.powerSource == .battery)
        let host = ensureHost(model: model)
        let panel = ensurePanel(host: host)
        anchor = button
        let screen = button.window?.screen ?? NSScreen.main
        let maxHeight = max(280, (screen?.visibleFrame.height ?? 700) - 12)
        let height = min(680, maxHeight)
        let size = NSSize(width: 336, height: height)
        panel.setContentSize(size)
        var origin = NSPoint(x: 0, y: 0)
        if let window = button.window {
            let buttonFrame = window.convertToScreen(button.convert(button.bounds, to: nil))
            origin.x = buttonFrame.midX - size.width / 2
            origin.y = buttonFrame.minY - size.height - 8
            if let visible = screen?.visibleFrame {
                if origin.x < visible.minX + 8 { origin.x = visible.minX + 8 }
                if origin.x + size.width > visible.maxX - 8 {
                    origin.x = visible.maxX - 8 - size.width
                }
                if origin.y < visible.minY + 8 {
                    origin.y = visible.minY + 8
                }
            }
        }
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        button.isHighlighted = true
        panel.orderFrontRegardless()
        panel.makeKey()
        installMonitors()
    }

    private func ensureHost(model: DuoStatusBarController) -> NSHostingView<DuoStatusDetail> {
        if let host { return host }
        let view = DuoStatusDetail(model: model, actions: model.actions, bluetooth: model.bluetooth, placement: .popover)
        let host = ClearHost(rootView: view)
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor.clear.cgColor
        self.host = host
        return host
    }

    private func ensurePanel(host: NSView) -> DuoGlassPanel {
        if let panel { return panel }
        let panel = DuoGlassPanel(contentView: DuoGlassBackdrop(host: host))
        self.panel = panel
        return panel
    }

    private func installMonitors() {
        guard localMonitor == nil else { return }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            self?.closeIfOutside()
            return event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.closeIfOutside()
        }
    }

    private func removeMonitors() {
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        localMonitor = nil
        globalMonitor = nil
    }

    private func closeIfOutside() {
        guard isShown, let panel else { return }
        let point = NSEvent.mouseLocation
        if panel.frame.contains(point) { return }
        if let anchor, let window = anchor.window {
            let frame = window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
            if frame.contains(point) { return }
        }
        close()
    }
}

private enum DuoPanelMetrics {
    static let cornerRadius: CGFloat = 22
}

private enum DuoRowMetrics {
    static let icon: CGFloat = 15
    static let iconBox: CGFloat = 20
    static let title = Font.system(size: 13, weight: .medium)
    static let heading = Font.system(size: 13, weight: .semibold)
    static let section = Font.system(size: 12, weight: .semibold)
    static let subtitle = Font.system(size: 11)
    static let rowLink = Font.system(size: 13)
    static let toggleWidth: CGFloat = 44
}

private final class ClearHost<Content: View>: NSHostingView<Content> {
    override var isOpaque: Bool { false }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        (window as? DuoGlassPanel)?.clipRoundedCorners()
    }
}

private final class DuoGlassPanel: NSPanel {
    private var clippedSize = NSSize.zero

    init(contentView: NSView) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 336, height: 640),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        self.contentView = contentView
        isFloatingPanel = true
        level = .statusBar
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isMovable = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        clipRoundedCorners()
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// 玻璃是圆角，窗口本身仍是方的。方框四角会垫一块黑底，按同样半径裁掉才透出去。
    func clipRoundedCorners() {
        isOpaque = false
        backgroundColor = .clear
        let radius = DuoPanelMetrics.cornerRadius
        for view in [contentView?.superview, contentView].compactMap({ $0 }) {
            view.wantsLayer = true
            view.layer?.backgroundColor = NSColor.clear.cgColor
            view.layer?.cornerRadius = radius
            view.layer?.masksToBounds = true
        }
        let size = frame.size
        guard size != clippedSize else { return }
        clippedSize = size
        invalidateShadow()
    }
}

private final class DuoGlassBackdrop: NSView {
    private let chrome: NSView
    private let host: NSView

    init(host: NSView) {
        self.host = host
        if let glass = Self.makeGlass(host: host) {
            chrome = glass
        } else {
            let effect = NSVisualEffectView()
            effect.material = .popover
            effect.blendingMode = .behindWindow
            effect.state = .active
            effect.wantsLayer = true
            effect.layer?.cornerRadius = DuoPanelMetrics.cornerRadius
            effect.layer?.masksToBounds = true
            effect.addSubview(host)
            chrome = effect
        }
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        addSubview(chrome)
    }

    override var isOpaque: Bool { false }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        (window as? DuoGlassPanel)?.clipRoundedCorners()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    /// macOS 14 的 SDK 没有这个类。只有带 macOS 26 SDK 的编译器才创建它。
    private static func makeGlass(host: NSView) -> NSView? {
#if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.style = .regular
            glass.cornerRadius = DuoPanelMetrics.cornerRadius
            glass.tintColor = NSColor(srgbRed: 0.55, green: 0.78, blue: 0.96, alpha: 0.38)
            glass.contentView = host
            return glass
        }
#endif
        return nil
    }

    override func layout() {
        super.layout()
        chrome.frame = bounds
        host.frame = chrome.bounds
        (window as? DuoGlassPanel)?.clipRoundedCorners()
    }
}

struct DuoStatusDetail: View {
    @ObservedObject var model: DuoStatusBarController
    @ObservedObject var actions: DuoQuickActions
    @ObservedObject var bluetooth: DuoBluetoothModel
    var placement: DuoDetailPlacement
    @AppStorage(LocalizationSettings.defaultsKey) private var language = AppLanguage.system.rawValue
    @State private var showingCustomize = false
    @State private var showOtherNetworks = false
    @State private var awakeExpanded = false
    @State private var awakeHovering = false
    @State private var bluetoothExpanded = false
    @State private var bluetoothHovering = false

    var body: some View {
        Group {
            if placement == .popover {
                Group {
                    if showingCustomize {
                        VStack(alignment: .leading, spacing: 14) {
                            customizeBlock
                            footerBar
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    } else {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 10) {
                                popoverSections
                                footerBar
                            }
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .scrollContentBackground(.hidden)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.clear)
            } else {
                VStack(alignment: .leading, spacing: 18) {
                    Card { batteryBlock }
                    Card { wifiBlock }
                    Card { volumeBlock }
                    Card { shortcutsBlock(onlyVisible: false) }
                }
            }
        }
        .tint(Color(nsColor: .systemBlue))
        .id(language)
        .onAppear {
            actions.refreshForDisplay(onBattery: model.status.powerSource == .battery)
            bluetooth.refresh()
        }
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
            guard placement == .page else { return }
            bluetooth.refresh()
        }
    }

    private var popoverSections: some View {
        VStack(alignment: .leading, spacing: 0) {
            batteryBlock
            menuDivider
                .padding(.top, 10)
                .padding(.bottom, 8)
            wifiBlock
            menuDivider
                .padding(.top, 8)
                .padding(.bottom, 6)
            volumeBlock
            menuDivider
                .padding(.vertical, 6)
            shortcutsBlock(onlyVisible: true)
        }
    }

    private var menuDivider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.14))
            .frame(height: 0.5)
    }

    private var batteryBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 8) {
                DuoStatusIconView(status: model.status, pointSize: placement == .popover ? 28 : 44)
                VStack(alignment: .leading, spacing: 1) {
                    Text(DuoStatusText.batteryTitle(model.status))
                        .font(.body.weight(.semibold))
                    if let time = DuoStatusText.batteryTime(model.status) {
                        Text(time)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            infoRow(title: L("duo.power"), value: DuoStatusText.powerSource(model.status))
            energyBlock
            menuButton(L("duo.batterySettings"), identifier: "duo.batterySettings") {
                model.closePanel()
                DuoSystemSettings.battery()
            }
        }
    }

    @ViewBuilder
    private var energyBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L("duo.energy"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            if let mode = actions.energyMode {
                HStack(spacing: 4) {
                    energyChoice(.automatic, current: mode)
                    energyChoice(.low, current: mode)
                    if actions.supportsHighPower {
                        energyChoice(.high, current: mode)
                    }
                }
                if actions.energyFailed {
                    Text(L("duo.energy.failed"))
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            } else {
                Text(L("duo.energy.unavailable"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func energyChoice(_ mode: DuoEnergyMode, current: DuoEnergyMode) -> some View {
        let selected = mode == current
        return Button {
            actions.setEnergy(mode, onBattery: model.status.powerSource == .battery)
        } label: {
            VStack(spacing: 3) {
                ZStack {
                    Circle()
                        .fill(selected ? Color(nsColor: .systemBlue) : Color.primary.opacity(0.08))
                        .frame(width: 28, height: 28)
                    Image(systemName: energySymbol(mode))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(selected ? Color.white : Color.secondary)
                }
                Text(energyTitle(mode))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(selected ? Color(nsColor: .systemBlue) : Color.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(selected)
        .accessibilityLabel(energyTitle(mode))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("duo.energy.\(mode.rawValue)")
    }

    private func energySymbol(_ mode: DuoEnergyMode) -> String {
        switch mode {
        case .automatic: return "battery.100"
        case .low: return "battery.25"
        case .high: return "battery.100.bolt"
        }
    }

    private func energyTitle(_ mode: DuoEnergyMode) -> String {
        switch mode {
        case .automatic: return L("duo.energy.auto")
        case .low: return L("duo.energy.low")
        case .high: return L("duo.energy.high")
        }
    }

    private var wifiBlock: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                Text(L("duo.wifi.menuTitle"))
                    .font(DuoRowMetrics.heading)
                    .foregroundStyle(.primary)
                Spacer(minLength: 8)
                Toggle("", isOn: wifiBinding)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .controlSize(.small)
                    .tint(Color(nsColor: .systemBlue))
                    .disabled(model.status.wifiPowerOn == nil)
                    .accessibilityLabel(L("duo.wifi.menuTitle"))
                    .accessibilityIdentifier("duo.wifi.power")
            }
            .padding(.bottom, 6)
            menuDivider
            if !actions.nearbyHotspots.isEmpty {
                sectionLabel(L("duo.wifi.hotspot"))
                    .padding(.top, 8)
                ForEach(actions.nearbyHotspots) { hotspot in
                    hotspotRow(hotspot)
                }
                menuDivider
                    .padding(.top, 8)
            }
            if wifiIsAssociated {
                sectionLabel(L("duo.wifi.known"))
                    .padding(.top, actions.nearbyHotspots.isEmpty ? 8 : 6)
                currentNetworkRow
                    .padding(.bottom, 8)
                menuDivider
            } else if model.status.wifiPowerOn == false || model.status.link == .wifiOff {
                Text(L("duo.wifi.off"))
                    .font(DuoRowMetrics.rowLink)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 10)
                menuDivider
            }
            if !otherNetworkNames.isEmpty {
                HStack(alignment: .center, spacing: 8) {
                    Button {
                        showOtherNetworks.toggle()
                    } label: {
                        HStack(spacing: 4) {
                            Text(L("duo.wifi.other"))
                                .font(.system(size: 12, weight: .regular))
                                .foregroundStyle(.secondary)
                            Image(systemName: showOtherNetworks ? "chevron.down" : "chevron.right")
                                .font(.system(size: 10, weight: .regular))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("duo.wifi.other")
                    Spacer(minLength: 8)
                    wifiSettingsButton(fillsRow: false)
                }
                if showOtherNetworks {
                    ForEach(Array(otherNetworkNames.enumerated()), id: \.offset) { _, name in
                        Text(name)
                            .font(DuoRowMetrics.rowLink)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .padding(.vertical, 4)
                            .padding(.leading, 36)
                    }
                }
            } else {
                wifiSettingsButton(fillsRow: true)
                    .padding(.top, 4)
            }
        }
    }

    private func wifiSettingsButton(fillsRow: Bool) -> some View {
        Button {
            model.closePanel()
            DuoSystemSettings.wifi()
        } label: {
            Text(L("duo.wifi.settings"))
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(.secondary)
                .padding(.vertical, 6)
                .frame(maxWidth: fillsRow ? .infinity : nil, alignment: .leading)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("duo.wifi.settings")
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title)
            .font(DuoRowMetrics.section)
            .foregroundStyle(.secondary)
            .padding(.bottom, 4)
    }

    private func hotspotRow(_ hotspot: DuoNearbyHotspot) -> some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(Color.primary.opacity(0.08))
                    .frame(width: 24, height: 24)
                Image(systemName: "link")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            Text(hotspot.name)
                .font(DuoRowMetrics.title)
                .foregroundStyle(.primary)
                .lineLimit(1)
            Spacer(minLength: 8)
            Image(systemName: "wifi", variableValue: Double(max(0, min(3, hotspot.bars))) / 3)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .accessibilityLabel(L("duo.wifi.connected", hotspot.bars))
            if let band = hotspot.band {
                Text(band)
                    .font(DuoRowMetrics.subtitle)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 6)
    }

    private var currentNetworkRow: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(Color(nsColor: .systemBlue))
                    .frame(width: 24, height: 24)
                Image(systemName: "wifi")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
            }
            Text(currentNetworkTitle)
                .font(DuoRowMetrics.title)
                .foregroundStyle(.primary)
                .lineLimit(1)
            Spacer(minLength: 8)
            if actions.currentSecured, actions.currentSSID?.isEmpty == false {
                Image(systemName: "lock")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(L("duo.wifi.secured"))
            }
        }
        .padding(.vertical, 4)
        .accessibilityLabel(currentNetworkTitle)
    }

    private var bluetoothBlock: some View {
        VStack(alignment: .leading, spacing: 0) {
            DuoModuleHeader(
                symbol: bluetoothSymbol,
                badgeBluetooth: bluetoothBadge,
                title: bluetoothTitle,
                subtitle: bluetoothSubtitle,
                expanded: bluetoothExpanded,
                isOn: bluetooth.poweredOn == true,
                enabled: bluetooth.poweredOn != nil,
                toggleID: "duo.bluetooth.power",
                expandID: "duo.bluetooth.expand",
                expandLabel: L("duo.bluetooth.expand"),
                hovering: bluetoothHovering
            ) { bluetooth.setPower($0) } expand: {
                withAnimation(.easeOut(duration: 0.16)) {
                    bluetoothExpanded.toggle()
                }
            }
            if bluetoothExpanded {
                menuDivider
                    .padding(.top, 8)
                if bluetooth.poweredOn == true {
                    if bluetooth.devices.isEmpty {
                        Text(L("duo.bluetooth.empty"))
                            .font(DuoRowMetrics.rowLink)
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 6)
                            .padding(.leading, DuoRowMetrics.iconBox + 8)
                    } else {
                        ForEach(bluetooth.devices) { device in
                            DuoCheckRow(
                                title: device.name,
                                checked: device.connected || device.connecting,
                                identifier: "duo.bluetooth.device.\(device.address)",
                                label: device.connected
                                    ? L("duo.bluetooth.disconnect", device.name)
                                    : L("duo.bluetooth.connect", device.name)
                            ) {
                                bluetooth.activate(device.address)
                                collapseBluetooth()
                            }
                        }
                    }
                }
                menuDivider
                    .padding(.top, 4)
                menuButton(L("duo.bluetooth.settings"), identifier: "duo.bluetooth.settings") {
                    model.closePanel()
                    DuoSystemSettings.bluetooth()
                }
                .padding(.leading, DuoRowMetrics.iconBox + 8)
            }
        }
        .onContinuousHover { phase in
            setHover(phase, hovering: $bluetoothHovering)
        }
    }

    private func collapseBluetooth() {
        guard bluetoothExpanded else { return }
        withAnimation(.easeOut(duration: 0.16)) {
            bluetoothExpanded = false
        }
    }

    private var bluetoothTitle: String {
        if bluetooth.poweredOn == true, let name = bluetooth.featured?.name {
            return name
        }
        return L("duo.bluetooth")
    }

    private var bluetoothSubtitle: String {
        guard bluetooth.poweredOn == true else { return L("duo.bluetooth.off") }
        if bluetooth.featured?.connecting == true {
            return L("duo.bluetooth.connecting")
        }
        let connected = bluetooth.devices.filter(\.connected).count
        if connected > 1 {
            return L("duo.bluetooth.connectedCount", connected)
        }
        if connected == 1 {
            return L("duo.bluetooth.connected")
        }
        return L("duo.bluetooth.on")
    }

    private var bluetoothSymbol: String {
        if bluetooth.poweredOn == true, let symbol = bluetooth.featured?.symbol {
            return symbol
        }
        return "bluetooth"
    }

    private var bluetoothBadge: Bool {
        switch bluetoothSymbol {
        case "airpodspro", "airpodsmax", "airpods", "headphones", "beats.headphones":
            return true
        default:
            return false
        }
    }

    private var awakeControl: some View {
        VStack(alignment: .leading, spacing: 0) {
            DuoModuleHeader(
                symbol: "cup.and.saucer.fill",
                title: L("duo.shortcut.awake"),
                subtitle: awakeSubtitle,
                expanded: awakeExpanded,
                isOn: actions.awake,
                toggleID: "duo.shortcut.awake",
                expandID: "duo.shortcut.awake.expand",
                expandLabel: L("duo.shortcut.awake.expand"),
                hovering: awakeHovering
            ) { actions.setAwake($0) } expand: {
                withAnimation(.easeOut(duration: 0.16)) {
                    awakeExpanded.toggle()
                }
            }
            if awakeExpanded {
                menuDivider
                    .padding(.top, 8)
                ForEach(DuoAwakeSpan.allCases) { span in
                    DuoCheckRow(
                        title: DuoAwakeText.title(span),
                        checked: actions.awakeSpan == span,
                        identifier: "duo.shortcut.awake.span.\(span.rawValue)"
                    ) {
                        actions.selectAwakeSpan(span)
                        collapseAwake()
                    }
                }
                menuDivider
                    .padding(.top, 4)
                DuoCheckRow(
                    title: L("duo.shortcut.awake.lid"),
                    checked: actions.preventLidSleep,
                    identifier: "duo.shortcut.awake.lid"
                ) {
                    actions.setPreventLidSleep(!actions.preventLidSleep)
                    collapseAwake()
                }
            }
        }
        .onContinuousHover { phase in
            setHover(phase, hovering: $awakeHovering)
        }
    }

    private func collapseAwake() {
        guard awakeExpanded else { return }
        withAnimation(.easeOut(duration: 0.16)) {
            awakeExpanded = false
        }
    }

    private func setHover(_ phase: HoverPhase, hovering: Binding<Bool>) {
        let next: Bool
        switch phase {
        case .active:
            next = true
        case .ended:
            next = false
        @unknown default:
            next = false
        }
        if hovering.wrappedValue != next {
            hovering.wrappedValue = next
        }
    }

    private var awakeSubtitle: String {
        if actions.awake {
            if let deadline = actions.awakeDeadline {
                return L("duo.shortcut.awake.until", DuoAwakeText.clock(deadline))
            }
            return L("duo.shortcut.awake.forever")
        }
        return DuoAwakeText.title(actions.awakeSpan)
    }

    private var volumeBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                DuoRowIcon(symbol: model.status.isMuted ? "speaker.slash" : "speaker.wave.2")
                Text(L("duo.volume"))
                    .font(DuoRowMetrics.title)
                Spacer(minLength: 8)
                Text(DuoStatusText.volume(model.status))
                    .font(DuoRowMetrics.subtitle)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Button {
                    model.toggleMuted()
                } label: {
                    Image(systemName: model.status.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .font(.system(size: 13, weight: .medium))
                }
                .buttonStyle(.borderless)
                .disabled(model.status.volumeScalar == nil)
                .accessibilityLabel(L("duo.volume.mute"))
            }
            Slider(
                value: Binding(
                    get: { model.status.isMuted ? 0 : (model.status.volumeScalar ?? 0) },
                    set: { model.setVolume($0) }
                ),
                in: 0...1
            )
            .disabled(model.status.volumeScalar == nil)
            .controlSize(.small)
            .tint(Color(nsColor: .systemBlue))
            .accessibilityLabel(L("duo.volume"))
        }
    }

    private func shortcutsBlock(onlyVisible: Bool) -> some View {
        let tools = actions.toolsInOrder().filter { !onlyVisible || actions.toolIsShown($0) }
        return VStack(alignment: .leading, spacing: 2) {
            Text(L("duo.shortcuts"))
                .font(DuoRowMetrics.section)
                .foregroundStyle(.secondary)
                .padding(.bottom, 2)
            if tools.isEmpty {
                Text(L("duo.customize.empty"))
                    .font(DuoRowMetrics.subtitle)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            }
            ForEach(tools) { tool in
                toolControl(tool)
            }
        }
    }

    private var dockFailureText: String? {
        switch actions.dockFailure {
        case .denied:
            return L("duo.shortcut.dock.denied")
        case .failed:
            return L("duo.shortcut.dock.failed")
        case nil:
            return nil
        }
    }

    @ViewBuilder
    private func toolControl(_ tool: DuoToolID) -> some View {
        switch tool {
        case .bluetooth:
            bluetoothBlock
        case .dock:
            DuoSwitchRow(
                symbol: "dock.rectangle",
                title: L("duo.shortcut.dock"),
                subtitle: dockFailureText,
                isOn: actions.dockHidden,
                identifier: "duo.shortcut.dock"
            ) {
                actions.setDockHidden($0)
            }
        case .widgets:
            DuoSwitchRow(symbol: "square.grid.2x2", title: L("duo.shortcut.widgets"), isOn: actions.widgetsHidden, identifier: "duo.shortcut.widgets") {
                actions.setWidgetsHidden($0)
            }
        case .stageManager:
            DuoSwitchRow(
                symbol: "rectangle.stack",
                title: L("duo.shortcut.stageManager"),
                isOn: actions.stageManagerEnabled,
                identifier: "duo.shortcut.stageManager"
            ) { actions.setStageManager($0) }
        case .mic:
            DuoSwitchRow(
                symbol: "mic",
                title: L("duo.shortcut.mic"),
                subtitle: actions.micMuted == nil ? L("duo.shortcut.mic.unavailable") : nil,
                isOn: actions.micMuted == true,
                enabled: actions.micMuted != nil,
                identifier: "duo.shortcut.mic"
            ) { actions.setMicMuted($0) }
        case .desktop:
            DuoSwitchRow(symbol: "desktopcomputer", title: L("duo.shortcut.desktop"), isOn: actions.desktopHidden, identifier: "duo.shortcut.desktop") {
                actions.setDesktopHidden($0)
            }
        case .awake:
            awakeControl
        case .clean:
            DuoSwitchRow(
                symbol: "sparkles",
                title: L("duo.shortcut.clean"),
                subtitle: L("duo.shortcut.clean.hint"),
                isOn: actions.screenClean,
                identifier: "duo.shortcut.clean"
            ) { actions.setScreenClean($0) }
        case .keyboard:
            DuoSwitchRow(
                symbol: "keyboard",
                title: L("duo.shortcut.keyboard"),
                subtitle: actions.keyboardNeedsAccess ? L("duo.shortcut.keyboard.access") : L("duo.shortcut.keyboard.hint"),
                isOn: actions.keyboardLocked,
                identifier: "duo.shortcut.keyboard"
            ) { actions.setKeyboardLocked($0) }
        case .menuBar:
            DuoSwitchRow(
                symbol: "menubar.rectangle",
                title: L("duo.shortcut.menuBar"),
                isOn: actions.menuBarAutoHide,
                identifier: "duo.shortcut.menuBar"
            ) { actions.setMenuBarAutoHide($0) }
        case .hiddenFiles:
            DuoSwitchRow(
                symbol: "eye",
                title: L("duo.shortcut.hiddenFiles"),
                isOn: actions.hiddenFilesShown,
                identifier: "duo.shortcut.hiddenFiles"
            ) { actions.setHiddenFilesShown($0) }
        case .darkMode:
            DuoSwitchRow(
                symbol: "circle.lefthalf.filled",
                title: L("duo.shortcut.dark"),
                subtitle: actions.darkFailed ? L("duo.shortcut.dark.failed") : nil,
                isOn: actions.darkMode,
                identifier: "duo.shortcut.dark"
            ) { actions.setDarkMode($0) }
        case .extensions:
            DuoSwitchRow(
                symbol: "doc.text",
                title: L("duo.shortcut.extensions"),
                isOn: actions.showExtensions,
                identifier: "duo.shortcut.extensions"
            ) { actions.setShowExtensions($0) }
        case .pathbar:
            DuoSwitchRow(
                symbol: "rectangle.split.1x2",
                title: L("duo.shortcut.pathbar"),
                isOn: actions.showPathbar,
                identifier: "duo.shortcut.pathbar"
            ) { actions.setShowPathbar($0) }
        case .clipboard:
            actionRow(
                symbol: "doc.on.clipboard",
                title: L("duo.shortcut.clipboard"),
                subtitle: actions.clipboardCleared ? L("duo.shortcut.clipboard.done") : L("duo.shortcut.clipboard.detail"),
                button: L("duo.shortcut.clipboard.run"),
                identifier: "duo.shortcut.clipboard"
            ) { actions.clearClipboard() }
        case .sleep:
            actionRow(
                symbol: "moon.zzz",
                title: L("duo.shortcut.sleep"),
                subtitle: actions.sessionFailed ? L("duo.shortcut.session.failed") : L("duo.shortcut.sleep.detail"),
                button: L("duo.shortcut.sleep.run"),
                identifier: "duo.shortcut.sleep"
            ) { actions.sleepNow() }
        case .restart:
            actionRow(
                symbol: "arrow.clockwise",
                title: L("duo.shortcut.restart"),
                subtitle: actions.sessionFailed ? L("duo.shortcut.session.failed") : L("duo.shortcut.restart.detail"),
                button: L("duo.shortcut.restart.run"),
                identifier: "duo.shortcut.restart"
            ) { confirmSession(L("duo.shortcut.restart"), L("duo.shortcut.restart.confirm")) { actions.restartNow() } }
        case .logout:
            actionRow(
                symbol: "rectangle.portrait.and.arrow.right",
                title: L("duo.shortcut.logout"),
                subtitle: L("duo.shortcut.logout.detail"),
                button: L("duo.shortcut.logout.run"),
                identifier: "duo.shortcut.logout"
            ) { confirmSession(L("duo.shortcut.logout"), L("duo.shortcut.logout.confirm")) { actions.logOutNow() } }
        case .emptyTrash:
            actionRow(
                symbol: "trash",
                title: L("duo.shortcut.trash"),
                subtitle: actions.trashFailed ? L("duo.shortcut.trash.failed") : L("duo.shortcut.trash.detail"),
                button: L("duo.shortcut.trash.run"),
                identifier: "duo.shortcut.trash"
            ) { actions.emptyTrash() }
        case .derived:
            actionRow(
                symbol: "hammer",
                title: L("duo.shortcut.derived"),
                subtitle: derivedSubtitle,
                button: L("duo.shortcut.derived.open"),
                identifier: "duo.shortcut.derived"
            ) { model.showDestination(.cleanup) }
        case .eject:
            actionRow(
                symbol: "eject",
                title: L("duo.shortcut.eject"),
                subtitle: ejectSubtitle,
                button: L("duo.shortcut.eject"),
                enabled: !actions.disks.isEmpty,
                identifier: "duo.shortcut.eject"
            ) { actions.ejectDisks() }
        }
    }

    private var customizeBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("duo.customize.title"))
                .font(.callout.weight(.semibold))
            Text(L("duo.customize.detail"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            List {
                ForEach(actions.toolsInOrder()) { tool in
                    customizeRow(tool)
                        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 4))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                }
                .onMove(perform: actions.moveTools)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .environment(\.defaultMinListRowHeight, 36)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func customizeRow(_ tool: DuoToolID) -> some View {
        HStack(spacing: 8) {
            DuoRowIcon(symbol: toolSymbol(tool))
            Text(toolTitle(tool))
                .font(DuoRowMetrics.title)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            Toggle("", isOn: Binding(
                get: { actions.toolIsShown(tool) },
                set: { actions.setToolShown(tool, $0) }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
            .controlSize(.small)
            .frame(width: DuoRowMetrics.toggleWidth, alignment: .trailing)
            .accessibilityLabel(L("duo.customize.show", toolTitle(tool)))
            Image(systemName: "line.3.horizontal")
                .font(.body)
                .frame(width: 22, height: 22, alignment: .center)
                .foregroundStyle(.secondary)
                .accessibilityLabel(L("duo.customize.drag"))
                .accessibilityIdentifier("duo.customize.drag.\(tool.rawValue)")
        }
        .frame(minHeight: 36)
        .contentShape(Rectangle())
    }

    private var footerBar: some View {
        HStack(spacing: 8) {
            Button {
                model.showDestination(.menuBar)
            } label: {
                Image(systemName: "gearshape")
                    .font(.body)
                    .frame(width: 36, height: 32)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.primary)
            .accessibilityLabel(L("duo.footer.settings"))
            .accessibilityIdentifier("duo.footer.settings")

            Button {
                showingCustomize.toggle()
            } label: {
                Text(showingCustomize ? L("duo.customize.back") : L("duo.footer.customize"))
                    .font(DuoRowMetrics.title)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7)
                    .background(Capsule().fill(.ultraThinMaterial))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.primary)
            .accessibilityIdentifier("duo.footer.customize")

            Button {
                NSApp.terminate(nil)
            } label: {
                Image(systemName: "power")
                    .font(.body)
                    .frame(width: 36, height: 32)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.primary)
            .accessibilityLabel(L("duo.footer.power"))
            .accessibilityIdentifier("duo.footer.power")
        }
        .padding(.top, 4)
    }

    private var derivedSubtitle: String {
        guard actions.derivedReady else { return L("duo.shortcut.derived.counting") }
        guard let bytes = actions.derivedBytes else { return L("duo.shortcut.derived.missing") }
        return L("duo.shortcut.derived.size", DuoQuickText.byteText(bytes))
    }

    private var ejectSubtitle: String {
        if actions.disks.isEmpty { return L("duo.shortcut.eject.none") }
        let names = actions.disks.prefix(3).map(\.name).joined(separator: "、")
        if actions.disks.count > 3 {
            return names + " · " + L("duo.shortcut.eject.count", actions.disks.count)
        }
        return names
    }

    private var wifiIsAssociated: Bool {
        if case .wifi = model.status.link { return true }
        return false
    }

    private var currentNetworkTitle: String {
        if let name = actions.currentSSID, !name.isEmpty {
            return name
        }
        if case .wifi(let bars, false) = model.status.link {
            return L("duo.wifi.noInternet", bars)
        }
        if case .wifi(let bars, true) = model.status.link {
            return L("duo.wifi.connected", bars)
        }
        return DuoStatusText.link(model.status.link)
    }

    private var otherNetworkNames: [String] {
        let current = actions.currentSSID
        return actions.knownNetworks.filter { name in
            guard let current, !current.isEmpty else { return true }
            return name.caseInsensitiveCompare(current) != .orderedSame
        }
    }

    private func toolTitle(_ tool: DuoToolID) -> String {
        switch tool {
        case .bluetooth: return L("duo.bluetooth")
        case .dock: return L("duo.shortcut.dock")
        case .widgets: return L("duo.shortcut.widgets")
        case .stageManager: return L("duo.shortcut.stageManager")
        case .mic: return L("duo.shortcut.mic")
        case .desktop: return L("duo.shortcut.desktop")
        case .awake: return L("duo.shortcut.awake")
        case .clean: return L("duo.shortcut.clean")
        case .keyboard: return L("duo.shortcut.keyboard")
        case .menuBar: return L("duo.shortcut.menuBar")
        case .hiddenFiles: return L("duo.shortcut.hiddenFiles")
        case .darkMode: return L("duo.shortcut.dark")
        case .extensions: return L("duo.shortcut.extensions")
        case .pathbar: return L("duo.shortcut.pathbar")
        case .clipboard: return L("duo.shortcut.clipboard")
        case .sleep: return L("duo.shortcut.sleep")
        case .restart: return L("duo.shortcut.restart")
        case .logout: return L("duo.shortcut.logout")
        case .emptyTrash: return L("duo.shortcut.trash")
        case .derived: return L("duo.shortcut.derived")
        case .eject: return L("duo.shortcut.eject")
        }
    }

    private func toolSymbol(_ tool: DuoToolID) -> String {
        switch tool {
        case .bluetooth: return "bluetooth"
        case .dock: return "dock.rectangle"
        case .widgets: return "square.grid.2x2"
        case .stageManager: return "rectangle.stack"
        case .mic: return "mic"
        case .desktop: return "desktopcomputer"
        case .awake: return "cup.and.saucer"
        case .clean: return "sparkles"
        case .keyboard: return "keyboard"
        case .menuBar: return "menubar.rectangle"
        case .hiddenFiles: return "eye"
        case .darkMode: return "circle.lefthalf.filled"
        case .extensions: return "doc.text"
        case .pathbar: return "rectangle.split.1x2"
        case .clipboard: return "doc.on.clipboard"
        case .sleep: return "moon.zzz"
        case .restart: return "arrow.clockwise"
        case .logout: return "rectangle.portrait.and.arrow.right"
        case .emptyTrash: return "trash"
        case .derived: return "hammer"
        case .eject: return "eject"
        }
    }

    private var wifiBinding: Binding<Bool> {
        Binding(
            get: { model.status.wifiPowerOn == true },
            set: { model.setWiFiPower($0) }
        )
    }

    private var linkSymbol: String {
        switch model.status.link {
        case .wifi(_, true): return "wifi"
        case .wifi(_, false): return "wifi.exclamationmark"
        case .wifiOff, .offline: return "wifi.slash"
        case .wifiIdle: return "wifi"
        case .ethernet: return "cable.connector"
        }
    }

    private func infoRow(title: String, value: String) -> some View {
        HStack(spacing: 8) {
            Text(title)
            Spacer(minLength: 8)
            Text(value)
                .foregroundStyle(.secondary)
        }
        .font(.system(size: 12))
    }

    private func confirmSession(_ title: String, _ message: String, run: @escaping () -> Void) {
        model.closePanel()
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: L("duo.shortcut.session.confirm"))
        alert.addButton(withTitle: L("duo.shortcut.session.cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        run()
    }

    private func menuButton(
        _ title: String,
        identifier: String,
        font: Font = DuoRowMetrics.rowLink,
        color: Color = .primary,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(font)
                .foregroundStyle(color)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
    }

    private func actionRow(
        symbol: String,
        title: String,
        subtitle: String,
        button: String,
        enabled: Bool = true,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .center, spacing: 8) {
            DuoRowIcon(symbol: symbol)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(DuoRowMetrics.title)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(subtitle)
                    .font(DuoRowMetrics.subtitle)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button(button, action: action)
                .font(.system(size: 12, weight: .medium))
                .controlSize(.small)
                .disabled(!enabled)
                .lineLimit(1)
                .accessibilityIdentifier(identifier)
        }
        .frame(minHeight: 34)
    }
}

private struct DuoSwitchRow: View {
    var symbol: String
    var title: String
    var subtitle: String?
    var isOn: Bool
    var enabled: Bool = true
    var identifier: String
    var action: (Bool) -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            DuoRowIcon(symbol: symbol)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(DuoRowMetrics.title)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let subtitle {
                    Text(subtitle)
                        .font(DuoRowMetrics.subtitle)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Toggle("", isOn: Binding(get: { isOn }, set: action))
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.small)
                .tint(Color(nsColor: .systemBlue))
                .disabled(!enabled)
                .frame(width: DuoRowMetrics.toggleWidth, alignment: .trailing)
                .accessibilityLabel(title)
                .accessibilityIdentifier(identifier)
        }
        .frame(minHeight: 32)
    }
}

private struct DuoModuleHeader: View {
    var symbol: String
    var badgeBluetooth = false
    var title: String
    var subtitle: String?
    var expanded: Bool
    var isOn: Bool
    var enabled = true
    var toggleID: String
    var expandID: String
    var expandLabel: String
    var hovering: Bool
    var onToggle: (Bool) -> Void
    var expand: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            DuoRowIcon(symbol: symbol, badge: badgeBluetooth)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(DuoRowMetrics.title)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(DuoRowMetrics.subtitle)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.trailing, hovering ? 36 : 0)
            .contentShape(Rectangle())
            .onTapGesture(perform: expand)
            Toggle("", isOn: Binding(get: { isOn }, set: onToggle))
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.small)
                .disabled(!enabled)
                .tint(Color(nsColor: .systemBlue))
                .frame(width: DuoRowMetrics.toggleWidth, alignment: .trailing)
                .accessibilityLabel(title)
                .accessibilityIdentifier(toggleID)
        }
        .overlay(alignment: .trailing) {
            Button(action: expand) {
                Image(systemName: expanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 22, height: 18)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color(nsColor: .systemBlue))
                    )
                    .frame(width: 28, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .offset(x: -48)
            .opacity(hovering ? 1 : 0)
            .allowsHitTesting(hovering)
            .accessibilityLabel(expandLabel)
            .accessibilityIdentifier(expandID)
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

private struct DuoRowIcon: View {
    var symbol: String
    var badge = false

    var body: some View {
        glyph(symbol)
            .frame(width: DuoRowMetrics.iconBox, height: DuoRowMetrics.iconBox)
            .overlay(alignment: .bottomTrailing) {
                if badge {
                    DuoBluetoothGlyph()
                        .frame(width: 8, height: 8)
                        .offset(x: 3, y: 2)
                }
            }
    }

    @ViewBuilder
    private func glyph(_ name: String) -> some View {
        if DuoSymbol.missingBluetooth(name) {
            DuoBluetoothGlyph()
        } else {
            Image(systemName: name)
                .font(.system(size: DuoRowMetrics.icon, weight: .medium))
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(Color.primary)
        }
    }
}

/// 这台系统的公开符号表里没有 `bluetooth`，`Image(systemName:)` 会画成空白。
private enum DuoSymbol {
    static func missingBluetooth(_ name: String) -> Bool {
        guard name == "bluetooth" || name.hasPrefix("bluetooth.") else { return false }
        return NSImage(systemSymbolName: name, accessibilityDescription: nil) == nil
    }
}

private struct DuoBluetoothGlyph: View {
    var body: some View {
        GeometryReader { geo in
            DuoBluetoothRune()
                .stroke(
                    Color.primary,
                    style: StrokeStyle(
                        lineWidth: max(1, min(geo.size.width, geo.size.height) * 0.08),
                        lineCap: .round,
                        lineJoin: .round
                    )
                )
        }
    }
}

private struct DuoBluetoothRune: Shape {
    func path(in rect: CGRect) -> Path {
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(
                x: rect.minX + rect.width * x / 24,
                y: rect.minY + rect.height * y / 24
            )
        }
        var path = Path()
        path.move(to: point(7, 7))
        path.addLine(to: point(17, 17))
        path.addLine(to: point(12, 22))
        path.addLine(to: point(12, 2))
        path.addLine(to: point(17, 7))
        path.addLine(to: point(7, 17))
        return path
    }
}

private struct DuoCheckRow: View {
    var title: String
    var checked: Bool
    var identifier: String
    var label: String?
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: DuoRowMetrics.iconBox, height: 16)
                    .foregroundStyle(.primary)
                    .opacity(checked ? 1 : 0)
                    .accessibilityHidden(!checked)
                Text(title)
                    .font(DuoRowMetrics.rowLink)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label ?? title)
        .accessibilityAddTraits(checked ? .isSelected : [])
        .accessibilityIdentifier(identifier)
    }
}
