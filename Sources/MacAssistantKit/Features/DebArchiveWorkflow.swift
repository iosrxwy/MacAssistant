import CryptoKit
import Foundation

public enum DebArtifactKind: String, Codable, Hashable, Sendable {
    case dylib
    case frameworkExecutable
    case bundleExecutable
    case executable
    case machO
}

public struct DebMachOArtifact: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public let relativePath: String
    public let localURL: URL
    public let kind: DebArtifactKind
    public let containerRelativePath: String?
    public let companionPlistRelativePath: String?
    public let companionPlistURL: URL?
    public let analysis: DylibAnalysisSnapshot

    public init(
        id: UUID = UUID(),
        relativePath: String,
        localURL: URL,
        kind: DebArtifactKind,
        containerRelativePath: String?,
        companionPlistRelativePath: String?,
        companionPlistURL: URL?,
        analysis: DylibAnalysisSnapshot
    ) {
        self.id = id
        self.relativePath = relativePath
        self.localURL = localURL
        self.kind = kind
        self.containerRelativePath = containerRelativePath
        self.companionPlistRelativePath = companionPlistRelativePath
        self.companionPlistURL = companionPlistURL
        self.analysis = analysis
    }
}

public struct DebScanResult: Sendable {
    public let archiveID: UUID
    public let archiveURL: URL
    public let archiveSHA256: String
    public let info: DebInfo
    public let safety: ArchiveValidationReport
    public let artifacts: [DebMachOArtifact]
}

/// 持有安全扫描产生的私有 0700 解包目录；生命周期结束后自动清理。
public final class DebScanSession: @unchecked Sendable {
    public let result: DebScanResult
    fileprivate let workspaceRoot: URL

    fileprivate init(result: DebScanResult, workspaceRoot: URL) {
        self.result = result
        self.workspaceRoot = workspaceRoot
    }

    deinit {
        try? FileManager.default.removeItem(at: workspaceRoot)
    }
}

public enum DebExtractionMode: String, Codable, Hashable, CaseIterable, Sendable {
    case preserveRelativePaths
    case flat
}

public struct DebExtractionManifestEntry: Codable, Hashable, Sendable {
    public let artifactID: UUID
    public let sourceRelativePath: String
    public let outputRelativePath: String
    public let sha256: String
    public let kind: DebArtifactKind
    public let companionForArtifactID: UUID?
}

public struct DebExtractionManifest: Codable, Hashable, Sendable {
    public let schemaVersion: Int
    public let sourceArchive: String
    public let sourceArchiveSHA256: String
    public let mode: DebExtractionMode
    public let createdAt: Date
    public let entries: [DebExtractionManifestEntry]
}

public struct DebExtractionResult: Sendable {
    public let outputDirectory: URL
    public let manifestURL: URL
    public let manifest: DebExtractionManifest
}

public enum DebArchiveWorkflowError: LocalizedError {
    case artifactNotFound(UUID)
    case noDylibsFound
    case destinationNotEmpty(String)
    case outputConflict(String)
    case invalidExtractedPath(String)
    case manifestVerificationFailed

    public var errorDescription: String? {
        switch self {
        case let .artifactNotFound(id): return L("deb.archive.error.artifactNotFound", id.uuidString)
        case .noDylibsFound: return L("deb.archive.error.noDylibsFound")
        case let .destinationNotEmpty(path): return L("deb.archive.error.destinationNotEmpty", path)
        case let .outputConflict(path): return L("deb.archive.error.outputConflict", path)
        case let .invalidExtractedPath(path): return L("deb.archive.error.invalidExtractedPath", path)
        case .manifestVerificationFailed: return L("deb.archive.error.manifestVerificationFailed")
        }
    }
}

public enum DebArchiveWorkflow {
    /// 先枚举并应用 ArchiveSafety，再落地到私有工作区分析；不安全归档不会进入解包步骤。
    public static func scan(debAt url: URL) throws -> DebScanSession {
        let info = try DebService.inspect(debAt: url)
        let safety = try ArchiveSafety.validateEntries(
            info.entries.map { ($0.path, $0.size ?? 0, $0.link) }
        )
        let workspace = try FileSystemHelper.makeTemporaryDirectory(prefix: "deb-scan")
        do {
            let payload = workspace.appendingPathComponent("payload", isDirectory: true)
            try DebService.extract(debAt: url, to: payload, dataOnly: true)
            let payloadRoot = payload.standardizedFileURL
            let files = FileSystemHelper.allFiles(in: payload) {
                MachOIdentifier.isMachO(fileAt: $0)
            }.sorted { $0.path < $1.path }
            let artifacts = try files.map { file -> DebMachOArtifact in
                let archivePath = try relativePath(of: file, under: payloadRoot)
                let companion = companionPlist(for: file)
                let companionRelative = try companion.map { try relativePath(of: $0, under: payloadRoot) }
                let classification = classify(relativePath: archivePath, file: file)
                return try DebMachOArtifact(
                    relativePath: archivePath,
                    localURL: file,
                    kind: classification.kind,
                    containerRelativePath: classification.container,
                    companionPlistRelativePath: companionRelative,
                    companionPlistURL: companion,
                    analysis: DylibService.analyze(fileAt: file)
                )
            }
            let archiveID = UUID()
            let result = DebScanResult(
                archiveID: archiveID,
                archiveURL: url,
                archiveSHA256: try DylibService.sha256(fileAt: url),
                info: info,
                safety: safety,
                artifacts: artifacts
            )
            return DebScanSession(result: result, workspaceRoot: workspace)
        } catch {
            try? FileManager.default.removeItem(at: workspace)
            throw error
        }
    }

    /// 从既有安全扫描会话中选择真正的 MH_DYLIB；Framework 主二进制默认不混入普通 dylib 汇总。
    public static func dylibArtifacts(
        in session: DebScanSession,
        includeFrameworks: Bool = false
    ) -> [DebMachOArtifact] {
        session.result.artifacts.filter { artifact in
            guard isDynamicLibrary(fileAt: artifact.localURL) else { return false }
            return includeFrameworks || artifact.kind != .frameworkExecutable
        }.sorted { $0.relativePath < $1.relativePath }
    }

    /// 将安全扫描工作区中的全部动态库及同目录 filter plist 汇总到单层目录。
    ///
    /// 此入口固定使用 flat 模式，避免“一键汇总”意外继承 UI 的“保留相对目录”设置。
    public static func summarizeDylibs(
        from session: DebScanSession,
        includeFrameworks: Bool = false,
        to destination: URL
    ) throws -> DebExtractionResult {
        let artifacts = dylibArtifacts(in: session, includeFrameworks: includeFrameworks)
        guard !artifacts.isEmpty else {
            throw DebArchiveWorkflowError.noDylibsFound
        }
        return try extract(
            from: session,
            artifactIDs: Set(artifacts.map(\.id)),
            mode: .flat,
            to: destination
        )
    }

    public static func extract(
        from session: DebScanSession,
        artifactIDs: Set<DebMachOArtifact.ID>,
        mode: DebExtractionMode,
        to destination: URL
    ) throws -> DebExtractionResult {
        let selected = try artifactIDs.map { id -> DebMachOArtifact in
            guard let artifact = session.result.artifacts.first(where: { $0.id == id }) else {
                throw DebArchiveWorkflowError.artifactNotFound(id)
            }
            return artifact
        }.sorted { $0.relativePath < $1.relativePath }

        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) {
            guard FileSystemHelper.isDirectory(destination),
                  try fm.contentsOfDirectory(atPath: destination.path).isEmpty else {
                throw DebArchiveWorkflowError.destinationNotEmpty(destination.path)
            }
        }

        let staging = destination.deletingLastPathComponent()
            .appendingPathComponent(".deb-selection-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(
            at: staging,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? fm.removeItem(at: staging) }

        let flatNameCounts = Dictionary(grouping: selected, by: {
            $0.localURL.lastPathComponent.precomposedStringWithCanonicalMapping.lowercased()
        }).mapValues(\.count)
        var manifestEntries: [DebExtractionManifestEntry] = []
        var outputKeys = Set<String>()

        for artifact in selected {
            let outputRelative = outputPath(
                for: artifact,
                mode: mode,
                hasFlatCollision: (flatNameCounts[
                    artifact.localURL.lastPathComponent.precomposedStringWithCanonicalMapping.lowercased()
                ] ?? 0) > 1
            )
            try copy(
                artifact.localURL,
                relativeOutputPath: outputRelative,
                into: staging,
                outputKeys: &outputKeys
            )
            manifestEntries.append(
                DebExtractionManifestEntry(
                    artifactID: artifact.id,
                    sourceRelativePath: artifact.relativePath,
                    outputRelativePath: outputRelative,
                    sha256: try DylibService.sha256(fileAt: artifact.localURL),
                    kind: artifact.kind,
                    companionForArtifactID: nil
                )
            )

            if let plist = artifact.companionPlistURL,
               let sourceRelative = artifact.companionPlistRelativePath {
                let companionOutput: String
                switch mode {
                case .preserveRelativePaths:
                    companionOutput = sourceRelative
                case .flat:
                    companionOutput = (outputRelative as NSString)
                        .deletingPathExtension + ".plist"
                }
                try copy(
                    plist,
                    relativeOutputPath: companionOutput,
                    into: staging,
                    outputKeys: &outputKeys
                )
                manifestEntries.append(
                    DebExtractionManifestEntry(
                        artifactID: UUID(),
                        sourceRelativePath: sourceRelative,
                        outputRelativePath: companionOutput,
                        sha256: try DylibService.sha256(fileAt: plist),
                        kind: .machO,
                        companionForArtifactID: artifact.id
                    )
                )
            }
        }

        let manifest = DebExtractionManifest(
            schemaVersion: 1,
            sourceArchive: session.result.archiveURL.lastPathComponent,
            sourceArchiveSHA256: session.result.archiveSHA256,
            mode: mode,
            createdAt: Date(),
            entries: manifestEntries.sorted { $0.outputRelativePath < $1.outputRelativePath }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(manifest)
        let manifestURL = staging.appendingPathComponent("extraction-manifest.json")
        try data.write(to: manifestURL, options: .atomic)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard (try? decoder.decode(DebExtractionManifest.self, from: Data(contentsOf: manifestURL))) != nil else {
            throw DebArchiveWorkflowError.manifestVerificationFailed
        }

        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
        try fm.moveItem(at: staging, to: destination)
        return DebExtractionResult(
            outputDirectory: destination,
            manifestURL: destination.appendingPathComponent("extraction-manifest.json"),
            manifest: manifest
        )
    }

    private static func relativePath(of file: URL, under root: URL) throws -> String {
        let standardized = file.standardizedFileURL
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard standardized.path.hasPrefix(rootPath) else {
            throw DebArchiveWorkflowError.invalidExtractedPath(standardized.path)
        }
        let relative = String(standardized.path.dropFirst(rootPath.count))
        try ArchiveSafety.validatePath(relative)
        return relative
    }

    private static func companionPlist(for file: URL) -> URL? {
        let candidate = file.deletingPathExtension().appendingPathExtension("plist")
        guard FileManager.default.fileExists(atPath: candidate.path),
              !FileSystemHelper.isDirectory(candidate) else { return nil }
        return candidate
    }

    private static func classify(
        relativePath: String,
        file: URL
    ) -> (kind: DebArtifactKind, container: String?) {
        let components = relativePath.split(separator: "/").map(String.init)
        if let index = components.lastIndex(where: { $0.hasSuffix(".framework") }) {
            return (.frameworkExecutable, components[...index].joined(separator: "/"))
        }
        if let index = components.lastIndex(where: { $0.hasSuffix(".bundle") }) {
            return (.bundleExecutable, components[...index].joined(separator: "/"))
        }
        if isDynamicLibrary(fileAt: file) {
            return (.dylib, nil)
        }
        switch MachOIdentifier.machOFileType(fileAt: file) {
        case 0x2: return (.executable, nil) // MH_EXECUTE
        default: break
        }
        if file.pathExtension.isEmpty { return (.executable, nil) }
        return (.machO, nil)
    }

    private static func isDynamicLibrary(fileAt file: URL) -> Bool {
        if let fileType = MachOIdentifier.machOFileType(fileAt: file) {
            return fileType == 0x6 // MH_DYLIB
        }
        // 当前轻量 filetype 读取器可能无法覆盖首切片偏移超出前缀的 fat Mach-O；
        // 仅在扫描已确认 Mach-O 且 filetype 不可读时，才回退到 .dylib 扩展名。
        return file.pathExtension.lowercased() == "dylib"
            && MachOIdentifier.isMachO(fileAt: file)
    }

    private static func outputPath(
        for artifact: DebMachOArtifact,
        mode: DebExtractionMode,
        hasFlatCollision: Bool
    ) -> String {
        guard mode == .flat else { return artifact.relativePath }
        let original = artifact.localURL.lastPathComponent
        guard hasFlatCollision else { return original }
        let stem = artifact.localURL.deletingPathExtension().lastPathComponent
        let ext = artifact.localURL.pathExtension
        let suffix = stablePathSuffix(artifact.relativePath)
        return "\(stem)__\(suffix)\(ext.isEmpty ? "" : ".\(ext)")"
    }

    private static func stablePathSuffix(_ value: String) -> String {
        let digest = SHA256.hash(data: Data(value.utf8))
        return digest.prefix(4).map { String(format: "%02x", $0) }.joined()
    }

    private static func copy(
        _ source: URL,
        relativeOutputPath: String,
        into staging: URL,
        outputKeys: inout Set<String>
    ) throws {
        try ArchiveSafety.validatePath(relativeOutputPath)
        let key = relativeOutputPath.precomposedStringWithCanonicalMapping.lowercased()
        guard outputKeys.insert(key).inserted else {
            throw DebArchiveWorkflowError.outputConflict(relativeOutputPath)
        }
        let output = staging.appendingPathComponent(relativeOutputPath)
        let rootPath = staging.standardizedFileURL.path + "/"
        guard output.standardizedFileURL.path.hasPrefix(rootPath) else {
            throw DebArchiveWorkflowError.invalidExtractedPath(relativeOutputPath)
        }
        try FileManager.default.createDirectory(
            at: output.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.copyItem(at: source, to: output)
        guard try DylibService.sha256(fileAt: source) == DylibService.sha256(fileAt: output) else {
            throw DebArchiveWorkflowError.manifestVerificationFailed
        }
    }
}
