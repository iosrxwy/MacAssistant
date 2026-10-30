import SwiftUI
import AppKit
import UniformTypeIdentifiers
import MacAssistantKit

// MARK: - 风险等级视觉

extension RiskLevel {
    var color: Color {
        switch self {
        case .safe: return .green
        case .caution: return .orange
        case .danger: return .red
        }
    }
}

/// 风险等级标签(彩色圆点 + 文字)。
struct RiskBadge: View {
    let risk: RiskLevel
    var compact = false

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(risk.color).frame(width: 8, height: 8)
            if !compact {
                Text(risk.label).font(.caption2.weight(.medium))
            }
        }
        .padding(.horizontal, compact ? 4 : 8)
        .padding(.vertical, 3)
        // 徽章总是嵌在卡片里,所以走内嵌层;玻璃背景更花,着色需要再重一点才读得出来。
        .insetSurfaceBackground(
            Capsule(),
            legacyFill: risk.color.opacity(0.12),
            glassFill: AnyShapeStyle(risk.color.opacity(0.22)),
            stroke: risk.color.opacity(0.35)
        )
        .foregroundStyle(risk.color)
    }
}

// MARK: - 剪贴板 / 访达

func copyToClipboard(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}

func revealInFinder(_ url: URL) {
    NSWorkspace.shared.activateFileViewerSelecting([url])
}

extension UTType {
    static var debPackage: UTType { UTType(filenameExtension: "deb") ?? .data }
    static var ipaPackage: UTType { UTType(filenameExtension: "ipa") ?? .data }
    static var dylibFile: UTType { UTType(filenameExtension: "dylib") ?? .data }
}

// MARK: - 异步任务状态

@MainActor
final class TaskState: ObservableObject {
    @Published var running = false
    @Published var log = ""
    @Published var ok: Bool?

    func reset() { log = ""; ok = nil }
}

/// 在后台执行 work(返回文本日志),完成后回主线程更新状态。
@MainActor
func performTask(_ state: TaskState, _ work: @escaping @Sendable () throws -> String) {
    state.running = true
    state.ok = nil
    Task {
        do {
            let text = try await Task.detached(priority: .userInitiated) { try work() }.value
            state.log = text
            state.ok = true
        } catch {
            state.log = error.localizedDescription
            state.ok = false
        }
        state.running = false
    }
}

// MARK: - 页面骨架

struct FeatureScaffold<Content: View, Trailing: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var content: () -> Content
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(title).font(.largeTitle.bold())
                        Text(subtitle).font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    trailing()
                }
                content()
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .softScrollEdgeEffect()
        // 不要在 onAppear 里 ScrollViewProxy.scrollTo：macOS 15.0–15.1 会在
        // identity 尚未入图时 precondition 崩掉。首屏主线程再套 waitUntilExit
        // 重入 runloop 时必现。初始锚点交给系统 API。
        .defaultScrollAnchorTopIfAvailable()
        .featureSurfaceBackground()
    }
}

extension View {
    @ViewBuilder
    func clearListRowIf(_ enabled: Bool) -> some View {
        if enabled {
            listRowBackground(Color.clear)
        } else {
            self
        }
    }

    /// 关掉 AppKit 列表的系统蓝选中底，改由 SwiftUI 自己画毛玻璃。
    func disableSystemListSelection() -> some View {
        background(DisableListSelectionHighlight())
    }
}

struct SidebarFocusChrome: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 14.0, *) {
            content.focusable().focusEffectDisabled()
        } else {
            content.focusable()
        }
    }
}

/// 自己画选中；不用 ButtonStyle 的 isPressed，避免松手后旧行还留着灰底。
struct QuietRowButtonStyle: PrimitiveButtonStyle {
    var selected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background {
                SidebarSelectionChrome(selected: selected)
                    .transaction { $0.animation = nil }
            }
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .onTapGesture(perform: configuration.trigger)
    }
}

/// 侧栏选中底：一层浅灰，瞬时切换，不描边、不叠材质。
struct SidebarSelectionChrome: View {
    let selected: Bool
    @SwiftUI.Environment(\.sceneBackdrop) private var scene
    @SwiftUI.Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if selected {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(fill)
        } else {
            Color.clear
        }
    }

    private var fill: Color {
        let dark = colorScheme == .dark
        if scene.isDecorative {
            return Color.primary.opacity(dark ? 0.18 : 0.10)
        }
        return Color.primary.opacity(dark ? 0.14 : 0.07)
    }
}

/// 系统源列表选中会用「控制强调色」铺蓝，并把行内容反成白。
/// SwiftUI 每次刷新还可能把 `selectionHighlightStyle` 设回去，所以要点下去的当帧就关掉。
private struct DisableListSelectionHighlight: NSViewRepresentable {
    func makeNSView(context: Context) -> SelectionHighlightProbe {
        SelectionHighlightProbe()
    }

    func updateNSView(_ view: SelectionHighlightProbe, context: Context) {
        view.apply()
    }
}

private final class SelectionHighlightProbe: NSView {
    private var observers: [NSObjectProtocol] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        listen()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        listen()
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        apply()
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        apply()
    }

    private func listen() {
        let center = NotificationCenter.default
        let handler: (Notification) -> Void = { [weak self] note in
            guard let table = note.object as? NSTableView, self?.nearestTable() === table else { return }
            self?.sanitize(table)
        }
        observers.append(contentsOf: [
            center.addObserver(forName: NSTableView.selectionIsChangingNotification, object: nil, queue: .main, using: handler),
            center.addObserver(forName: NSTableView.selectionDidChangeNotification, object: nil, queue: .main, using: handler)
        ])
    }

    func apply() {
        if let table = nearestTable() {
            sanitize(table)
        }
    }

    private func nearestTable() -> NSTableView? {
        var ancestor = superview
        while let current = ancestor {
            if let table = current as? NSTableView { return table }
            for subview in current.subviews {
                if let table = subview as? NSTableView { return table }
            }
            ancestor = current.superview
        }
        return nil
    }

    private func sanitize(_ table: NSTableView) {
        if table.selectionHighlightStyle != .none {
            table.selectionHighlightStyle = .none
        }
        for row in 0..<table.numberOfRows {
            guard let rowView = table.rowView(atRow: row, makeIfNecessary: false) else { continue }
            if rowView.selectionHighlightStyle != .none {
                rowView.selectionHighlightStyle = .none
            }
            if rowView.isEmphasized {
                rowView.isEmphasized = false
            }
            if rowView.backgroundColor != .clear {
                rowView.backgroundColor = .clear
            }
        }
    }
}

extension SidebarItem {
    var iconColor: Color {
        switch self {
        case .dashboard: return .teal
        case .menuBar: return .green
        case .repair: return .orange
        case .cleanup: return .red
        case .appUninstall: return .pink
        case .desktopIcons: return .blue
        case .appClone: return .indigo
        case .memory: return .purple
        case .network: return .cyan
        case .cheatsheet: return Color(nsColor: .secondaryLabelColor)
        case .recipes: return .mint
        case .deb: return .brown
        case .dylib: return .orange
        case .ipa: return .pink
        case .macApp: return .blue
        case .binary: return .purple
        case .environment: return .green
        case .about: return .teal
        case .opensource: return .gray
        }
    }
}

extension FeatureScaffold where Trailing == EmptyView {
    init(title: String, subtitle: String, @ViewBuilder content: @escaping () -> Content) {
        self.init(title: title, subtitle: subtitle, content: content, trailing: { EmptyView() })
    }
}

enum PrivacySettingsOpener {
    @discardableResult
    static func open(anchor: String) -> Bool {
        for url in PermissionGuide.settingsURLs(anchor: anchor) {
            if NSWorkspace.shared.open(url) { return true }
        }
        return false
    }
}

struct PermissionGuideCard: View {
    let needs: [PermissionNeed]
    @State private var snapshot = PermissionGuideCardCache.snapshot ?? PermissionStatusSnapshot()

    private var visible: [PermissionNeed] {
        PermissionGuide.visibleNeeds(needs, snapshot: snapshot)
    }

    var body: some View {
        Group {
            if !visible.isEmpty {
                Card {
                    VStack(alignment: .leading, spacing: 10) {
                        Label(L("permission.card.title"), systemImage: "lock.shield")
                            .font(.headline)
                        Text(L("permission.card.subtitle"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        ForEach(visible) { need in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Text(need.title)
                                        .font(.callout.weight(.semibold))
                                    if need.isOptional {
                                        Text(L("permission.optional"))
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer(minLength: 8)
                                    if let anchor = need.settingsAnchor {
                                        Button(L("permission.openSettings")) {
                                            PrivacySettingsOpener.open(anchor: anchor)
                                        }
                                        .buttonStyle(.borderless)
                                    }
                                }
                                Text(L("permission.usedBy", need.usedBy))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(L("permission.withoutIt", need.withoutIt))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            if need.id != visible.last?.id {
                                Divider()
                            }
                        }
                    }
                }
            }
        }
        .onAppear(perform: refresh)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refresh()
        }
    }

    private func refresh() {
        Task.detached(priority: .utility) {
            let next = PermissionStatusProbe.live.snapshot()
            await MainActor.run {
                PermissionGuideCardCache.snapshot = next
                snapshot = next
            }
        }
    }
}

private enum PermissionGuideCardCache {
    static var snapshot: PermissionStatusSnapshot?
}

struct ToolFinderCard: View {
    @ObservedObject var workspace: WorkspaceStore
    @State private var query = ""

    private var hits: [ToolFindHit] {
        ToolFinder.search(query)
    }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Text(L("toolfinder.title")).font(.headline)
                TextField(L("toolfinder.prompt"), text: $query)
                    .textFieldStyle(.soft)
                if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(L("toolfinder.hint"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if hits.isEmpty {
                    Text(L("toolfinder.empty"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(hits) { hit in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(hit.title)
                                        .font(.callout.weight(.medium))
                                    Text(hit.kindLabel)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Text(hit.detail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                            Spacer(minLength: 8)
                            CopyButton(text: hit.copyText, label: L("theme.copy"))
                                .labelStyle(.iconOnly)
                            Button(L("toolfinder.open")) {
                                workspace.request(hit.destination, searchQuery: hit.searchQuery)
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
            }
        }
    }
}

struct UsageSparkline: View {
    let values: [Double]
    var tint: Color = .accentColor

    var body: some View {
        Canvas { context, size in
            guard values.count > 1, size.width > 1, size.height > 1 else { return }
            let points = scaledPoints(in: size)
            guard let first = points.first, let last = points.last else { return }

            var fill = Path()
            fill.move(to: CGPoint(x: first.x, y: size.height))
            for point in points {
                fill.addLine(to: point)
            }
            fill.addLine(to: CGPoint(x: last.x, y: size.height))
            fill.closeSubpath()
            context.fill(fill, with: .color(tint.opacity(0.16)))

            var line = Path()
            line.addLines(points)
            context.stroke(line, with: .color(tint), style: StrokeStyle(lineWidth: 1.4, lineJoin: .round))
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 3)
        .frame(width: 72, height: 22)
        .background(tint.opacity(0.07), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
        .accessibilityHidden(true)
        .help(L("dashboard.sparkline.help"))
    }

    /// 按近期高低点缩放，避免低占用贴底、高占用贴顶。
    private func scaledPoints(in size: CGSize) -> [CGPoint] {
        let samples = values.map { min(1, max(0, $0)) }
        let lowest = samples.min() ?? 0
        let highest = samples.max() ?? 1
        let span = max(highest - lowest, 0.06)
        let center = (lowest + highest) / 2
        let floor = center - span / 2
        let ceiling = center + span / 2
        return samples.enumerated().map { index, value in
            let x = size.width * CGFloat(index) / CGFloat(samples.count - 1)
            let t = (value - floor) / (ceiling - floor)
            let y = size.height * (1 - CGFloat(min(1, max(0, t))))
            return CGPoint(x: x, y: y)
        }
    }
}

// MARK: - 卡片

struct Card<Content: View>: View {
    var padding: CGFloat = 16
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentSurfaceBackground(
                RoundedRectangle(cornerRadius: 14, style: .continuous),
                fill: Color(nsColor: .controlBackgroundColor),
                stroke: Color.primary.opacity(0.08)
            )
    }
}

// MARK: - 文件选择按钮

struct FilePickerButton: View {
    var title: String = L("theme.chooseFile")
    var systemImage: String = "folder"
    var types: [UTType] = [.item]
    var chooseDirectory: Bool = false
    /// 外层卡片已经接收拖放、并且处理逻辑和这个按钮不一样时关掉，避免按钮把拖放抢走。
    var acceptsDrop: Bool = true
    let onPick: (URL) -> Void

    @State private var presented = false

    var body: some View {
        if acceptsDrop {
            button.filePickerDrop { urls in
                if let url = urls.first { onPick(url) }
            }
        } else {
            button
        }
    }

    private var button: some View {
        Button {
            presented = true
        } label: {
            Label(title, systemImage: systemImage)
        }
        .fileImporter(
            isPresented: $presented,
            allowedContentTypes: chooseDirectory ? [.folder] : types,
            allowsMultipleSelection: false
        ) { result in
            if case let .success(urls) = result, let url = urls.first {
                let accessed = url.startAccessingSecurityScopedResource()
                defer {
                    if accessed { url.stopAccessingSecurityScopedResource() }
                }
                onPick(url)
            }
        }
    }
}

struct MultiFilePickerButton: View {
    var title: String
    var systemImage: String = "folder"
    var types: [UTType] = [.item]
    var chooseDirectory: Bool = false
    let onPick: ([URL]) -> Void

    @State private var presented = false

    var body: some View {
        Button {
            presented = true
        } label: {
            Label(title, systemImage: systemImage)
        }
        .fileImporter(
            isPresented: $presented,
            allowedContentTypes: chooseDirectory ? [.folder] : types,
            allowsMultipleSelection: true
        ) { result in
            guard case let .success(urls) = result, !urls.isEmpty else { return }
            FileSystemHelper.withSecurityScopedAccess(to: urls) {
                onPick(urls)
            }
        }
        .filePickerDrop(multiple: true, onPick: onPick)
    }
}

// MARK: - 复制按钮

struct CopyButton: View {
    let text: String
    var label: String = L("theme.copy")

    @State private var copied = false

    var body: some View {
        Button {
            copyToClipboard(text)
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
        } label: {
            Label(copied ? L("theme.copied") : label, systemImage: copied ? "checkmark" : "doc.on.doc")
        }
        .buttonStyle(.borderless)
    }
}

// MARK: - 控制台输出

struct ConsoleView: View {
    let text: String
    var minHeight: CGFloat = 120

    var body: some View {
        ScrollView {
            Text(text.isEmpty ? "—" : text)
                .font(.system(.footnote, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
        }
        .frame(minHeight: minHeight)
        .insetSurfaceBackground(
            RoundedRectangle(cornerRadius: 10),
            legacyFill: Color.black.opacity(0.04),
            stroke: Color.primary.opacity(0.08)
        )
    }
}

// MARK: - 状态徽标

struct StatusBadge: View {
    let ok: Bool?
    var runningText = L("theme.running")

    var body: some View {
        switch ok {
        case .some(true):
            Label(L("theme.success"), systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .some(false):
            Label(L("theme.failure"), systemImage: "xmark.circle.fill").foregroundStyle(.red)
        case .none:
            EmptyView()
        }
    }
}

// MARK: - 路径展示行

struct PathBadge: View {
    let url: URL?
    var placeholder = L("theme.noSelection")
    /// 与 IPA 工作台拖放区一致:悬停时加粗虚线+强调色。
    var isDropTargeted = false
    var showsDropChrome = false
    /// 设置后，这条路径本身也能接收访达拖入，并画出虚线框。
    var onDropFiles: (([URL]) -> Void)? = nil

    @State private var localDropTargeted = false

    private var highlighted: Bool { isDropTargeted || localDropTargeted }
    private var chrome: Bool { showsDropChrome || onDropFiles != nil }

    var body: some View {
        let row = HStack(spacing: 6) {
            Image(systemName: "doc")
                .foregroundStyle(highlighted ? Color.accentColor : .secondary)
            Text(url?.path ?? placeholder)
                .font(.footnote)
                .foregroundStyle(url == nil && !highlighted ? .secondary : (highlighted ? Color.accentColor : .primary))
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .insetSurfaceBackground(
            RoundedRectangle(cornerRadius: 8),
            legacyFill: Color.primary.opacity(highlighted ? 0.10 : 0.05)
        )
        .overlay {
            if chrome || highlighted {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(
                        highlighted ? Color.accentColor : Color.secondary.opacity(0.35),
                        style: StrokeStyle(lineWidth: 1.5, dash: [7])
                    )
                    .allowsHitTesting(false)
            }
        }

        if let onDropFiles {
            row
                .fileURLsDropTarget(isTargeted: $localDropTargeted, onDrop: onDropFiles)
                .help(L("theme.dropHint"))
        } else {
            row
        }
    }
}

extension View {
    /// 让选择文件的按钮接收访达拖入。单选只取第一项；拖到按钮上时画出虚线。
    func filePickerDrop(multiple: Bool = false, onPick: @escaping ([URL]) -> Void) -> some View {
        modifier(FilePickerDropModifier(multiple: multiple, onPick: onPick))
    }
}

private struct FilePickerDropModifier: ViewModifier {
    var multiple: Bool
    let onPick: ([URL]) -> Void
    @State private var targeted = false

    func body(content: Content) -> some View {
        content
            .overlay {
                if targeted {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 1.5, dash: [4]))
                        .allowsHitTesting(false)
                }
            }
            .fileURLsDropTarget(isTargeted: $targeted) { urls in
                let accepted = multiple ? urls : Array(urls.prefix(1))
                guard !accepted.isEmpty else { return }
                onPick(accepted)
            }
            .help(L("theme.dropHint"))
    }
}

// MARK: - 文件拖放

private let droppedFileTypes: [UTType] = [
    .fileURL, .item, .content, .data, .package, .directory, .folder,
    .application, .applicationBundle, .debPackage, .ipaPackage, .dylibFile, .unixExecutable, .executable
]

extension View {
    /// 接收 Finder 拖入的文件 URL,样式与命中态由调用方自己画(工作台虚线框 / PathBadge)。
    func fileURLDropTarget(isTargeted: Binding<Bool>, onDrop handle: @escaping (URL) -> Void) -> some View {
        fileURLsDropTarget(isTargeted: isTargeted) { urls in
            urls.forEach(handle)
        }
    }

    func fileURLsDropTarget(isTargeted: Binding<Bool>, onDrop handle: @escaping ([URL]) -> Void) -> some View {
        contentShape(Rectangle())
            .onDrop(of: droppedFileTypes, isTargeted: isTargeted) { providers in
                ingestDroppedFileURLs(providers, onDrop: handle)
            }
    }
}

/// 从 `NSItemProvider` 解出文件 URL。Finder 对 .deb 等自定义后缀经常不给 `public.file-url` 的 Data,
/// 所以 fileURL / url / item 都试一遍,凑齐一批后再回主线程,才能一次处理多个拖入。
@discardableResult
func ingestDroppedFileURLs(_ providers: [NSItemProvider], onDrop handle: @escaping ([URL]) -> Void) -> Bool {
    let loaders = providers.filter { provider in
        droppedFileTypes.contains { provider.hasItemConformingToTypeIdentifier($0.identifier) }
            || provider.hasItemConformingToTypeIdentifier(UTType.url.identifier)
    }
    guard !loaders.isEmpty else { return false }
    Task {
        var urls: [URL] = []
        for provider in loaders {
            if let url = await loadDroppedFileURL(from: provider) {
                urls.append(url)
            }
        }
        let unique = uniquedDroppedURLs(urls)
        guard !unique.isEmpty else { return }
        await MainActor.run { handle(unique) }
    }
    return true
}

@discardableResult
func ingestDroppedFileURLs(_ providers: [NSItemProvider], onDrop handle: @escaping (URL) -> Void) -> Bool {
    ingestDroppedFileURLs(providers) { urls in
        urls.forEach(handle)
    }
}

private func loadDroppedFileURL(from provider: NSItemProvider) async -> URL? {
    let identifiers = [
        UTType.fileURL.identifier,
        UTType.url.identifier,
        UTType.item.identifier
    ]
    for identifier in identifiers where provider.hasItemConformingToTypeIdentifier(identifier) {
        if let url = await loadDropItem(provider, typeIdentifier: identifier) { return url }
        if identifier == UTType.fileURL.identifier,
           let url = await loadFileURLData(provider) {
            return url
        }
    }
    return nil
}

private func loadDropItem(_ provider: NSItemProvider, typeIdentifier: String) async -> URL? {
    await withCheckedContinuation { continuation in
        provider.loadItem(forTypeIdentifier: typeIdentifier, options: nil) { item, _ in
            continuation.resume(returning: urlFromDropItem(item))
        }
    }
}

private func loadFileURLData(_ provider: NSItemProvider) async -> URL? {
    await withCheckedContinuation { continuation in
        provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
            continuation.resume(returning: data.flatMap { URL(dataRepresentation: $0, relativeTo: nil) })
        }
    }
}

private func urlFromDropItem(_ item: NSSecureCoding?) -> URL? {
    if let url = item as? URL { return url }
    if let data = item as? Data {
        if let url = URL(dataRepresentation: data, relativeTo: nil) { return url }
        if let text = String(data: data, encoding: .utf8) {
            return urlFromDropString(text)
        }
    }
    if let text = item as? String {
        return urlFromDropString(text)
    }
    return nil
}

private func urlFromDropString(_ text: String) -> URL? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if let data = trimmed.data(using: .utf8),
       let url = URL(dataRepresentation: data, relativeTo: nil),
       url.isFileURL {
        return url
    }
    if trimmed.hasPrefix("file:") {
        if let url = URL(string: trimmed), url.isFileURL { return url }
        var path = trimmed
        if path.hasPrefix("file://") { path = String(path.dropFirst("file://".count)) }
        if let decoded = path.removingPercentEncoding { path = decoded }
        if path.hasPrefix("/") { return URL(fileURLWithPath: path) }
    }
    if trimmed.hasPrefix("/") { return URL(fileURLWithPath: trimmed) }
    return nil
}

private func uniquedDroppedURLs(_ urls: [URL]) -> [URL] {
    var seen = Set<String>()
    return urls.filter { seen.insert($0.standardizedFileURL.path).inserted }
}
