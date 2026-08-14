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

    private enum ScrollAnchor: Hashable { case top }

    var body: some View {
        ScrollViewReader { proxy in
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
                    .id(ScrollAnchor.top)
                    content()
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .softScrollEdgeEffect()
            .onAppear {
                // 页面里的第一个文本框会自动成为第一响应者，滚动视图为露出它会把页头顶出可视区。
                DispatchQueue.main.async {
                    proxy.scrollTo(ScrollAnchor.top, anchor: .top)
                }
            }
        }
        .featureSurfaceBackground()
    }
}

extension FeatureScaffold where Trailing == EmptyView {
    init(title: String, subtitle: String, @ViewBuilder content: @escaping () -> Content) {
        self.init(title: title, subtitle: subtitle, content: content, trailing: { EmptyView() })
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
    let onPick: (URL) -> Void

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

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "doc")
                .foregroundStyle(.secondary)
            Text(url?.path ?? placeholder)
                .font(.footnote)
                .foregroundStyle(url == nil ? .secondary : .primary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .insetSurfaceBackground(
            RoundedRectangle(cornerRadius: 8),
            legacyFill: Color.primary.opacity(0.05)
        )
    }
}
