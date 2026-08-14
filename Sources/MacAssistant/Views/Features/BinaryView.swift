import AppKit
import MacAssistantKit
import SwiftUI
import UniformTypeIdentifiers

struct BinaryView: View {
    private enum TargetFilter: String, CaseIterable, Identifiable {
        case all = "全部"
        case main = "主程序"
        case frameworks = "Framework / dylib"
        case extensions = "App Extensions"
        case restricted = "Watch / App Clip"
        var id: String { rawValue }

        /// rawValue 同时是选中态的标识,展示一律走这里。
        var title: String {
            switch self {
            case .all: return L("binaryview.filter.all")
            case .main: return L("binaryview.filter.main")
            case .frameworks: return L("binaryview.filter.frameworks")
            case .extensions: return L("binaryview.filter.extensions")
            case .restricted: return L("binaryview.filter.restricted")
            }
        }
    }

    @State private var sourceURL: URL?
    @State private var session: BinaryAnalysisSession?
    @State private var selectedTargetID: String?
    @State private var analysis: BinaryTargetAnalysis?
    @State private var capability: ClassDumpCapabilityReport?
    @State private var searchText = ""
    @State private var targetFilter: TargetFilter = .all
    @State private var selectedArch = ""
    @State private var exportMode: ClassDumpExportMode = .aggregate
    @State private var flattenBulkExport = false
    @State private var busy = false
    @State private var log = ""
    @State private var ok: Bool?

    var body: some View {
        FeatureScaffold(
            title: L("binaryview.title"),
            subtitle: L("binaryview.subtitle")
        ) {
            inputCard

            if let session {
                inventoryCard(session)
            }

            if let target = selectedTarget {
                overviewCard(target)
                operationCard(target)
                signingCard(target)
            }

            if let analysis {
                Card {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(L("binaryview.machHeader")).font(.headline)
                        ConsoleView(text: analysis.machHeader, minHeight: 120)
                        DisclosureGroup(L("binaryview.linkedLibraries")) {
                            ConsoleView(text: analysis.linkedLibraries, minHeight: 100)
                                .padding(.top, 4)
                        }
                    }
                }
            }

            if busy || !log.isEmpty {
                Card {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(L("binaryview.output")).font(.headline)
                            if busy { ProgressView().controlSize(.small) }
                            Spacer()
                            StatusBadge(ok: ok)
                        }
                        ConsoleView(text: log)
                    }
                }
            }
        }
        .onDisappear {
            session = nil
            analysis = nil
        }
    }

    private var inputCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Text(L("binaryview.chooseInput")).font(.headline)
                HStack {
                    FilePickerButton(
                        title: L("binaryview.chooseMachOOrIPA"),
                        systemImage: "cpu",
                        types: [.ipaPackage, .unixExecutable, .executable, .dylibFile, .data, .item]
                    ) {
                        openInput($0)
                    }
                    FilePickerButton(
                        title: L("binaryview.chooseApp"),
                        systemImage: "app",
                        chooseDirectory: true
                    ) {
                        guard $0.pathExtension.lowercased() == "app" else {
                            ok = false
                            log = L("binaryview.needAppDirectory")
                            return
                        }
                        openInput($0)
                    }
                    if sourceURL != nil {
                        Button(L("binaryview.reload")) {
                            if let sourceURL { openInput(sourceURL) }
                        }
                        .disabled(busy)
                    }
                    Spacer()
                }
                PathBadge(url: sourceURL, placeholder: L("binaryview.inputPlaceholder"))
                Text(L("binaryview.safetyNote"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityIdentifier("binary.input")
    }

    private func inventoryCard(_ session: BinaryAnalysisSession) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(L("binaryview.inventory")).font(.headline)
                    Text(L("binaryview.itemCount", session.targets.count))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(inputKindLabel(session.inputKind))
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .insetSurfaceBackground(
                            Capsule(),
                            legacyFill: .appAccent.opacity(0.14),
                            glassFill: AnyShapeStyle(Color.appAccent.opacity(0.24))
                        )
                }
                HStack {
                    TextField(L("binaryview.search"), text: $searchText)
                        .textFieldStyle(.roundedBorder)
                    Picker(L("binaryview.kind"), selection: $targetFilter) {
                        ForEach(TargetFilter.allCases) { Text($0.title).tag($0) }
                    }
                    .frame(width: 210)
                }
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(filteredTargets(session.targets)) { target in
                            targetRow(target)
                        }
                    }
                }
                .frame(maxHeight: 260)
            }
        }
        .accessibilityIdentifier("binary.inventory")
    }

    private func targetRow(_ target: BundleMachOTarget) -> some View {
        Button {
            select(target)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: icon(target.kind))
                    .frame(width: 20)
                    .foregroundStyle(target.id == selectedTargetID ? Color.appAccent : Color.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(target.name).font(.callout.weight(.medium))
                        Text(target.kind.displayName).font(.caption).foregroundStyle(.secondary)
                        if target.isRecommended {
                            Text(L("binaryview.recommended")).font(.caption2.weight(.semibold)).foregroundStyle(.green)
                        }
                    }
                    Text(target.relativePath)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Text(targetMetadata(target))
                        .font(.caption2)
                        .foregroundStyle(target.cryptid == 1 ? .red : .secondary)
                }
                Spacer()
                if target.id == selectedTargetID {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint)
                }
            }
            .padding(7)
            .insetSurfaceBackground(
                RoundedRectangle(cornerRadius: 7),
                legacyFill: target.id == selectedTargetID ? Color.appAccent.opacity(0.12) : .clear,
                glassFill: AnyShapeStyle(
                    target.id == selectedTargetID ? Color.appAccent.opacity(0.22) : .clear
                )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("binary.target.\(target.id)")
    }

    private func overviewCard(_ target: BundleMachOTarget) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    Text(L("binaryview.selected")).font(.headline)
                    Spacer()
                    Button(L("binaryview.reanalyze")) { analyze(target) }.disabled(busy)
                }
                detailLine(L("binaryview.detail.path"), target.relativePath)
                detailLine(L("binaryview.detail.kind"), analysis?.fileType ?? target.kind.displayName)
                detailLine(L("binaryview.detail.arch"), target.architectures.joined(separator: ", "))
                detailLine(
                    L("binaryview.detail.security"),
                    L("binaryview.detail.security.value", target.cryptid, signatureLabel(target.signature), FileSystemHelper.humanReadableSize(target.size))
                )
                if let bundleID = target.bundleID { detailLine("Bundle ID", bundleID) }
                if let extensionPoint = target.extensionPointIdentifier {
                    detailLine("Extension Point", extensionPoint)
                }
                if let restriction = target.restrictionNote {
                    Label(restriction, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    private func operationCard(_ target: BundleMachOTarget) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Text(L("binaryview.extractSection")).font(.headline)
                HStack {
                    Button(L("binaryview.exportSelected")) { chooseSelectedExport(target) }
                    Button(L("binaryview.exportAll")) { chooseAllExport() }
                    Button(L("binaryview.checkCapability")) { inspectCapability(target) }
                    Spacer()
                }
                Toggle(L("binaryview.flattenBulk"), isOn: $flattenBulkExport)
                    .font(.caption)
                if target.architectures.count > 1 {
                    HStack {
                        Picker(L("binaryview.detail.arch"), selection: $selectedArch) {
                            ForEach(target.architectures, id: \.self) { Text($0).tag($0) }
                        }
                        .frame(width: 220)
                        Button(L("binaryview.exportSlice")) { chooseThinExport(target) }
                            .disabled(selectedArch.isEmpty)
                    }
                }
                if let capability {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(L("binaryview.capability", capability.completeness.rawValue))
                                .font(.callout.weight(.semibold))
                            if capability.isEncrypted {
                                Text(L("binaryview.fairplay")).foregroundStyle(.red)
                            }
                        }
                        ForEach(capability.skipReasons, id: \.self) {
                            Text("• \($0)").font(.caption).foregroundStyle(.secondary)
                        }
                        HStack {
                            Picker(L("binaryview.output"), selection: $exportMode) {
                                Text(L("binaryview.mode.aggregate")).tag(ClassDumpExportMode.aggregate)
                                Text(L("binaryview.mode.perClass")).tag(ClassDumpExportMode.oneFilePerClass)
                            }
                            .frame(width: 220)
                            Button(L("binaryview.exportHeaders")) {
                                chooseHeaderExport(target)
                            }
                            .disabled(capability.isEncrypted)
                        }
                    }
                    .padding(.top, 2)
                } else {
                    Text(L("binaryview.capability.note"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func signingCard(_ target: BundleMachOTarget) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Text(L("binaryview.signing")).font(.headline)
                HStack {
                    Button(L("binaryview.showSignature")) {
                        log = analysis?.signatureInfo ?? L("binaryview.noSignature")
                    }
                    Button(L("binaryview.verifySignature")) { verifySign(target) }
                    Button(L("binaryview.adhocSign")) { adhocSign(target) }
                    if ExternalTool.ldid.isAvailable {
                        Button(L("binaryview.ldidSign")) { ldidSign(target) }
                    }
                    Spacer()
                }
                .disabled(busy)
                if session?.inputKind != .machO {
                    Text(L("binaryview.signing.note"))
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    private var selectedTarget: BundleMachOTarget? {
        guard let selectedTargetID else { return nil }
        return session?.targets.first { $0.id == selectedTargetID }
    }

    private func openInput(_ url: URL) {
        sourceURL = url
        session = nil
        selectedTargetID = nil
        analysis = nil
        capability = nil
        busy = true
        ok = nil
        log = L("binaryview.openingSession")
        Task {
            do {
                let opened = try await Task.detached {
                    try BinaryAnalysisSession.open(url)
                }.value
                session = opened
                selectedTargetID = opened.selectedTargetID
                guard let target = opened.selectedTarget else {
                    throw BinaryWorkflowError.unsupportedInput(url.path)
                }
                try await analyzeAsync(target)
                ok = true
                log = L("binaryview.opened", opened.targets.count, target.relativePath)
            } catch {
                ok = false
                log = "❌ \(operationError(error, paths: [url]))"
            }
            busy = false
        }
    }

    private func select(_ target: BundleMachOTarget) {
        do {
            try session?.select(targetID: target.id)
            selectedTargetID = target.id
            analysis = nil
            capability = nil
            selectedArch = target.architectures.first ?? ""
            analyze(target)
        } catch {
            ok = false
            log = error.localizedDescription
        }
    }

    private func analyze(_ target: BundleMachOTarget) {
        busy = true
        ok = nil
        Task {
            do {
                try await analyzeAsync(target)
                ok = true
                log = L("binaryview.analyzed", target.relativePath)
            } catch {
                ok = false
                log = "❌ \(operationError(error, paths: [sourceURL ?? target.fileURL]))"
            }
            busy = false
        }
    }

    private func analyzeAsync(_ target: BundleMachOTarget) async throws {
        guard let session else { throw BinaryWorkflowError.targetNotFound(target.id) }
        let value = try await Task.detached {
            try session.analysis(targetID: target.id)
        }.value
        analysis = value
        selectedArch = target.architectures.first ?? ""
    }

    private func inspectCapability(_ target: BundleMachOTarget) {
        run(L("binaryview.checkCapability"), paths: [sourceURL ?? target.fileURL]) {
            let report = try ClassDumpService.preflightCapability(fileAt: target.fileURL)
            await MainActor.run { capability = report }
            return report.skipReasons.isEmpty
                ? report.completeness.rawValue
                : report.skipReasons.joined(separator: "\n")
        }
    }

    private func chooseSelectedExport(_ target: BundleMachOTarget) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = target.fileURL.lastPathComponent
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let output = panel.url else { return }
        run(L("binaryview.task.exportSelected"), paths: [sourceURL ?? target.fileURL, output]) {
            guard let session else { throw BinaryWorkflowError.targetNotFound(target.id) }
            let exported = try FileSystemHelper.withSecurityScopedAccess(to: [output]) {
                try session.extractSelected(targetID: target.id, to: output)
            }
            return L("binaryview.result.exported", exported.path)
        }
    }

    private func chooseAllExport() {
        guard let session else { return }
        let flatten = flattenBulkExport
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = L("binaryview.prompt.outputDirectory")
        guard panel.runModal() == .OK, let directory = panel.url else { return }
        run(L("binaryview.task.exportAll"), paths: [sourceURL ?? directory, directory]) {
            let result = try FileSystemHelper.withSecurityScopedAccess(to: [directory]) {
                try session.extractAll(to: directory, flatten: flatten)
            }
            return L("binaryview.result.exportedAll", result.entries.count, result.manifestURL.path)
        }
    }

    private func chooseThinExport(_ target: BundleMachOTarget) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(target.fileURL.lastPathComponent)-\(selectedArch)"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let output = panel.url else { return }
        let arch = selectedArch
        run(L("binaryview.task.exportSlice", arch), paths: [sourceURL ?? target.fileURL, output]) {
            try FileSystemHelper.withSecurityScopedAccess(to: [output]) {
                guard !FileManager.default.fileExists(atPath: output.path) else {
                    throw BinaryWorkflowError.outputExists(output.path)
                }
                let result = try BinaryService.thin(fileAt: target.fileURL, arch: arch, to: output)
                guard result.succeeded else { throw IpaError.commandFailed(result.combinedOutput) }
            }
            return L("binaryview.result.exportedSlice", output.path)
        }
    }

    private func chooseHeaderExport(_ target: BundleMachOTarget) {
        guard target.cryptid == 0 else {
            ok = false
            log = "❌ \(ClassDumpError.encrypted.localizedDescription)"
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = L("binaryview.prompt.headerDirectory")
        guard panel.runModal() == .OK, let directory = panel.url else { return }
        let mode = exportMode
        run(L("binaryview.task.exportHeaders"), paths: [sourceURL ?? target.fileURL, directory]) {
            let dump = try ClassDumpService.dump(fileAt: target.fileURL)
            let summary = try FileSystemHelper.withSecurityScopedAccess(to: [directory]) {
                try ClassDumpService.export(
                    dump,
                    to: directory,
                    baseName: target.name,
                    mode: mode
                )
            }
            await MainActor.run { capability = dump.capabilityReport }
            let warnings = summary.warnings.isEmpty
                ? ""
                : "\n" + L("binaryview.result.warnings") + "\n" + summary.warnings.joined(separator: "\n")
            return L("binaryview.result.headers", summary.files.count, summary.classCount) + warnings
        }
    }

    private func verifySign(_ target: BundleMachOTarget) {
        run(L("binaryview.verifySignature"), paths: [sourceURL ?? target.fileURL]) {
            let result = try BinaryService.codesignVerify(fileAt: target.fileURL)
            return (result.succeeded ? L("binaryview.result.signatureValid") : L("binaryview.result.signatureInvalid")) + "\n" + result.combinedOutput
        }
    }

    private func adhocSign(_ target: BundleMachOTarget) {
        run(L("binaryview.task.adhocSign"), paths: [sourceURL ?? target.fileURL]) {
            let result = try BinaryService.adhocSign(fileAt: target.fileURL)
            guard result.succeeded else { throw IpaError.commandFailed(result.combinedOutput) }
            return L("binaryview.result.adhocSigned")
        }
    }

    private func ldidSign(_ target: BundleMachOTarget) {
        run(L("binaryview.task.ldidSign"), paths: [sourceURL ?? target.fileURL]) {
            let result = try BinaryService.ldidSign(fileAt: target.fileURL)
            guard result.succeeded else { throw IpaError.commandFailed(result.combinedOutput) }
            return L("binaryview.result.ldidSigned")
        }
    }

    private func run(
        _ label: String,
        paths: [URL],
        _ work: @escaping @Sendable () async throws -> String
    ) {
        busy = true
        ok = nil
        log = ""
        Task {
            do {
                let output = try await Task.detached(priority: .userInitiated) {
                    try await work()
                }.value
                ok = true
                log = L("binaryview.log.line", label, output)
            } catch {
                ok = false
                log = "❌ \(operationError(error, paths: paths))"
            }
            busy = false
        }
    }

    private func filteredTargets(_ targets: [BundleMachOTarget]) -> [BundleMachOTarget] {
        targets.filter { target in
            let typeMatches: Bool
            switch targetFilter {
            case .all: typeMatches = true
            case .main: typeMatches = target.kind == .mainExecutable
            case .frameworks: typeMatches = target.kind == .framework || target.kind == .dylib
            case .extensions: typeMatches = target.kind == .appExtension
            case .restricted: typeMatches = target.kind == .watchApp || target.kind == .appClip
            }
            let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            let searchMatches = query.isEmpty
                || target.name.localizedCaseInsensitiveContains(query)
                || target.relativePath.localizedCaseInsensitiveContains(query)
                || target.bundleID?.localizedCaseInsensitiveContains(query) == true
            return typeMatches && searchMatches
        }
    }

    @ViewBuilder
    private func detailLine(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label).font(.callout.weight(.semibold)).frame(width: 88, alignment: .leading)
            Text(value.isEmpty ? "—" : value)
                .font(.callout.monospaced())
                .textSelection(.enabled)
        }
    }

    private func targetMetadata(_ target: BundleMachOTarget) -> String {
        let archs = target.architectures.isEmpty ? L("binaryview.unknownArch") : target.architectures.joined(separator: ", ")
        return "\(archs) · \(FileSystemHelper.humanReadableSize(target.size)) · cryptid=\(target.cryptid) · \(signatureLabel(target.signature))"
    }

    private func signatureLabel(_ signature: DylibSignatureState) -> String {
        switch signature {
        case .valid: return L("binaryview.signature.valid")
        case .invalid: return L("binaryview.signature.invalid")
        case .unsigned: return L("binaryview.signature.unsigned")
        case .unavailable: return L("binaryview.signature.unknown")
        }
    }

    private func inputKindLabel(_ kind: BinaryInputKind) -> String {
        switch kind {
        case .machO: return L("binaryview.input.machO")
        case .app: return L("binaryview.input.app")
        case .ipa: return L("binaryview.input.ipa")
        }
    }

    private func icon(_ kind: BundleMachOTargetKind) -> String {
        switch kind {
        case .standalone, .mainExecutable: return "app.fill"
        case .framework: return "shippingbox.fill"
        case .dylib: return "link"
        case .appExtension: return "puzzlepiece.extension.fill"
        case .watchApp: return "applewatch"
        case .appClip: return "bolt.fill"
        }
    }

    private func operationError(_ error: Error, paths: [URL]) -> String {
        FileSystemHelper.isAccessPermissionError(error)
            ? FileSystemHelper.userFacingAccessError(error, paths: paths)
            : error.localizedDescription
    }
}
