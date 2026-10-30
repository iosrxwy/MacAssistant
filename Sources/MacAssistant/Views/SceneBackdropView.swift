import SwiftUI
import AppKit
import MacAssistantKit

private struct SceneBackdropEnvironmentKey: EnvironmentKey {
    static let defaultValue = SceneBackdropID.system
}

extension EnvironmentValues {
    var sceneBackdrop: SceneBackdropID {
        get { self[SceneBackdropEnvironmentKey.self] }
        set { self[SceneBackdropEnvironmentKey.self] = newValue }
    }
}

extension SceneColor {
    var color: Color {
        Color(.sRGB, red: red, green: green, blue: blue, opacity: 1)
    }

    var nsColor: NSColor {
        NSColor(srgbRed: red, green: green, blue: blue, alpha: 1)
    }
}

private struct ScenePointerSample {
    var position: CGPoint
    var velocity: CGPoint

    static let idle = ScenePointerSample(position: CGPoint(x: 0.5, y: 0.5), velocity: .zero)
}

/// 鼠标在窗口里的归一化位置与速度。不走 @Published，由 TimelineView 每帧取样。
private final class ScenePointerMonitor {
    static let shared = ScenePointerMonitor()
    private let lock = NSLock()
    private var raw = CGPoint(x: 0.5, y: 0.5)
    private var eased = CGPoint(x: 0.5, y: 0.5)
    private var velocity = CGPoint.zero
    private var token: Any?
    /// 侧栏和内容区各有一条时间线，同一帧里会各取一次样。只推进一次缓动。
    private var lastSampleTime = -1.0

    func start() {
        guard token == nil else { return }
        token = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] event in
            let window = event.window ?? NSApp.keyWindow
            guard let window else { return event }
            let size = window.frame.size
            guard size.width > 1, size.height > 1 else { return event }
            let loc = event.locationInWindow
            let point = CGPoint(
                x: min(1, max(0, loc.x / size.width)),
                y: min(1, max(0, 1 - loc.y / size.height))
            )
            self?.lock.lock()
            self?.raw = point
            self?.lock.unlock()
            return event
        }
    }

    func sample() -> ScenePointerSample {
        let now = Date().timeIntervalSinceReferenceDate
        lock.lock()
        defer { lock.unlock() }
        if now - lastSampleTime < (1.0 / 30.0) {
            return ScenePointerSample(position: eased, velocity: velocity)
        }
        lastSampleTime = now
        let next = CGPoint(
            x: eased.x + (raw.x - eased.x) * 0.16,
            y: eased.y + (raw.y - eased.y) * 0.16
        )
        let inst = CGPoint(x: next.x - eased.x, y: next.y - eased.y)
        velocity = CGPoint(
            x: velocity.x * 0.72 + inst.x * 0.28,
            y: velocity.y * 0.72 + inst.y * 0.28
        )
        eased = next
        return ScenePointerSample(position: eased, velocity: velocity)
    }

    /// 粒子从指针处分开，像水流让开笔锋。
    static func part(_ point: CGPoint, around sample: ScenePointerSample?) -> CGPoint {
        guard let sample else { return point }
        let dx = point.x - sample.position.x
        let dy = point.y - sample.position.y
        let dist = max(0.0008, hypot(dx, dy))
        let radius = 0.24
        guard dist < radius else { return point }
        let falloff = pow(1 - dist / radius, 2)
        let nx = dx / dist
        let ny = dy / dist
        let speed = min(1.2, hypot(sample.velocity.x, sample.velocity.y) * 22)
        var ox = nx * falloff * (0.05 + 0.05 * speed)
        var oy = ny * falloff * (0.05 + 0.05 * speed)
        if speed > 0.015 {
            let vlen = max(0.0001, hypot(sample.velocity.x, sample.velocity.y))
            let tx = -sample.velocity.y / vlen
            let ty = sample.velocity.x / vlen
            let side = (dx * tx + dy * ty) >= 0 ? 1.0 : -1.0
            ox += tx * side * falloff * 0.04 * speed
            oy += ty * side * falloff * 0.04 * speed
            ox += (sample.velocity.x / vlen) * falloff * 0.018 * speed
            oy += (sample.velocity.y / vlen) * falloff * 0.018 * speed
        }
        return CGPoint(
            x: min(1.15, max(-0.15, point.x + ox)),
            y: min(1.15, max(-0.15, point.y + oy))
        )
    }
}

/// 按窗口坐标系切片绘制，侧栏和内容区是同一张背景，而不是各自缩略一遍。
struct WindowAlignedBackdrop: View {
    let recipe: SceneBackdropRecipe
    var animated = false
    var reduceTransparency = false
    var showsVeil = true

    @State private var windowSize: CGSize = .zero
    @State private var originInWindow: CGPoint = .zero

    var body: some View {
        GeometryReader { geo in
            let aligned = windowSize.width > 8 && windowSize.height > 8
            let size = aligned ? windowSize : geo.size
            let origin = aligned ? originInWindow : .zero
            SceneBackdropCanvas(
                recipe: recipe,
                animated: animated,
                reduceTransparency: reduceTransparency,
                showsVeil: showsVeil
            )
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .offset(x: -origin.x, y: -origin.y)
        }
        .clipped()
        .allowsHitTesting(false)
        .background(WindowFrameProbe(size: $windowSize, origin: $originInWindow))
    }
}

private struct WindowFrameProbe: NSViewRepresentable {
    @Binding var size: CGSize
    @Binding var origin: CGPoint

    func makeNSView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.onChange = { nextSize, nextOrigin in
            DispatchQueue.main.async {
                if abs(size.width - nextSize.width) > 0.5
                    || abs(size.height - nextSize.height) > 0.5
                    || abs(origin.x - nextOrigin.x) > 0.5
                    || abs(origin.y - nextOrigin.y) > 0.5 {
                    size = nextSize
                    origin = nextOrigin
                }
            }
        }
        return view
    }

    func updateNSView(_ view: ProbeView, context: Context) {
        view.onChange = { nextSize, nextOrigin in
            DispatchQueue.main.async {
                if abs(size.width - nextSize.width) > 0.5
                    || abs(size.height - nextSize.height) > 0.5
                    || abs(origin.x - nextOrigin.x) > 0.5
                    || abs(origin.y - nextOrigin.y) > 0.5 {
                    size = nextSize
                    origin = nextOrigin
                }
            }
        }
        view.report()
    }

    final class ProbeView: NSView {
        var onChange: ((CGSize, CGPoint) -> Void)?
        private var observer: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let observer {
                NotificationCenter.default.removeObserver(observer)
                self.observer = nil
            }
            if let window {
                observer = NotificationCenter.default.addObserver(
                    forName: NSWindow.didResizeNotification,
                    object: window,
                    queue: .main
                ) { [weak self] _ in
                    self?.report()
                }
            }
            report()
        }

        deinit {
            if let observer {
                NotificationCenter.default.removeObserver(observer)
            }
        }

        func report() {
            guard let window else { return }
            let rect = convert(bounds, to: nil)
            let size = window.frame.size
            let origin = CGPoint(x: rect.minX, y: size.height - rect.maxY)
            onChange?(size, origin)
        }
    }
}

struct WindowSceneChrome: NSViewRepresentable {
    var immersive: Bool
    var chrome = SidebarChromePolicy.resolve(
        appearance: .material,
        decorativeScene: false,
        reduceTransparency: false
    )
    var recipe: SceneBackdropRecipe?
    var animated = false
    var reduceTransparency = false

    func makeNSView(context: Context) -> ChromeView {
        ChromeView()
    }

    func updateNSView(_ view: ChromeView, context: Context) {
        let changed = view.immersive != immersive
            || view.chrome != chrome
            || view.recipe != recipe
            || view.animated != animated
            || view.reduceTransparency != reduceTransparency
        view.immersive = immersive
        view.chrome = chrome
        view.recipe = recipe
        view.animated = animated
        view.reduceTransparency = reduceTransparency
        if changed || !view.didApplyOnce {
            view.didApplyOnce = true
            view.scheduleApply()
        }
    }

    final class ChromeView: NSView {
        var immersive = false
        var chrome = SidebarChromePolicy.resolve(
            appearance: .material,
            decorativeScene: false,
            reduceTransparency: false
        )
        var recipe: SceneBackdropRecipe?
        var animated = false
        var reduceTransparency = false
        var didApplyOnce = false
        private var applying = false
        private var applyGeneration = 0
        private var hosting: NSHostingView<SceneBackdropCanvas>?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            scheduleApply()
        }

        override func layout() {
            super.layout()
            guard let window else { return }
            // SwiftUI 会在布局后再把整窗 hosting view 放到标题栏前面。
            raiseTitlebar(in: window)
        }

        func scheduleApply() {
            applyGeneration += 1
            let generation = applyGeneration
            apply()
            // SwiftUI 会在这一帧之后才铺好侧栏玻璃，所以下一拍和短延迟再刷一次。
            DispatchQueue.main.async { [weak self] in
                guard let self, self.applyGeneration == generation else { return }
                self.apply()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
                guard let self, self.applyGeneration == generation else { return }
                self.apply()
            }
        }

        func apply() {
            guard let window, !applying else { return }
            applying = true
            defer { applying = false }

            // 页面里已有大标题，顶栏再写一遍会和内容撞在一起。
            window.titleVisibility = .hidden
            window.title = L("root.appName")

            if !window.styleMask.contains(.fullSizeContentView) {
                window.styleMask.insert(.fullSizeContentView)
            }
            window.titlebarAppearsTransparent = true
            if #available(macOS 11.0, *) {
                window.titlebarSeparatorStyle = .none
            }

            if chrome.windowOpaque {
                window.isOpaque = true
                window.backgroundColor = .windowBackgroundColor
            } else {
                window.isOpaque = false
                // 用配方底色兜住顶栏，避免 macOS 26 交通灯胶囊透出系统青。
                window.backgroundColor = recipe?.base.nsColor ?? .clear
            }

            installBackdrop(in: window)
            configureSplitItems(in: window)
            raiseTitlebar(in: window)

            if let theme = window.contentView?.superview {
                neutralize(theme)
            }
            if let content = window.contentView {
                neutralize(content)
            }
        }

        private func configureSplitItems(in window: NSWindow) {
            func walk(_ controller: NSViewController?) {
                guard let controller else { return }
                if let split = controller as? NSSplitViewController {
                    let sidebarItems = split.splitViewItems.filter { $0.behavior == .sidebar }
                    let resolvedSidebar = sidebarItems.isEmpty
                        ? Array(split.splitViewItems.prefix(1))
                        : sidebarItems
                    let sidebarIDs = Set(resolvedSidebar.map(ObjectIdentifier.init))
                    for item in split.splitViewItems {
                        item.allowsFullHeightLayout = true
                        if #available(macOS 11.0, *) {
                            item.titlebarSeparatorStyle = .none
                        }
                        let isSidebar = sidebarIDs.contains(ObjectIdentifier(item))
                        paintSplitPane(item.viewController.view, sidebar: isSidebar)
                    }
                }
                controller.children.forEach(walk)
            }
            walk(window.contentViewController)
        }

        private func paintSplitPane(_ view: NSView, sidebar: Bool) {
            view.wantsLayer = true
            if sidebar && (chrome.hidesSidebarMaterial || chrome.usesClearSidebarGlass) {
                view.layer?.backgroundColor = CGColor.clear
            } else if immersive {
                view.layer?.backgroundColor = CGColor.clear
            } else {
                view.layer?.backgroundColor = nil
            }
        }

        /// SwiftUI 的 hosting view 铺满整窗，并且排在标题栏容器前面。
        /// 交通灯和侧栏开关都在标题栏里，不抬上来就看不见。
        private func raiseTitlebar(in window: NSWindow) {
            guard let theme = window.contentView?.superview else { return }
            guard let titlebar = theme.subviews.first(where: {
                String(describing: type(of: $0)).contains("TitlebarContainer")
            }) else { return }
            if theme.subviews.last !== titlebar {
                theme.addSubview(titlebar)
            }
            if titlebar.layer?.zPosition != 1000 {
                titlebar.wantsLayer = true
                titlebar.layer?.zPosition = 1000
            }
            // 页面大标题已经占了内容区。空的标题视图仍横向铺满，会挡住右上角的控件。
            if window.titleVisibility == .hidden {
                hideEmptyTitleView(in: titlebar)
            }
            for kind: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
                window.standardWindowButton(kind)?.isHidden = false
            }
        }

        private func hideEmptyTitleView(in root: NSView) {
            var stack = [root]
            while let view = stack.popLast() {
                if String(describing: type(of: view)).contains("ToolbarTitleView") {
                    view.isHidden = true
                }
                stack.append(contentsOf: view.subviews)
            }
        }

        private func installBackdrop(in window: NSWindow) {
            guard let content = window.contentView else { return }
            if immersive, let recipe {
                let canvas = SceneBackdropCanvas(
                    recipe: recipe,
                    animated: animated && !reduceTransparency,
                    reduceTransparency: reduceTransparency,
                    showsVeil: false
                )
                if let hosting {
                    hosting.rootView = canvas
                } else {
                    let view = NSHostingView(rootView: canvas)
                    view.autoresizingMask = [.width, .height]
                    hosting = view
                }
                guard let hosting else { return }
                hosting.frame = content.bounds
                // `relativeTo: nil` 在这套系统上会把视图放到最前，动画底盖住侧栏和内容。
                // 挂到现有最底层那张视图的后面，才能留在 SwiftUI 内容之下。
                if let anchor = content.subviews.first(where: { $0 !== hosting }) {
                    content.addSubview(hosting, positioned: .below, relativeTo: anchor)
                } else if hosting.superview !== content {
                    content.addSubview(hosting)
                }
                hosting.wantsLayer = true
                hosting.layer?.zPosition = -1000
            } else {
                hosting?.removeFromSuperview()
                hosting = nil
            }
        }

        private func neutralize(_ root: NSView) {
            var stack = [root]
            while let view = stack.popLast() {
                if view === hosting { continue }
                if let effect = view as? NSVisualEffectView {
                    tuneVisualEffect(effect)
                }
                if let field = view as? NSTextField {
                    NativeFieldChrome.stripBezel(field)
                }
                tuneGlassEffect(view)
                if let split = view as? NSSplitView {
                    tuneSplitView(split)
                }
                if looksLikeSidebarChrome(view) {
                    let clearFill = chrome.hidesSidebarMaterial || chrome.usesClearSidebarGlass
                    if let scroll = view as? NSScrollView {
                        scroll.drawsBackground = !clearFill
                        if clearFill {
                            scroll.backgroundColor = .clear
                        }
                    }
                    if let table = view as? NSTableView, clearFill {
                        table.backgroundColor = .clear
                    }
                }
                stack.append(contentsOf: view.subviews)
            }
        }

        private func tuneSplitView(_ split: NSSplitView) {
            if !chrome.windowOpaque {
                split.wantsLayer = true
                split.layer?.backgroundColor = CGColor.clear
            } else {
                split.layer?.backgroundColor = nil
            }
            let panes = split.arrangedSubviews
            guard panes.count >= 2 else { return }
            paintSplitPane(panes[0], sidebar: true)
            for pane in panes.dropFirst() {
                paintSplitPane(pane, sidebar: false)
            }
        }

        private func tuneVisualEffect(_ effect: NSVisualEffectView) {
            if isInTitlebar(effect) || effect.material == .titlebar || effect.material == .headerView {
                effect.isHidden = immersive
                if !immersive {
                    effect.blendingMode = .behindWindow
                }
                return
            }

            let sidebarChrome = looksLikeSidebarChrome(effect) || effect.material == .sidebar
            if sidebarChrome {
                if chrome.hidesSidebarMaterial, canHideAsBackdrop(effect) {
                    effect.isHidden = true
                } else if chrome.hidesSidebarMaterial || chrome.usesClearSidebarGlass {
                    effect.isHidden = false
                    effect.blendingMode = .behindWindow
                    effect.material = .underWindowBackground
                    effect.state = .active
                } else {
                    effect.isHidden = false
                    effect.blendingMode = chrome.blendsMaterialWithinWindow ? .withinWindow : .behindWindow
                    if effect.material == .underWindowBackground {
                        effect.material = .sidebar
                    }
                }
                return
            }

            effect.isHidden = false
            effect.blendingMode = immersive ? .withinWindow : .behindWindow
        }

        private func tuneGlassEffect(_ view: NSView) {
            guard isGlassEffectView(view), looksLikeSidebarChrome(view) else { return }
            if chrome.hidesSidebarMaterial {
                setGlassStyle(view, clear: true)
                setGlassBackdropHidden(view, hidden: true)
            } else if chrome.usesClearSidebarGlass {
                setGlassStyle(view, clear: true)
                setGlassBackdropHidden(view, hidden: false)
            } else {
                setGlassStyle(view, clear: false)
                setGlassBackdropHidden(view, hidden: false)
            }
        }

        private func isGlassEffectView(_ view: NSView) -> Bool {
            let name = String(describing: type(of: view))
            return name.contains("GlassEffectView") && !name.contains("Container")
        }

        private func setGlassStyle(_ view: NSView, clear: Bool) {
            // macOS 14 SDK 没有 NSGlassEffectView。新编译器才走类型，旧编译器用 KVC。
#if compiler(>=6.2)
            if #available(macOS 26.0, *), let glass = view as? NSGlassEffectView {
                glass.style = clear ? .clear : .regular
                glass.tintColor = nil
                return
            }
#endif
            view.setValue(clear ? 1 : 0, forKey: "style")
        }

        private func setGlassBackdropHidden(_ view: NSView, hidden: Bool) {
            let content: NSView?
#if compiler(>=6.2)
            if #available(macOS 26.0, *), let glass = view as? NSGlassEffectView {
                content = glass.contentView
            } else {
                content = view.value(forKey: "contentView") as? NSView
            }
#else
            content = view.value(forKey: "contentView") as? NSView
#endif
            for sub in view.subviews where sub !== content {
                let name = String(describing: type(of: sub))
                let looksLikeMaterial = name.contains("Backdrop")
                    || name.contains("Material")
                    || name.contains("Glass")
                    || name.contains("Effect")
                    || name.contains("Visual")
                if content != nil || looksLikeMaterial {
                    sub.alphaValue = hidden ? 0 : 1
                }
            }
        }

        private func canHideAsBackdrop(_ effect: NSVisualEffectView) -> Bool {
            effect.subviews.isEmpty || effect.subviews.allSatisfy { sub in
                sub is NSVisualEffectView || String(describing: type(of: sub)).contains("Backdrop")
            }
        }

        private func looksLikeSidebarChrome(_ view: NSView) -> Bool {
            if isInSidebarColumn(view) { return true }
            guard isGlassEffectView(view) || (view as? NSVisualEffectView)?.material == .sidebar else {
                return false
            }
            guard let window else { return false }
            let frame = view.convert(view.bounds, to: nil)
            return frame.minX < 24
                && frame.width < window.frame.width * 0.45
                && frame.height > window.frame.height * 0.45
        }

        private func isInSidebarColumn(_ view: NSView) -> Bool {
            var current: NSView? = view
            while let node = current {
                if let split = node.superview as? NSSplitView, split.isVertical {
                    guard let first = split.arrangedSubviews.first else { return false }
                    return node === first || node.isDescendant(of: first)
                }
                current = node.superview
            }
            return false
        }

        private func isInTitlebar(_ view: NSView) -> Bool {
            var current: NSView? = view
            while let node = current {
                let name = String(describing: type(of: node))
                if name.contains("Titlebar") { return true }
                current = node.superview
            }
            return false
        }
    }
}

/// 窗口不在前台、被完全挡住或缩进程序坞时，背景动画停掉。
private struct SceneMotionPauseProbe: NSViewRepresentable {
    var onPauseChange: (Bool) -> Void

    func makeNSView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.onPauseChange = onPauseChange
        return view
    }

    func updateNSView(_ view: ProbeView, context: Context) {
        view.onPauseChange = onPauseChange
    }

    final class ProbeView: NSView {
        var onPauseChange: ((Bool) -> Void)?
        private var observers: [NSObjectProtocol] = []
        private var lastPaused: Bool?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach { NotificationCenter.default.removeObserver($0) }
            observers.removeAll()
            observe(NSApplication.didBecomeActiveNotification, object: NSApp)
            observe(NSApplication.didResignActiveNotification, object: NSApp)
            if let window {
                observe(NSWindow.didChangeOcclusionStateNotification, object: window)
                observe(NSWindow.didMiniaturizeNotification, object: window)
                observe(NSWindow.didDeminiaturizeNotification, object: window)
            }
            publish()
        }

        deinit {
            observers.forEach { NotificationCenter.default.removeObserver($0) }
        }

        private func observe(_ name: Notification.Name, object: Any?) {
            let token = NotificationCenter.default.addObserver(
                forName: name,
                object: object,
                queue: .main
            ) { [weak self] _ in
                self?.publish()
            }
            observers.append(token)
        }

        private func publish() {
            let paused = Self.shouldPause(window: window)
            guard paused != lastPaused else { return }
            lastPaused = paused
            let callback = onPauseChange
            DispatchQueue.main.async {
                callback?(paused)
            }
        }

        private static func shouldPause(window: NSWindow?) -> Bool {
            guard NSApp.isActive else { return true }
            guard let window else { return false }
            if window.isMiniaturized { return true }
            return !window.occlusionState.contains(.visible)
        }
    }
}

/// 背景漂移大约一分半一个来回，12 帧就连续。窗口不在前台时暂停。
private struct SceneMotionClock<Content: View>: View {
    var animated: Bool
    var paused: Bool
    var reduceTransparency: Bool
    @ViewBuilder var content: (TimeInterval, ScenePointerSample?) -> Content

    var body: some View {
        if animated && !reduceTransparency {
            TimelineView(.animation(minimumInterval: Self.frameInterval, paused: paused)) { timeline in
                content(
                    timeline.date.timeIntervalSinceReferenceDate,
                    ScenePointerMonitor.shared.sample()
                )
            }
            .onAppear { ScenePointerMonitor.shared.start() }
        } else {
            content(0, nil)
        }
    }

    private static var frameInterval: TimeInterval { 1.0 / 12.0 }
}

/// 颗粒、网点、横线和圆环不随时间变，从每帧重绘里拆出来。
private struct SceneOverlayBands {
    var before: [SceneOverlay] = []
    var baked: [SceneOverlay] = []
    var after: [SceneOverlay] = []

    init(_ overlays: [SceneOverlay]) {
        var index = overlays.startIndex
        while index < overlays.endIndex, !overlays[index].isBaked {
            before.append(overlays[index])
            index = overlays.index(after: index)
        }
        while index < overlays.endIndex, overlays[index].isBaked {
            baked.append(overlays[index])
            index = overlays.index(after: index)
        }
        if index < overlays.endIndex {
            after.append(contentsOf: overlays[index...])
        }
    }
}

private extension SceneOverlay {
    var isBaked: Bool {
        switch self {
        case .paperLines, .dots, .rings, .grain:
            return true
        case .hills, .spotlight, .stars:
            return false
        }
    }
}

/// 按配方绘制页面背景。macOS 15+ 用 MeshGradient，旧系统退回径向光斑。
struct SceneBackdropCanvas: View {
    let recipe: SceneBackdropRecipe
    var animated = false
    var reduceTransparency = false
    var showsVeil = true

    /// 先停着，等探到窗口在前台再动，避免一创建就空转。
    @State private var motionPaused = true

    private var bands: SceneOverlayBands {
        SceneOverlayBands(recipe.overlays)
    }

    var body: some View {
        ZStack {
            SceneMotionClock(
                animated: animated,
                paused: motionPaused,
                reduceTransparency: reduceTransparency
            ) { time, pointer in
                ZStack {
                    baseLayer(time: time, pointer: pointer)
                    if !reduceTransparency {
                        Canvas { context, size in
                            drawBlobs(context: &context, size: size, time: time, pointer: pointer)
                            if pointer != nil {
                                drawMotes(context: &context, size: size, time: time, pointer: pointer)
                                drawWake(context: &context, size: size, pointer: pointer)
                            }
                            if !bands.before.isEmpty {
                                drawOverlayList(
                                    context: &context,
                                    size: size,
                                    overlays: bands.before,
                                    time: time,
                                    pointer: pointer
                                )
                            }
                        }
                    }
                }
            }
            if !reduceTransparency, !bands.baked.isEmpty {
                Canvas { context, size in
                    drawOverlayList(
                        context: &context,
                        size: size,
                        overlays: bands.baked,
                        time: 0,
                        pointer: nil
                    )
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .allowsHitTesting(false)
            }
            if !reduceTransparency, !bands.after.isEmpty {
                SceneMotionClock(
                    animated: animated,
                    paused: motionPaused,
                    reduceTransparency: reduceTransparency
                ) { time, pointer in
                    Canvas { context, size in
                        drawOverlayList(
                            context: &context,
                            size: size,
                            overlays: bands.after,
                            time: time,
                            pointer: pointer
                        )
                    }
                }
            }
            if showsVeil {
                readabilityVeil
            }
        }
        .background {
            if animated && !reduceTransparency {
                SceneMotionPauseProbe { paused in
                    if motionPaused != paused {
                        motionPaused = paused
                    }
                }
            }
        }
        .clipped()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func baseLayer(time: TimeInterval, pointer: ScenePointerSample?) -> some View {
        if reduceTransparency {
            LinearGradient(
                colors: [recipe.base.color, recipe.secondary.color],
                startPoint: .top,
                endPoint: .bottom
            )
        } else {
            meshOrFallback(time: time, pointer: pointer)
        }
    }

    @ViewBuilder
    private func meshOrFallback(time: TimeInterval, pointer: ScenePointerSample?) -> some View {
#if compiler(>=6.0)
        if #available(macOS 15.0, *), recipe.mesh.count == 9 {
            MeshGradient(
                width: 3,
                height: 3,
                points: meshPoints(time: time, pointer: pointer),
                colors: recipe.mesh.map(\.color)
            )
        } else {
            Canvas { context, size in
                drawFallback(context: &context, size: size, time: time, pointer: pointer)
            }
        }
#else
        Canvas { context, size in
            drawFallback(context: &context, size: size, time: time, pointer: pointer)
        }
#endif
    }

    private var readabilityVeil: some View {
        LinearGradient(
            stops: [
                .init(color: recipe.base.color.opacity(0.18), location: 0),
                .init(color: recipe.base.color.opacity(0.05), location: 0.16),
                .init(color: .clear, location: 0.34)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

#if compiler(>=6.0)
    @available(macOS 15.0, *)
    private func meshPoints(time: TimeInterval, pointer: ScenePointerSample?) -> [SIMD2<Float>] {
        let dx = sin(time * 0.07) * 0.028
        let dy = cos(time * 0.055) * 0.022
        let parted = ScenePointerMonitor.part(CGPoint(x: 0.5 + dx, y: 0.5 + dy), around: pointer)
        func clamp(_ value: Double) -> Float { Float(min(1, max(0, value))) }
        return [
            [0, 0],
            [clamp(0.5 + dx * 0.35), 0],
            [1, 0],
            [0, clamp(0.5 + dy * 0.3)],
            [clamp(parted.x), clamp(parted.y)],
            [1, clamp(0.5 - dy * 0.2)],
            [0, 1],
            [clamp(0.5 - dx * 0.25), 1],
            [1, 1]
        ]
    }
#endif

    private func drawFallback(context: inout GraphicsContext, size: CGSize, time: TimeInterval, pointer: ScenePointerSample?) {
        let bounds = CGRect(origin: .zero, size: size)
        context.fill(
            Path(bounds),
            with: .linearGradient(
                Gradient(colors: [recipe.base.color, recipe.secondary.color]),
                startPoint: CGPoint(x: 0, y: 0),
                endPoint: CGPoint(x: 0, y: size.height)
            )
        )
        drawBlobs(context: &context, size: size, time: time, pointer: pointer)
    }

    private func drawBlobs(context: inout GraphicsContext, size: CGSize, time: TimeInterval, pointer: ScenePointerSample?) {
        for (index, blob) in recipe.blobs.enumerated() {
            let phase = time * (0.07 + Double(index) * 0.012) + Double(index)
            let rest = CGPoint(
                x: blob.x + sin(phase) * 0.028,
                y: blob.y + cos(phase * 0.85) * 0.024
            )
            let parted = ScenePointerMonitor.part(rest, around: pointer)
            let center = CGPoint(x: size.width * parted.x, y: size.height * parted.y)
            let radius = min(size.width, size.height) * blob.radius
            let rect = CGRect(
                x: center.x - radius,
                y: center.y - radius,
                width: radius * 2,
                height: radius * 2
            )
            context.fill(
                Path(ellipseIn: rect),
                with: .radialGradient(
                    Gradient(colors: [
                        blob.color.color.opacity(blob.opacity * 0.85),
                        blob.color.color.opacity(0)
                    ]),
                    center: center,
                    startRadius: 0,
                    endRadius: radius
                )
            )
        }
    }

    private func drawMotes(context: inout GraphicsContext, size: CGSize, time: TimeInterval, pointer: ScenePointerSample?) {
        let ink = recipe.looksDark ? Color.white.opacity(0.22) : Color.white.opacity(0.38)
        let count = 18
        for index in 0..<count {
            let seed = grainHash(index &* 11, index &* 19)
            let rest = CGPoint(
                x: 0.08 + (Double(index % 6) / 5.0) * 0.84 + (seed - 0.5) * 0.08,
                y: 0.10 + (Double(index / 6) / 3.0) * 0.78 + (grainHash(index, 3) - 0.5) * 0.10
            )
            let drift = CGPoint(
                x: rest.x + sin(time * 0.11 + seed * 6) * 0.035,
                y: rest.y + cos(time * 0.09 + seed * 5) * 0.03
            )
            let parted = ScenePointerMonitor.part(drift, around: pointer)
            let radius = 1.1 + seed * 2.2
            let x = size.width * parted.x
            let y = size.height * parted.y
            context.fill(
                Path(ellipseIn: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2)),
                with: .color(ink.opacity(0.35 + seed * 0.45))
            )
        }
    }

    private func drawWake(context: inout GraphicsContext, size: CGSize, pointer: ScenePointerSample?) {
        guard let pointer else { return }
        let speed = hypot(pointer.velocity.x, pointer.velocity.y)
        guard speed > 0.004 else { return }
        let center = CGPoint(x: size.width * pointer.position.x, y: size.height * pointer.position.y)
        let radius = min(size.width, size.height) * (0.16 + min(0.12, speed * 8))
        let glow = recipe.looksDark ? Color.white.opacity(0.05) : Color.white.opacity(0.10)
        context.fill(
            Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)),
            with: .radialGradient(
                Gradient(colors: [glow, Color.clear]),
                center: center,
                startRadius: 0,
                endRadius: radius
            )
        )
    }

    private func drawOverlayList(
        context: inout GraphicsContext,
        size: CGSize,
        overlays: [SceneOverlay],
        time: TimeInterval,
        pointer: ScenePointerSample?
    ) {
        for overlay in overlays {
            switch overlay {
            case .hills:
                drawHills(context: &context, size: size, time: time)
            case .paperLines:
                drawPaperLines(context: &context, size: size)
            case .dots:
                drawDots(context: &context, size: size)
            case .rings:
                drawRings(context: &context, size: size)
            case .grain:
                drawGrain(context: &context, size: size)
            case .spotlight:
                drawSpotlight(context: &context, size: size, pointer: pointer)
            case .stars:
                drawStars(context: &context, size: size, time: time, pointer: pointer)
            }
        }
    }

    private func drawHills(context: inout GraphicsContext, size: CGSize, time: TimeInterval) {
        let colors = recipe.hillColors
        guard !colors.isEmpty else { return }
        let bands: [(y: Double, amp: Double)] = [
            (0.30, 0.075),
            (0.48, 0.060),
            (0.66, 0.048)
        ]
        for (index, band) in bands.enumerated() {
            let color = colors[min(index, colors.count - 1)].color.opacity(0.72 - Double(index) * 0.08)
            var path = Path()
            path.move(to: CGPoint(x: 0, y: size.height))
            let y0 = size.height * band.y
            path.addLine(to: CGPoint(x: 0, y: y0))
            let steps = 10
            for step in 0...steps {
                let t = Double(step) / Double(steps)
                let x = size.width * t
                let wave = sin(t * 2.4 + Double(index) * 1.15 + time * 0.12) * band.amp
                path.addLine(to: CGPoint(x: x, y: size.height * (band.y + wave)))
            }
            path.addLine(to: CGPoint(x: size.width, y: size.height))
            path.closeSubpath()
            context.fill(path, with: .color(color))
        }
    }

    private func drawStars(context: inout GraphicsContext, size: CGSize, time: TimeInterval, pointer: ScenePointerSample?) {
        let columns = max(18, Int(size.width / 28))
        let rows = max(12, Int(size.height / 28))
        for row in 0..<rows {
            for column in 0..<columns {
                let jitter = grainHash(column &* 3, row &* 7)
                guard jitter > 0.62 else { continue }
                let rest = CGPoint(
                    x: Double(column) / Double(max(columns - 1, 1)) + (grainHash(row, column) - 0.5) * 0.03,
                    y: Double(row) / Double(max(rows - 1, 1)) + (grainHash(column, row) - 0.5) * 0.03
                )
                let parted = ScenePointerMonitor.part(rest, around: pointer)
                let x = size.width * parted.x
                let y = size.height * parted.y
                let twinkle = 0.55 + 0.45 * sin(time * (0.6 + jitter) + Double(column + row))
                let radius = 0.6 + jitter * 1.4
                let glow = jitter > 0.92 ? 2.8 : (jitter > 0.82 ? 1.6 : 0)
                if glow > 0 {
                    context.fill(
                        Path(ellipseIn: CGRect(x: x - glow, y: y - glow, width: glow * 2, height: glow * 2)),
                        with: .color(Color.white.opacity(0.08 * twinkle))
                    )
                }
                context.fill(
                    Path(ellipseIn: CGRect(x: x - radius / 2, y: y - radius / 2, width: radius, height: radius)),
                    with: .color(Color.white.opacity((0.35 + jitter * 0.55) * twinkle))
                )
            }
        }
    }

    private func drawPaperLines(context: inout GraphicsContext, size: CGSize) {
        let ink = recipe.looksDark ? Color.white.opacity(0.06) : Color.brown.opacity(0.10)
        var y: CGFloat = 0
        while y < size.height {
            var line = Path()
            line.move(to: CGPoint(x: 0, y: y))
            line.addLine(to: CGPoint(x: size.width, y: y))
            context.stroke(line, with: .color(ink), lineWidth: 0.6)
            y += 28
        }
    }

    private func drawDots(context: inout GraphicsContext, size: CGSize) {
        let ink = recipe.looksDark ? Color.white.opacity(0.10) : Color.black.opacity(0.10)
        let step: CGFloat = 22
        var x: CGFloat = 12
        while x < size.width {
            var y: CGFloat = 12
            while y < size.height {
                context.fill(
                    Path(ellipseIn: CGRect(x: x, y: y, width: 2.1, height: 2.1)),
                    with: .color(ink)
                )
                y += step
            }
            x += step
        }
    }

    private func drawRings(context: inout GraphicsContext, size: CGSize) {
        let center = CGPoint(x: size.width * 0.76, y: size.height * 0.24)
        let ink = recipe.looksDark ? Color.white.opacity(0.10) : Color.purple.opacity(0.14)
        let maxRadius = max(size.width, size.height) * 0.85
        var radius = min(size.width, size.height) * 0.10
        while radius < maxRadius {
            let rect = CGRect(
                x: center.x - radius,
                y: center.y - radius,
                width: radius * 2,
                height: radius * 2
            )
            context.stroke(Path(ellipseIn: rect), with: .color(ink), lineWidth: 1.1)
            radius += min(size.width, size.height) * 0.09
        }
    }

    private func drawGrain(context: inout GraphicsContext, size: CGSize) {
        let ink = recipe.looksDark ? Color.white.opacity(0.05) : Color.black.opacity(0.045)
        let columns = max(24, Int(size.width / 18))
        let rows = max(16, Int(size.height / 18))
        for row in 0..<rows {
            for column in 0..<columns {
                let jitter = grainHash(column, row)
                guard jitter > 0.35 else { continue }
                let x = CGFloat(column) / CGFloat(columns) * size.width + CGFloat(jitter - 0.5) * 14
                let y = CGFloat(row) / CGFloat(rows) * size.height + CGFloat(grainHash(row, column) - 0.5) * 14
                context.fill(
                    Path(ellipseIn: CGRect(x: x, y: y, width: 1.2, height: 1.2)),
                    with: .color(ink.opacity(0.4 + jitter * 0.6))
                )
            }
        }
    }

    private func drawSpotlight(context: inout GraphicsContext, size: CGSize, pointer: ScenePointerSample?) {
        let px = pointer?.position.x ?? 0.5
        let py = pointer?.position.y ?? 0.5
        let center = CGPoint(
            x: size.width * (0.42 + px * 0.16),
            y: size.height * (0.06 + py * 0.08)
        )
        let radius = max(size.width, size.height) * 0.72
        context.fill(
            Path(CGRect(origin: .zero, size: size)),
            with: .radialGradient(
                Gradient(colors: [
                    Color.white.opacity(recipe.looksDark ? 0.10 : 0.18),
                    Color.clear
                ]),
                center: center,
                startRadius: 0,
                endRadius: radius
            )
        )
        context.fill(
            Path(CGRect(origin: .zero, size: size)),
            with: .radialGradient(
                Gradient(colors: [
                    Color.clear,
                    Color.black.opacity(recipe.looksDark ? 0.28 : 0.06)
                ]),
                center: CGPoint(x: size.width / 2, y: size.height / 2),
                startRadius: min(size.width, size.height) * 0.35,
                endRadius: max(size.width, size.height) * 0.75
            )
        )
    }

    private func grainHash(_ a: Int, _ b: Int) -> Double {
        var hash = UInt64(bitPattern: Int64(a &* 374_761_393 &+ b &* 668_265_263))
        hash = (hash ^ (hash >> 13)) &* 1_274_126_177
        return Double(hash % 1_000) / 1_000
    }
}

struct SceneBackdropPicker: View {
    @AppStorage(SceneBackdropSettings.defaultsKey) private var sceneRaw = SceneBackdropID.system.rawValue
    @AppStorage(SceneBackdropSettings.motionDefaultsKey) private var sceneMotion = true
    @SwiftUI.Environment(\.colorScheme) private var colorScheme
    @SwiftUI.Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @SwiftUI.Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var selection: SceneBackdropID {
        SceneBackdropID.resolved(sceneRaw)
    }

    private let columns = [GridItem(.adaptive(minimum: 124), spacing: 10)]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "paintpalette")
                    .frame(width: 16, alignment: .center)
                    .foregroundStyle(.secondary)
                Text(L("about.scene.title"))
                    .font(.body.weight(.medium))
            }
            Text(L("about.scene.detail"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                Image(systemName: "sparkles")
                    .frame(width: 16, alignment: .center)
                    .foregroundStyle(.secondary)
                Text(L("about.scene.motion"))
                    .font(.body.weight(.medium))
                Spacer(minLength: 12)
                Toggle("", isOn: $sceneMotion)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
                    .disabled(selection == .system || reduceTransparency || reduceMotion)
                    .accessibilityLabel(L("about.scene.motion"))
                    .accessibilityIdentifier("about.scene.motion")
            }
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(SceneBackdropID.allCases) { scene in
                    sceneButton(scene)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L("about.scene.title"))
    }

    private func sceneButton(_ scene: SceneBackdropID) -> some View {
        let selected = selection == scene
        return Button {
            sceneRaw = scene.rawValue
        } label: {
            VStack(spacing: 7) {
                preview(scene)
                    .frame(height: 74)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(
                                selected ? Color.appAccent : Color.primary.opacity(0.10),
                                lineWidth: selected ? 2 : 1
                            )
                    }
                    .overlay(alignment: .topTrailing) {
                        if selected {
                            Image(systemName: "checkmark.circle.fill")
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(.white, Color.appAccent)
                                .font(.body)
                                .padding(6)
                        }
                    }
                Text(scene.title)
                    .font(.caption)
                    .foregroundStyle(selected ? Color.appAccent : .primary)
                    .lineLimit(1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(scene.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("about.scene.\(scene.rawValue)")
    }

    @ViewBuilder
    private func preview(_ scene: SceneBackdropID) -> some View {
        if scene == .system {
            ZStack(alignment: .bottom) {
                Color(nsColor: .windowBackgroundColor)
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .frame(height: 26)
                    .padding(8)
                    .opacity(0.9)
            }
        } else {
            SceneBackdropCanvas(
                recipe: scene.recipe(dark: colorScheme == .dark),
                animated: false,
                reduceTransparency: reduceTransparency,
                showsVeil: false
            )
        }
    }
}
