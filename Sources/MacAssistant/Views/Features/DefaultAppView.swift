import AppKit
import SwiftUI
import MacAssistantKit
import UniformTypeIdentifiers

@MainActor
final class DefaultAppModel: ObservableObject {
    @Published private(set) var rows: [DefaultAppRowModel] = []
    @Published private(set) var loading = false
    @Published var status = ""
    @Published var statusIsError = false
    @Published var picker: DefaultAppPickerRequest?
    @Published var pendingShared: DefaultAppSharedPrompt?

    private let service: DefaultAppService
    private var reloadTask: Task<Void, Never>?

    init(service: DefaultAppService? = nil) {
        if let service {
            self.service = service
        } else {
            self.service = Self.liveService()
        }
    }

    func reload() {
        reloadTask?.cancel()
        loading = true
        reloadTask = Task { [service] in
            let loaded: Result<[DefaultAppRowModel], Error> = Result {
                try service.rows()
            }
            guard !Task.isCancelled else { return }
            loading = false
            switch loaded {
            case .success(let rows):
                self.rows = rows
            case .failure(let error):
                show(error)
            }
        }
    }

    func add(_ raw: String) {
        do {
            let ext = try service.addCustomExtension(raw)
            status = L("defaultapp.status.added", ext)
            statusIsError = false
            reload()
        } catch {
            show(error)
        }
    }

    func removeCustom(_ fileExtension: String) {
        do {
            try service.removeCustomExtension(fileExtension)
            status = L("defaultapp.status.removed", fileExtension)
            statusIsError = false
            reload()
        } catch {
            show(error)
        }
    }

    func beginChange(_ fileExtension: String) {
        do {
            let choices = try service.choices(forExtension: fileExtension)
            picker = DefaultAppPickerRequest(fileExtension: fileExtension, choices: choices)
        } catch {
            show(error)
        }
    }

    func apply(app: URL, fileExtension: String, allowShared: Bool) {
        picker = nil
        Task { await applyNow(app: app, fileExtension: fileExtension, allowShared: allowShared) }
    }

    private func applyNow(app: URL, fileExtension: String, allowShared: Bool) async {
        do {
            let result = try await service.setDefault(app: app, forExtension: fileExtension, allowShared: allowShared)
            pendingShared = nil
            switch result.kind {
            case .changed:
                status = L("defaultapp.status.changed", result.fileExtension, result.appName)
            case .unchanged:
                status = L("defaultapp.status.unchanged", result.fileExtension, result.appName)
            case .restored:
                status = L("defaultapp.status.restored", result.fileExtension, result.appName)
            }
            statusIsError = false
            reload()
        } catch DefaultAppError.sharedType(let identifier) {
            pendingShared = DefaultAppSharedPrompt(
                fileExtension: fileExtension,
                contentTypeIdentifier: identifier,
                action: .apply(app)
            )
        } catch {
            show(error)
        }
    }

    func restore(_ fileExtension: String, allowShared: Bool) {
        Task { await restoreNow(fileExtension, allowShared: allowShared) }
    }

    private func restoreNow(_ fileExtension: String, allowShared: Bool) async {
        do {
            let result = try await service.restore(fileExtension: fileExtension, allowShared: allowShared)
            pendingShared = nil
            switch result.kind {
            case .restored:
                status = L("defaultapp.status.restored", result.fileExtension, result.appName)
            case .unchanged:
                status = L("defaultapp.status.unchanged", result.fileExtension, result.appName)
            case .changed:
                status = L("defaultapp.status.changed", result.fileExtension, result.appName)
            }
            statusIsError = false
            reload()
        } catch DefaultAppError.sharedType(let identifier) {
            pendingShared = DefaultAppSharedPrompt(
                fileExtension: fileExtension,
                contentTypeIdentifier: identifier,
                action: .restore
            )
        } catch {
            show(error)
        }
    }

    func restoreAll() {
        Task { await restoreAllNow() }
    }

    private func restoreAllNow() async {
        do {
            let result = try await service.restoreAll()
            pendingShared = nil
            if result.failures.isEmpty {
                status = L("defaultapp.status.restoredAll", result.restoredExtensions.count)
                statusIsError = false
            } else {
                status = L(
                    "defaultapp.status.restoredPartial",
                    result.restoredExtensions.count,
                    result.failures.count
                )
                statusIsError = true
            }
            reload()
        } catch {
            show(error)
        }
    }

    func confirmPendingShared() {
        guard let pending = pendingShared else { return }
        switch pending.action {
        case .apply(let app):
            apply(app: app, fileExtension: pending.fileExtension, allowShared: true)
        case .restore:
            restore(pending.fileExtension, allowShared: true)
        }
    }

    func browse(for fileExtension: String) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = L("defaultapp.picker.choose")
        panel.message = L("defaultapp.picker.message", fileExtension)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        apply(app: url, fileExtension: fileExtension, allowShared: false)
    }

    var canRestoreAny: Bool {
        rows.contains(where: \.canRestore)
    }

    /// jpg 和 jpeg 共用一个类型，全部恢复时只算一次。
    var restorableTypeCount: Int {
        Set(rows.filter(\.canRestore).map { $0.contentTypeIdentifier ?? $0.fileExtension }).count
    }

    private func show(_ error: Error) {
        status = error.localizedDescription
        statusIsError = true
    }

    private static func liveService() -> DefaultAppService {
        let launchServices = SystemDefaultAppLaunchServices()
        return DefaultAppService(
            launchServices: launchServices,
            claims: SystemDefaultAppClaimSource(launchServices: launchServices),
            history: DefaultAppHistoryStore(fileURL: DefaultAppHistoryStore.defaultFileURL())
        )
    }
}

struct DefaultAppPickerRequest: Identifiable, Equatable {
    let fileExtension: String
    let choices: [DefaultAppChoice]
    var id: String { fileExtension }
}

struct DefaultAppSharedPrompt: Identifiable, Equatable {
    enum Action: Equatable {
        case apply(URL)
        case restore
    }

    let fileExtension: String
    let contentTypeIdentifier: String
    let action: Action
    var id: String { fileExtension + contentTypeIdentifier }
}

struct DefaultAppView: View {
    @StateObject private var model = DefaultAppModel()
    @State private var query = ""
    @State private var draft = ""
    @State private var confirmRestoreAll = false

    var body: some View {
        FeatureScaffold(
            title: SidebarItem.defaultApps.title,
            subtitle: L("defaultapp.subtitle")
        ) {
            controls
            if !model.status.isEmpty {
                Text(model.status)
                    .font(.callout)
                    .foregroundStyle(model.statusIsError ? Color.red : Color.secondary)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("defaultapp.status")
            }
            if model.loading && model.rows.isEmpty {
                ProgressView(L("defaultapp.status.loading"))
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else if sections.isEmpty {
                Text(L("defaultapp.empty"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 80)
            } else {
                ForEach(sections, id: \.title) { section in
                    sectionCard(section.title, rows: section.rows)
                }
            }
            Text(L("defaultapp.footnote"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } trailing: {
            HStack(spacing: 8) {
                Button {
                    model.reload()
                } label: {
                    Label(L("defaultapp.refresh"), systemImage: "arrow.clockwise")
                }
                .disabled(model.loading)
                .keyboardShortcut("r", modifiers: [.command])
                .accessibilityIdentifier("defaultapp.refresh")
                Button {
                    confirmRestoreAll = true
                } label: {
                    Label(L("defaultapp.restoreAll"), systemImage: "arrow.uturn.backward")
                }
                .disabled(!model.canRestoreAny || model.loading)
                .accessibilityIdentifier("defaultapp.restoreAll")
            }
        }
        .onAppear { model.reload() }
        .sheet(item: $model.picker) { request in
            DefaultAppPickerSheet(
                request: request,
                onPick: { model.apply(app: $0, fileExtension: request.fileExtension, allowShared: false) },
                onBrowse: {
                    let ext = request.fileExtension
                    model.picker = nil
                    DispatchQueue.main.async {
                        model.browse(for: ext)
                    }
                },
                onClose: { model.picker = nil }
            )
        }
        .confirmationDialog(
            L("defaultapp.shared.title"),
            isPresented: sharedPresented,
            titleVisibility: .visible,
            presenting: model.pendingShared
        ) { _ in
            Button(L("defaultapp.shared.confirm")) { model.confirmPendingShared() }
            Button(L("common.cancel"), role: .cancel) { model.pendingShared = nil }
        } message: { prompt in
            Text(L("defaultapp.shared.message", prompt.fileExtension, prompt.contentTypeIdentifier))
        }
        .confirmationDialog(
            L("defaultapp.restoreAll.confirm.title"),
            isPresented: $confirmRestoreAll,
            titleVisibility: .visible
        ) {
            Button(L("defaultapp.restoreAll.confirm.action")) { model.restoreAll() }
            Button(L("common.cancel"), role: .cancel) {}
        } message: {
            Text(L("defaultapp.restoreAll.confirm.message", model.restorableTypeCount))
        }
    }

    private var sharedPresented: Binding<Bool> {
        Binding(
            get: { model.pendingShared != nil },
            set: { if !$0 { model.pendingShared = nil } }
        )
    }

    private var controls: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    TextField(L("defaultapp.search"), text: $query)
                        .textFieldStyle(.plain)
                        .accessibilityLabel(L("defaultapp.search.accessibility"))
                        .accessibilityIdentifier("defaultapp.search")
                    if !query.isEmpty {
                        Button {
                            query = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(L("defaultapp.clearSearch"))
                    }
                }
                HStack(spacing: 8) {
                    TextField(L("defaultapp.add.prompt"), text: $draft)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 180)
                        .onSubmit(addDraft)
                        .accessibilityIdentifier("defaultapp.addField")
                    Button(L("defaultapp.add"), action: addDraft)
                        .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("defaultapp.add")
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private var sections: [(title: String, rows: [DefaultAppRowModel])] {
        let filtered = model.rows.filter(matches)
        var result: [(title: String, rows: [DefaultAppRowModel])] = []
        for group in DefaultAppPresetGroup.allCases {
            let items = filtered.filter { $0.group == group }
            if !items.isEmpty {
                result.append((groupTitle(group), items))
            }
        }
        let custom = filtered.filter(\.isCustom)
        if !custom.isEmpty {
            result.append((L("defaultapp.group.custom"), custom))
        }
        return result
    }

    private func sectionCard(_ title: String, rows: [DefaultAppRowModel]) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(.headline)
                    .padding(.bottom, 8)
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    if index > 0 {
                        Divider().padding(.leading, 44)
                    }
                    rowView(row)
                }
            }
        }
    }

    private func rowView(_ row: DefaultAppRowModel) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(nsImage: fileIcon(row.fileExtension))
                .resizable()
                .interpolation(.high)
                .frame(width: 32, height: 32)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(".\(row.fileExtension)")
                    .font(.body.weight(.semibold))
                Text(currentLine(row))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(restoreLine(row))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                if !row.relatedExtensions.isEmpty {
                    Text(L("defaultapp.related", relatedText(row)))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if row.scope.needsSharedConfirmation {
                    Text(L("defaultapp.shared.badge"))
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                if case .unsafe = row.scope {
                    Text(L("defaultapp.unsafe"))
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                if case .unknown = row.scope {
                    Text(L("defaultapp.unknown"))
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            Spacer(minLength: 8)
            if row.isCustom {
                Button {
                    model.removeCustom(row.fileExtension)
                } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.borderless)
                .help(L("defaultapp.removeCustom"))
                .accessibilityLabel(L("defaultapp.removeCustom"))
                .accessibilityIdentifier("defaultapp.remove.\(row.fileExtension)")
            }
            Button(L("defaultapp.change")) {
                model.beginChange(row.fileExtension)
            }
            .disabled(!row.canChange || model.loading)
            .controlSize(.small)
            .accessibilityIdentifier("defaultapp.change.\(row.fileExtension)")
            Button(L("defaultapp.restore")) {
                model.restore(row.fileExtension, allowShared: false)
            }
            .disabled(!row.canRestore || model.loading)
            .controlSize(.small)
            .help(restoreHelp(row))
            .accessibilityIdentifier("defaultapp.restore.\(row.fileExtension)")
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("defaultapp.row.\(row.fileExtension)")
    }

    private func currentLine(_ row: DefaultAppRowModel) -> String {
        if let name = row.currentAppName, !name.isEmpty {
            return L("defaultapp.current", name)
        }
        return L("defaultapp.current.none")
    }

    private func restoreLine(_ row: DefaultAppRowModel) -> String {
        switch row.restoreKind {
        case .system:
            return L("defaultapp.systemDefault", row.restoreAppName ?? "")
        case .previous:
            return L("defaultapp.previous", row.restoreAppName ?? "")
        case .none:
            return L("defaultapp.noDefault")
        }
    }

    private func restoreHelp(_ row: DefaultAppRowModel) -> String {
        guard row.canRestore, let name = row.restoreAppName else {
            if row.restoreKind != .none, row.restoreAppName != nil {
                return L("defaultapp.restore.help.current")
            }
            return L("defaultapp.restore.help.none")
        }
        switch row.restoreKind {
        case .system:
            return L("defaultapp.restore.help.system", name)
        case .previous:
            return L("defaultapp.restore.help.previous", name)
        case .none:
            return L("defaultapp.restore.help.none")
        }
    }

    private func relatedText(_ row: DefaultAppRowModel) -> String {
        row.relatedExtensions.map { ".\($0)" }.joined(separator: "、")
    }

    private func matches(_ row: DefaultAppRowModel) -> Bool {
        let key = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return true }
        let group = row.group.map(groupTitle) ?? L("defaultapp.group.custom")
        let haystack = [
            row.fileExtension,
            ".\(row.fileExtension)",
            row.currentAppName ?? "",
            row.restoreAppName ?? "",
            row.contentTypeIdentifier ?? "",
            group
        ].joined(separator: " ")
        return haystack.localizedStandardContains(key)
    }

    private func groupTitle(_ group: DefaultAppPresetGroup) -> String {
        switch group {
        case .image: return L("defaultapp.group.image")
        case .document: return L("defaultapp.group.document")
        case .design: return L("defaultapp.group.design")
        case .archive: return L("defaultapp.group.archive")
        case .media: return L("defaultapp.group.media")
        }
    }

    private func fileIcon(_ fileExtension: String) -> NSImage {
        if let type = UTType(filenameExtension: fileExtension) {
            return NSWorkspace.shared.icon(for: type)
        }
        return NSWorkspace.shared.icon(for: .data)
    }

    private func addDraft() {
        let raw = draft
        guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        model.add(raw)
        if !model.statusIsError {
            draft = ""
        }
    }
}

private struct DefaultAppPickerSheet: View {
    let request: DefaultAppPickerRequest
    let onPick: (URL) -> Void
    let onBrowse: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L("defaultapp.picker.title", request.fileExtension))
                    .font(.headline)
                Spacer()
                Button(L("defaultapp.picker.close"), action: onClose)
                    .keyboardShortcut(.cancelAction)
            }
            if request.choices.isEmpty {
                Text(L("defaultapp.picker.empty"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(request.choices) { choice in
                            Button {
                                onPick(URL(fileURLWithPath: choice.path))
                            } label: {
                                HStack(spacing: 10) {
                                    Image(nsImage: NSWorkspace.shared.icon(forFile: choice.path))
                                        .resizable()
                                        .frame(width: 28, height: 28)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(choice.name)
                                            .foregroundStyle(.primary)
                                        if let bundleID = choice.bundleID {
                                            Text(bundleID)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                        }
                                    }
                                    Spacer(minLength: 8)
                                    if choice.isSystemDefault {
                                        Text(L("defaultapp.picker.system"))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    if choice.isCurrent {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(.tint)
                                            .accessibilityLabel(L("defaultapp.picker.current"))
                                    }
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 6)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("defaultapp.choice.\(choice.bundleID ?? choice.name)")
                        }
                    }
                }
                .frame(maxHeight: 360)
            }
            Button(L("defaultapp.picker.other"), action: onBrowse)
                .accessibilityIdentifier("defaultapp.picker.other")
        }
        .padding(20)
        .frame(width: 440)
    }
}
