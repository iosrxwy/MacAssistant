import SwiftUI
import MacAssistantKit

/// 使用项目自有纯 Swift 引擎提取 Objective-C 声明；外部 CLI 仅为用户主动启用的增强。
struct ClassDumpTab: View {
    @State private var inputURL: URL?
    @State private var outputDirectory: URL?
    @State private var archText = ""
    @State private var allowExternalEnhancement = true
    @State private var facts: MachOFacts?
    @State private var inspecting = false
    @State private var busy = false
    @State private var ok: Bool?
    @State private var log = ""
    @State private var headers = ""

    private var externalAvailable: Bool {
        ExternalTool.classDump.isAvailable || ExternalTool.dsdump.isAvailable
    }

    var body: some View {
        Group {
            Card {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Label("Class Dump", systemImage: "curlybraces.square")
                            .font(.headline)
                        Spacer()
                        Label(
                            externalAvailable ? L("classdumptab.engine.enhanced") : L("classdumptab.engine.builtIn"),
                            systemImage: externalAvailable ? "checkmark.circle" : "testtube.2"
                        )
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                    Text(L("classdumptab.intro"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    HStack {
                        FilePickerButton(
                            title: L("classdumptab.chooseBinary"),
                            systemImage: "doc.text.magnifyingglass",
                            types: [.ipaPackage, .dylibFile, .unixExecutable, .item]
                        ) { selectInput($0) }
                        FilePickerButton(
                            title: L("classdumptab.chooseApp"),
                            systemImage: "app.badge",
                            chooseDirectory: true
                        ) { selectInput($0) }
                        Spacer()
                    }
                    PathBadge(url: inputURL)
                }
            }

            if inspecting {
                ProgressView(L("classdumptab.inspecting"))
                    .controlSize(.small)
            } else if let facts {
                factsCard(facts)
            }

            Card {
                VStack(alignment: .leading, spacing: 12) {
                    Text(L("classdumptab.exportSettings")).font(.headline)
                    HStack {
                        FilePickerButton(
                            title: L("classdumptab.chooseOutput"),
                            systemImage: "folder",
                            chooseDirectory: true
                        ) { outputDirectory = $0 }
                        PathBadge(url: outputDirectory, placeholder: L("classdumptab.noOutput"))
                    }

                    HStack {
                        Text(L("classdumptab.architecture"))
                            .frame(width: 110, alignment: .leading)
                        TextField(L("classdumptab.architecture.placeholder"), text: $archText)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 300)
                        Spacer()
                    }

                    Toggle(L("classdumptab.allowExternal"), isOn: $allowExternalEnhancement)
                        .disabled(!externalAvailable)
                        .accessibilityHint(L("classdumptab.allowExternal.hint"))
                    if !externalAvailable {
                        Text(L("classdumptab.noExternal"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Button {
                dump()
            } label: {
                Label(busy ? L("classdumptab.exporting") : L("classdumptab.export"), systemImage: "square.and.arrow.down")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(busy || inputURL == nil || outputDirectory == nil || facts?.isEncrypted == true)
            .accessibilityIdentifier("classdump.export")

            if busy || !log.isEmpty {
                Card {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(L("classdumptab.summary")).font(.headline)
                            if busy { ProgressView().controlSize(.small) }
                            Spacer()
                            StatusBadge(ok: ok)
                        }
                        ConsoleView(text: log, minHeight: 90)
                    }
                }
            }

            if !headers.isEmpty {
                Card {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(L("classdumptab.preview")).font(.headline)
                            Spacer()
                            CopyButton(text: headers)
                        }
                        ConsoleView(text: String(headers.prefix(10_000)), minHeight: 220)
                    }
                }
            }
        }
    }

    private func factsCard(_ facts: MachOFacts) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Label(
                    facts.isEncrypted ? L("classdumptab.encrypted") : L("classdumptab.inspected"),
                    systemImage: facts.isEncrypted ? "lock.fill" : "checkmark.shield"
                )
                .font(.headline)
                .foregroundStyle(facts.isEncrypted ? .red : .primary)
                HStack(spacing: 16) {
                    fact(L("classdumptab.fact.arch"), facts.archs.joined(separator: ", "))
                    fact("Chained Fixups", facts.hasChainedFixups ? L("classdumptab.yes") : L("classdumptab.no"))
                    fact(L("classdumptab.fact.swift"), facts.hasSwift ? L("classdumptab.yes") : L("classdumptab.no"))
                    fact(L("classdumptab.fact.builtIn"), facts.nativeObjCDumpSupported ? L("classdumptab.supported") : L("classdumptab.limited"))
                }
                if facts.isEncrypted {
                    Text(L("classdumptab.encrypted.detail"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else if !facts.nativeObjCDumpSupported {
                    Text(
                        externalAvailable
                            ? L("classdumptab.limited.detail.external")
                            : L("classdumptab.limited.detail")
                    )
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityIdentifier("classdump.facts")
        }
    }

    private func fact(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.caption.monospacedDigit())
        }
    }

    private func selectInput(_ url: URL) {
        inputURL = url
        outputDirectory = url.deletingLastPathComponent()
            .appendingPathComponent(url.deletingPathExtension().lastPathComponent + "-Headers")
        headers = ""
        log = ""
        ok = nil
        facts = nil
        inspecting = true
        Task {
            do {
                facts = try await Task.detached {
                    try FileSystemHelper.withSecurityScopedAccess(to: [url]) {
                        try ClassDumpService.inspect(fileAt: url)
                    }
                }.value
            } catch {
                log = error.localizedDescription
                ok = false
            }
            inspecting = false
        }
    }

    private func dump() {
        guard let inputURL, let outputDirectory else { return }
        let destination = resolvedOutputDirectory(
            selected: outputDirectory,
            input: inputURL
        )
        let arch = archText.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowExternal = allowExternalEnhancement
        busy = true
        ok = nil
        log = L("classdumptab.selectingEngine")
        headers = ""

        Task {
            do {
                let pair = try await Task.detached {
                    try FileSystemHelper.withSecurityScopedAccess(to: [inputURL, outputDirectory]) {
                        let result = try ClassDumpService.dump(
                            fileAt: inputURL,
                            arch: arch.isEmpty ? nil : arch,
                            preferExternal: false,
                            allowExternalFallback: allowExternal
                        )
                        let summary = try ClassDumpService.export(
                            result,
                            to: destination,
                            baseName: inputURL.deletingPathExtension().lastPathComponent,
                            mode: .oneFilePerClass
                        )
                        return (result, summary)
                    }
                }.value
                headers = pair.0.headers
                let engine = pair.0.usedExternalTool
                    .map { L("classdumptab.engine.external", $0.commandName) }
                    ?? L("classdumptab.engine.native")
                let capability = pair.0.capabilityReport
                self.outputDirectory = destination
                var lines = [
                    L("classdumptab.result.done", engine, capability.completeness.rawValue),
                    L("classdumptab.result.classes", capability.discoveredClassCount, capability.exportedClassCount),
                    L("classdumptab.result.members", capability.methodCount, capability.propertyCount, capability.protocolCount),
                    L("classdumptab.result.coverage", capability.skippedCount, Int(capability.coverage * 100)),
                    L("classdumptab.result.files", pair.1.files.count),
                    L("classdumptab.result.directory", destination.path)
                ]
                lines.append(contentsOf: capability.skipReasons.map { "⚠️ \($0)" })
                lines.append(contentsOf: pair.1.warnings.map { "⚠️ \($0)" })
                log = lines.joined(separator: "\n")
                ok = true
                revealInFinder(destination)
            } catch {
                ok = false
                log = "❌ \(error.localizedDescription)"
            }
            busy = false
        }
    }

    private func resolvedOutputDirectory(selected: URL, input: URL) -> URL {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(
            atPath: selected.path,
            isDirectory: &isDirectory
        )
        if !exists {
            return selected
        }
        if isDirectory.boolValue,
           let contents = try? FileManager.default.contentsOfDirectory(atPath: selected.path),
           contents.isEmpty {
            return selected
        }

        let base = ClassDumpService.safeHeaderFileName(
            input.deletingPathExtension().lastPathComponent
        ) + "-Headers"
        return FileSystemHelper.uniqueOutputURL(
            basedOn: selected.appendingPathComponent(base, isDirectory: true)
        )
    }
}
