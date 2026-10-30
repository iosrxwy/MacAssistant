import AppKit
import SwiftUI
import MacAssistantKit

struct AppUninstallView: View {
    @ObservedObject private var library = MacAppLibraryMonitor.shared
    @StateObject private var model = AppUninstallModel()
    @State private var selectedApp: URL?
    @State private var showConfirm = false
    @State private var didAutoSelect = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(SidebarItem.appUninstall.title).font(.largeTitle.bold())
                Text(L("appuninstall.subtitle"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 24)
            .padding(.top, 24)
            .padding(.bottom, 12)

            VStack(alignment: .leading, spacing: 12) {
                PermissionGuideCard(needs: PermissionGuide.appUninstall)
                GeometryReader { proxy in
                    HStack(alignment: .top, spacing: 16) {
                        MacAppLibraryPane(
                            library: library,
                            selection: $selectedApp,
                            interactionLocked: model.isUninstalling,
                            fillsAvailableHeight: true
                        )
                        .frame(width: 270, height: proxy.size.height, alignment: .top)

                        detail
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                            .frame(height: proxy.size.height)
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .featureSurfaceBackground()
        .onAppear {
            library.ensureLoaded()
            autoSelectIfNeeded()
        }
        .onChange(of: library.visibleApps) { _ in
            pruneMissingSelection()
            autoSelectIfNeeded()
        }
        .onChange(of: selectedApp) { app in
            model.scan(app)
        }
        .confirmationDialog(
            L("appuninstall.confirm.title"),
            isPresented: $showConfirm,
            titleVisibility: .visible
        ) {
            Button(L("appuninstall.confirm.action"), role: .destructive) {
                let app = selectedApp
                Task {
                    await model.uninstall()
                    if let app, !FileSystemHelper.isDirectory(app) {
                        library.extras.removeAll { $0.standardizedFileURL.path == app.standardizedFileURL.path }
                        library.reload()
                        selectedApp = nil
                        didAutoSelect = true
                    }
                }
            }
            Button(L("common.cancel"), role: .cancel) {}
        } message: {
            Text(L("appuninstall.confirm.message", model.selectedCount, model.selectedSizeText))
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let selectedApp {
            VStack(alignment: .leading, spacing: 12) {
                header(selectedApp)
                if let block = model.survey?.block {
                    Card {
                        Label(L("appuninstall.block.\(block.rawValue)"), systemImage: "lock.fill")
                            .font(.callout)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Spacer(minLength: 0)
                } else {
                    itemsCard
                }
                footnote
            }
        } else {
            Card {
                VStack(spacing: 8) {
                    Image(systemName: model.status.isEmpty ? "square.grid.3x3" : "checkmark.circle")
                        .font(.title)
                        .foregroundStyle(model.status.isEmpty ? Color.secondary : Color.appAccent)
                    Text(model.status.isEmpty ? L("appuninstall.noSelection") : model.status)
                        .font(.headline)
                        .multilineTextAlignment(.center)
                    Text(L("appuninstall.noSelectionDetail"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func header(_ app: URL) -> some View {
        let version = MacAppLibrary.marketingVersion(of: app)
        let bundleID = model.survey?.bundleID ?? MacAppLibrary.bundleID(of: app)
        let identity = [bundleID, version].compactMap { $0 }.joined(separator: " · ")
        return Card(padding: 14) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center, spacing: 14) {
                    Image(nsImage: MacAppIconCache.image(for: app, pointSize: 128))
                        .resizable()
                        .renderingMode(.original)
                        .interpolation(.high)
                        .frame(width: 64, height: 64)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 8) {
                            Text(MacAppLibrary.displayName(of: app))
                                .font(.title3.weight(.semibold))
                                .lineLimit(1)
                            if model.isRunning {
                                Text(L("appuninstall.running"))
                                    .font(.caption2.weight(.semibold))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.orange.opacity(0.16), in: Capsule())
                            }
                        }
                        Text(identity.isEmpty ? app.lastPathComponent : identity)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        HStack(spacing: 4) {
                            Text(app.path)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .textSelection(.enabled)
                            Button {
                                reveal(app)
                            } label: {
                                Image(systemName: "folder")
                            }
                            .buttonStyle(.borderless)
                            .help(L("macappview.reveal"))
                            .accessibilityLabel(L("macappview.reveal"))
                        }
                    }
                    Spacer(minLength: 0)
                }
                HStack(spacing: 8) {
                    Button {
                        model.scan(app)
                    } label: {
                        Label(
                            model.isScanning ? L("appuninstall.scanning") : L("appuninstall.rescan"),
                            systemImage: "arrow.clockwise"
                        )
                    }
                    .disabled(model.isBusy)
                    .keyboardShortcut("r", modifiers: [.command])
                    .glassActionButtonStyle()
                    Button(role: .destructive) {
                        showConfirm = true
                    } label: {
                        Label(L("appuninstall.uninstall"), systemImage: "trash")
                    }
                    .disabled(!model.canUninstall)
                    .glassActionButtonStyle(prominent: model.canUninstall)
                    .accessibilityIdentifier("appuninstall.moveToTrash")
                    Spacer(minLength: 0)
                    if model.isBusy {
                        ProgressView().controlSize(.small)
                        Text(model.isScanning ? L("appuninstall.scanning") : model.status)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .labelStyle(.titleAndIcon)
                if !model.status.isEmpty, !model.isBusy {
                    Text(model.status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        }
    }

    private var itemsCard: some View {
        Card(padding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                selectionHeader
                    .padding(.horizontal, 14)
                    .padding(.top, 12)
                    .padding(.bottom, 10)
                Divider().opacity(0.45)
                Group {
                    if model.isScanning, model.survey == nil {
                        ProgressView(L("appuninstall.scanning"))
                            .controlSize(.small)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if model.survey?.items.isEmpty == true {
                        Text(L("appuninstall.empty"))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ScrollView {
                            LazyVStack(spacing: 0) {
                                ForEach(model.survey?.items ?? []) { item in
                                    UninstallItemRow(
                                        item: item,
                                        selected: model.isSelected(item),
                                        enabled: !model.isBusy,
                                        toggle: { model.toggle(item) },
                                        reveal: { reveal(URL(fileURLWithPath: item.path)) }
                                    )
                                }
                            }
                            .padding(.vertical, 6)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                if let roots = model.survey?.unreadableRoots, !roots.isEmpty {
                    Text(L("appuninstall.unreadable", roots.count))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 14)
                        .padding(.bottom, 12)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var selectionHeader: some View {
        HStack(alignment: .center, spacing: 12) {
            Button(action: model.toggleAll) {
                HStack(spacing: 6) {
                    Image(systemName: bulkSymbol)
                        .font(.body)
                        .foregroundStyle(Color.appAccent)
                        .symbolRenderingMode(.hierarchical)
                    Text(model.allSelected ? L("appuninstall.deselectAll") : L("appuninstall.selectAll"))
                        .font(.callout.weight(.semibold))
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
            .disabled(model.isBusy || (model.survey?.items.isEmpty ?? true))
            .accessibilityIdentifier("appuninstall.selectAll")

            Text(L("appuninstall.related"))
                .font(.headline)
            Spacer(minLength: 8)
            if model.survey != nil {
                VStack(alignment: .trailing, spacing: 1) {
                    Text(model.selectedSizeText)
                        .font(.title3.weight(.semibold).monospacedDigit())
                    Text(L("appuninstall.selectedSummary", model.selectedCount))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if model.isScanning {
                ProgressView().controlSize(.small)
            }
        }
    }

    private var bulkSymbol: String {
        if model.selectedCount == 0 { return "square" }
        if model.allSelected { return "checkmark.square.fill" }
        return "minus.square.fill"
    }

    private var footnote: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "info.circle")
            Text(L("appuninstall.footnote"))
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func autoSelectIfNeeded() {
        guard !didAutoSelect, selectedApp == nil, let first = library.visibleApps.first else { return }
        selectedApp = first
        didAutoSelect = true
    }

    private func pruneMissingSelection() {
        let known = Set((library.apps + library.extras).map(\.standardizedFileURL.path))
        guard let selectedApp else { return }
        if known.contains(selectedApp.standardizedFileURL.path) == false,
           !FileSystemHelper.isDirectory(selectedApp) {
            self.selectedApp = nil
            didAutoSelect = true
        }
    }
}

private struct UninstallItemRow: View {
    let item: AppUninstallItem
    let selected: Bool
    let enabled: Bool
    let toggle: () -> Void
    let reveal: () -> Void

    @State private var hovering = false

    var body: some View {
        Group {
            if selected || (hovering && enabled) {
                row.insetSurfaceBackground(
                    RoundedRectangle(cornerRadius: 8, style: .continuous),
                    legacyFill: Color.primary.opacity(selected ? 0.035 : 0.05),
                    glassFill: AnyShapeStyle(Color.primary.opacity(selected ? 0.055 : 0.07)),
                    stroke: selected ? Color.appAccent.opacity(0.22) : nil
                )
            } else {
                row
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .animation(.easeOut(duration: 0.12), value: selected)
    }

    private var row: some View {
        HStack(spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: selected ? "checkmark.square.fill" : "square")
                    .font(.body)
                    .foregroundStyle(enabled ? Color.appAccent : Color.secondary)
                    .symbolRenderingMode(.hierarchical)
                    .frame(width: 22)
                Image(nsImage: MacAppIconCache.image(for: URL(fileURLWithPath: item.path), pointSize: 64))
                    .resizable()
                    .renderingMode(.original)
                    .interpolation(.high)
                    .frame(width: 32, height: 32)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(L("appuninstall.kind.\(item.kind.rawValue)"))
                            .font(.callout.weight(selected ? .semibold : .medium))
                            .lineLimit(1)
                        if item.match == .applicationName {
                            Text(L("appuninstall.match.name"))
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.orange)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Color.orange.opacity(0.14), in: Capsule())
                        }
                    }
                    Text(item.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 8)
                Text(FileSystemHelper.humanReadableSize(item.bytes))
                    .font(.callout.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.primary)
                    .frame(minWidth: 64, alignment: .trailing)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                guard enabled else { return }
                toggle()
            }
            .help(item.path)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityAddTraits(selected ? .isSelected : [])

            Button(action: reveal) {
                Image(systemName: "folder")
                    .frame(width: 22, height: 22)
                    .foregroundStyle(hovering ? Color.appAccent : Color.secondary)
            }
            .buttonStyle(.borderless)
            .disabled(!enabled)
            .help(L("macappview.reveal"))
            .accessibilityLabel(L("macappview.reveal"))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }
}

@MainActor
final class AppUninstallModel: ObservableObject {
    @Published private(set) var survey: AppUninstallSurvey?
    @Published private(set) var selectedIDs: Set<String> = []
    @Published private(set) var isScanning = false
    @Published private(set) var isUninstalling = false
    @Published private(set) var isRunning = false
    @Published var status = ""

    private var scanTask: Task<Void, Never>?
    private var app: URL?

    var isBusy: Bool { isScanning || isUninstalling }

    var canUninstall: Bool {
        survey?.block == nil && !selectedIDs.isEmpty && !isBusy
    }

    var allSelected: Bool {
        let items = survey?.items ?? []
        return !items.isEmpty && items.allSatisfy { selectedIDs.contains($0.id) }
    }

    var selectedCount: Int { selectedIDs.count }

    var selectedSizeText: String {
        let bytes = (survey?.items ?? [])
            .filter { selectedIDs.contains($0.id) }
            .reduce(Int64(0)) { $0 + $1.bytes }
        return FileSystemHelper.humanReadableSize(bytes)
    }

    func isSelected(_ item: AppUninstallItem) -> Bool {
        selectedIDs.contains(item.id)
    }

    func toggle(_ item: AppUninstallItem) {
        if selectedIDs.contains(item.id) {
            selectedIDs.remove(item.id)
        } else {
            selectedIDs.insert(item.id)
        }
    }

    func toggleAll() {
        if allSelected {
            selectedIDs.removeAll()
        } else {
            selectedIDs = Set((survey?.items ?? []).map(\.id))
        }
    }

    func scan(_ app: URL?, keepStatus: Bool = false) {
        scanTask?.cancel()
        self.app = app
        if app != nil, !keepStatus {
            status = ""
        }
        guard let app else {
            survey = nil
            selectedIDs = []
            isScanning = false
            isRunning = false
            return
        }
        survey = nil
        selectedIDs = []
        isRunning = Self.running(app)
        isScanning = true
        scanTask = Task.detached(priority: .userInitiated) { [app] in
            let survey = AppUninstallService.survey(app: app)
            await MainActor.run { [weak self] in
                guard let self, self.app?.path == app.path else { return }
                self.survey = survey
                self.selectedIDs = Set(survey.items.map(\.id))
                self.isScanning = false
                self.isRunning = Self.running(app)
            }
        }
    }

    func uninstall() async {
        guard let app, let survey, survey.block == nil else { return }
        let paths = survey.items.map(\.path).filter { selectedIDs.contains($0) }
        guard !paths.isEmpty else { return }
        isUninstalling = true
        status = L("appuninstall.status.quitting")
        if isRunning {
            let stopped = await Self.stop(app)
            isRunning = !stopped
        }
        status = L("appuninstall.status.trashing")
        let result = await Task.detached {
            try? AppUninstallService.uninstall(app: app, paths: paths)
        }.value
        isUninstalling = false
        if let result {
            if result.failures.isEmpty {
                status = L("appuninstall.status.done", result.trashed.count)
            } else {
                status = L("appuninstall.status.partial", result.trashed.count, result.failures.count)
            }
        } else {
            status = L("appuninstall.status.failed")
        }
        scan(FileSystemHelper.isDirectory(app) ? app : nil, keepStatus: true)
    }

    private static func running(_ app: URL) -> Bool {
        let path = app.standardizedFileURL.resolvingSymlinksInPath().path
        return NSWorkspace.shared.runningApplications.contains { process in
            process.bundleURL?.standardizedFileURL.resolvingSymlinksInPath().path == path
        }
    }

    private static func stop(_ app: URL) async -> Bool {
        let path = app.standardizedFileURL.resolvingSymlinksInPath().path
        let processes = NSWorkspace.shared.runningApplications.filter { process in
            process.bundleURL?.standardizedFileURL.resolvingSymlinksInPath().path == path
        }
        guard !processes.isEmpty else { return true }
        processes.forEach { $0.terminate() }
        if await waitUntilStopped(path, seconds: 2) { return true }
        NSWorkspace.shared.runningApplications
            .filter { $0.bundleURL?.standardizedFileURL.resolvingSymlinksInPath().path == path }
            .forEach { $0.forceTerminate() }
        return await waitUntilStopped(path, seconds: 1)
    }

    private static func waitUntilStopped(_ path: String, seconds: Double) async -> Bool {
        let steps = Int(seconds / 0.2)
        for _ in 0..<max(steps, 1) {
            try? await Task.sleep(nanoseconds: 200_000_000)
            let still = NSWorkspace.shared.runningApplications.contains { process in
                process.bundleURL?.standardizedFileURL.resolvingSymlinksInPath().path == path
            }
            if !still { return true }
        }
        return false
    }
}
