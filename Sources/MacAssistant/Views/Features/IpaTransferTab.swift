import AppKit
import SwiftUI
import UniformTypeIdentifiers
import MacAssistantKit

/// IPA 安装与原样提取。不脱壳。
struct IpaTransferTab: View {
    private enum Mode: String, CaseIterable, Identifiable {
        case install
        case extract
        case store
        var id: String { rawValue }
        var title: String {
            switch self {
            case .install: return L("ipatransfer.mode.install")
            case .extract: return L("ipatransfer.mode.extract")
            case .store: return L("ipatransfer.mode.store")
            }
        }
    }

    @State private var mode: Mode = .install
    @State private var ipaURL: URL?
    @State private var appURL: URL?
    @State private var outputDirectory: URL?
    @State private var devices: [ConnectedDevice] = []
    @State private var selectedDeviceID: String?
    @State private var manualUDID = ""
    @State private var manualDeviceName = ""
    @State private var apps: [InstalledApp] = []
    @State private var selectedAppID: String?
    @State private var appQuery = ""
    @State private var includeSystem = false
    @State private var deviceMessage = ""
    @State private var installPlan: AppInstallPlan?
    @State private var comparing = false
    @State private var replaceConfirmed = false
    @State private var keepDataDowngrade = true
    @State private var downgradeSignMethod: SignMethod = ExternalTool.ldid.isAvailable ? .ldid : .codesignAdhoc
    @State private var busy = false
    @State private var ok: Bool?
    @State private var log = ""

    var body: some View {
        Group {
            Card {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("", selection: $mode) {
                        ForEach(Mode.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    Text(introText)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Label(L("ipatransfer.noDecrypt"), systemImage: "lock.shield")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if mode != .store {
                deviceCard
            }

            switch mode {
            case .install: installCard
            case .extract: extractCards
            case .store:
                IpaStoreSection { url in
                    ipaURL = url
                    replaceConfirmed = false
                    installPlan = nil
                    mode = .install
                    log = L("ipastore.handedOff")
                    ok = nil
                }
            }

            if mode != .store, busy || !log.isEmpty {
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
        .onAppear { refreshDevices() }
        .onChange(of: ipaURL) { _ in refreshInstallPlan() }
        .onChange(of: selectedDeviceID) { _ in refreshInstallPlan() }
        .onChange(of: manualUDID) { _ in refreshInstallPlan() }
    }

    private var introText: String {
        switch mode {
        case .install: return L("ipatransfer.install.intro")
        case .extract: return L("ipatransfer.extract.intro")
        case .store: return L("ipatransfer.store.intro")
        }
    }

    private var deviceCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(L("ipatransfer.device")).font(.headline)
                    Spacer()
                    Button(L("ipatransfer.refreshDevices")) { refreshDevices() }
                        .disabled(busy)
                }
                if devices.isEmpty {
                    Text(deviceMessage.isEmpty ? L("ipatransfer.noDevices") : deviceMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    Picker(L("ipatransfer.chooseDevice"), selection: $selectedDeviceID) {
                        Text(L("ipatransfer.chooseDevice")).tag(String?.none)
                        ForEach(devices) { device in
                            Text(device.summary).tag(Optional(device.udid))
                        }
                    }
                    .labelsHidden()
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(L("ipatransfer.manualUDID")).font(.subheadline.weight(.medium))
                    HStack {
                        TextField(L("ipatransfer.manualUDID.placeholder"), text: $manualUDID)
                            .textFieldStyle(.roundedBorder)
                        TextField(L("ipatransfer.manualName.placeholder"), text: $manualDeviceName)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 180)
                    }
                }
                if mode == .install, !ConnectedDeviceService.canInstall {
                    Label(L("ipatransfer.toolsMissing.install"), systemImage: "info.circle")
                        .font(.footnote).foregroundStyle(.orange)
                }
                if mode == .extract, !ConnectedDeviceService.canExportApps {
                    Label(L("ipatransfer.toolsMissing.export"), systemImage: "info.circle")
                        .font(.footnote).foregroundStyle(.orange)
                }
            }
        }
    }

    private var installCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                Text(L("ipatransfer.mode.install")).font(.headline)
                HStack {
                    FilePickerButton(
                        title: L("ipatransfer.chooseIPA"),
                        systemImage: "app.gift",
                        types: [.ipaPackage, .data]
                    ) { url in
                        ipaURL = url
                        replaceConfirmed = false
                        log = ""
                        ok = nil
                    }
                    Spacer()
                }
                PathBadge(url: ipaURL, placeholder: L("ipatransfer.noIPA"))
                if comparing {
                    ProgressView(L("ipatransfer.comparing")).controlSize(.small)
                } else if let plan = installPlan {
                    installPlanCard(plan)
                }
                Button {
                    install()
                } label: {
                    Label(
                        busy ? L("ipatransfer.installing") : installButtonTitle,
                        systemImage: "iphone.and.arrow.forward"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(
                    busy
                        || ipaURL == nil
                        || resolvedDevice == nil
                        || !ConnectedDeviceService.canInstall
                        || (installPlan?.relation == .downgrade && !keepDataDowngrade && !replaceConfirmed)
                )
            }
        }
    }

    @ViewBuilder
    private var extractCards: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                Text(L("ipatransfer.packageSource")).font(.headline)
                HStack {
                    FilePickerButton(
                        title: L("ipatransfer.chooseApp"),
                        systemImage: "app.badge",
                        chooseDirectory: true
                    ) { url in
                        appURL = url
                        log = ""
                        ok = nil
                    }
                    Spacer()
                }
                PathBadge(url: appURL, placeholder: L("ipatransfer.noApp"))
                Button {
                    packageLocal()
                } label: {
                    Label(
                        busy ? L("ipatransfer.packaging") : L("ipatransfer.package"),
                        systemImage: "archivebox"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(busy || appURL == nil)
            }
        }

        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(L("ipatransfer.deviceApps")).font(.headline)
                    Spacer()
                    Button(L("ipatransfer.refreshApps")) { refreshApps() }
                        .disabled(busy || resolvedDevice == nil || !ConnectedDeviceService.canListApps)
                }
                Toggle(L("ipatransfer.includeSystem"), isOn: $includeSystem)
                TextField(L("ipatransfer.filterApps"), text: $appQuery)
                    .textFieldStyle(.roundedBorder)
                if filteredApps.isEmpty {
                    Text(L("ipatransfer.noApps"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    List(filteredApps, selection: $selectedAppID) { app in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(app.name).font(.callout.weight(.medium))
                            Text(app.summary)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                        .tag(app.bundleIdentifier)
                    }
                    .frame(minHeight: 160, maxHeight: 240)
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
                Button {
                    exportFromDevice()
                } label: {
                    Label(
                        busy ? L("ipatransfer.exporting") : L("ipatransfer.export"),
                        systemImage: "square.and.arrow.down"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(
                    busy
                        || selectedApp == nil
                        || resolvedDevice == nil
                        || outputDirectory == nil
                        || !ConnectedDeviceService.canExportApps
                )
            }
        }
    }

    private var filteredApps: [InstalledApp] {
        let query = appQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return apps }
        return apps.filter {
            $0.name.lowercased().contains(query) || $0.bundleIdentifier.lowercased().contains(query)
        }
    }

    private var selectedApp: InstalledApp? {
        apps.first { $0.bundleIdentifier == selectedAppID }
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
                deviceMessage = L("ipatransfer.noDevices")
            }
            refreshInstallPlan()
        }
    }

    private var installButtonTitle: String {
        switch installPlan?.relation {
        case .upgrade: return L("ipatransfer.upgrade")
        case .same: return L("ipatransfer.reinstall")
        case .downgrade:
            return keepDataDowngrade ? L("ipatransfer.downgrade.keepData") : L("ipatransfer.downgrade")
        default: return L("ipatransfer.install")
        }
    }

    @ViewBuilder
    private func installPlanCard(_ plan: AppInstallPlan) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L("ipatransfer.plan.ipa", plan.identity.appName, plan.identity.versionLabel))
                .font(.callout)
            if let installed = plan.installed {
                Text(L("ipatransfer.plan.device", AppVersionOrdering.label(short: installed.shortVersion, build: installed.version)))
                    .font(.callout)
            } else if plan.relation == .fresh {
                Text(L("ipatransfer.plan.missing")).font(.callout).foregroundStyle(.secondary)
            }
            Text(planDescription(plan))
                .font(.footnote)
                .foregroundStyle(plan.relation == .downgrade ? Color.orange : .secondary)
                .fixedSize(horizontal: false, vertical: true)
            if plan.relation == .downgrade {
                Picker("", selection: $keepDataDowngrade) {
                    Text(L("ipatransfer.downgrade.keepData")).tag(true)
                    Text(L("ipatransfer.downgrade.uninstall")).tag(false)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                if keepDataDowngrade {
                    HStack {
                        Text(L("ipatransfer.downgrade.signMethod")).frame(width: 120, alignment: .leading)
                        Picker("", selection: $downgradeSignMethod) {
                            Text(SignMethod.codesignAdhoc.label).tag(SignMethod.codesignAdhoc)
                            Text(SignMethod.ldid.label).tag(SignMethod.ldid)
                            Text(SignMethod.none.label).tag(SignMethod.none)
                        }
                        .labelsHidden()
                        .frame(width: 220)
                        Spacer()
                    }
                    if downgradeSignMethod == .ldid, !ExternalTool.ldid.isAvailable {
                        Label(L("signingtab.ldidMissing"), systemImage: "info.circle")
                            .font(.footnote).foregroundStyle(.orange)
                    }
                    Text(L("ipatransfer.downgrade.keepData.hint"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Toggle(L("ipatransfer.replaceConfirm"), isOn: $replaceConfirmed)
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    private func planDescription(_ plan: AppInstallPlan) -> String {
        let ipa = plan.identity.versionLabel
        let device = AppVersionOrdering.label(
            short: plan.installed?.shortVersion,
            build: plan.installed?.version
        )
        switch plan.relation {
        case .fresh: return L("ipatransfer.plan.fresh")
        case .upgrade: return L("ipatransfer.plan.upgrade", device, ipa)
        case .same: return L("ipatransfer.plan.same", ipa)
        case .downgrade: return L("ipatransfer.plan.downgrade", device, ipa)
        case .unknown: return L("ipatransfer.plan.unknown")
        }
    }

    private func refreshInstallPlan() {
        guard let ipa = ipaURL else {
            installPlan = nil
            comparing = false
            return
        }
        let device = resolvedDevice
        comparing = true
        Task {
            do {
                let plan = try await Task.detached {
                    try FileSystemHelper.withSecurityScopedAccess(to: [ipa]) {
                        let identity = try IpaService.identity(ipaAt: ipa)
                        var installed: InstalledApp?
                        if let device, ConnectedDeviceService.canListApps {
                            installed = try? ConnectedDeviceService.listInstalledApps(on: device)
                                .first { $0.bundleIdentifier == identity.bundleIdentifier }
                        }
                        return AppInstallPlan.make(identity: identity, installed: installed)
                    }
                }.value
                guard ipaURL == ipa else { return }
                installPlan = plan
                if plan.relation != .downgrade { replaceConfirmed = false }
            } catch {
                guard ipaURL == ipa else { return }
                installPlan = nil
                ok = false
                log = "❌ " + operationError(error, paths: [ipa])
            }
            comparing = false
        }
    }

    private func refreshApps() {
        guard let device = resolvedDevice else { return }
        let includeSystemApps = includeSystem
        busy = true
        ok = nil
        log = ""
        Task {
            do {
                let listed = try await Task.detached {
                    try ConnectedDeviceService.listInstalledApps(on: device, includeSystem: includeSystemApps)
                }.value
                apps = listed
                if selectedAppID == nil || listed.contains(where: { $0.bundleIdentifier == selectedAppID }) == false {
                    selectedAppID = listed.first?.bundleIdentifier
                }
                log = L("ipatransfer.listedApps", listed.count)
                ok = true
            } catch {
                ok = false
                log = "❌ " + error.localizedDescription
            }
            busy = false
        }
    }

    private func install() {
        guard let ipa = ipaURL, let device = resolvedDevice else { return }
        let plan = installPlan
        let replaceExisting = replaceConfirmed
        let keepData = keepDataDowngrade
        let signMethod = downgradeSignMethod
        busy = true
        ok = nil
        log = ""
        Task {
            do {
                let relation = try await Task.detached {
                    try FileSystemHelper.withSecurityScopedAccess(to: [ipa]) {
                        if let plan {
                            let strategy: AppDowngradeStrategy = keepData
                                ? .keepData(signMethod: signMethod)
                                : .uninstallFirst
                            if plan.relation == .downgrade, strategy == .uninstallFirst, !replaceExisting {
                                throw ConnectedDeviceError.downgradeNeedsConfirmation
                            }
                            try ConnectedDeviceService.install(
                                ipaAt: ipa,
                                to: device,
                                plan: plan,
                                downgrade: strategy
                            )
                            return plan.relation
                        }
                        try ConnectedDeviceService.install(ipaAt: ipa, to: device)
                        return AppVersionRelation.unknown
                    }
                }.value
                switch relation {
                case .upgrade: log = L("ipatransfer.install.done.upgrade")
                case .downgrade:
                    log = keepData
                        ? L("ipatransfer.install.done.downgradeKeep")
                        : L("ipatransfer.install.done.downgrade")
                case .same: log = L("ipatransfer.install.done.reinstall")
                default: log = L("ipatransfer.install.done")
                }
                log += "\n" + device.summary
                ok = true
                refreshInstallPlan()
            } catch {
                ok = false
                log = "❌ " + operationError(error, paths: [ipa])
            }
            busy = false
        }
    }

    private func packageLocal() {
        guard let app = appURL else { return }
        busy = true
        ok = nil
        log = ""
        Task {
            do {
                let result = try await Task.detached {
                    try FileSystemHelper.withSecurityScopedAccess(to: [app]) {
                        try IpaService.package(source: app)
                    }
                }.value
                present(result)
            } catch {
                ok = false
                log = "❌ " + operationError(error, paths: [app])
            }
            busy = false
        }
    }

    private func exportFromDevice() {
        guard let app = selectedApp, let device = resolvedDevice, let directory = outputDirectory else { return }
        busy = true
        ok = nil
        log = ""
        Task {
            do {
                let result = try await Task.detached {
                    try FileSystemHelper.withSecurityScopedAccess(to: [directory]) {
                        try ConnectedDeviceService.exportApp(app, from: device, toDirectory: directory)
                    }
                }.value
                present(result)
            } catch {
                ok = false
                log = "❌ " + error.localizedDescription
            }
            busy = false
        }
    }

    private func present(_ result: IpaPackageResult) {
        let badge = result.isEncrypted ? L("ipatransfer.encryptedBadge") : L("ipatransfer.unencryptedBadge")
        log = ([badge, result.outputIPA.path, "———"] + result.log).joined(separator: "\n")
        ok = true
        revealInFinder(result.outputIPA)
    }

    private func operationError(_ error: Error, paths: [URL]) -> String {
        FileSystemHelper.isAccessPermissionError(error)
            ? FileSystemHelper.userFacingAccessError(error, paths: paths)
            : error.localizedDescription
    }
}
