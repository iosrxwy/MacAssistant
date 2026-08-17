import SwiftUI
import MacAssistantKit

struct DylibView: View {
    @ObservedObject private var workspace: WorkspaceStore
    @State private var currentItemID: WorkspaceItem.ID?
    @State private var fileURL: URL?
    @State private var deps: [DylibDependency] = []
    @State private var rpaths: [String] = []
    @State private var snapshot: DylibAnalysisSnapshot?
    @State private var analysisBusy = false
    @State private var extractBusy = false
    @State private var log = ""
    @State private var ok: Bool?

    @State private var changeOld = ""
    @State private var changeNew = ""
    @State private var newRPath = "@executable_path/Frameworks"

    // 从 app/deb/目录提取
    @State private var extractSources: [URL] = []
    @State private var pendingExtract: (sources: [URL], skipped: [URL])?
    @State private var machODropTargeted = false
    @State private var extractDropTargeted = false

    init(workspace: WorkspaceStore) {
        self.workspace = workspace
    }

    private var busy: Bool { analysisBusy || extractBusy }

    var body: some View {
        FeatureScaffold(title: L("dylibview.title"), subtitle: L("dylibview.subtitle")) {
            Card {
                VStack(alignment: .leading, spacing: 10) {
                    Text(L("dylibview.chooseMachO")).font(.headline)
                    HStack {
                        FilePickerButton(title: L("dylibview.chooseFile"), systemImage: "link",
                                         types: [.dylibFile, .unixExecutable, .executable, .item]) { url in
                            acceptMachO(url)
                        }
                        Spacer()
                        if fileURL != nil {
                            Button(L("dylibview.packAsDeb")) {
                                if let id = currentItemID {
                                    workspace.createDebDraft(from: [id])
                                } else if let fileURL {
                                    workspace.createDebDraft(fileURL: fileURL)
                                }
                            }
                        }
                        if fileURL != nil { Button(L("dylibview.reload")) { load() }.disabled(busy) }
                    }
                    PathBadge(url: fileURL, isDropTargeted: machODropTargeted, showsDropChrome: true)
                    Text(L("dylibview.drop.hintMachO"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .fileURLsDropTarget(isTargeted: $machODropTargeted) { urls in
                acceptMachODrops(urls)
            }

            if let snapshot {
                Card {
                    VStack(alignment: .leading, spacing: 7) {
                        Text(L("dylibview.analysis")).font(.headline)
                        Text(L("dylibview.architectures", snapshot.architectures.joined(separator: ", ")))
                        Text(L("dylibview.installName", snapshot.installName ?? "—"))
                        Text(L("dylibview.uuid", snapshot.uuids.isEmpty ? "—" : snapshot.uuids.joined(separator: ", ")))
                        Text(L("dylibview.minimumOS", snapshot.minimumOSVersions.isEmpty
                            ? L("dylibview.unknown")
                            : snapshot.minimumOSVersions.joined(separator: ", ")))
                        Text(L("dylibview.signature", snapshot.signature.rawValue, String(snapshot.sha256.prefix(16))))
                        if snapshot.isEncrypted {
                            Label(L("dylibview.encrypted"), systemImage: "lock.fill").foregroundStyle(.red)
                        }
                    }
                    .font(.callout)
                    .textSelection(.enabled)
                }
            }

            if !deps.isEmpty {
                Card {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(L("dylibview.dependencies", deps.count)).font(.headline)
                        ForEach(deps) { dep in
                            HStack {
                                Text(dep.path).font(.caption.monospaced()).textSelection(.enabled)
                                    .lineLimit(1).truncationMode(.middle)
                                Spacer()
                                if let cur = dep.currentVersion {
                                    Text("v\(cur)").font(.caption2).foregroundStyle(.secondary)
                                }
                                Button {
                                    changeOld = dep.path
                                } label: { Image(systemName: "arrow.right.circle") }
                                    .buttonStyle(.borderless)
                                    .help(L("dylibview.fillOldPath"))
                            }
                        }
                    }
                }
            }

            if !rpaths.isEmpty {
                Card {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("LC_RPATH(\(rpaths.count))").font(.headline)
                        ForEach(rpaths, id: \.self) { path in
                            HStack {
                                Text(path).font(.caption.monospaced()).textSelection(.enabled)
                                Spacer()
                                Button {
                                    guard let url = fileURL else { return }
                                    let target = path
                                    run(L("dylibview.done.deleteRPath")) { try DylibService.deleteRPath(target, fileAt: url).combinedOutput }
                                } label: { Image(systemName: "trash") }.buttonStyle(.borderless).foregroundStyle(.red)
                            }
                        }
                    }
                }
            }

            if fileURL != nil {
                Card {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(L("dylibview.edit")).font(.headline)

                        VStack(alignment: .leading, spacing: 6) {
                            Text(L("dylibview.changeDependency")).font(.subheadline.weight(.medium))
                            TextField(L("dylibview.oldPath"), text: $changeOld).textFieldStyle(.roundedBorder)
                            TextField(L("dylibview.newPath"), text: $changeNew).textFieldStyle(.roundedBorder)
                            Button(L("dylibview.apply")) {
                                guard let url = fileURL else { return }
                                let old = changeOld, new = changeNew
                                run(L("dylibview.done.changeDependency")) { try DylibService.changeDependency(from: old, to: new, fileAt: url).combinedOutput }
                            }
                            .disabled(busy || changeOld.isEmpty || changeNew.isEmpty)
                        }

                        Divider()

                        VStack(alignment: .leading, spacing: 6) {
                            Text(L("dylibview.addRPath")).font(.subheadline.weight(.medium))
                            HStack {
                                TextField("rpath", text: $newRPath).textFieldStyle(.roundedBorder)
                                Button(L("dylibview.add")) {
                                    guard let url = fileURL else { return }
                                    let value = newRPath
                                    run(L("dylibview.done.addRPath")) { try DylibService.addRPath(value, fileAt: url).combinedOutput }
                                }.disabled(busy || newRPath.isEmpty)
                            }
                        }
                    }
                }
            }

            Card {
                VStack(alignment: .leading, spacing: 10) {
                    Text(L("dylibview.extract.title")).font(.headline)
                    HStack {
                        MultiFilePickerButton(
                            title: L("dylibview.sourceFile"),
                            systemImage: "app.badge",
                            types: [.debPackage, .ipaPackage, .applicationBundle, .dylibFile, .item]
                        ) { urls in
                            acceptExtractSources(urls)
                        }
                        MultiFilePickerButton(
                            title: L("dylibview.sourceFolder"),
                            systemImage: "folder",
                            chooseDirectory: true
                        ) { urls in
                            acceptExtractSources(urls)
                        }
                        if !extractSources.isEmpty {
                            Button(L("dylibview.extract")) { extract(extractSources) }.disabled(extractBusy)
                        }
                        Spacer()
                    }
                    if extractSources.isEmpty {
                        PathBadge(
                            url: nil,
                            placeholder: L("dylibview.extract.placeholder"),
                            isDropTargeted: extractDropTargeted,
                            showsDropChrome: true
                        )
                    } else {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(extractSources, id: \.path) { url in
                                PathBadge(
                                    url: url,
                                    isDropTargeted: extractDropTargeted,
                                    showsDropChrome: true
                                )
                            }
                        }
                    }
                    Text(L("dylibview.drop.hintExtract"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .fileURLsDropTarget(isTargeted: $extractDropTargeted) { urls in
                acceptExtractSources(urls)
            }

            if busy || !log.isEmpty {
                Card {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack { Text(L("dylibview.outputSection")).font(.headline); if busy { ProgressView().controlSize(.small) }; Spacer(); StatusBadge(ok: ok) }
                        ConsoleView(text: log)
                    }
                }
            }
        }
        .onAppear { acceptPendingWorkspaceItem() }
        .onReceive(workspace.$pendingDylibItemID) { itemID in
            if itemID != nil { acceptPendingWorkspaceItem() }
        }
    }

    private func load() {
        guard let url = fileURL else { return }
        analysisBusy = true; ok = nil; log = ""
        Task {
            do {
                let d = try await Task.detached { try DylibService.dependencies(fileAt: url) }.value
                let r = (try? await Task.detached { try DylibService.rpaths(fileAt: url) }.value) ?? []
                let s = try await Task.detached { try DylibService.analyze(fileAt: url) }.value
                deps = d; rpaths = r; snapshot = s; ok = true
                log = L("dylibview.loaded", d.count, r.count)
            } catch { ok = false; log = error.localizedDescription }
            analysisBusy = false
        }
    }

    private func acceptMachO(_ url: URL) {
        do {
            _ = try workspace.importForDylib(fileURL: url)
            acceptPendingWorkspaceItem()
        } catch {
            ok = false
            log = error.localizedDescription
        }
    }

    private func acceptMachODrops(_ urls: [URL]) {
        FileSystemHelper.withSecurityScopedAccess(to: urls) {
            let extractable = urls.filter { !MachOIdentifier.isMachO(fileAt: $0) && isExtractSource($0) }
            // 混入 .deb/.app 时整批走提取,避免分析日志把提取结果盖掉。
            if !extractable.isEmpty {
                acceptExtractSources(urls.filter(isExtractSource))
                return
            }
            if let first = urls.first(where: { MachOIdentifier.isMachO(fileAt: $0) }) {
                acceptMachO(first)
                return
            }
            let names = urls.map(\.lastPathComponent).joined(separator: ", ")
            rejectDrop(L("dylibview.drop.notMachO", names))
        }
    }

    private func acceptExtractSources(_ urls: [URL]) {
        FileSystemHelper.withSecurityScopedAccess(to: urls) {
            let valid = uniquedURLs(urls.filter(isExtractSource))
            let rejected = urls.filter { !isExtractSource($0) }
            guard !valid.isEmpty else {
                let names = rejected.map(\.lastPathComponent).joined(separator: ", ")
                rejectDrop(L("dylibview.drop.notExtractSource", names))
                return
            }
            extractSources = uniquedURLs(extractSources + valid)
            extract(valid, skipped: rejected)
        }
    }

    private func isExtractSource(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        if ["deb", "ipa", "app", "framework", "bundle", "appex", "xpc", "dylib", "theme"].contains(ext) {
            return true
        }
        if MachOIdentifier.isMachO(fileAt: url) { return true }
        return FileSystemHelper.isDirectory(url)
    }

    private func rejectDrop(_ message: String) {
        ok = false
        log = message
    }

    private func acceptPendingWorkspaceItem() {
        guard let item = workspace.consumePendingDylib() else { return }
        currentItemID = item.id
        fileURL = item.fileURL
        deps = []
        rpaths = []
        snapshot = nil
        log = ""
        ok = nil
        load()
    }

    private func extract(_ sources: [URL], skipped: [URL] = []) {
        let uniqueSources = uniquedURLs(sources)
        guard !uniqueSources.isEmpty else { return }
        if extractBusy {
            let queued = pendingExtract.map(\.sources) ?? []
            let queuedSkipped = pendingExtract.map(\.skipped) ?? []
            pendingExtract = (uniquedURLs(queued + uniqueSources), uniquedURLs(queuedSkipped + skipped))
            return
        }
        extractBusy = true; ok = nil; log = ""
        Task {
            let results = await Task.detached {
                FileSystemHelper.withSecurityScopedAccess(to: uniqueSources) {
                    DylibService.extractPayloads(from: uniqueSources)
                }
            }.value
            let items = results.flatMap(\.items)
            let failures = results.filter { $0.error != nil }
            var lines: [String] = []
            if items.isEmpty, failures.isEmpty {
                lines.append(L("dylibview.noPayload"))
            } else if !items.isEmpty {
                lines.append(L("dylibview.extracted", results.count, items.count))
            }
            for result in results {
                if let error = result.error {
                    lines.append(L("dylibview.extract.failed", result.source.lastPathComponent, error))
                    continue
                }
                if result.items.isEmpty { continue }
                lines.append(L("dylibview.extracted.destination", result.destination.path))
                lines.append(contentsOf: result.items.map { item in
                    let name = item.outputURL.lastPathComponent
                    return "· \(name) (\(kindLabel(item.kind)))"
                })
            }
            if !skipped.isEmpty {
                lines.append(L("dylibview.drop.skipped", skipped.map(\.lastPathComponent).joined(separator: ", ")))
            }
            ok = failures.isEmpty && !items.isEmpty
            log = lines.joined(separator: "\n")
            let successful = results.filter { $0.error == nil && !$0.items.isEmpty }
            if let first = successful.first {
                revealInFinder(
                    successful.count == 1 ? first.destination : first.destination.deletingLastPathComponent()
                )
            }
            extractBusy = false
            if let pending = pendingExtract {
                pendingExtract = nil
                extract(pending.sources, skipped: pending.skipped)
            }
        }
    }

    private func uniquedURLs(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        return urls.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    private func kindLabel(_ kind: ExtractedPayloadKind) -> String {
        switch kind {
        case .dylib: return L("dylibview.kind.dylib")
        case .framework: return L("dylibview.kind.framework")
        case .bundle: return L("dylibview.kind.bundle")
        case .resourcePackage: return L("dylibview.kind.resourcePackage")
        case .resource: return L("dylibview.kind.resource")
        case .machO: return L("dylibview.kind.machO")
        }
    }

    /// 传入的是「已完成」整句而不是动作名:中英文里动作名和「完成」的拼接顺序不一样。
    private func run(_ doneMessage: String, _ work: @escaping @Sendable () throws -> String) {
        analysisBusy = true; ok = nil; log = ""
        Task {
            do {
                let out = try await Task.detached(priority: .userInitiated, operation: work).value
                ok = true; log = "\(doneMessage)\n\(out)"
                load()
            } catch { ok = false; log = error.localizedDescription; analysisBusy = false }
        }
    }
}
