import AppKit
import SwiftUI
import MacAssistantKit

/// macOS 本机应用工作台：左侧应用库，右侧可注入或卸除插件；隔离登录请走应用分身页。
struct MacAppView: View {
    @ObservedObject var workspace: WorkspaceStore
    @ObservedObject private var library = MacAppLibraryMonitor.shared
    @State private var selectedApp: URL?
    @State private var showingClone = false
    @State private var showingGuide = false
    @State private var launchError = ""

    var body: some View {
        FeatureScaffold(
            title: L("macappview.title"),
            subtitle: L("macappview.subtitle"),
            content: {
            PermissionGuideCard(needs: PermissionGuide.macApp)

            HStack(alignment: .top, spacing: 16) {
                MacAppLibraryPane(library: library, selection: $selectedApp)
                    .frame(width: 270)

                VStack(alignment: .leading, spacing: 16) {
                    if let selectedApp {
                        appHeader(selectedApp)
                        InjectedPluginPane(app: selectedApp) { self.selectedApp = $0 }
                        TweakInjectTab(
                            inputMode: .macOSApp,
                            initialInput: selectedApp,
                            managedInput: true
                        )
                        .id(selectedApp.standardizedFileURL.path)
                    } else {
                        Card {
                            VStack(spacing: 8) {
                                Image(systemName: "app.dashed").font(.title)
                                Text(L("macappview.noSelection")).font(.headline)
                                Text(L("macappview.noSelectionDetail"))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity)
                            .frame(maxWidth: .infinity, minHeight: 360)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            },
            trailing: {
                Button {
                    showingGuide = true
                } label: {
                    Label(L("macappview.guide"), systemImage: "questionmark.circle")
                }
                .buttonStyle(.borderless)
                .help(L("macappview.guide.help"))
            }
        )
        .onAppear { library.ensureLoaded() }
        .onChange(of: library.apps) { _ in
            let known = Set(library.apps + library.extras)
            if let selectedApp, known.contains(selectedApp) == false {
                self.selectedApp = nil
            }
            if selectedApp == nil {
                selectedApp = library.visibleApps.first
            }
        }
        .sheet(isPresented: $showingClone) {
            if let selectedApp {
                MacAppCloneSheet(sourceURL: selectedApp) { output in
                    library.addExtra(output)
                    self.selectedApp = output
                }
            }
        }
        .sheet(isPresented: $showingGuide) {
            MacAppGuideSheet()
        }
        .alert(L("macappview.launchFailed"), isPresented: Binding(
            get: { !launchError.isEmpty },
            set: { if !$0 { launchError = "" } }
        )) {
            Button(L("macappview.clone.cancel"), role: .cancel) { launchError = "" }
        } message: {
            Text(launchError)
        }
    }

    private func appHeader(_ app: URL) -> some View {
        Card(padding: 14) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    Image(nsImage: MacAppIconCache.image(for: app))
                        .resizable()
                        .frame(width: 56, height: 56)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(MacAppLibrary.displayName(of: app)).font(.title3.weight(.semibold))
                        Text(MacAppLibrary.copyLabel(of: app))
                            .font(.callout.weight(.medium))
                            .foregroundStyle(.primary)
                        Text(app.path)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                    Spacer(minLength: 0)
                }
                HStack(spacing: 8) {
                    Button(L("macappview.open")) { open(app) }
                    Button(L("macappview.reveal")) {
                        NSWorkspace.shared.activateFileViewerSelecting([app])
                    }
                    Button(L("macappview.clone")) { showingClone = true }
                    Button(L("macappview.isolatedClone")) {
                        workspace.requestAppClone(source: app)
                    }
                    .buttonStyle(.borderedProminent)
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private func open(_ app: URL) {
        Task {
            do {
                try await MacAppLaunchService.open(app)
            } catch {
                launchError = error.localizedDescription
            }
        }
    }
}

/// 注入页、分身页、卸载页共用的本机应用列表。一行一个。
struct MacAppLibraryPane: View {
    @ObservedObject var library: MacAppLibraryMonitor
    @Binding var selection: URL?
    var interactionLocked = false
    /// 卸载页把左栏拉满窗口高度；注入页和分身页保持内容高度。
    var fillsAvailableHeight = false

    var body: some View {
        Card(padding: 10) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(L("macappview.library")).font(.headline)
                    Spacer()
                    Button { library.reload() } label: {
                        if library.isScanning {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .buttonStyle(.borderless)
                    .disabled(library.isScanning || interactionLocked)
                    .help(L("macappview.refresh"))
                    .accessibilityLabel(L("macappview.refresh"))
                }

                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField(L("macappview.search"), text: $library.searchText)
                        .textFieldStyle(.plain)
                }
                .padding(7)
                .insetSurfaceBackground(
                    RoundedRectangle(cornerRadius: 8),
                    legacyFill: Color.primary.opacity(0.06)
                )
                .disabled(interactionLocked)

                libraryList

                FilePickerButton(
                    title: L("macappview.chooseApp"),
                    systemImage: "plus",
                    chooseDirectory: true
                ) { url in
                    guard !interactionLocked, url.pathExtension.lowercased() == "app" else { return }
                    library.addExtra(url)
                    selection = url
                }
                .disabled(interactionLocked)
            }
            .modifier(LibraryPaneFill(enabled: fillsAvailableHeight))
        }
    }

    @ViewBuilder
    private var libraryList: some View {
        if library.visibleApps.isEmpty {
            Group {
                if library.isScanning {
                    ProgressView(L("macappview.scanning"))
                        .controlSize(.small)
                } else {
                    Text(L("macappview.noSelection"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 360)
            .modifier(LibraryPaneFill(enabled: fillsAvailableHeight))
        } else {
            ScrollView {
                LazyVStack(spacing: 1) {
                    ForEach(library.visibleApps, id: \.self) { app in
                        Button {
                            guard !interactionLocked else { return }
                            selection = app
                        } label: {
                            HStack(spacing: 8) {
                                Image(nsImage: MacAppIconCache.image(for: app))
                                    .resizable()
                                    .frame(width: 28, height: 28)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(MacAppLibrary.displayName(of: app))
                                        .foregroundStyle(Color.primary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    Text(MacAppLibrary.copyLabel(of: app))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(QuietRowButtonStyle(selected: isCurrent(app)))
                        .disabled(interactionLocked)
                    }
                }
                .animation(nil, value: selection)
            }
            .frame(minHeight: 360)
            .modifier(LibraryPaneFill(enabled: fillsAvailableHeight))
            .accessibilityIdentifier("macapp.library")
        }
    }

    private func isCurrent(_ app: URL) -> Bool {
        selection?.standardizedFileURL.path == app.standardizedFileURL.path
    }
}

private struct LibraryPaneFill: ViewModifier {
    var enabled: Bool

    func body(content: Content) -> some View {
        if enabled {
            content.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        } else {
            content
        }
    }
}

private struct MacAppGuideSheet: View {
    @SwiftUI.Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text(L("macappview.guide.title")).font(.title3.weight(.semibold))
                Spacer()
                Button(L("macappview.clone.cancel")) { dismiss() }
            }
            guideBlock(
                title: L("macappview.guide.permission.title"),
                detail: L("macappview.guide.permission.detail")
            )
            guideBlock(
                title: L("macappview.guide.clone.title"),
                detail: L("macappview.guide.clone.detail")
            )
            guideBlock(
                title: L("macappview.guide.inject.title"),
                detail: L("macappview.guide.inject.detail")
            )
            guideBlock(
                title: L("macappview.guide.uninject.title"),
                detail: L("macappview.guide.uninject.detail")
            )
            Spacer(minLength: 0)
        }
        .padding(22)
        .frame(width: 460, height: 480)
    }

    private func guideBlock(title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct MacAppCloneSheet: View {
    let sourceURL: URL
    let onComplete: (URL) -> Void
    @SwiftUI.Environment(\.dismiss) private var dismiss
    @State private var displayName: String
    @State private var bundleID: String
    @State private var signMethod: SignMethod = .codesignAdhoc
    @State private var stripNestedBundles = true
    @State private var stripLocalizedNames = true
    @State private var tintFinderIcon = true
    @State private var busy = false
    @State private var errorMessage = ""

    init(sourceURL: URL, onComplete: @escaping (URL) -> Void) {
        self.sourceURL = sourceURL
        self.onComplete = onComplete
        let plist = try? IpaService.infoPlist(appBundle: sourceURL)
        let originalName = (plist?["CFBundleDisplayName"] as? String)
            ?? sourceURL.deletingPathExtension().lastPathComponent
        let originalID = (plist?["CFBundleIdentifier"] as? String) ?? "com.example.app"
        _displayName = State(initialValue: L("macappview.clone.defaultName", originalName))
        _bundleID = State(initialValue: originalID + ".clone")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L("macappview.clone.title")).font(.title3.weight(.semibold))
            Text(sourceURL.path).font(.caption).foregroundStyle(.secondary)
            TextField(L("macappview.clone.displayName"), text: $displayName)
                .textFieldStyle(.soft)
            TextField(L("macappview.clone.bundleID"), text: $bundleID)
                .textFieldStyle(.soft)
            Picker(L("macappview.clone.signMethod"), selection: $signMethod) {
                Text(SignMethod.codesignAdhoc.label).tag(SignMethod.codesignAdhoc)
                Text(SignMethod.none.label).tag(SignMethod.none)
            }
            Toggle(L("macappview.clone.stripNested"), isOn: $stripNestedBundles)
            Toggle(L("macappview.clone.stripLocalized"), isOn: $stripLocalizedNames)
            Toggle(L("macappview.clone.tintIcon"), isOn: $tintFinderIcon)
            Text(L("macappview.clone.outputHint"))
                .font(.caption)
                .foregroundStyle(.secondary)
            if !errorMessage.isEmpty {
                Text(errorMessage).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button(L("macappview.clone.cancel")) { dismiss() }
                Button(busy ? L("macappview.clone.creating") : L("macappview.clone.create")) {
                    clone()
                }
                .buttonStyle(.borderedProminent)
                .disabled(busy)
            }
        }
        .padding(22)
        .frame(width: 460)
    }

    private func clone() {
        busy = true
        errorMessage = ""
        let options = MacAppCloneOptions(
            displayName: displayName,
            bundleID: bundleID,
            signMethod: signMethod,
            prep: AppCloneBundlePrep(
                stripNestedBundles: stripNestedBundles,
                stripProvisioningProfile: stripNestedBundles,
                stripLocalizedNames: stripLocalizedNames,
                tintFinderIcon: tintFinderIcon,
                iconIndex: 2
            )
        )
        Task {
            do {
                let output = try await Task.detached {
                    try FileSystemHelper.withSecurityScopedAccess(
                        to: [sourceURL, sourceURL.deletingLastPathComponent()]
                    ) {
                        try MacAppCloneService.clone(appAt: sourceURL, options: options)
                    }
                }.value
                onComplete(output)
                dismiss()
            } catch let caught {
                errorMessage = caught.localizedDescription
                busy = false
            }
        }
    }
}
