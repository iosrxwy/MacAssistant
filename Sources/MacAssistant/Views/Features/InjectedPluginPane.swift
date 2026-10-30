import SwiftUI
import MacAssistantKit

/// 扫描选中 .app 里已写入的第三方 LC_LOAD，并就地卸除。
struct InjectedPluginPane: View {
    let app: URL
    var onSelectApp: (URL) -> Void = { _ in }

    @State private var findings: [InjectedPluginFinding] = []
    @State private var otherCopies: [(app: URL, findings: [InjectedPluginFinding])] = []
    @State private var scanned = false
    @State private var scanning = false
    @State private var busy = false
    @State private var deletePayload = true
    @State private var resign = true
    @State private var log = ""
    @State private var ok: Bool?
    @State private var pending: PendingRemoval?

    private var working: Bool { scanning || busy }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 8) {
                            Text(L("macappview.injected.title")).font(.headline)
                            RiskBadge(risk: .caution)
                        }
                        Text(L("macappview.injected.detail"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        scan()
                    } label: {
                        if scanning {
                            ProgressView().controlSize(.small)
                        } else {
                            Label(L("macappview.injected.scan"), systemImage: "magnifyingglass")
                        }
                    }
                    .disabled(working)
                }

                Toggle(L("macappview.injected.deletePayload"), isOn: $deletePayload)
                    .font(.caption)
                    .disabled(working)
                Toggle(L("macappview.injected.resign"), isOn: $resign)
                    .font(.caption)
                    .disabled(working)

                if scanned && findings.isEmpty && !scanning {
                    Text(L("macappview.injected.empty"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    ForEach(otherCopies, id: \.app) { copy in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(L(
                                "macappview.injected.otherCopy",
                                MacAppLibrary.copyLabel(of: copy.app),
                                copy.findings.count
                            ))
                            .font(.footnote)
                            Text(copy.app.path)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                            Button {
                                onSelectApp(copy.app)
                            } label: {
                                Label(L("macappview.injected.openOther"), systemImage: "arrow.right.circle")
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }

                ForEach(findings) { finding in
                    findingRow(finding)
                }

                if findings.count > 1 {
                    Button {
                        pending = .all
                    } label: {
                        Label(
                            busy ? L("macappview.injected.removing") : L("macappview.injected.removeAll"),
                            systemImage: "trash"
                        )
                    }
                    .disabled(working)
                }

                if busy || !log.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(L("macappview.injected.log")).font(.subheadline.weight(.medium))
                            if busy { ProgressView().controlSize(.small) }
                            Spacer()
                            StatusBadge(ok: ok)
                        }
                        ConsoleView(text: log, minHeight: 80)
                    }
                }
            }
        }
        .onAppear { scan() }
        .onChange(of: app) { _ in
            findings = []
            otherCopies = []
            scanned = false
            log = ""
            ok = nil
            scan()
        }
        .confirmationDialog(
            confirmationTitle,
            isPresented: Binding(
                get: { pending != nil },
                set: { if !$0 { pending = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(L("macappview.injected.remove"), role: .destructive) {
                confirmRemoval()
            }
            Button(L("macappview.clone.cancel"), role: .cancel) {
                pending = nil
            }
        } message: {
            Text(confirmationDetail)
        }
    }

    private var confirmationTitle: String {
        switch pending {
        case .all:
            return L("macappview.injected.confirmAll.title")
        case .one:
            return L("macappview.injected.confirm.title")
        case nil:
            return L("macappview.injected.confirm.title")
        }
    }

    private var confirmationDetail: String {
        switch pending {
        case .all:
            return L("macappview.injected.confirmAll.detail", findings.count, app.lastPathComponent)
        case let .one(finding):
            return L("macappview.injected.confirm.detail", finding.displayName, finding.hostRelativePath)
        case nil:
            return ""
        }
    }

    private func findingRow(_ finding: InjectedPluginFinding) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(finding.displayName).font(.callout.weight(.semibold))
                Text(finding.weak ? L("macappview.injected.weak") : L("macappview.injected.required"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    pending = .one(finding)
                } label: {
                    Label(L("macappview.injected.remove"), systemImage: "trash")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.red)
                .disabled(working)
            }
            Text(finding.loadPath)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .lineLimit(2)
                .truncationMode(.middle)
            Text(L("macappview.injected.host", finding.hostRelativePath))
                .font(.caption2)
                .foregroundStyle(.secondary)
            if let payload = finding.payloadRelativePath {
                Text(L("macappview.injected.payload", payload))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private func scan() {
        scanning = true
        ok = nil
        Task {
            do {
                let result = try await Task.detached {
                    try FileSystemHelper.withSecurityScopedAccess(to: [app]) {
                        try InjectedPluginService.scan(app: app)
                    }
                }.value
                findings = result
                otherCopies = result.isEmpty ? Self.injectedCopies(besides: app) : []
                scanned = true
                ok = true
                log = result.isEmpty
                    ? L("macappview.injected.empty")
                    : L("macappview.injected.found", result.count)
            } catch {
                scanned = true
                ok = false
                log = FileSystemHelper.isAccessPermissionError(error)
                    ? FileSystemHelper.userFacingAccessError(error, paths: [app])
                    : error.localizedDescription
            }
            scanning = false
        }
    }

    private func confirmRemoval() {
        let targets: [InjectedPluginFinding]
        switch pending {
        case .all:
            targets = findings
        case let .one(finding):
            targets = [finding]
        case nil:
            return
        }
        pending = nil
        remove(targets)
    }

    private func remove(_ targets: [InjectedPluginFinding]) {
        guard !targets.isEmpty else { return }
        busy = true
        ok = nil
        log = ""
        let options = InjectedPluginRemovalOptions(deletePayload: deletePayload, resign: resign)
        Task {
            do {
                let report = try await Task.detached {
                    try FileSystemHelper.withSecurityScopedAccess(to: [app]) {
                        try InjectedPluginService.remove(targets, in: app, options: options)
                    }
                }.value
                let remaining = try await Task.detached {
                    try FileSystemHelper.withSecurityScopedAccess(to: [app]) {
                        try InjectedPluginService.scan(app: app)
                    }
                }.value
                findings = remaining
                otherCopies = remaining.isEmpty ? Self.injectedCopies(besides: app) : []
                scanned = true
                ok = report.warnings.isEmpty
                log = ([L("macappview.injected.done")] + [report.log].filter { !$0.isEmpty })
                    .joined(separator: "\n")
            } catch {
                ok = false
                log = FileSystemHelper.isAccessPermissionError(error)
                    ? FileSystemHelper.userFacingAccessError(error, paths: [app])
                    : error.localizedDescription
            }
            busy = false
        }
    }

    private static func injectedCopies(besides app: URL) -> [(app: URL, findings: [InjectedPluginFinding])] {
        InjectedPluginService.otherCopies(of: app).compactMap { copy in
            guard let findings = try? InjectedPluginService.scan(app: copy), !findings.isEmpty else {
                return nil
            }
            return (copy, findings)
        }
    }
}

private enum PendingRemoval: Equatable {
    case one(InjectedPluginFinding)
    case all
}
