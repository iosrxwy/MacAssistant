import AppKit
import SwiftUI
import MacAssistantKit

/// 用本机 ipatool 搜索并下载自己账号的官方 IPA。不脱壳。
struct IpaStoreSection: View {
    var onUseForInstall: (URL) -> Void

    @State private var account: IpaStoreAccount?
    @State private var email = ""
    @State private var password = ""
    @State private var authCode = ""
    @State private var query = ""
    @State private var platform: IpaStorePlatform = .iphone
    @State private var apps: [IpaStoreApp] = []
    @State private var selectedAppID: Int64?
    @State private var versions: [IpaStoreVersion] = []
    @State private var selectedVersionID: String?
    @State private var outputDirectory: URL?
    @State private var purchaseIfNeeded = false
    @State private var resolveNames = true
    @State private var lastDownload: URL?
    @State private var toolAvailable = false
    @State private var busy = false
    @State private var ok: Bool?
    @State private var log = ""

    var body: some View {
        Group {
            accountCard
            searchCard
            if selectedApp != nil {
                versionCard
            }
            if busy || !log.isEmpty {
                Card {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(L("ipatransfer.log")).font(.headline)
                            if busy { ProgressView().controlSize(.small) }
                            Spacer()
                            StatusBadge(ok: ok)
                        }
                        ConsoleView(text: log, minHeight: 160)
                    }
                }
            }
        }
        .onAppear { refreshAccount() }
    }

    private var selectedApp: IpaStoreApp? {
        apps.first { $0.storeID == selectedAppID }
    }

    private var selectedVersion: IpaStoreVersion? {
        versions.first { $0.externalVersionID == selectedVersionID }
    }

    private var accountCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(L("ipastore.account")).font(.headline)
                    Spacer()
                    Button(L("ipastore.refreshAccount")) { refreshAccount() }
                        .disabled(busy)
                }
                if !toolAvailable {
                    Label(L("ipastore.toolMissing"), systemImage: "info.circle")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button(L("ipastore.openProject")) {
                            NSWorkspace.shared.open(ProductLinks.ipatoolProject)
                        }
                        Text("brew install ipatool")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                } else if let account {
                    Label(L("ipastore.signedIn", account.summary), systemImage: "checkmark.circle")
                        .font(.callout)
                    Button(L("ipastore.revoke"), role: .destructive) { revoke() }
                        .disabled(busy)
                } else {
                    Text(L("ipastore.login.hint"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        TextField(L("ipastore.email"), text: $email)
                            .textFieldStyle(.roundedBorder)
                        SecureField(L("ipastore.password"), text: $password)
                            .textFieldStyle(.roundedBorder)
                    }
                    TextField(L("ipastore.authCode"), text: $authCode)
                        .textFieldStyle(.roundedBorder)
                    Text(L("ipastore.authCode.hint"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button {
                        login()
                    } label: {
                        Label(L("ipastore.login"), systemImage: "person.badge.key")
                    }
                    .disabled(busy || email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || password.isEmpty)
                }
            }
        }
    }

    private var searchCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Text(L("ipastore.search")).font(.headline)
                HStack {
                    TextField(L("ipastore.search.placeholder"), text: $query)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { search() }
                    Picker("", selection: $platform) {
                        ForEach(IpaStorePlatform.allCases) { item in
                            Text(item.label).tag(item)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 140)
                    Button(L("ipastore.search.action")) { search() }
                        .disabled(busy || !toolAvailable || query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if apps.isEmpty {
                    Text(L("ipastore.search.empty"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    List(apps, selection: $selectedAppID) { app in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(app.name).font(.callout.weight(.medium))
                            Text(app.summary)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                        .tag(Optional(app.storeID))
                    }
                    .frame(minHeight: 140, maxHeight: 220)
                    .listStyle(.inset)
                }
            }
        }
    }

    private var versionCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(L("ipastore.versions")).font(.headline)
                    Spacer()
                    Toggle(L("ipastore.resolveNames"), isOn: $resolveNames)
                    Button(L("ipastore.listVersions")) { listVersions() }
                        .disabled(busy || selectedApp == nil || account == nil)
                }
                if let selectedApp {
                    Text(L("ipastore.selectedApp", selectedApp.name, selectedApp.bundleIdentifier, selectedApp.version))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if versions.isEmpty {
                    Text(L("ipastore.versions.empty"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    List(versions, selection: $selectedVersionID) { version in
                        Text(version.summary)
                            .font(.caption.monospaced())
                            .tag(Optional(version.externalVersionID))
                    }
                    .frame(minHeight: 120, maxHeight: 200)
                    .listStyle(.inset)
                }
                HStack {
                    FilePickerButton(
                        title: L("ipatransfer.chooseOutput"),
                        systemImage: "folder",
                        chooseDirectory: true
                    ) { outputDirectory = $0 }
                    PathBadge(url: outputDirectory, placeholder: L("ipatransfer.noOutput"))
                }
                Toggle(L("ipastore.purchase"), isOn: $purchaseIfNeeded)
                Text(L("ipastore.purchase.hint"))
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button {
                        download(versionID: nil)
                    } label: {
                        Label(
                            busy ? L("ipastore.downloading") : L("ipastore.downloadLatest"),
                            systemImage: "arrow.down.circle"
                        )
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(downloadDisabled)
                    Button {
                        download(versionID: selectedVersion?.externalVersionID)
                    } label: {
                        Label(L("ipastore.downloadVersion"), systemImage: "clock.arrow.circlepath")
                    }
                    .disabled(downloadDisabled || selectedVersion == nil)
                }
                .controlSize(.large)
                if let lastDownload {
                    HStack {
                        Button(L("ipastore.useForInstall")) {
                            onUseForInstall(lastDownload)
                        }
                        Button(L("ipastore.reveal")) {
                            revealInFinder(lastDownload)
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
        }
    }

    private var downloadDisabled: Bool {
        busy || selectedApp == nil || outputDirectory == nil || !toolAvailable || account == nil
    }

    private func refreshAccount() {
        busy = true
        ok = nil
        Task {
            let available = await Task.detached { IpaStoreService.isAvailable }.value
            toolAvailable = available
            guard available else {
                account = nil
                busy = false
                return
            }
            let current = await Task.detached { IpaStoreService.currentAccount() }.value
            account = current
            if let current {
                log = L("ipastore.signedIn", current.summary)
                ok = true
            } else {
                log = L("ipastore.login.needed")
                ok = nil
            }
            busy = false
        }
    }

    private func login() {
        let email = email.trimmingCharacters(in: .whitespacesAndNewlines)
        let password = password
        let code = authCode.trimmingCharacters(in: .whitespacesAndNewlines)
        busy = true
        ok = nil
        log = L("ipastore.loggingIn")
        Task {
            do {
                let signedIn = try await Task.detached {
                    try IpaStoreService.login(
                        email: email,
                        password: password,
                        authCode: code.isEmpty ? nil : code
                    )
                }.value
                account = signedIn
                self.password = ""
                authCode = ""
                log = L("ipastore.signedIn", signedIn.summary)
                ok = true
            } catch {
                ok = false
                log = "❌ " + error.localizedDescription
            }
            busy = false
        }
    }

    private func revoke() {
        busy = true
        ok = nil
        Task {
            do {
                try await Task.detached { try IpaStoreService.revoke() }.value
                account = nil
                log = L("ipastore.revoked")
                ok = true
            } catch {
                ok = false
                log = "❌ " + error.localizedDescription
            }
            busy = false
        }
    }

    private func search() {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let platform = platform
        busy = true
        ok = nil
        log = L("ipastore.searching")
        Task {
            do {
                let found = try await Task.detached {
                    try IpaStoreService.search(term, platform: platform)
                }.value
                apps = found
                versions = []
                selectedVersionID = nil
                selectedAppID = found.first?.storeID
                lastDownload = nil
                log = L("ipastore.search.done", found.count)
                ok = true
            } catch {
                ok = false
                log = "❌ " + error.localizedDescription
            }
            busy = false
        }
    }

    private func listVersions() {
        guard let app = selectedApp else { return }
        let resolve = resolveNames
        busy = true
        ok = nil
        log = L("ipastore.listingVersions")
        Task {
            do {
                let ids = try await Task.detached {
                    try IpaStoreService.listVersionIDs(app: app)
                }.value
                var listed = ids.map { IpaStoreVersion(externalVersionID: $0) }
                versions = listed
                selectedVersionID = listed.first?.externalVersionID
                log = L("ipastore.versions.done", listed.count)
                if resolve {
                    let cap = min(listed.count, 25)
                    let versionIDs = listed.prefix(cap).map(\.externalVersionID)
                    for (index, versionID) in versionIDs.enumerated() {
                        let metadata = try? await Task.detached {
                            try IpaStoreService.versionMetadata(
                                app: app,
                                externalVersionID: versionID
                            )
                        }.value
                        if let metadata {
                            listed[index] = metadata
                            versions = listed
                        }
                    }
                    log = L("ipastore.versions.resolved", cap, listed.count)
                }
                ok = true
            } catch {
                ok = false
                log = "❌ " + error.localizedDescription
            }
            busy = false
        }
    }

    private func download(versionID: String?) {
        guard let app = selectedApp, let directory = outputDirectory else { return }
        let platform = platform
        let purchase = purchaseIfNeeded
        busy = true
        ok = nil
        log = L("ipastore.downloading")
        Task {
            do {
                let result = try await Task.detached {
                    try FileSystemHelper.withSecurityScopedAccess(to: [directory]) {
                        try IpaStoreService.download(
                            app: app,
                            externalVersionID: versionID,
                            platform: platform,
                            toDirectory: directory,
                            purchaseIfNeeded: purchase
                        )
                    }
                }.value
                lastDownload = result.ipaURL
                log = ([L("ipatransfer.encryptedBadge"), result.ipaURL.path, "———"] + result.log)
                    .joined(separator: "\n")
                ok = true
                revealInFinder(result.ipaURL)
            } catch {
                ok = false
                log = "❌ " + operationError(error, paths: [directory])
            }
            busy = false
        }
    }

    private func operationError(_ error: Error, paths: [URL]) -> String {
        FileSystemHelper.isAccessPermissionError(error)
            ? FileSystemHelper.userFacingAccessError(error, paths: paths)
            : error.localizedDescription
    }
}
