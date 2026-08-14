import Foundation

public enum DebWorkspaceEntryType: String, Codable, Hashable, Sendable {
    case regular
    case directory
    case symbolicLink
}

public struct DebWorkspaceManifestEntry: Codable, Hashable, Sendable {
    public let relativePath: String
    public let type: DebWorkspaceEntryType
    public let mode: UInt16
    public let size: Int64
    public let sha256: String?
    public let symlinkTarget: String?
}

public struct DebWorkspaceManifest: Codable, Hashable, Sendable {
    public let schemaVersion: Int
    public let sourceArchiveSHA256: String
    public let controlText: String
    public let entries: [DebWorkspaceManifestEntry]
    public let fidelityLimitations: [String]
}

public enum DebWorkspaceChangeKind: String, Codable, Hashable, Sendable {
    case added
    case removed
    case modified
    case metadataChanged
}

public struct DebWorkspaceChange: Codable, Hashable, Sendable {
    public let relativePath: String
    public let kind: DebWorkspaceChangeKind
    public let beforeSHA256: String?
    public let afterSHA256: String?
}

public struct DebWorkspaceBuildResult: Sendable {
    public let outputURL: URL
    public let sha256: String
    public let changes: [DebWorkspaceChange]
    public let verification: DebInfo
    public let fidelityLimitations: [String]
}

public final class DebEditableWorkspace: @unchecked Sendable {
    public let sourceArchive: URL
    public let root: URL
    public let stage: URL
    public let originalManifest: DebWorkspaceManifest

    fileprivate init(
        sourceArchive: URL,
        root: URL,
        stage: URL,
        originalManifest: DebWorkspaceManifest
    ) {
        self.sourceArchive = sourceArchive
        self.root = root
        self.stage = stage
        self.originalManifest = originalManifest
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }
}

public enum DebEditableWorkspaceError: LocalizedError {
    case invalidPath(String)
    case notDylib(String)
    case scriptInvalid(String)
    case controlInvalid(String)
    case unsupportedFidelity(String)

    public var errorDescription: String? {
        switch self {
        case let .invalidPath(path): return L("deb.workspace.error.invalidPath", path)
        case let .notDylib(path): return L("deb.workspace.error.notDylib", path)
        case let .scriptInvalid(reason): return L("deb.workspace.error.scriptInvalid", reason)
        case let .controlInvalid(reason): return L("deb.workspace.error.controlInvalid", reason)
        case let .unsupportedFidelity(reason): return L("deb.workspace.error.unsupportedFidelity", reason)
        }
    }
}

/// DEB P1 的可测试服务层。源包永不修改；所有编辑发生在私有 0700 stage。
///
/// 当前安全基线会阻止含 symlink/hardlink/特殊节点的包进入编辑模式，避免把“规范化副本”
/// 误报为保真往返；numeric owner 在 macOS 普通目录中无法完整保留，会明确报告。
public enum DebEditableWorkspaceService {
    public static func create(from deb: URL) throws -> DebEditableWorkspace {
        let scan = try DebArchiveWorkflow.scan(debAt: deb)
        if scan.result.info.entries.contains(where: { $0.link != nil }) {
            throw DebEditableWorkspaceError.unsupportedFidelity(L("deb.workspace.fidelity.linkEntries"))
        }
        let root = try FileSystemHelper.makeTemporaryDirectory(prefix: "deb-workspace")
        do {
            let original = root.appendingPathComponent("original", isDirectory: true)
            let stage = root.appendingPathComponent("stage", isDirectory: true)
            let reports = root.appendingPathComponent("reports", isDirectory: true)
            try FileManager.default.createDirectory(at: original, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: reports, withIntermediateDirectories: true)
            try FileManager.default.copyItem(
                at: deb,
                to: original.appendingPathComponent("source.deb")
            )
            try DebService.extract(debAt: deb, to: stage, dataOnly: false)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: root.path
            )
            let limitations = [
                L("deb.workspace.limitation.numericOwner"),
                L("deb.workspace.limitation.failClosedLinks"),
                L("deb.workspace.limitation.extendedAttributes")
            ]
            let manifest = try makeManifest(
                stage: stage,
                sourceArchiveSHA256: scan.result.archiveSHA256,
                limitations: limitations
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try encoder.encode(manifest).write(
                to: original.appendingPathComponent("archive-manifest.json"),
                options: .atomic
            )
            return DebEditableWorkspace(
                sourceArchive: deb,
                root: root,
                stage: stage,
                originalManifest: manifest
            )
        } catch {
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }

    public static func diff(_ workspace: DebEditableWorkspace) throws -> [DebWorkspaceChange] {
        let current = try makeManifest(
            stage: workspace.stage,
            sourceArchiveSHA256: workspace.originalManifest.sourceArchiveSHA256,
            limitations: workspace.originalManifest.fidelityLimitations
        )
        let before = Dictionary(uniqueKeysWithValues: workspace.originalManifest.entries.map {
            ($0.relativePath, $0)
        })
        let after = Dictionary(uniqueKeysWithValues: current.entries.map {
            ($0.relativePath, $0)
        })
        let paths = Set(before.keys).union(after.keys)
        return paths.compactMap { path in
            switch (before[path], after[path]) {
            case (nil, let new?):
                return DebWorkspaceChange(
                    relativePath: path,
                    kind: .added,
                    beforeSHA256: nil,
                    afterSHA256: new.sha256
                )
            case (let old?, nil):
                return DebWorkspaceChange(
                    relativePath: path,
                    kind: .removed,
                    beforeSHA256: old.sha256,
                    afterSHA256: nil
                )
            case (let old?, let new?) where old.sha256 != new.sha256 || old.size != new.size:
                return DebWorkspaceChange(
                    relativePath: path,
                    kind: .modified,
                    beforeSHA256: old.sha256,
                    afterSHA256: new.sha256
                )
            case (let old?, let new?) where old.mode != new.mode || old.type != new.type
                || old.symlinkTarget != new.symlinkTarget:
                return DebWorkspaceChange(
                    relativePath: path,
                    kind: .metadataChanged,
                    beforeSHA256: old.sha256,
                    afterSHA256: new.sha256
                )
            default:
                return nil
            }
        }.sorted { $0.relativePath < $1.relativePath }
    }

    public static func replaceDylib(
        in workspace: DebEditableWorkspace,
        at relativePath: ValidatedRelativePath,
        with source: URL
    ) throws {
        guard MachOIdentifier.isDylib(fileAt: source) else {
            throw DebEditableWorkspaceError.notDylib(source.path)
        }
        let destination = try containedURL(relativePath, in: workspace.stage)
        guard FileManager.default.fileExists(atPath: destination.path),
              !FileSystemHelper.isDirectory(destination) else {
            throw DebEditableWorkspaceError.invalidPath(relativePath.rawValue)
        }
        try rejectSymlinkAncestors(destination, root: workspace.stage)
        let mode = try fileMode(destination)
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".replace-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try FileManager.default.copyItem(at: source, to: temporary)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: mode)],
            ofItemAtPath: temporary.path
        )
        _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
    }

    public static func addDylib(
        to workspace: DebEditableWorkspace,
        at relativePath: ValidatedRelativePath,
        from source: URL,
        mode: UInt16 = 0o755
    ) throws {
        guard MachOIdentifier.isDylib(fileAt: source) else {
            throw DebEditableWorkspaceError.notDylib(source.path)
        }
        let destination = try containedURL(relativePath, in: workspace.stage)
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw DebError.outputExists(destination.path)
        }
        try rejectSymlinkAncestors(destination, root: workspace.stage)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.copyItem(at: source, to: destination)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: mode)],
            ofItemAtPath: destination.path
        )
    }

    public static func remove(
        from workspace: DebEditableWorkspace,
        at relativePath: ValidatedRelativePath
    ) throws {
        let target = try containedURL(relativePath, in: workspace.stage)
        try rejectSymlinkAncestors(target, root: workspace.stage)
        guard FileManager.default.fileExists(atPath: target.path) else {
            throw DebEditableWorkspaceError.invalidPath(relativePath.rawValue)
        }
        try FileManager.default.removeItem(at: target)
    }

    public static func updateControl(
        in workspace: DebEditableWorkspace,
        text: String
    ) throws {
        guard !text.contains("\0"), text.hasSuffix("\n") else {
            throw DebEditableWorkspaceError.controlInvalid(L("deb.workspace.control.needsTrailingNewline"))
        }
        let parsed = DebService.parseControl(text)
        guard parsed.package != nil, parsed.version != nil, parsed.architecture != nil else {
            throw DebEditableWorkspaceError.controlInvalid(L("deb.workspace.control.missingCoreFields"))
        }
        try text.write(
            to: workspace.stage.appendingPathComponent("DEBIAN/control"),
            atomically: true,
            encoding: .utf8
        )
    }

    public static func repack(
        _ workspace: DebEditableWorkspace,
        to output: URL
    ) throws -> DebWorkspaceBuildResult {
        try validateControlAndScripts(in: workspace.stage)
        let changes = try diff(workspace)
        _ = try DebService.repack(directory: workspace.stage, to: output)
        let verification = try DebService.inspect(debAt: output)
        guard verification.control.package != nil, !verification.entries.isEmpty else {
            throw DebError.commandFailed(L("deb.workspace.error.repackVerificationFailed"))
        }
        return DebWorkspaceBuildResult(
            outputURL: output,
            sha256: try DylibService.sha256(fileAt: output),
            changes: changes,
            verification: verification,
            fidelityLimitations: workspace.originalManifest.fidelityLimitations
        )
    }

    private static func makeManifest(
        stage: URL,
        sourceArchiveSHA256: String,
        limitations: [String]
    ) throws -> DebWorkspaceManifest {
        let controlURL = stage.appendingPathComponent("DEBIAN/control")
        let control = try String(contentsOf: controlURL, encoding: .utf8)
        var entries: [DebWorkspaceManifestEntry] = []
        for url in FileSystemHelper.allFiles(in: stage, where: { _ in true }) {
            guard let relative = relativePath(url, under: stage) else {
                throw DebEditableWorkspaceError.invalidPath(url.path)
            }
            let values = try url.resourceValues(forKeys: [
                .isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey
            ])
            let type: DebWorkspaceEntryType
            let hash: String?
            let link: String?
            if values.isSymbolicLink == true {
                type = .symbolicLink
                hash = nil
                link = try FileManager.default.destinationOfSymbolicLink(atPath: url.path)
            } else if values.isDirectory == true {
                type = .directory
                hash = nil
                link = nil
            } else {
                type = .regular
                hash = try DylibService.sha256(fileAt: url)
                link = nil
            }
            entries.append(
                DebWorkspaceManifestEntry(
                    relativePath: relative,
                    type: type,
                    mode: try fileMode(url),
                    size: Int64(values.fileSize ?? 0),
                    sha256: hash,
                    symlinkTarget: link
                )
            )
        }
        return DebWorkspaceManifest(
            schemaVersion: 1,
            sourceArchiveSHA256: sourceArchiveSHA256,
            controlText: control,
            entries: entries.sorted { $0.relativePath < $1.relativePath },
            fidelityLimitations: limitations
        )
    }

    private static func validateControlAndScripts(in stage: URL) throws {
        let control = try String(
            contentsOf: stage.appendingPathComponent("DEBIAN/control"),
            encoding: .utf8
        )
        guard control.hasSuffix("\n"), !control.contains("\0") else {
            throw DebEditableWorkspaceError.controlInvalid(L("deb.workspace.control.mustKeepTrailingNewline"))
        }
        let parsed = DebService.parseControl(control)
        guard parsed.package != nil, parsed.version != nil, parsed.architecture != nil else {
            throw DebEditableWorkspaceError.controlInvalid(L("deb.workspace.control.missingRequiredFields"))
        }
        for script in DebMaintainerScript.allCases {
            let url = stage.appendingPathComponent("DEBIAN/\(script.rawValue)")
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let text = try String(contentsOf: url, encoding: .utf8)
            let mode = try fileMode(url)
            guard text.hasPrefix("#!"), !text.contains("\0"), mode & 0o111 != 0,
                  mode & 0o002 == 0 else {
                throw DebEditableWorkspaceError.scriptInvalid(
                    L("deb.workspace.script.requirements", script.rawValue)
                )
            }
        }
    }

    private static func containedURL(
        _ path: ValidatedRelativePath,
        in root: URL
    ) throws -> URL {
        let result = root.appendingPathComponent(path.rawValue).standardizedFileURL
        guard result.path.hasPrefix(root.standardizedFileURL.path + "/") else {
            throw DebEditableWorkspaceError.invalidPath(path.rawValue)
        }
        return result
    }

    private static func rejectSymlinkAncestors(_ url: URL, root: URL) throws {
        var current = url.deletingLastPathComponent()
        let root = root.standardizedFileURL
        while current.standardizedFileURL.path.hasPrefix(root.path) {
            if (try? current.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                throw DebEditableWorkspaceError.invalidPath(url.path)
            }
            if current.standardizedFileURL == root { return }
            let parent = current.deletingLastPathComponent()
            guard parent != current else { break }
            current = parent
        }
        throw DebEditableWorkspaceError.invalidPath(url.path)
    }

    private static func relativePath(_ url: URL, under root: URL) -> String? {
        let rootPath = root.standardizedFileURL.path + "/"
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(rootPath) else { return nil }
        return String(path.dropFirst(rootPath.count))
    }

    private static func fileMode(_ url: URL) throws -> UInt16 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return UInt16(
            truncating: attributes[.posixPermissions] as? NSNumber ?? NSNumber(value: 0)
        )
    }
}
