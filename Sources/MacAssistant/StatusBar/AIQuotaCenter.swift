import AppKit
import ApplicationServices
import MacAssistantKit
import SwiftUI

@MainActor
final class AIQuotaCenter: ObservableObject {
    static let shared = AIQuotaCenter()

    @Published private(set) var snapshots: [AIQuotaSnapshot]
    @Published private(set) var refreshing = false
    @Published private(set) var accessibilityTrusted = false
    @Published var menuBarEnabled: Bool {
        didSet { persistAndApply(Keys.menuBar, menuBarEnabled, old: oldValue) }
    }
    @Published var dockHoverEnabled: Bool {
        didSet { persistAndApply(Keys.dockHover, dockHoverEnabled, old: oldValue) }
    }
    @Published var dockAlwaysEnabled: Bool {
        didSet { persistAndApply(Keys.dockAlways, dockAlwaysEnabled, old: oldValue) }
    }
    @Published var dockDetailEnabled: Bool {
        didSet { persistAndApply(Keys.dockDetail, dockDetailEnabled, old: oldValue) }
    }

    private let status = AIQuotaStatusController()
    private let dock = DockQuotaOverlay()
    private var refreshTimer: Timer?
    private var generation = 0

    private enum Keys {
        static let menuBar = "aiquota.menuBar"
        static let dockHover = "aiquota.dockHover"
        static let dockAlways = "aiquota.dockAlways"
        static let dockDetail = "aiquota.dockDetail"
    }

    private init() {
        snapshots = []
        menuBarEnabled = Self.stored(Keys.menuBar, default: true)
        dockHoverEnabled = Self.stored(Keys.dockHover, default: true)
        dockAlwaysEnabled = Self.stored(Keys.dockAlways, default: false)
        dockDetailEnabled = Self.stored(Keys.dockDetail, default: true)
        status.onShowPage = { [weak self] in
            self?.openPage()
        }
    }

    func install() {
        accessibilityTrusted = AXIsProcessTrusted()
        status.setVisible(false, snapshots: snapshots)
        pushDock()
        refresh(interactive: false)
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 180, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refresh(interactive: false)
            }
        }
    }

    func prepareForTermination() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        generation += 1
        dock.stop()
        status.setVisible(false, snapshots: snapshots)
    }

    func refresh(interactive: Bool) {
        generation += 1
        let ticket = generation
        refreshing = true
        status.render(snapshots, refreshing: true)
        Task {
            let loaded = await AIQuotaClient.load(interactiveKeychain: interactive)
            guard ticket == self.generation else { return }
            snapshots = loaded
            refreshing = false
            accessibilityTrusted = AXIsProcessTrusted()
            status.render(snapshots, refreshing: false)
            pushDock()
        }
    }

    func requestAccessibility() {
        if !AXIsProcessTrusted() {
            let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        }
        accessibilityTrusted = AXIsProcessTrusted()
        if !accessibilityTrusted {
            for url in PermissionGuide.settingsURLs(anchor: "Privacy_Accessibility") {
                if NSWorkspace.shared.open(url) { break }
            }
        }
        pushDock()
    }

    func openPage() {
        status.closePopover()
        DuoStatusBarController.shared.showDestination(.aiQuota)
    }

    private func persistAndApply(_ key: String, _ value: Bool, old: Bool) {
        guard value != old else { return }
        UserDefaults.standard.set(value, forKey: key)
        status.setVisible(false, snapshots: snapshots)
        pushDock()
    }

    private func pushDock() {
        let enabled = dockHoverEnabled || dockAlwaysEnabled
        dock.apply(
            enabled: enabled,
            hover: dockHoverEnabled,
            always: dockAlwaysEnabled,
            detail: dockDetailEnabled,
            snapshots: snapshots
        ) { [weak self] trusted in
            guard let self, self.accessibilityTrusted != trusted else { return }
            self.accessibilityTrusted = trusted
        }
    }

    private static func stored(_ key: String, default defaultValue: Bool) -> Bool {
        guard UserDefaults.standard.object(forKey: key) != nil else { return defaultValue }
        return UserDefaults.standard.bool(forKey: key)
    }
}

// MARK: - Menu bar

@MainActor
final class AIQuotaStatusController: NSObject, NSPopoverDelegate {
    var onShowPage: (() -> Void)?
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private var snapshots: [AIQuotaSnapshot] = []

    override init() {
        super.init()
        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self
    }

    func setVisible(_ visible: Bool, snapshots: [AIQuotaSnapshot]) {
        self.snapshots = snapshots
        if visible {
            createStatusItem()
            render(snapshots, refreshing: false)
        } else {
            closePopover()
            if let statusItem {
                NSStatusBar.system.removeStatusItem(statusItem)
                self.statusItem = nil
            }
        }
    }

    /// 没有记录过位置时，系统会把新图标排进刘海空隙，菜单栏上看不到。
    private func createStatusItem() {
        UserDefaults.standard.set(true, forKey: "NSStatusItem Visible \(Self.autosaveName)")
        if UserDefaults.standard.object(forKey: "NSStatusItem Preferred Position \(Self.autosaveName)") == nil {
            UserDefaults.standard.set(200.0, forKey: "NSStatusItem Preferred Position \(Self.autosaveName)")
        }
        if let statusItem {
            statusItem.isVisible = true
            return
        }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = Self.autosaveName
        item.behavior = .removalAllowed
        item.isVisible = true
        item.button?.target = self
        item.button?.action = #selector(togglePopover)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem = item
    }

    func render(_ snapshots: [AIQuotaSnapshot], refreshing: Bool) {
        self.snapshots = snapshots
        guard let button = statusItem?.button else { return }
        let title = AIQuotaFormat.menuTitle(snapshots)
        let symbol = NSImage(systemSymbolName: "gauge.with.dots.needle.33percent", accessibilityDescription: title)
            ?? NSImage(systemSymbolName: "gauge", accessibilityDescription: title)
        symbol?.isTemplate = true
        symbol?.size = NSSize(width: 16, height: 16)
        button.image = symbol
        button.title = title
        button.imagePosition = title.isEmpty ? .imageOnly : .imageLeading
        button.appearsDisabled = refreshing
        button.toolTip = title.isEmpty ? L("aiquota.menuBar.detail") : title
    }

    func closePopover() {
        if popover.isShown { popover.performClose(nil) }
    }

    @objc private func togglePopover() {
        guard let button = statusItem?.button else { return }
        if popover.isShown {
            closePopover()
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        let host = NSHostingController(rootView: AIQuotaPopover(onOpenPage: { [weak self] in
            self?.onShowPage?()
        }))
        popover.contentViewController = host
        popover.contentSize = NSSize(width: 720, height: 490)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        AIQuotaCenter.shared.refresh(interactive: false)
    }

    private static let autosaveName = "MacAssistantAIQuota"
}

// MARK: - Dock

@MainActor
final class DockQuotaOverlay {
    private struct Hit {
        var id: AIQuotaProviderID
        var frame: CGRect
        var snapshot: AIQuotaSnapshot
    }

    private var snapshots: [AIQuotaSnapshot] = []
    private var hoverEnabled = false
    private var alwaysOn = false
    private var detailEnabled = true
    private var running = false
    private var timer: Timer?
    private var badges: [AIQuotaProviderID: NSPanel] = [:]
    private var badgeViews: [AIQuotaProviderID: QuotaBadgeView] = [:]
    private var card: NSPanel?
    private var cardHost: NSHostingView<AIQuotaHoverCard>?
    private var cached: [DockIconLocator.Icon] = []
    private var lastLookup = Date.distantPast
    private var shown: AIQuotaProviderID?
    private var misses = 0
    private var onTrust: ((Bool) -> Void)?

    func apply(
        enabled: Bool,
        hover: Bool,
        always: Bool,
        detail: Bool,
        snapshots: [AIQuotaSnapshot],
        onTrust: @escaping (Bool) -> Void
    ) {
        hoverEnabled = hover
        alwaysOn = always
        detailEnabled = detail
        self.snapshots = snapshots
        self.onTrust = onTrust
        if enabled {
            start()
            tick()
        } else {
            stop()
        }
    }

    func stop() {
        running = false
        timer?.invalidate()
        timer = nil
        hideAll()
    }

    private func start() {
        guard !running else { return }
        running = true
        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        let trusted = AXIsProcessTrusted()
        onTrust?(trusted)
        guard trusted, hoverEnabled || alwaysOn else {
            hideAll()
            return
        }
        let mouse = NSEvent.mouseLocation
        let nearCache = cached.contains { $0.frame.insetBy(dx: -90, dy: -90).contains(mouse) }
        if nearCache || alwaysOn || shown != nil || Date().timeIntervalSince(lastLookup) > 1 {
            cached = DockIconLocator.icons()
            lastLookup = Date()
        }
        let hits: [Hit] = cached.compactMap { icon in
            guard let id = icon.provider,
                  let snapshot = snapshots.first(where: { $0.id == id && $0.state == .ready && $0.headline != nil }) else {
                return nil
            }
            return Hit(id: id, frame: icon.frame, snapshot: snapshot)
        }
        let hovered = hits.first { $0.frame.insetBy(dx: -6, dy: -6).contains(mouse) }
        // 收起的卡片还留着上次的 frame。不看 isVisible 的话，鼠标早已离开，液位也会被当成还停在卡片上。
        let cardHot = detailEnabled
            && card?.isVisible == true
            && card?.frame.insetBy(dx: -12, dy: -12).contains(mouse) == true
        if hovered != nil || cardHot {
            misses = 0
        } else {
            misses += 1
        }

        if alwaysOn {
            syncBadges(hits)
        } else if let hovered {
            syncBadges([hovered])
        } else if misses >= 1 {
            syncBadges([])
        }

        if detailEnabled, let hovered {
            showCard(hovered, edge: DockEdge.detect(hits.map(\.frame)))
            shown = hovered.id
        } else if cardHot {
            // 指针从图标移到卡片上时，两边都先留着。
        } else if misses >= 1 {
            hideCard()
            shown = nil
        }
    }

    private func syncBadges(_ hits: [Hit]) {
        let wanted = Set(hits.map(\.id))
        for (id, panel) in badges where !wanted.contains(id) {
            badgeViews[id]?.setRunning(false)
            panel.orderOut(nil)
        }
        for hit in hits {
            let panel = badges[hit.id] ?? makeBadge(for: hit.id)
            badgeViews[hit.id]?.update(
                percent: "\(hit.snapshot.headline?.remainingPercent ?? 0)%",
                level: CGFloat(hit.snapshot.headline?.remainingFraction ?? 0),
                juice: Self.juiceColor(hit.id, remaining: hit.snapshot.headline?.remainingFraction ?? 0),
                icon: AIQuotaIcons.image(for: hit.id)
            )
            badgeViews[hit.id]?.setRunning(true)
            if panel.frame.integral != hit.frame.integral {
                panel.setFrame(hit.frame, display: false)
            }
            if !panel.isVisible {
                panel.orderFrontRegardless()
            }
        }
    }

    private func showCard(_ hit: Hit, edge: DockEdge) {
        let height = AIQuotaHoverCard.preferredHeight(for: hit.snapshot)
        let size = CGSize(width: 320, height: height)
        let panel = card ?? makeCard()
        let host = cardHost
        host?.rootView = AIQuotaHoverCard(snapshot: hit.snapshot)
        let origin = DockEdge.origin(icon: hit.frame, card: size, edge: edge)
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        if let content = panel.contentView {
            content.subviews.first?.frame = content.bounds
        }
        clipCardCorners(panel)
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    /// 每个图标一种果汁。快用尽时改成橙色或红色，余量本身仍由液面高度表示。
    private static func juiceColor(_ id: AIQuotaProviderID, remaining: Double) -> NSColor {
        if remaining <= 0.05 { return .systemRed }
        if remaining <= 0.2 { return .systemOrange }
        switch id {
        case .cursor: return NSColor(srgbRed: 0.45, green: 0.38, blue: 0.95, alpha: 1)
        case .codex: return NSColor(srgbRed: 0.18, green: 0.72, blue: 0.48, alpha: 1)
        case .gemini: return NSColor(srgbRed: 0.22, green: 0.48, blue: 0.96, alpha: 1)
        case .claude: return NSColor(srgbRed: 0.86, green: 0.48, blue: 0.32, alpha: 1)
        case .grok: return NSColor(srgbRed: 0.20, green: 0.45, blue: 0.95, alpha: 1)
        case .grokBot: return NSColor(srgbRed: 0.95, green: 0.55, blue: 0.20, alpha: 1)
        case .muse: return NSColor(srgbRed: 0.55, green: 0.36, blue: 0.95, alpha: 1)
        }
    }

    private func makeBadge(for id: AIQuotaProviderID) -> NSPanel {
        let panel = makePanel(shadow: false)
        let view = QuotaBadgeView(frame: panel.contentView?.bounds ?? .zero)
        view.autoresizingMask = [.width, .height]
        panel.contentView?.addSubview(view)
        badges[id] = panel
        badgeViews[id] = view
        return panel
    }

    private func makeCard() -> NSPanel {
        let panel = makePanel(shadow: true)
        let host = NSHostingView(rootView: AIQuotaHoverCard(snapshot: .placeholder(.cursor)))
        host.wantsLayer = true
        host.layer?.isOpaque = false
        host.layer?.backgroundColor = NSColor.clear.cgColor
        let chrome = QuotaCardChrome(host: host)
        chrome.frame = panel.contentView?.bounds ?? .zero
        chrome.autoresizingMask = [.width, .height]
        panel.contentView?.addSubview(chrome)
        clipCardCorners(panel)
        card = panel
        cardHost = host
        return panel
    }

    /// 窗口四角是方的，毛玻璃圆角外面会露出一块底。按卡片半径裁掉。
    private func clipCardCorners(_ panel: NSPanel) {
        let radius = QuotaCardChrome.cornerRadius
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        for view in [panel.contentView?.superview, panel.contentView].compactMap({ $0 }) {
            view.wantsLayer = true
            view.layer?.backgroundColor = NSColor.clear.cgColor
            view.layer?.cornerRadius = radius
            view.layer?.masksToBounds = true
        }
        panel.invalidateShadow()
    }

    private final class QuotaCardChrome: NSView {
        static let cornerRadius: CGFloat = 16

        private let effect = NSVisualEffectView()
        private let host: NSView

        init(host: NSView) {
            self.host = host
            super.init(frame: .zero)
            effect.material = .menu
            effect.blendingMode = .behindWindow
            effect.state = .active
            effect.isEmphasized = false
            wantsLayer = true
            layer?.backgroundColor = NSColor.clear.cgColor
            layer?.cornerRadius = Self.cornerRadius
            layer?.masksToBounds = true
            addSubview(effect)
            addSubview(host)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            nil
        }

        override var isOpaque: Bool { false }

        override func layout() {
            super.layout()
            effect.frame = bounds
            host.frame = bounds
        }
    }

    private func makePanel(shadow: Bool) -> NSPanel {
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = shadow
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)) + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.contentView?.wantsLayer = true
        panel.contentView?.layer?.isOpaque = false
        panel.contentView?.layer?.backgroundColor = NSColor.clear.cgColor
        return panel
    }

    private func hideCard() {
        card?.orderOut(nil)
    }

    private func hideAll() {
        badgeViews.values.forEach { $0.setRunning(false) }
        badges.values.forEach { $0.orderOut(nil) }
        hideCard()
        shown = nil
        misses = 0
    }
}

/// 盖在程序坞图标上的透明层。真实图标留在后面，这里只画从底部涨上来的水位和百分比。
private final class QuotaBadgeView: NSView {
    private var percent = ""
    private var target: CGFloat = 0
    private var displayed: CGFloat = 0
    private var juice = NSColor.systemBlue
    private var running = false
    private var timer: Timer?
    private var sourceIcon: NSImage?
    private var vessel: IconVessel?
    private var vesselSide: CGFloat = 0
    private var vesselScale: CGFloat = 0

    override var isOpaque: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.isOpaque = false
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        timer?.invalidate()
    }

    func update(percent: String, level: CGFloat, juice: NSColor, icon: NSImage) {
        self.percent = percent
        target = min(1, max(0, level))
        self.juice = juice
        icon.isTemplate = false
        if sourceIcon !== icon {
            sourceIcon = icon
            vessel = nil
        }
        if running { needsDisplay = true }
    }

    func setRunning(_ on: Bool) {
        guard on != running else { return }
        running = on
        timer?.invalidate()
        timer = nil
        guard on else { return }
        displayed = 0
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            self?.step()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        step()
    }

    private func step() {
        let delta = target - displayed
        if abs(delta) < 0.004 {
            displayed = target
        } else {
            displayed += delta * 0.07
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard !percent.isEmpty, bounds.width > 8, bounds.height > 8 else { return }
        let square = iconSquare()
        guard square.width > 8, let vessel = vessel(for: square),
              let rep = composedBadge(vessel: vessel, side: square.width) else { return }
        rep.draw(in: square)
    }

    /// 格子比系统图标大一圈。底边程序坞上量过：格子 49×61 时，图标图是 47×47，
    /// 沿坞方向居中（左右各 1 点），再往屏幕边缘收 2 点，多出来的空档在屏幕内侧。
    /// 贴在内侧的话，液面就会飘在图标上方，底部的图案盖不住。
    private func iconSquare() -> NSRect {
        let frame = window?.frame ?? bounds
        let screen = window?.screen?.frame ?? NSScreen.main?.frame ?? frame
        let padding: CGFloat = 2
        let verticalDock = bounds.height > bounds.width
        let along = verticalDock ? bounds.width : bounds.height
        let side = max(8, along - padding)
        let centered = (along - side) / 2
        if verticalDock {
            let closerToBottom = frame.minY - screen.minY <= screen.maxY - frame.maxY
            let y = closerToBottom ? bounds.minY + padding : bounds.maxY - side - padding
            return NSRect(x: bounds.minX + centered, y: y, width: side, height: side)
        }
        let closerToLeft = frame.minX - screen.minX <= screen.maxX - frame.maxX
        let x = closerToLeft ? bounds.minX + padding : bounds.maxX - side - padding
        return NSRect(x: x, y: bounds.minY + centered, width: side, height: side)
    }

    private func vessel(for square: NSRect) -> IconVessel? {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        if let vessel, abs(vesselSide - square.width) < 0.5, abs(vesselScale - scale) < 0.01 {
            return vessel
        }
        guard let sourceIcon,
              let made = IconVessel.make(icon: sourceIcon, side: square.width, scale: scale) else { return nil }
        vessel = made
        vesselSide = square.width
        vesselScale = scale
        return made
    }

    /// 在一张自带透明通道的图里画水位，再用图标的不透明像素裁掉外面。
    private func composedBadge(vessel: IconVessel, side: CGFloat) -> NSBitmapImageRep? {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let pixels = max(1, Int((side * scale).rounded()))
        guard let rep = IconVessel.bitmap(pixels: pixels, side: side) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        NSColor.clear.set()
        NSRect(x: 0, y: 0, width: side, height: side).fill(using: .copy)
        drawJuice(in: vessel.tank)
        drawPercent(in: vessel.tank)
        vessel.image.draw(
            in: NSRect(x: 0, y: 0, width: side, height: side),
            from: .zero,
            operation: .destinationIn,
            fraction: 1
        )
        return rep
    }

    /// 图标轮廓是杯子，剩余额度是里面的果汁。液面一直轻轻晃。
    private func drawJuice(in tank: NSRect) {
        guard displayed > 0.004 else { return }
        let phase = CGFloat(Date().timeIntervalSinceReferenceDate * 1.6)
        let front = juiceSurface(in: tank, level: displayed, phase: phase)
        let back = juiceSurface(in: tank, level: displayed, phase: phase + 1.7)
        let tint = juice
        let foam = tint.blended(withFraction: 0.42, of: .white) ?? tint
        if let path = wavePath(tank: tank, points: back) {
            tint.withAlphaComponent(0.34).setFill()
            path.fill()
        }
        if let path = wavePath(tank: tank, points: front),
           let gradient = NSGradient(colors: [
            foam.withAlphaComponent(0.62),
            tint.withAlphaComponent(0.86)
           ]) {
            gradient.draw(in: path, angle: 90)
        }
        drawBubbles(in: tank, surface: front, phase: phase)
        stroke(front, color: NSColor.white.withAlphaComponent(0.88), width: max(0.9, tank.width * 0.018))
    }

    private func juiceSurface(in rect: CGRect, level: CGFloat, phase: CGFloat) -> [CGPoint] {
        let clamped = min(1, max(0, level))
        let room = min(clamped, 1 - clamped)
        let amplitude = min(2.4, max(0.6, rect.height * 0.04)) * min(1, room / 0.08)
        let base = rect.minY + rect.height * clamped
        let steps = 24
        var points: [CGPoint] = []
        points.reserveCapacity(steps + 1)
        for index in 0...steps {
            let t = CGFloat(index) / CGFloat(steps)
            let x = rect.minX + rect.width * t
            let wave = sin(t * .pi * 2 * 1.15 + phase) * amplitude
                + sin(t * .pi * 2 * 2.1 + phase * 1.35) * amplitude * 0.28
            points.append(CGPoint(x: x, y: base + wave))
        }
        return points
    }

    private func drawBubbles(in tank: NSRect, surface: [CGPoint], phase: CGFloat) {
        guard displayed > 0.14, let top = surface.map(\.y).min() else { return }
        let seeds: [(CGFloat, CGFloat, CGFloat)] = [(0.32, 0.37, 1.7), (0.68, 0.23, 1.2)]
        NSColor.white.withAlphaComponent(0.55).setFill()
        for (xFrac, speed, radius) in seeds {
            let cycle = (phase * speed / (.pi * 2)).truncatingRemainder(dividingBy: 1)
            let travel = cycle < 0 ? cycle + 1 : cycle
            let y = tank.minY + 3 + travel * max(4, top - tank.minY - 6)
            let x = tank.minX + tank.width * xFrac + sin(phase * speed) * 1.2
            NSBezierPath(ovalIn: NSRect(x: x, y: y, width: radius, height: radius)).fill()
        }
    }

    private func wavePath(tank: NSRect, points: [CGPoint]) -> NSBezierPath? {
        guard let first = points.first else { return nil }
        let path = NSBezierPath()
        path.move(to: NSPoint(x: tank.minX, y: tank.minY - 2))
        path.line(to: first)
        for point in points.dropFirst() {
            path.line(to: point)
        }
        path.line(to: NSPoint(x: tank.maxX, y: tank.minY - 2))
        path.close()
        return path
    }

    private func stroke(_ points: [CGPoint], color: NSColor, width: CGFloat) {
        guard let first = points.first else { return }
        let path = NSBezierPath()
        path.move(to: first)
        for point in points.dropFirst() {
            path.line(to: point)
        }
        path.lineWidth = width
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        color.setStroke()
        path.stroke()
    }

    private func drawPercent(in tank: NSRect) {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.55)
        shadow.shadowBlurRadius = 2
        shadow.shadowOffset = .zero
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: min(13, max(8, tank.width * 0.16)), weight: .bold),
            .foregroundColor: NSColor.white,
            .paragraphStyle: style,
            .shadow: shadow
        ]
        let text = percent as NSString
        let size = text.size(withAttributes: attributes)
        let juiceTop = tank.minY + tank.height * displayed
        let y = min(tank.minY + tank.height * 0.08, max(tank.minY + 1, juiceTop - size.height - 2))
        text.draw(
            in: NSRect(x: tank.minX, y: y, width: tank.width, height: size.height),
            withAttributes: attributes
        )
    }
}

/// 图标不透明区域。水位只在这个轮廓里涨，百分比也落在里面。
private struct IconVessel {
    var image: NSImage
    var tank: NSRect

    static func make(icon: NSImage, side: CGFloat, scale: CGFloat) -> IconVessel? {
        let pixels = max(1, Int((side * scale).rounded()))
        guard let rep = bitmap(pixels: pixels, side: side) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        NSColor.clear.set()
        NSRect(x: 0, y: 0, width: side, height: side).fill(using: .copy)
        icon.draw(in: NSRect(x: 0, y: 0, width: side, height: side), from: .zero, operation: .sourceOver, fraction: 1)
        guard let tank = opaqueTank(rep: rep, side: side) else { return nil }
        let image = NSImage(size: NSSize(width: side, height: side))
        image.addRepresentation(rep)
        return IconVessel(image: image, tank: tank)
    }

    fileprivate static func bitmap(pixels: Int, side: CGFloat) -> NSBitmapImageRep? {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixels,
            pixelsHigh: pixels,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }
        rep.size = NSSize(width: side, height: side)
        return rep
    }

    /// 像素行 0 在上方。返回的矩形用 AppKit 坐标，y 向上，单位是点。
    private static func opaqueTank(rep: NSBitmapImageRep, side: CGFloat) -> NSRect? {
        guard let data = rep.bitmapData else { return nil }
        let width = rep.pixelsWide
        let height = rep.pixelsHigh
        let bytesPerPixel = max(rep.bitsPerPixel / 8, 1)
        let bytesPerRow = rep.bytesPerRow
        guard width > 2, height > 2, bytesPerPixel >= 4 else { return nil }
        func sample(_ x: Int, _ y: Int) -> UnsafeMutablePointer<UInt8> {
            data.advanced(by: y * bytesPerRow + x * bytesPerPixel)
        }
        let corner = sample(0, 0)
        let center = sample(width / 2, height / 2)
        var alphaIndex = bytesPerPixel - 1
        var best = -1
        for index in 0..<min(4, bytesPerPixel) {
            let score = Int(center[index]) - Int(corner[index])
            if score > best {
                best = score
                alphaIndex = index
            }
        }
        let full = NSRect(x: 0, y: 0, width: side, height: side)
        guard best > 40 else { return full }
        var minX = width
        var minY = height
        var maxX = 0
        var maxY = 0
        for y in 0..<height {
            let row = data.advanced(by: y * bytesPerRow)
            for x in 0..<width where row[x * bytesPerPixel + alphaIndex] > 24 {
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        let imageWidth = CGFloat(width)
        let imageHeight = CGFloat(height)
        let left = CGFloat(minX) / imageWidth * side
        let right = CGFloat(maxX + 1) / imageWidth * side
        let top = CGFloat(minY) / imageHeight * side
        let bottom = CGFloat(maxY + 1) / imageHeight * side
        return NSRect(x: left, y: side - bottom, width: max(1, right - left), height: max(1, bottom - top))
    }
}

private enum DockEdge {
    case bottom, top, left, right

    static func detect(_ frames: [CGRect]) -> DockEdge {
        guard let first = frames.first,
              let screen = NSScreen.screens.first(where: { $0.frame.intersects(first) }) else { return .bottom }
        let bounds = screen.frame
        let midX = frames.reduce(0) { $0 + $1.midX } / CGFloat(frames.count)
        let midY = frames.reduce(0) { $0 + $1.midY } / CGFloat(frames.count)
        let distances = [
            (DockEdge.bottom, midY - bounds.minY),
            (.top, bounds.maxY - midY),
            (.left, midX - bounds.minX),
            (.right, bounds.maxX - midX)
        ]
        return distances.min { $0.1 < $1.1 }?.0 ?? .bottom
    }

    static func origin(icon: CGRect, card: CGSize, edge: DockEdge) -> CGPoint {
        let screen = NSScreen.screens.first { $0.frame.intersects(icon) }
        let visible = screen?.visibleFrame ?? icon
        let origin: CGPoint
        switch edge {
        case .bottom:
            origin = CGPoint(x: icon.midX - card.width / 2, y: icon.maxY + 10)
        case .top:
            origin = CGPoint(x: icon.midX - card.width / 2, y: icon.minY - card.height - 10)
        case .left:
            origin = CGPoint(x: icon.maxX + 10, y: icon.midY - card.height / 2)
        case .right:
            origin = CGPoint(x: icon.minX - card.width - 10, y: icon.midY - card.height / 2)
        }
        return CGPoint(
            x: min(max(origin.x, visible.minX + 8), visible.maxX - card.width - 8),
            y: min(max(origin.y, visible.minY + 8), visible.maxY - card.height - 8)
        )
    }
}

enum DockIconLocator {
    struct Icon {
        var provider: AIQuotaProviderID?
        var frame: CGRect
    }

    static func icons() -> [Icon] {
        guard AXIsProcessTrusted(),
              let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else {
            return []
        }
        let application = AXUIElementCreateApplication(dock.processIdentifier)
        var found: [Icon] = []
        for child in axChildren(application) {
            walk(child, into: &found, depth: 0)
        }
        return found
    }

    private static func walk(_ element: AXUIElement, into found: inout [Icon], depth: Int) {
        guard depth <= 6 else { return }
        if let frame = axFrame(element), isIcon(frame) {
            let title = axString(element, kAXTitleAttribute) ?? ""
            let bundle = axString(element, kAXURLAttribute).flatMap(bundleID(from:))
            let provider = AIQuotaProviderID.allCases.first { id in
                if let bundle, id.bundleIDs.contains(bundle) { return true }
                return bundle == nil && id.dockNames.contains(title)
            }
            found.append(Icon(provider: provider, frame: frame))
            return
        }
        for child in axChildren(element) {
            walk(child, into: &found, depth: depth + 1)
        }
    }

    private static func isIcon(_ frame: CGRect) -> Bool {
        guard frame.width >= 16, frame.height >= 16, frame.width <= 320, frame.height <= 320 else { return false }
        return frame.width / frame.height < 1.7 && frame.height / frame.width < 1.7
    }

    private static func axChildren(_ element: AXUIElement) -> [AXUIElement] {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &raw) == .success,
              let raw else { return [] }
        if let list = raw as? [AXUIElement] { return list }
        guard let array = raw as? NSArray else { return [] }
        return array.compactMap { item in
            let type = item as CFTypeRef
            guard CFGetTypeID(type) == AXUIElementGetTypeID() else { return nil }
            return (type as! AXUIElement)
        }
    }

    private static func axString(_ element: AXUIElement, _ attribute: String) -> String? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success, let raw else {
            return nil
        }
        if let text = raw as? String { return text }
        if let url = raw as? URL { return url.absoluteString }
        return nil
    }

    private static func axFrame(_ element: AXUIElement) -> CGRect? {
        var position: CFTypeRef?
        var size: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &position) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &size) == .success,
              let position, let size,
              CFGetTypeID(position) == AXValueGetTypeID(),
              CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        var dimensions = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &point),
              AXValueGetValue(size as! AXValue, .cgSize, &dimensions) else { return nil }
        let raw = CGRect(origin: point, size: dimensions)
        let primary = NSScreen.screens.first { $0.frame.origin == .zero } ?? NSScreen.screens.first
        let flipped = CGRect(
            x: point.x,
            y: (primary?.frame.height ?? 0) - point.y - dimensions.height,
            width: dimensions.width,
            height: dimensions.height
        )
        func onScreen(_ rect: CGRect) -> Bool {
            NSScreen.screens.contains { $0.frame.intersects(rect) }
        }
        if onScreen(flipped) { return flipped }
        if onScreen(raw) { return raw }
        return flipped
    }

    private static func bundleID(from raw: String) -> String? {
        let url: URL?
        if raw.hasPrefix("file:") {
            url = URL(string: raw)
        } else if raw.hasPrefix("/") {
            url = URL(fileURLWithPath: raw)
        } else {
            url = nil
        }
        guard var current = url else { return nil }
        while current.path != "/" {
            if current.pathExtension == "app" {
                return Bundle(url: current)?.bundleIdentifier
            }
            current.deleteLastPathComponent()
        }
        return nil
    }
}
