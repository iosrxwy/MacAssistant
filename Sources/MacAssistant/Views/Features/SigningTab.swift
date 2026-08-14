import SwiftUI
import AppKit
import UniformTypeIdentifiers
import MacAssistantKit

/// 签名:越狱(ldid / ad-hoc)与真机(真实证书由内向外逐层重签)。
struct SigningTab: View {
    enum Mode: String, CaseIterable, Identifiable {
        case jailbreak = "越狱 / 本地"
        case realDevice = "真机证书（Beta）"
        var id: String { rawValue }

        /// rawValue 同时是选中态的标识,展示一律走这里。
        var title: String {
            switch self {
            case .jailbreak: return L("signingtab.mode.jailbreak")
            case .realDevice: return L("signingtab.mode.realDevice")
            }
        }
    }

    @State private var mode: Mode = .jailbreak
    @State private var ipaURL: URL?

    // 越狱
    @State private var jbMethod: SignMethod = .codesignAdhoc

    // 真机
    @State private var identities: [SigningIdentity] = []
    @State private var selectedIdentity: SigningIdentity?
    @State private var targetSession: InjectionTargetSession?
    @State private var profilesByBundleID: [String: URL] = [:]
    @State private var overrideBundleID = ""

    @State private var busy = false
    @State private var ok: Bool?
    @State private var log = ""

    var body: some View {
        Group {
            Card {
                VStack(alignment: .leading, spacing: 10) {
                    Text(L("signingtab.chooseIPA")).font(.headline)
                    HStack {
                        FilePickerButton(title: L("signingtab.chooseIPA"), systemImage: "app.gift", types: [.ipaPackage, .data]) { url in
                            selectIPA(url)
                        }
                        Spacer()
                    }
                    PathBadge(url: ipaURL, placeholder: L("signingtab.noIPA"))
                }
            }

            Picker("", selection: $mode) {
                ForEach(Mode.allCases) { Text($0.title).tag($0) }
            }.pickerStyle(.segmented).labelsHidden()

            if mode == .jailbreak {
                jailbreakSection
            } else {
                realDeviceSection
            }

            if busy || !log.isEmpty {
                Card {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack { Text(L("signingtab.log")).font(.headline); if busy { ProgressView().controlSize(.small) }; Spacer(); StatusBadge(ok: ok) }
                        ConsoleView(text: log, minHeight: 180)
                    }
                }
            }
        }
    }

    private var jailbreakSection: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                Text(L("signingtab.jailbreak.title")).font(.headline)
                HStack {
                    Text(L("signingtab.method")).frame(width: 120, alignment: .leading)
                    Picker("", selection: $jbMethod) {
                        Text(SignMethod.codesignAdhoc.label).tag(SignMethod.codesignAdhoc)
                        Text(SignMethod.ldid.label).tag(SignMethod.ldid)
                    }.labelsHidden().frame(width: 220)
                    Spacer()
                }
                if jbMethod == .ldid, !ExternalTool.ldid.isAvailable {
                    Label(L("signingtab.ldidMissing"), systemImage: "info.circle")
                        .font(.footnote).foregroundStyle(.orange)
                }
                Text(L("signingtab.jailbreak.detail"))
                    .font(.footnote).foregroundStyle(.secondary)
                Button {
                    signJailbreak()
                } label: {
                    Label(busy ? L("signingtab.signing") : L("signingtab.sign"), systemImage: "signature").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .disabled(busy || ipaURL == nil)
            }
        }
    }

    private var realDeviceSection: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                Text(L("signingtab.realDevice.title")).font(.headline)
                DeveloperSigningPicker(
                    bundleIDs: signingBundleIDs,
                    identities: $identities,
                    selectedIdentity: $selectedIdentity,
                    profilesByBundleID: $profilesByBundleID
                )
                VStack(alignment: .leading, spacing: 4) {
                    Text(L("signingtab.overrideBundleID")).font(.subheadline.weight(.medium))
                    TextField(L("signingtab.bundleID.placeholder"), text: $overrideBundleID).textFieldStyle(.roundedBorder)
                }
                Text(L("signingtab.realDevice.detail"))
                    .font(.caption).foregroundStyle(.secondary)
                Button {
                    signRealDevice()
                } label: {
                    Label(busy ? L("signingtab.signing") : L("signingtab.resignLayered"), systemImage: "signature").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .disabled(
                    busy || ipaURL == nil || selectedIdentity == nil
                        || signingBundleIDs.isEmpty
                        || Set(signingBundleIDs).contains { profilesByBundleID[$0] == nil }
                )
            }
        }
    }

    private func signJailbreak() {
        guard let ipa = ipaURL else { return }
        let method = jbMethod
        busy = true; ok = nil; log = ""
        Task {
            do {
                let (out, lines) = try await Task.detached {
                    try FileSystemHelper.withSecurityScopedAccess(to: [ipa]) {
                        try SigningService.resignIPAJailbreak(ipaAt: ipa, method: method)
                    }
                }.value
                log = ([L("signingtab.done"), L("signingtab.output", out.path), "———"] + lines).joined(separator: "\n")
                ok = true; revealInFinder(out)
            } catch { ok = false; log = "❌ " + operationError(error, paths: [ipa]) }
            busy = false
        }
    }

    private func signRealDevice() {
        guard let ipa = ipaURL, let identity = selectedIdentity, !signingBundleIDs.isEmpty else { return }
        let bid = overrideBundleID.trimmingCharacters(in: .whitespaces)
        let activeProfiles = profilesByBundleID.filter { signingBundleIDs.contains($0.key) }
        let recipe = RealDeviceSigningRecipe(
            identityID: identity.id,
            identityName: identity.name,
            profilesByBundleID: activeProfiles
        )
        busy = true; ok = nil; log = ""
        Task {
            do {
                let (out, lines) = try await Task.detached {
                    try FileSystemHelper.withSecurityScopedAccess(to: [ipa] + Array(recipe.profilesByBundleID.values)) {
                        try SigningService.resignIPARealDeviceGraph(
                            ipaAt: ipa,
                            recipe: recipe,
                            overrideBundleID: bid.isEmpty ? nil : bid
                        )
                    }
                }.value
                log = ([L("signingtab.realDevice.done"), L("signingtab.output", out.path), "———"] + lines).joined(separator: "\n")
                ok = true; revealInFinder(out)
            } catch {
                ok = false
                log = "❌ " + operationError(
                    error,
                    paths: [ipa] + Array(recipe.profilesByBundleID.values)
                )
            }
            busy = false
        }
    }

    private var signingBundleIDs: [String] {
        guard let app = targetSession?.appURL else { return [] }
        let bid = overrideBundleID.trimmingCharacters(in: .whitespaces)
        return (try? SigningService.profileBundleIDs(
            in: app,
            overridingRootBundleID: bid.isEmpty ? nil : bid
        )) ?? []
    }

    private func selectIPA(_ url: URL) {
        ipaURL = url
        targetSession = nil
        profilesByBundleID = [:]
        log = ""
        ok = nil
        Task {
            let session = try? await Task.detached {
                try FileSystemHelper.withSecurityScopedAccess(to: [url]) {
                    try InjectionTargetDiscovery.open(.ipa(url))
                }
            }.value
            targetSession = session
            if let app = session?.appURL,
               let plist = try? IpaService.infoPlist(appBundle: app) {
                overrideBundleID = plist["CFBundleIdentifier"] as? String ?? ""
            }
        }
    }

    private func operationError(_ error: Error, paths: [URL]) -> String {
        FileSystemHelper.isAccessPermissionError(error)
            ? FileSystemHelper.userFacingAccessError(error, paths: paths)
            : error.localizedDescription
    }
}

/// 一个共享的 .p12 开发者证书，以及每个嵌套 bundle 自己的 profile。
struct DeveloperSigningPicker: View {
    let bundleIDs: [String]
    @Binding var identities: [SigningIdentity]
    @Binding var selectedIdentity: SigningIdentity?
    @Binding var profilesByBundleID: [String: URL]

    @State private var p12URL: URL?
    @State private var p12Password = ""
    @State private var certificateMessage = ""
    @State private var certificateBusy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    FilePickerButton(
                        title: p12URL?.lastPathComponent ?? L("signingtab.chooseP12"),
                        systemImage: "key.fill",
                        types: [.item]
                    ) { url in
                        guard ["p12", "pfx"].contains(url.pathExtension.lowercased()) else { return }
                        p12URL = url
                        certificateMessage = ""
                    }
                    SecureField(L("signingtab.p12Password"), text: $p12Password)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 220)
                    Button {
                        importP12()
                    } label: {
                        Label(L("signingtab.importP12"), systemImage: "arrow.down.doc")
                    }
                    .disabled(certificateBusy || p12URL == nil)
                }
                HStack {
                    if let selectedIdentity {
                        Label(L("signingtab.p12Identity", selectedIdentity.name), systemImage: "checkmark.seal")
                    } else {
                        Text(L("signingtab.p12Hint"))
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        exportP12()
                    } label: {
                        Label(L("signingtab.exportP12"), systemImage: "square.and.arrow.up")
                    }
                    .disabled(certificateBusy || selectedIdentity == nil)
                }
                if !certificateMessage.isEmpty {
                    Text(certificateMessage)
                        .font(.caption)
                        .foregroundStyle(certificateMessage.hasPrefix("❌") ? .red : .secondary)
                }
            }

            if bundleIDs.isEmpty {
                Text(L("signingtab.loadingBundles"))
                    .font(.footnote).foregroundStyle(.secondary)
            } else {
                ForEach(bundleIDs, id: \.self) { bundleID in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(bundleID).font(.caption.monospaced())
                        FilePickerButton(
                            title: profilesByBundleID[bundleID]?.lastPathComponent
                                ?? L("signingtab.chooseProfile"),
                            systemImage: "doc.badge.gearshape",
                            types: [.item]
                        ) { url in
                            profilesByBundleID[bundleID] = url
                        }
                    }
                }
            }
            Text(L("signingtab.profileMappingDetail"))
                .font(.caption).foregroundStyle(.secondary)
        }
        .task { restoreStoredCertificate() }
    }

    private func restoreStoredCertificate() {
        p12URL = SigningService.storedDeveloperCertificateURL()
        p12Password = SigningService.rememberedDeveloperCertificatePassword() ?? ""
        identities = SigningService.identities()
        if let id = SigningService.rememberedDeveloperCertificateIdentityID() {
            selectedIdentity = identities.first { $0.id.caseInsensitiveCompare(id) == .orderedSame }
        }
    }

    private func importP12() {
        guard let url = p12URL else { return }
        let password = p12Password
        certificateBusy = true
        certificateMessage = ""
        Task {
            do {
                let identity = try await Task.detached {
                    try FileSystemHelper.withSecurityScopedAccess(to: [url]) {
                        try SigningService.importDeveloperCertificate(p12At: url, password: password)
                    }
                }.value
                identities = SigningService.identities()
                selectedIdentity = identity
                certificateMessage = L("signingtab.p12Imported")
            } catch {
                certificateMessage = "❌ " + error.localizedDescription
            }
            certificateBusy = false
        }
    }

    private func exportP12() {
        guard let identity = selectedIdentity else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "p12") ?? .data]
        panel.nameFieldStringValue = "DeveloperCertificate.p12"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let alert = NSAlert()
        alert.messageText = L("signingtab.exportPasswordTitle")
        alert.informativeText = L("signingtab.exportPasswordHint")
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        alert.accessoryView = field
        alert.addButton(withTitle: L("signingtab.exportConfirm"))
        alert.addButton(withTitle: L("signingtab.cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let password = field.stringValue
        certificateBusy = true
        certificateMessage = ""
        Task {
            do {
                try await Task.detached {
                    try FileSystemHelper.withSecurityScopedAccess(to: [url]) {
                        try SigningService.exportDeveloperCertificate(identity: identity, to: url, password: password)
                    }
                }.value
                certificateMessage = L("signingtab.p12Exported", url.path)
            } catch {
                certificateMessage = "❌ " + error.localizedDescription
            }
            certificateBusy = false
        }
    }
}
