import SwiftUI
import UniformTypeIdentifiers
import MacAssistantKit

/// 插件 / tweak 注入:支持多个 .dylib 或 .deb,自动 @rpath 改写 + 重签 + 重打包。
struct TweakInjectTab: View {
    let inputMode: InjectionInputMode
    let managedInput: Bool

    init(inputMode: InjectionInputMode = .ipa, initialInput: URL? = nil, managedInput: Bool = false) {
        self.inputMode = inputMode
        self.managedInput = managedInput
        _ipaURL = State(initialValue: initialInput)
    }

    @State private var ipaURL: URL?
    @State private var targetSession: InjectionTargetSession?
    @State private var tweaks: [URL] = []
    @State private var extraFrameworks: [URL] = []
    @State private var dropTargeted = false
    @State private var elleKit: URL?
    @State private var protobufLite2: URL?
    @State private var protobufLite3: URL?

    @State private var weak = false
    @State private var stripSignature = true
    @State private var signMethod: SignMethod = .codesignAdhoc
    @State private var developerSigning = false
    @State private var identities: [SigningIdentity] = []
    @State private var selectedIdentity: SigningIdentity?
    @State private var profilesByBundleID: [String: URL] = [:]
    @State private var confirmed = false

    @State private var busy = false
    @State private var ok: Bool?
    @State private var log = ""

    var body: some View {
        Group {
            Label(L("tweaktab.betaNotice"), systemImage: "testtube.2")
                .font(.footnote)
                .foregroundStyle(.orange)
            Card {
                VStack(alignment: .leading, spacing: 10) {
                    Text(L(inputMode == .macOSApp ? "macappview.chooseApp" : "tweaktab.chooseIPA")).font(.headline)
                    if managedInput {
                        PathBadge(url: ipaURL, placeholder: L("tweaktab.noInput"))
                    } else {
                        HStack {
                            if inputMode == .ipa {
                                FilePickerButton(title: L("tweaktab.chooseIPA"), systemImage: "app.gift", types: [.ipaPackage, .data]) { url in
                                    selectInput(url)
                                }
                            } else {
                                FilePickerButton(title: L("macappview.chooseApp"), systemImage: "app", chooseDirectory: true) { url in
                                    guard url.pathExtension.lowercased() == "app" else { return }
                                    selectInput(url)
                                }
                            }
                            Spacer()
                        }
                        PathBadge(url: ipaURL, placeholder: L("tweaktab.noInput"))
                    }
                    Text(L("tweaktab.inputDetail"))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Card {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text(L(inputMode == .macOSApp ? "macappview.plugins" : "tweaktab.tweaks")).font(.headline)
                        Spacer()
                        MultiFilePickerButton(title: L(inputMode == .macOSApp ? "macappview.addPlugin" : "tweaktab.addTweak"), systemImage: "plus",
                                              types: payloadTypes) { urls in
                            urls.forEach(addPayload)
                        }
                    }
                    payloadDropZone
                    if tweaks.isEmpty && extraFrameworks.isEmpty {
                        Text(L(inputMode == .macOSApp ? "macappview.noPlugins" : "tweaktab.noTweaks"))
                            .font(.footnote).foregroundStyle(.secondary)
                    } else {
                        ForEach(tweaks, id: \.self) { url in
                            payloadRow(url, icon: url.pathExtension == "deb" ? "shippingbox" : "puzzlepiece.extension") {
                                tweaks.removeAll { $0 == url }
                            }
                        }
                        ForEach(extraFrameworks, id: \.self) { url in
                            payloadRow(url, icon: "shippingbox") {
                                extraFrameworks.removeAll { $0 == url }
                            }
                        }
                    }
                }
            }

            if inputMode == .ipa {
                Card {
                VStack(alignment: .leading, spacing: 10) {
                    Text(L("tweaktab.frameworks")).font(.headline)
                    frameworkPicker(title: L("tweaktab.protobufLite2"), value: $protobufLite2)
                    frameworkPicker(title: L("tweaktab.protobufLite3"), value: $protobufLite3)
                    Divider()
                    Text(L("tweaktab.dependencies")).font(.headline)
                    HStack {
                        FilePickerButton(title: L("tweaktab.elleKit"),
                                         systemImage: "cube", chooseDirectory: true) { url in elleKit = url }
                        if elleKit != nil { Button(L("tweaktab.clear")) { elleKit = nil }.buttonStyle(.borderless) }
                        Spacer()
                    }
                    if let elleKit { PathBadge(url: elleKit) }
                    Text(L("tweaktab.substrateNote"))
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle(L("tweaktab.weak"), isOn: $weak)
                    Toggle(L("tweaktab.stripSignature"), isOn: $stripSignature)
                    HStack {
                        Text(L("tweaktab.signMethod")).frame(width: 150, alignment: .leading)
                        Picker("", selection: $signMethod) {
                            ForEach(SignMethod.allCases, id: \.self) { Text($0.label).tag($0) }
                        }.labelsHidden().frame(width: 220)
                        Spacer()
                    }
                    Toggle(L("tweaktab.developerSigning"), isOn: $developerSigning)
                    if developerSigning {
                        DeveloperSigningPicker(
                            bundleIDs: signingBundleIDs,
                            identities: $identities,
                            selectedIdentity: $selectedIdentity,
                            profilesByBundleID: $profilesByBundleID
                        )
                    }
                }
            }
            } else {
                Card {
                    HStack {
                        Text(L("tweaktab.signMethod")).frame(width: 150, alignment: .leading)
                        Picker("", selection: $signMethod) {
                            ForEach(SignMethod.allCases, id: \.self) { Text($0.label).tag($0) }
                        }.labelsHidden().frame(width: 220)
                        Spacer()
                    }
                }
            }

            if inputMode == .ipa {
                Card {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(L("tweaktab.differenceTitle")).font(.headline)
                        Text(L("tweaktab.differenceDetail"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            Card {
                Toggle(isOn: $confirmed) {
                    Label(L("tweaktab.consent"), systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
            }

            Button {
                inject()
            } label: {
                Label(busy ? L("tweaktab.injecting") : L("tweaktab.inject"), systemImage: "puzzlepiece.extension.fill").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent).controlSize(.large)
            .disabled(busy || ipaURL == nil || tweaks.isEmpty || !confirmed)

            if busy || !log.isEmpty {
                Card {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack { Text(L("tweaktab.log")).font(.headline); if busy { ProgressView().controlSize(.small) }; Spacer(); StatusBadge(ok: ok) }
                        ConsoleView(text: log, minHeight: 180)
                    }
                }
            }
        }
    }

    private func inject() {
        guard let input = ipaURL else { return }
        let deviceSigning = developerSigning ? makeDeviceRecipe() : nil
        guard !developerSigning || deviceSigning != nil else {
            ok = false
            log = L("tweaktab.developerSigningMissing")
            return
        }
        let options = TweakInjectOptions(tweaks: tweaks, elleKitFramework: elleKit,
                                         frameworks: [protobufLite2, protobufLite3].compactMap { $0 } + extraFrameworks,
                                         weak: weak, stripCodeSignature: stripSignature,
                                         signMethod: signMethod,
                                         deviceSigning: deviceSigning)
        let profileURLs = options.deviceSigning.map { Array($0.profilesByBundleID.values) } ?? []
        let accessURLs = [input] + options.tweaks
            + [options.elleKitFramework].compactMap { $0 }
            + options.frameworks
            + profileURLs
        let injectionInput: InjectionInput = inputMode == .macOSApp ? .app(input) : .ipa(input)
        busy = true; ok = nil; log = ""
        Task {
            do {
                let r = try await Task.detached {
                    try FileSystemHelper.withSecurityScopedAccess(to: accessURLs) {
                        try TweakInjectService.injectTweaks(
                            input: injectionInput,
                            options: options
                        )
                    }
                }.value
                var lines = [
                    L("tweaktab.done"),
                    L("tweaktab.output", r.output.path),
                    L("tweaktab.injected", r.injected.joined(separator: ", "))
                ]
                if !r.rewrites.isEmpty {
                    lines.append(L("tweaktab.section.rewrites"))
                    lines.append(contentsOf: r.rewrites.map { "  \($0.from)\n    → \($0.to)" })
                }
                if !r.warnings.isEmpty {
                    lines.append(L("tweaktab.section.warnings"))
                    lines.append(contentsOf: r.warnings.map { "⚠️ \($0)" })
                }
                lines.append(L("tweaktab.section.log"))
                lines.append(contentsOf: r.log)
                log = lines.joined(separator: "\n")
                ok = true
                revealInFinder(r.output)
            } catch {
                ok = false; log = "❌ " + error.localizedDescription
            }
            busy = false
        }
    }

    private func makeDeviceRecipe() -> RealDeviceSigningRecipe? {
        guard let identity = selectedIdentity, !signingBundleIDs.isEmpty else { return nil }
        let bundleIDs = signingBundleIDs
        guard bundleIDs.allSatisfy({ profilesByBundleID[$0] != nil }) else { return nil }
        return RealDeviceSigningRecipe(
            identityID: identity.id,
            identityName: identity.name,
            profilesByBundleID: profilesByBundleID.filter { bundleIDs.contains($0.key) }
        )
    }

    private var signingBundleIDs: [String] {
        guard let app = targetSession?.appURL else { return [] }
        return (try? SigningService.profileBundleIDs(in: app)) ?? []
    }

    private func frameworkPicker(title: String, value: Binding<URL?>) -> some View {
        HStack {
            FilePickerButton(
                title: value.wrappedValue?.lastPathComponent ?? title,
                systemImage: "shippingbox",
                chooseDirectory: true
            ) { url in value.wrappedValue = url }
            if value.wrappedValue != nil {
                Button(L("tweaktab.clear")) { value.wrappedValue = nil }
                    .buttonStyle(.borderless)
            }
        }
    }

    private var payloadDropZone: some View {
        VStack(spacing: 6) {
            Image(systemName: "plus.circle")
                .font(.title2)
            Text(L("tweaktab.dropPayloads"))
                .font(.caption)
        }
        .frame(maxWidth: .infinity, minHeight: 76)
        .foregroundStyle(dropTargeted ? Color.accentColor : .secondary)
        .contentShape(Rectangle())
        .insetSurfaceBackground(
            RoundedRectangle(cornerRadius: 10),
            legacyFill: Color.primary.opacity(dropTargeted ? 0.10 : 0.04)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(
                    dropTargeted ? Color.accentColor : Color.secondary.opacity(0.35),
                    style: StrokeStyle(lineWidth: 1, dash: [6])
                )
        }
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: $dropTargeted) { providers in
            for provider in providers {
                provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
                    guard let data, let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                    Task { @MainActor in addPayload(url) }
                }
            }
            return true
        }
    }

    private func payloadRow(_ url: URL, icon: String, remove: @escaping () -> Void) -> some View {
        HStack {
            Image(systemName: icon).foregroundStyle(.secondary)
            Text(url.lastPathComponent)
                .font(.footnote)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Button(role: .destructive, action: remove) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
        }
        .padding(8)
        .insetSurfaceBackground(RoundedRectangle(cornerRadius: 8), legacyFill: .primary.opacity(0.05))
    }

    private func addPayload(_ url: URL) {
        let ext = url.pathExtension.lowercased()
        if ext == "framework" {
            if !extraFrameworks.contains(url) { extraFrameworks.append(url) }
        } else if (ext == "dylib" || (inputMode == .ipa && ext == "deb")), !tweaks.contains(url) {
            tweaks.append(url)
        }
    }

    private var payloadTypes: [UTType] {
        inputMode == .macOSApp ? [.dylibFile, .item] : [.dylibFile, .debPackage, .item]
    }

    private func selectInput(_ url: URL) {
        ipaURL = url
        if inputMode == .macOSApp { developerSigning = false }
        targetSession = nil
        profilesByBundleID = [:]
        log = ""
        ok = nil
        Task {
            targetSession = try? await Task.detached {
                try FileSystemHelper.withSecurityScopedAccess(to: [url]) {
                    try InjectionTargetDiscovery.open(inputMode == .macOSApp ? .app(url) : .ipa(url))
                }
            }.value
        }
    }
}
