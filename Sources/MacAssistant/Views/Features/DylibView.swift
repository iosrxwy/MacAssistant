import SwiftUI
import MacAssistantKit

struct DylibView: View {
    @ObservedObject private var workspace: WorkspaceStore
    @State private var currentItemID: WorkspaceItem.ID?
    @State private var fileURL: URL?
    @State private var deps: [DylibDependency] = []
    @State private var rpaths: [String] = []
    @State private var snapshot: DylibAnalysisSnapshot?
    @State private var busy = false
    @State private var log = ""
    @State private var ok: Bool?

    @State private var changeOld = ""
    @State private var changeNew = ""
    @State private var newRPath = "@executable_path/Frameworks"

    // 从 app/deb/目录提取
    @State private var extractSource: URL?

    init(workspace: WorkspaceStore) {
        self.workspace = workspace
    }

    var body: some View {
        FeatureScaffold(title: L("dylibview.title"), subtitle: L("dylibview.subtitle")) {
            Card {
                VStack(alignment: .leading, spacing: 10) {
                    Text(L("dylibview.chooseMachO")).font(.headline)
                    HStack {
                        FilePickerButton(title: L("dylibview.chooseFile"), systemImage: "link",
                                         types: [.dylibFile, .unixExecutable, .executable, .item]) { url in
                            do {
                                _ = try workspace.importForDylib(fileURL: url)
                                acceptPendingWorkspaceItem()
                            } catch {
                                ok = false
                                log = error.localizedDescription
                            }
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
                    PathBadge(url: fileURL)
                }
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
                        FilePickerButton(title: L("dylibview.sourceFile"), systemImage: "app.badge") { url in extractSource = url }
                        FilePickerButton(title: L("dylibview.sourceFolder"), systemImage: "folder", chooseDirectory: true) { url in extractSource = url }
                        if extractSource != nil {
                            Button(L("dylibview.extract")) { extract() }.disabled(busy)
                        }
                        Spacer()
                    }
                    PathBadge(url: extractSource, placeholder: L("dylibview.extract.placeholder"))
                }
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
        busy = true; ok = nil; log = ""
        Task {
            do {
                let d = try await Task.detached { try DylibService.dependencies(fileAt: url) }.value
                let r = (try? await Task.detached { try DylibService.rpaths(fileAt: url) }.value) ?? []
                let s = try await Task.detached { try DylibService.analyze(fileAt: url) }.value
                deps = d; rpaths = r; snapshot = s; ok = true
                log = L("dylibview.loaded", d.count, r.count)
            } catch { ok = false; log = error.localizedDescription }
            busy = false
        }
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

    private func extract() {
        guard let src = extractSource else { return }
        let dest = src.deletingPathExtension().appendingPathExtension("extracted-dylibs")
        busy = true; ok = nil; log = ""
        Task {
            do {
                let files = try await Task.detached { try DylibService.extractMachOFiles(from: src, to: dest) }.value
                ok = true
                log = files.isEmpty ? L("dylibview.noMachO") :
                    L("dylibview.extracted", files.count, dest.path) + "\n"
                        + files.map { "· " + $0.lastPathComponent }.joined(separator: "\n")
                revealInFinder(dest)
            } catch { ok = false; log = error.localizedDescription }
            busy = false
        }
    }

    /// 传入的是「已完成」整句而不是动作名:中英文里动作名和「完成」的拼接顺序不一样。
    private func run(_ doneMessage: String, _ work: @escaping @Sendable () throws -> String) {
        busy = true; ok = nil; log = ""
        Task {
            do {
                let out = try await Task.detached(priority: .userInitiated, operation: work).value
                ok = true; log = "\(doneMessage)\n\(out)"
                load()
            } catch { ok = false; log = error.localizedDescription; busy = false }
        }
    }
}
