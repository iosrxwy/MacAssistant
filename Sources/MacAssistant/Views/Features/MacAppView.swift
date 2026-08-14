import AppKit
import SwiftUI
import MacAssistantKit

/// macOS 本机应用工作台：左侧应用库，右侧插件注入与分身。
struct MacAppView: View {
    @State private var apps: [URL] = []
    @State private var selectedApp: URL?
    @State private var showingClone = false

    var body: some View {
        FeatureScaffold(title: L("macappview.title"), subtitle: L("macappview.subtitle")) {
            HStack(alignment: .top, spacing: 16) {
                appLibrary
                    .frame(width: 250)

                VStack(alignment: .leading, spacing: 16) {
                    if let selectedApp {
                        appHeader(selectedApp)
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
        }
        .task { reloadApps() }
        .sheet(isPresented: $showingClone) {
            if let selectedApp {
                MacAppCloneSheet(sourceURL: selectedApp) { output in
                    if !apps.contains(output) { apps.append(output) }
                    apps.sort { appName($0) < appName($1) }
                    self.selectedApp = output
                }
            }
        }
    }

    private var appLibrary: some View {
        Card(padding: 10) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(L("macappview.library")).font(.headline)
                    Spacer()
                    Button { reloadApps() } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .help(L("macappview.refresh"))
                }

                List(selection: $selectedApp) {
                    ForEach(apps, id: \.self) { app in
                        HStack(spacing: 8) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: app.path))
                                .resizable()
                                .frame(width: 28, height: 28)
                            Text(appName(app))
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .tag(app)
                    }
                }
                .listStyle(.plain)
                .frame(minHeight: 360)

                FilePickerButton(
                    title: L("macappview.chooseApp"),
                    systemImage: "plus",
                    chooseDirectory: true
                ) { url in
                    guard url.pathExtension.lowercased() == "app" else { return }
                    if !apps.contains(url) { apps.append(url) }
                    apps.sort { appName($0) < appName($1) }
                    selectedApp = url
                }
            }
        }
    }

    private func appHeader(_ app: URL) -> some View {
        Card(padding: 14) {
            HStack(spacing: 12) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: app.path))
                    .resizable()
                    .frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 3) {
                    Text(appName(app)).font(.title3.weight(.semibold))
                    Text(app.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                Spacer()
                Button(L("macappview.open")) { NSWorkspace.shared.open(app) }
                Button(L("macappview.reveal")) {
                    NSWorkspace.shared.activateFileViewerSelecting([app])
                }
                Button(L("macappview.clone")) { showingClone = true }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private func reloadApps() {
        let directories = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)
        ]
        let discovered = directories.flatMap { directory in
            (try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )) ?? []
        }.filter { $0.pathExtension.lowercased() == "app" && FileSystemHelper.isDirectory($0) }
        apps = Array(Set(discovered)).sorted { appName($0) < appName($1) }
        if let selectedApp, apps.contains(selectedApp) == false { self.selectedApp = nil }
        if selectedApp == nil { selectedApp = apps.first }
    }

    private func appName(_ app: URL) -> String {
        guard let plist = try? IpaService.infoPlist(appBundle: app) else {
            return app.deletingPathExtension().lastPathComponent
        }
        return (plist["CFBundleDisplayName"] as? String)
            ?? (plist["CFBundleName"] as? String)
            ?? app.deletingPathExtension().lastPathComponent
    }
}

private struct MacAppCloneSheet: View {
    let sourceURL: URL
    let onComplete: (URL) -> Void
    @SwiftUI.Environment(\.dismiss) private var dismiss
    @State private var displayName: String
    @State private var bundleID: String
    @State private var signMethod: SignMethod = .codesignAdhoc
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
                .textFieldStyle(.roundedBorder)
            TextField(L("macappview.clone.bundleID"), text: $bundleID)
                .textFieldStyle(.roundedBorder)
            Picker(L("macappview.clone.signMethod"), selection: $signMethod) {
                Text(SignMethod.codesignAdhoc.label).tag(SignMethod.codesignAdhoc)
                Text(SignMethod.none.label).tag(SignMethod.none)
            }
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
        .frame(width: 440)
    }

    private func clone() {
        busy = true
        errorMessage = ""
        let options = MacAppCloneOptions(
            displayName: displayName,
            bundleID: bundleID,
            signMethod: signMethod
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
