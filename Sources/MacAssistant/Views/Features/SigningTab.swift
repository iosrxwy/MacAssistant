import SwiftUI
import AppKit
import UniformTypeIdentifiers
import MacAssistantKit

/// 签名:越狱(ldid / ad-hoc)与真机(真实证书由内向外逐层重签)。
struct SigningTab: View {
    enum Mode: String, CaseIterable, Identifiable {
        case jailbreak = "越狱 / 本地"
        case realDevice = "真机证书（Beta）"
        case appleID = "Apple ID 签名"
        var id: String { rawValue }

        /// rawValue 同时是选中态的标识,展示一律走这里。
        var title: String {
            switch self {
            case .jailbreak: return L("signingtab.mode.jailbreak")
            case .realDevice: return L("signingtab.mode.realDevice")
            case .appleID: return L("signingtab.mode.appleID")
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

    // Apple ID
    @State private var appleID = ""
    @State private var appleIDPassword = ""
    @State private var rememberAppleID = true
    @State private var twoFactorCode = ""
    @State private var devices: [ConnectedDevice] = []
    @State private var selectedDeviceID: String?
    @State private var manualUDID = ""
    @State private var manualDeviceName = ""
    @State private var teams: [AppleDeveloperServices.Team] = []
    @State private var selectedTeamID: String?
    @State private var portalDevices: [AppleDeveloperServices.RemoteDevice] = []
    @State private var portalCertificates: [AppleDeveloperServices.RemoteCertificate] = []
    @State private var portalAppIDs: [AppleDeveloperServices.RemoteAppID] = []
    @State private var installToDevice = true
    @State private var addRenewal = true
    @State private var renewalJobs: [AppleIDRenewalJob] = []
    @State private var deviceMessage = ""

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

            switch mode {
            case .jailbreak: jailbreakSection
            case .realDevice: realDeviceSection
            case .appleID: appleIDSection
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

    private var appleIDSection: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                Text(L("signingtab.appleID.title")).font(.headline)
                Text(L("signingtab.appleID.detail"))
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    TextField(L("signingtab.appleID.account"), text: $appleID)
                        .textFieldStyle(.roundedBorder)
                    SecureField(L("signingtab.appleID.password"), text: $appleIDPassword)
                        .textFieldStyle(.roundedBorder)
                }
                HStack {
                    Toggle(L("signingtab.appleID.remember"), isOn: $rememberAppleID)
                    Spacer()
                    if AppleIDSigningService.rememberedAccount() != nil {
                        Button(L("signingtab.appleID.forget")) {
                            AppleIDSigningService.forgetAccount()
                            appleID = ""
                            appleIDPassword = ""
                        }
                        .buttonStyle(.borderless)
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                    TextField(L("signingtab.appleID.twoFactor"), text: $twoFactorCode)
                        .textFieldStyle(.roundedBorder)
                    Text(L("signingtab.appleID.twoFactor.hint"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button {
                    loginAppleID()
                } label: {
                    Label(L("signingtab.appleID.login"), systemImage: "person.badge.key")
                }
                .disabled(busy || appleID.isEmpty || appleIDPassword.isEmpty)

                if !teams.isEmpty {
                    HStack {
                        Text(L("signingtab.appleID.team")).frame(width: 120, alignment: .leading)
                        Picker("", selection: $selectedTeamID) {
                            ForEach(teams) { team in
                                Text("\(team.name) (\(team.id))").tag(Optional(team.id))
                            }
                        }
                        .labelsHidden()
                    }
                }

                HStack {
                    Text(L("signingtab.appleID.devices")).font(.subheadline.weight(.medium))
                    Spacer()
                    Button {
                        refreshDevices()
                    } label: {
                        Label(L("signingtab.appleID.refreshDevices"), systemImage: "arrow.clockwise")
                    }
                    .disabled(busy)
                }
                if devices.isEmpty {
                    Text(deviceMessage.isEmpty ? L("signingtab.appleID.noDevices") : deviceMessage)
                        .font(.footnote).foregroundStyle(.secondary)
                } else {
                    Picker(L("signingtab.appleID.devices"), selection: $selectedDeviceID) {
                        Text(L("signingtab.chooseIdentity")).tag(String?.none)
                        ForEach(devices) { device in
                            Text(device.summary).tag(Optional(device.udid))
                        }
                    }
                    .labelsHidden()
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(L("signingtab.appleID.manualUDID")).font(.subheadline.weight(.medium))
                    HStack {
                        TextField(L("signingtab.appleID.manualUDID.placeholder"), text: $manualUDID)
                            .textFieldStyle(.roundedBorder)
                        TextField(L("signingtab.appleID.manualName.placeholder"), text: $manualDeviceName)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 180)
                    }
                    Text(L("signingtab.appleID.manualUDID.hint"))
                        .font(.caption).foregroundStyle(.secondary)
                }

                if !portalDevices.isEmpty || !portalCertificates.isEmpty || !portalAppIDs.isEmpty {
                    Divider()
                    portalResourceLists
                }

                Toggle(L("signingtab.appleID.install"), isOn: $installToDevice)
                Toggle(L("signingtab.appleID.renew"), isOn: $addRenewal)
                if !ConnectedDeviceService.canListDevices {
                    Label(L("signingtab.appleID.toolsMissing"), systemImage: "info.circle")
                        .font(.footnote).foregroundStyle(.orange)
                }

                Button {
                    signWithAppleID()
                } label: {
                    Label(
                        busy ? L("signingtab.appleID.signing") : L("signingtab.appleID.signAndInstall"),
                        systemImage: "iphone.and.arrow.forward"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .disabled(busy || ipaURL == nil || appleID.isEmpty || appleIDPassword.isEmpty || resolvedDevice == nil)

                if !renewalJobs.isEmpty {
                    Divider()
                    Text(L("signingtab.appleID.jobs")).font(.subheadline.weight(.medium))
                    ForEach(renewalJobs) { job in
                        renewalRow(job)
                    }
                }
            }
        }
        .onAppear {
            restoreAppleID()
            renewalJobs = AppleIDRenewalStore.load()
            refreshDevices()
        }
    }

    private func renewalRow(_ job: AppleIDRenewalJob) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(job.displayName).font(.callout.weight(.medium))
                Spacer()
                if job.isDue() {
                    Text(L("signingtab.appleID.jobDue")).font(.caption).foregroundStyle(.orange)
                }
            }
            Text(L("signingtab.appleID.jobExpires", job.deviceName, shortDate(job.expiresAt)))
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Toggle(L("signingtab.appleID.autoRenew"), isOn: Binding(
                    get: { job.autoRenew },
                    set: { AppleIDRenewalStore.setAutoRenew(id: job.id, enabled: $0); reloadJobs() }
                ))
                Spacer()
                Button(L("signingtab.appleID.renewNow")) {
                    renewJob(job)
                }
                .disabled(busy)
                Button(L("signingtab.appleID.removeJob"), role: .destructive) {
                    AppleIDRenewalStore.remove(id: job.id)
                    reloadJobs()
                }
                .disabled(busy)
            }
            .font(.caption)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var portalResourceLists: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("signingtab.appleID.portalResources")).font(.subheadline.weight(.medium))
            if !portalDevices.isEmpty {
                Text(L("signingtab.appleID.registeredDevices", portalDevices.count))
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(portalDevices.prefix(8)) { device in
                    Text("\(device.name) · \(device.udid)")
                        .font(.caption.monospaced())
                }
            }
            if !portalCertificates.isEmpty {
                Text(L("signingtab.appleID.certificates", portalCertificates.count))
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(portalCertificates.prefix(8)) { cert in
                    Text(cert.name).font(.caption)
                }
            }
            if !portalAppIDs.isEmpty {
                Text(L("signingtab.appleID.appIDs", portalAppIDs.count))
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(portalAppIDs.prefix(8)) { appID in
                    Text(appID.identifier).font(.caption.monospaced())
                }
            }
        }
    }

    private var selectedDevice: ConnectedDevice? {
        devices.first { $0.udid == selectedDeviceID }
    }

    private var resolvedDevice: ConnectedDevice? {
        let manual = manualUDID.trimmingCharacters(in: .whitespacesAndNewlines)
        if ConnectedDeviceService.isLikelyUDID(manual) {
            let name = manualDeviceName.trimmingCharacters(in: .whitespacesAndNewlines)
            return ConnectedDevice(udid: manual, name: name.isEmpty ? manual : name)
        }
        return selectedDevice
    }

    private func restoreAppleID() {
        if let account = AppleIDSigningService.rememberedAccount() {
            appleID = account.appleID
            appleIDPassword = AppleIDSigningService.rememberedPassword(for: account.appleID) ?? ""
            if let session = AppleIDSigningService.currentSession(for: account.appleID) {
                applySession(session)
            }
        }
    }

    private func applySession(_ token: AppleDeveloperServices.LoginToken) {
        teams = token.teams
        selectedTeamID = token.teamID
    }

    private func loginAppleID() {
        let account = appleID.trimmingCharacters(in: .whitespacesAndNewlines)
        let password = appleIDPassword
        let code = twoFactorCode.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
        let remember = rememberAppleID
        busy = true
        ok = nil
        log = L("signingtab.appleID.loggingIn")
        Task {
            do {
                let token = try await Task.detached {
                    try AppleIDSigningService.login(
                        appleID: account,
                        password: password,
                        twoFactorCode: code,
                        remember: remember
                    )
                }.value
                applySession(token)
                log = L("signingtab.appleID.loggedIn", token.teamName, token.teamID)
                ok = true
                refreshPortal(token)
            } catch {
                ok = false
                log = "❌ " + error.localizedDescription
            }
            busy = false
        }
    }

    private func refreshPortal(_ token: AppleDeveloperServices.LoginToken) {
        Task {
            let snapshot = await Task.detached {
                try? AppleIDSigningService.fetchSnapshot(token: token)
            }.value
            portalDevices = snapshot?.devices ?? []
            portalCertificates = snapshot?.certificates ?? []
            portalAppIDs = snapshot?.appIDs ?? []
            if let snapshot, !snapshot.teams.isEmpty {
                teams = snapshot.teams
            }
        }
    }

    private func refreshDevices() {
        deviceMessage = ""
        Task {
            let listed = await Task.detached {
                (try? ConnectedDeviceService.listDevices()) ?? []
            }.value
            devices = listed
            if selectedDeviceID == nil {
                selectedDeviceID = listed.first?.udid
            }
            if listed.isEmpty {
                deviceMessage = L("signingtab.appleID.noDevices")
            }
        }
    }

    private func reloadJobs() {
        renewalJobs = AppleIDRenewalStore.load()
    }

    private func signWithAppleID() {
        guard let ipa = ipaURL, let device = resolvedDevice else { return }
        let request = AppleIDSignRequest(
            ipaURL: ipa,
            appleID: appleID.trimmingCharacters(in: .whitespacesAndNewlines),
            password: appleIDPassword,
            twoFactorCode: twoFactorCode.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank,
            device: device,
            teamID: selectedTeamID,
            installToDevice: installToDevice,
            addRenewal: addRenewal,
            rememberAccount: rememberAppleID
        )
        busy = true
        ok = nil
        log = ""
        Task {
            do {
                let result = try await Task.detached {
                    try FileSystemHelper.withSecurityScopedAccess(to: [ipa]) {
                        try AppleIDSigningService.sign(request)
                    }
                }.value
                log = ([L("signingtab.appleID.done"), L("signingtab.output", result.outputURL.path), "———"] + result.log)
                    .joined(separator: "\n")
                ok = true
                revealInFinder(result.outputURL)
                reloadJobs()
            } catch {
                ok = false
                log = "❌ " + operationError(error, paths: [ipa])
            }
            busy = false
        }
    }

    private func renewJob(_ job: AppleIDRenewalJob) {
        busy = true
        ok = nil
        log = L("signingtab.appleID.signing")
        let code = twoFactorCode.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
        Task {
            do {
                let result = try await Task.detached {
                    try AppleIDSigningService.renew(job, twoFactorCode: code)
                }.value
                log = ([L("signingtab.appleID.done"), L("signingtab.output", result.outputURL.path), "———"] + result.log)
                    .joined(separator: "\n")
                ok = true
                revealInFinder(result.outputURL)
                reloadJobs()
            } catch {
                ok = false
                log = "❌ " + error.localizedDescription
            }
            busy = false
        }
    }

    private func shortDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
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
    @State private var library: [StoredSigningCertificate] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !library.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L("signingtab.certificateLibrary")).font(.subheadline.weight(.medium))
                    ForEach(library) { cert in
                        HStack {
                            Button {
                                selectLibraryCertificate(cert)
                            } label: {
                                Label(cert.name, systemImage: selectedIdentity?.id == cert.identityID ? "checkmark.seal.fill" : "seal")
                            }
                            .buttonStyle(.borderless)
                            expiryLabel(cert.expiryStatus)
                            Spacer()
                            Button(L("signingtab.removeCertificate"), role: .destructive) {
                                SigningCertificateLibrary.remove(id: cert.id)
                                library = SigningCertificateLibrary.load()
                            }
                            .buttonStyle(.borderless)
                            .font(.caption)
                        }
                    }
                }
            }
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
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Label(L("signingtab.p12Identity", selectedIdentity.name), systemImage: "checkmark.seal")
                                expiryLabel(selectedIdentity.expiryStatus)
                            }
                            CertificateDetailsDisclosure(identity: selectedIdentity)
                        }
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
                        if let profileURL = profilesByBundleID[bundleID] {
                            ProfileCapabilitiesLoader(profileURL: profileURL)
                        }
                    }
                }
            }
            Text(L("signingtab.profileMappingDetail"))
                .font(.caption).foregroundStyle(.secondary)
        }
        .task { restoreStoredCertificate() }
    }

    @ViewBuilder
    private func expiryLabel(_ status: CertificateExpiryStatus) -> some View {
        switch status {
        case .unknown:
            EmptyView()
        case let .valid(days):
            Text(L("signingtab.certificateValid", days))
                .font(.caption).foregroundStyle(.secondary)
        case let .expiringSoon(days):
            Text(L("signingtab.certificateExpiring", days))
                .font(.caption).foregroundStyle(.orange)
        case .expired:
            Text(L("signingtab.certificateExpired"))
                .font(.caption).foregroundStyle(.red)
        }
    }

    private func restoreStoredCertificate() {
        library = SigningCertificateLibrary.load()
        p12URL = SigningService.storedDeveloperCertificateURL()
        p12Password = SigningService.rememberedDeveloperCertificatePassword() ?? ""
        identities = SigningService.identities()
        if let selected = SigningCertificateLibrary.selected() {
            selectedIdentity = identities.first { $0.id.caseInsensitiveCompare(selected.identityID) == .orderedSame }
            p12URL = SigningCertificateLibrary.p12URL(for: selected)
            p12Password = SigningCertificateLibrary.password(for: selected.id) ?? p12Password
        } else if let id = SigningService.rememberedDeveloperCertificateIdentityID() {
            selectedIdentity = identities.first { $0.id.caseInsensitiveCompare(id) == .orderedSame }
        }
    }

    private func selectLibraryCertificate(_ cert: StoredSigningCertificate) {
        SigningCertificateLibrary.select(cert)
        identities = SigningService.identities()
        selectedIdentity = identities.first { $0.id.caseInsensitiveCompare(cert.identityID) == .orderedSame }
        p12URL = SigningCertificateLibrary.p12URL(for: cert)
        p12Password = SigningCertificateLibrary.password(for: cert.id) ?? ""
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
                library = SigningCertificateLibrary.load()
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

        let password = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !password.isEmpty else {
            certificateMessage = "❌ " + L("signingtab.exportPasswordEmpty")
            return
        }
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

private extension String {
    var nilIfBlank: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
