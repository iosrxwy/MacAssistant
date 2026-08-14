import SwiftUI
import MacAssistantKit

/// 文件瘦身:去架构 / 去符号 / 清 dSYM·bcsymbolmap·Symbols + 前后体积对比 + 自动重签。
struct SlimTab: View {
    @State private var ipaURL: URL?

    @State private var thinArm64Only = true
    @State private var removeSimArchs = true
    @State private var stripSymbols = false
    @State private var stripConfirmed = false
    @State private var gentleStrip = false
    @State private var removeAppDSYM = true
    @State private var removeRootDebris = true
    @State private var signMethod: SignMethod = .codesignAdhoc

    @State private var busy = false
    @State private var ok: Bool?
    @State private var log = ""
    @State private var summary = ""

    var body: some View {
        Group {
            Card {
                VStack(alignment: .leading, spacing: 10) {
                    Text(L("slimtab.chooseIPA")).font(.headline)
                    HStack {
                        FilePickerButton(title: L("slimtab.chooseIPA"), systemImage: "app.gift", types: [.ipaPackage, .data]) { url in
                            ipaURL = url; log = ""; ok = nil; summary = ""
                        }
                        Spacer()
                    }
                    PathBadge(url: ipaURL, placeholder: L("slimtab.noIPA"))
                }
            }

            Card {
                VStack(alignment: .leading, spacing: 10) {
                    Text(L("slimtab.options")).font(.headline)

                    Toggle(L("slimtab.removeRootDebris"), isOn: $removeRootDebris)
                    Toggle(L("slimtab.removeAppDSYM"), isOn: $removeAppDSYM)

                    Divider()
                    HStack { Text(L("slimtab.architectures")).font(.callout.weight(.semibold)); RiskBadge(risk: .caution); Spacer() }
                    Toggle(L("slimtab.thinArm64"), isOn: $thinArm64Only)
                    Toggle(L("slimtab.removeSimArchs"), isOn: $removeSimArchs)
                        .disabled(thinArm64Only)

                    Divider()
                    HStack { Text(L("slimtab.strip")).font(.callout.weight(.semibold)); RiskBadge(risk: .danger); Spacer() }
                    Toggle(L("slimtab.gentleStrip"), isOn: $gentleStrip)
                    Toggle(L("slimtab.fullStrip"), isOn: $stripSymbols)
                    if stripSymbols {
                        Toggle(L("slimtab.stripConfirm"), isOn: $stripConfirmed)
                            .foregroundStyle(.red)
                    }

                    Divider()
                    HStack {
                        Text(L("slimtab.signMethod")).frame(width: 150, alignment: .leading)
                        Picker("", selection: $signMethod) {
                            ForEach(SignMethod.allCases, id: \.self) { Text($0.label).tag($0) }
                        }.labelsHidden().frame(width: 220)
                        Spacer()
                    }
                }
            }

            Button {
                slim()
            } label: {
                Label(busy ? L("slimtab.slimming") : L("slimtab.start"), systemImage: "scissors").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent).controlSize(.large)
            .disabled(busy || ipaURL == nil || (stripSymbols && !stripConfirmed))

            if !summary.isEmpty {
                Card { Text(summary).font(.callout).textSelection(.enabled) }
            }

            if busy || !log.isEmpty {
                Card {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack { Text(L("slimtab.log")).font(.headline); if busy { ProgressView().controlSize(.small) }; Spacer(); StatusBadge(ok: ok) }
                        ConsoleView(text: log, minHeight: 160)
                    }
                }
            }
        }
    }

    private func slim() {
        guard let ipa = ipaURL else { return }
        let options = SlimOptions(
            thinToArch: thinArm64Only ? "arm64" : nil,
            removeArchs: removeSimArchs ? ["x86_64", "i386"] : [],
            stripSymbols: stripSymbols,
            gentleStripFrameworksOnly: gentleStrip,
            removeAppDSYM: removeAppDSYM,
            removeRootDebris: removeRootDebris,
            signMethod: signMethod
        )
        busy = true; ok = nil; log = ""; summary = ""
        Task {
            do {
                let r = try await Task.detached { try SlimService.slim(ipaAt: ipa, options: options) }.value
                summary = L("slimtab.summary.zipped",
                            FileSystemHelper.humanReadableSize(r.before.zipped),
                            FileSystemHelper.humanReadableSize(r.after.zipped),
                            FileSystemHelper.humanReadableSize(r.freedZipped))
                    + "\n"
                    + L("slimtab.summary.unpacked",
                        FileSystemHelper.humanReadableSize(r.before.unpacked),
                        FileSystemHelper.humanReadableSize(r.after.unpacked),
                        FileSystemHelper.humanReadableSize(r.freedUnpacked))
                log = ([L("slimtab.done"), L("slimtab.output", r.output.path), "———"] + r.log).joined(separator: "\n")
                ok = true
                revealInFinder(r.output)
            } catch {
                ok = false; log = "❌ " + error.localizedDescription
            }
            busy = false
        }
    }
}
