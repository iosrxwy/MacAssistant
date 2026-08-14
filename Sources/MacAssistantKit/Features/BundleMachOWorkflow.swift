import Foundation

public enum BundleMachOTargetKind: String, Codable, CaseIterable, Hashable, Sendable {
    case standalone
    case mainExecutable
    case framework
    case dylib
    case appExtension
    case watchApp
    case appClip

    public var displayName: String {
        switch self {
        case .standalone: return L("machobundle.kind.standalone")
        case .mainExecutable: return L("machobundle.kind.mainExecutable")
        case .framework: return "Framework"
        case .dylib: return L("machobundle.kind.dylib")
        case .appExtension: return "App Extension"
        case .watchApp: return "Apple Watch App"
        case .appClip: return "App Clip"
        }
    }
}

public struct BundleMachOTarget: Identifiable, Hashable, Sendable {
    public let id: String
    public let kind: BundleMachOTargetKind
    public let name: String
    public let relativePath: String
    public let fileURL: URL
    public let architectures: [String]
    public let cryptid: Int
    public let signature: DylibSignatureState
    public let bundleID: String?
    public let extensionPointIdentifier: String?
    public let size: Int64
    public let restrictionNote: String?
    public let isRecommended: Bool

    public init(
        kind: BundleMachOTargetKind,
        name: String,
        relativePath: String,
        fileURL: URL,
        architectures: [String],
        cryptid: Int,
        signature: DylibSignatureState,
        bundleID: String? = nil,
        extensionPointIdentifier: String? = nil,
        size: Int64,
        restrictionNote: String? = nil,
        isRecommended: Bool = false
    ) {
        self.id = "\(kind.rawValue):\(relativePath.precomposedStringWithCanonicalMapping.lowercased())"
        self.kind = kind
        self.name = name
        self.relativePath = relativePath
        self.fileURL = fileURL
        self.architectures = architectures
        self.cryptid = cryptid
        self.signature = signature
        self.bundleID = bundleID
        self.extensionPointIdentifier = extensionPointIdentifier
        self.size = size
        self.restrictionNote = restrictionNote
        self.isRecommended = isRecommended
    }
}

public enum EmbeddedComponentKind: String, Codable, CaseIterable, Hashable, Sendable {
    case watch
    case appExtension
    case appClip
}

public struct EmbeddedComponent: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let kind: EmbeddedComponentKind
    public let name: String
    public let relativePath: String
    public let bundleID: String?
    public let size: Int64

    public init(
        kind: EmbeddedComponentKind,
        name: String,
        relativePath: String,
        bundleID: String?,
        size: Int64
    ) {
        self.id = "\(kind.rawValue):\(relativePath.precomposedStringWithCanonicalMapping.lowercased())"
        self.kind = kind
        self.name = name
        self.relativePath = relativePath
        self.bundleID = bundleID
        self.size = size
    }
}

public final class InjectionTargetSession: @unchecked Sendable {
    public let input: InjectionInput
    public let appURL: URL
    public let targets: [BundleMachOTarget]
    public let components: [EmbeddedComponent]
    private let ownedTemporaryRoot: URL?

    init(
        input: InjectionInput,
        appURL: URL,
        targets: [BundleMachOTarget],
        components: [EmbeddedComponent],
        ownedTemporaryRoot: URL?
    ) {
        self.input = input
        self.appURL = appURL
        self.targets = targets
        self.components = components
        self.ownedTemporaryRoot = ownedTemporaryRoot
    }

    deinit {
        if let ownedTemporaryRoot {
            try? FileManager.default.removeItem(at: ownedTemporaryRoot)
        }
    }
}

public enum InjectionTargetDiscovery {
    public static func open(_ input: InjectionInput) throws -> InjectionTargetSession {
        switch input {
        case let .ipa(ipa):
            let root = try FileSystemHelper.makeTemporaryDirectory(prefix: "ipa-targets")
            do {
                let extraction = root.appendingPathComponent("extract", isDirectory: true)
                try IpaService.unzip(ipa, to: extraction)
                try IpaService.validatePayloadStructure(in: extraction)
                let app = try IpaService.locateApp(in: extraction)
                let inspection = try AppBundleMachOScanner.inspect(app)
                return InjectionTargetSession(
                    input: input,
                    appURL: app,
                    targets: inspection.targets,
                    components: inspection.components,
                    ownedTemporaryRoot: root
                )
            } catch {
                try? FileManager.default.removeItem(at: root)
                throw error
            }
        case let .app(app):
            let inspection = try AppBundleMachOScanner.inspect(app)
            return InjectionTargetSession(
                input: input,
                appURL: app,
                targets: inspection.targets,
                components: inspection.components,
                ownedTemporaryRoot: nil
            )
        }
    }

    public static func components(in app: URL) throws -> [EmbeddedComponent] {
        try AppBundleMachOScanner.inspect(app).components
    }

    /// 把 App 内嵌的 Watch / App Extension / App Clip 原样提取到新目录。
    @discardableResult
    public static func extractComponents(from input: InjectionInput, to parent: URL) throws -> [URL] {
        let work = try FileSystemHelper.makeTemporaryDirectory(prefix: "ipa-components")
        defer { try? FileManager.default.removeItem(at: work) }

        let app: URL
        switch input {
        case let .ipa(url):
            let extraction = work.appendingPathComponent("extract", isDirectory: true)
            try IpaService.unzip(url, to: extraction)
            try IpaService.validatePayloadStructure(in: extraction)
            app = try IpaService.locateApp(in: extraction)
        case let .app(url):
            app = url
        }

        let components = try AppBundleMachOScanner.inspect(app).components
        let stem = input.url.deletingPathExtension().lastPathComponent
        let outputRoot = FileSystemHelper.uniqueOutputURL(
            basedOn: parent.appendingPathComponent("\(stem)-components", isDirectory: true)
        )
        try FileManager.default.createDirectory(
            at: outputRoot,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        do {
            for component in components {
                let relative = try ValidatedRelativePath(component.relativePath)
                let source = app.appendingPathComponent(relative.rawValue)
                let destination = outputRoot.appendingPathComponent(relative.rawValue)
                guard FileManager.default.fileExists(atPath: source.path) else {
                    throw BinaryWorkflowError.targetNotFound(component.relativePath)
                }
                try FileManager.default.createDirectory(
                    at: destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try FileManager.default.copyItem(at: source, to: destination)
            }
            return components.map { outputRoot.appendingPathComponent($0.relativePath) }
        } catch {
            try? FileManager.default.removeItem(at: outputRoot)
            throw error
        }
    }
}

private struct AppBundleInspection {
    let targets: [BundleMachOTarget]
    let components: [EmbeddedComponent]
}

private enum AppBundleMachOScanner {
    static func inspect(_ app: URL) throws -> AppBundleInspection {
        try validateAppDirectory(app)
        var targets: [BundleMachOTarget] = []
        var seenPaths = Set<String>()

        func append(
            _ file: URL,
            kind: BundleMachOTargetKind,
            bundle: URL?,
            restriction: String? = nil,
            recommended: Bool = false
        ) {
            let standardized = file.standardizedFileURL.path
            guard seenPaths.insert(standardized).inserted,
                  MachOIdentifier.isMachO(fileAt: file)
            else { return }
            let relative = relativePath(file, under: app) ?? file.lastPathComponent
            let plist = bundle.flatMap { try? IpaService.infoPlist(appBundle: $0) } ?? [:]
            let extensionPoint = (plist["NSExtension"] as? [String: Any])?["NSExtensionPointIdentifier"] as? String
            let facts = MachOInspector.facts(fileAt: file)
            targets.append(BundleMachOTarget(
                kind: kind,
                name: displayName(bundle: bundle, file: file, plist: plist),
                relativePath: relative,
                fileURL: file,
                architectures: facts?.archs ?? [],
                cryptid: facts?.isEncrypted == true ? 1 : 0,
                signature: signatureState(file),
                bundleID: plist["CFBundleIdentifier"] as? String,
                extensionPointIdentifier: extensionPoint,
                size: FileSystemHelper.size(at: file),
                restrictionNote: restriction,
                isRecommended: recommended
            ))
        }

        let rootPlist = try IpaService.infoPlist(appBundle: app)
        if let executableName = nonEmptyString(rootPlist["CFBundleExecutable"]) {
            append(
                app.appendingPathComponent(executableName),
                kind: .mainExecutable,
                bundle: app,
                recommended: true
            )
        }

        let frameworks = app.appendingPathComponent("Frameworks", isDirectory: true)
        for item in directoryContents(frameworks) {
            if item.pathExtension.lowercased() == "framework", FileSystemHelper.isDirectory(item) {
                let plist = (try? IpaService.infoPlist(appBundle: item)) ?? [:]
                let fallback = item.deletingPathExtension().lastPathComponent
                let executableName = nonEmptyString(plist["CFBundleExecutable"]) ?? fallback
                append(item.appendingPathComponent(executableName), kind: .framework, bundle: item)
            } else if item.pathExtension.lowercased() == "dylib" {
                append(item, kind: .dylib, bundle: nil)
            }
        }

        let plugins = app.appendingPathComponent("PlugIns", isDirectory: true)
        for appex in directoryContents(plugins)
        where appex.pathExtension.lowercased() == "appex" && FileSystemHelper.isDirectory(appex) {
            guard let executableName = executableName(of: appex) else { continue }
            append(appex.appendingPathComponent(executableName), kind: .appExtension, bundle: appex)
        }

        let restricted = L("machobundle.target.restrictedNote")
        let watch = app.appendingPathComponent("Watch", isDirectory: true)
        for watchApp in directoryContents(watch)
        where watchApp.pathExtension.lowercased() == "app" && FileSystemHelper.isDirectory(watchApp) {
            guard let executableName = executableName(of: watchApp) else { continue }
            append(
                watchApp.appendingPathComponent(executableName),
                kind: .watchApp,
                bundle: watchApp,
                restriction: restricted
            )
        }

        let appClips = app.appendingPathComponent("AppClips", isDirectory: true)
        for clip in directoryContents(appClips)
        where clip.pathExtension.lowercased() == "app" && FileSystemHelper.isDirectory(clip) {
            guard let executableName = executableName(of: clip) else { continue }
            append(
                clip.appendingPathComponent(executableName),
                kind: .appClip,
                bundle: clip,
                restriction: restricted
            )
        }

        targets.sort {
            let left = sortRank($0.kind)
            let right = sortRank($1.kind)
            return left == right ? $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending : left < right
        }
        return AppBundleInspection(targets: targets, components: discoverComponents(in: app))
    }

    private static func discoverComponents(in app: URL) -> [EmbeddedComponent] {
        var result: [EmbeddedComponent] = []
        let groups: [(EmbeddedComponentKind, String, String)] = [
            (.watch, "Watch", "app"),
            (.appExtension, "PlugIns", "appex"),
            (.appClip, "AppClips", "app")
        ]
        for (kind, directory, requiredExtension) in groups {
            let root = app.appendingPathComponent(directory, isDirectory: true)
            for bundle in directoryContents(root)
            where bundle.pathExtension.lowercased() == requiredExtension && FileSystemHelper.isDirectory(bundle) {
                let plist = (try? IpaService.infoPlist(appBundle: bundle)) ?? [:]
                result.append(EmbeddedComponent(
                    kind: kind,
                    name: nonEmptyString(plist["CFBundleDisplayName"])
                        ?? nonEmptyString(plist["CFBundleName"])
                        ?? bundle.deletingPathExtension().lastPathComponent,
                    relativePath: relativePath(bundle, under: app) ?? bundle.lastPathComponent,
                    bundleID: nonEmptyString(plist["CFBundleIdentifier"]),
                    size: FileSystemHelper.size(at: bundle)
                ))
            }
        }
        let watchPlaceholder = app.appendingPathComponent("WatchPlaceholder")
        if FileManager.default.fileExists(atPath: watchPlaceholder.path) {
            result.append(EmbeddedComponent(
                kind: .watch,
                name: "WatchPlaceholder",
                relativePath: "WatchPlaceholder",
                bundleID: nil,
                size: FileSystemHelper.size(at: watchPlaceholder)
            ))
        }
        return result.sorted { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending }
    }

    private static func validateAppDirectory(_ app: URL) throws {
        guard app.pathExtension.lowercased() == "app", FileSystemHelper.isDirectory(app) else {
            throw IpaError.appNotFound
        }
        let root = app.standardizedFileURL.path + "/"
        var count = 0
        var total: UInt64 = 0
        for file in FileSystemHelper.allFiles(in: app, where: { _ in true }) {
            count += 1
            guard count <= ArchiveLimits.default.maxEntries else {
                throw ArchiveSafetyError.entryLimit(count)
            }
            guard file.standardizedFileURL.path.hasPrefix(root) else {
                throw ArchiveSafetyError.unsafePath(file.path)
            }
            let values = try file.resourceValues(forKeys: [.isSymbolicLinkKey, .fileSizeKey, .isRegularFileKey])
            if values.isSymbolicLink == true { throw ArchiveSafetyError.symbolicLink(file.path) }
            if values.isRegularFile == true {
                let size = UInt64(max(0, values.fileSize ?? 0))
                guard size <= ArchiveLimits.default.maxSingleFileBytes else {
                    throw ArchiveSafetyError.singleFileLimit(path: file.path, size: size)
                }
                total += size
                guard total <= ArchiveLimits.default.maxTotalBytes else {
                    throw ArchiveSafetyError.totalSizeLimit(total)
                }
            }
        }
    }

    private static func executableName(of bundle: URL) -> String? {
        guard let plist = try? IpaService.infoPlist(appBundle: bundle) else { return nil }
        return nonEmptyString(plist["CFBundleExecutable"])
    }

    private static func displayName(bundle: URL?, file: URL, plist: [String: Any]) -> String {
        nonEmptyString(plist["CFBundleDisplayName"])
            ?? nonEmptyString(plist["CFBundleName"])
            ?? bundle?.deletingPathExtension().lastPathComponent
            ?? file.lastPathComponent
    }

    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func directoryContents(_ directory: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
    }

    private static func relativePath(_ url: URL, under root: URL) -> String? {
        let rootPath = root.standardizedFileURL.path + "/"
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(rootPath) else { return nil }
        return String(path.dropFirst(rootPath.count))
    }

    private static func signatureState(_ url: URL) -> DylibSignatureState {
        guard ExternalTool.codesign.isAvailable,
              let result = try? BinaryService.codesignVerify(fileAt: url)
        else { return .unavailable }
        if result.succeeded { return .valid }
        let output = result.combinedOutput.lowercased()
        return output.contains("not signed") || output.contains("code object is not signed")
            ? .unsigned
            : .invalid
    }

    private static func sortRank(_ kind: BundleMachOTargetKind) -> Int {
        switch kind {
        case .mainExecutable: return 0
        case .framework: return 1
        case .dylib: return 2
        case .appExtension: return 3
        case .watchApp: return 4
        case .appClip: return 5
        case .standalone: return 6
        }
    }
}

public enum BinaryInputKind: String, Codable, Hashable, Sendable {
    case machO
    case app
    case ipa
}

public struct BinaryTargetAnalysis: Sendable {
    public let target: BundleMachOTarget
    public let fileType: String
    public let machHeader: String
    public let linkedLibraries: String
    public let signatureInfo: String
}

public struct BinaryExtractionManifestEntry: Codable, Hashable, Sendable {
    public let targetID: String
    public let kind: BundleMachOTargetKind
    public let relativePath: String
    public let exportedRelativePath: String
    public let architectures: [String]
    public let cryptid: Int
    public let size: Int64
    public let sha256: String
}

public struct BinaryExtractionResult: Sendable {
    public let directoryURL: URL
    public let manifestURL: URL
    public let entries: [BinaryExtractionManifestEntry]
}

public enum BinaryWorkflowError: LocalizedError {
    case unsupportedInput(String)
    case targetNotFound(String)
    case outputExists(String)
    case hashMismatch(String)

    public var errorDescription: String? {
        switch self {
        case let .unsupportedInput(path):
            return L("machobundle.error.unsupportedInput", path)
        case let .targetNotFound(id): return L("machobundle.error.targetNotFound", id)
        case let .outputExists(path): return L("machobundle.error.outputExists", path)
        case let .hashMismatch(path): return L("machobundle.error.hashMismatch", path)
        }
    }
}

public final class BinaryAnalysisSession: @unchecked Sendable {
    public let sourceURL: URL
    public let inputKind: BinaryInputKind
    public let targets: [BundleMachOTarget]
    public private(set) var selectedTargetID: String?
    private let discoverySession: InjectionTargetSession?
    private let ownsSecurityScopedAccess: Bool

    public var selectedTarget: BundleMachOTarget? {
        guard let selectedTargetID else { return nil }
        return targets.first { $0.id == selectedTargetID }
    }

    private init(
        sourceURL: URL,
        inputKind: BinaryInputKind,
        targets: [BundleMachOTarget],
        discoverySession: InjectionTargetSession?,
        ownsSecurityScopedAccess: Bool
    ) {
        self.sourceURL = sourceURL
        self.inputKind = inputKind
        self.targets = targets
        self.discoverySession = discoverySession
        self.ownsSecurityScopedAccess = ownsSecurityScopedAccess
        self.selectedTargetID = targets.first(where: \.isRecommended)?.id ?? targets.first?.id
    }

    public static func open(_ url: URL) throws -> BinaryAnalysisSession {
        let accessed = url.startAccessingSecurityScopedResource()
        var transfersAccess = false
        defer {
            if accessed && !transfersAccess { url.stopAccessingSecurityScopedResource() }
        }
        let ext = url.pathExtension.lowercased()
        if ext == "ipa" {
            let discovery = try InjectionTargetDiscovery.open(.ipa(url))
            return BinaryAnalysisSession(
                sourceURL: url,
                inputKind: .ipa,
                targets: discovery.targets,
                discoverySession: discovery,
                ownsSecurityScopedAccess: false
            )
        }
        if ext == "app", FileSystemHelper.isDirectory(url) {
            let discovery = try InjectionTargetDiscovery.open(.app(url))
            transfersAccess = accessed
            return BinaryAnalysisSession(
                sourceURL: url,
                inputKind: .app,
                targets: discovery.targets,
                discoverySession: discovery,
                ownsSecurityScopedAccess: accessed
            )
        }
        guard MachOIdentifier.isMachO(fileAt: url),
              let facts = MachOInspector.facts(fileAt: url)
        else {
            throw BinaryWorkflowError.unsupportedInput(url.path)
        }
        transfersAccess = accessed
        let target = BundleMachOTarget(
            kind: .standalone,
            name: url.lastPathComponent,
            relativePath: url.lastPathComponent,
            fileURL: url,
            architectures: facts.archs,
            cryptid: facts.isEncrypted ? 1 : 0,
            signature: .unavailable,
            size: FileSystemHelper.size(at: url),
            isRecommended: true
        )
        return BinaryAnalysisSession(
            sourceURL: url,
            inputKind: .machO,
            targets: [target],
            discoverySession: nil,
            ownsSecurityScopedAccess: accessed
        )
    }

    deinit {
        if ownsSecurityScopedAccess {
            sourceURL.stopAccessingSecurityScopedResource()
        }
    }

    public func select(targetID: String) throws {
        guard targets.contains(where: { $0.id == targetID }) else {
            throw BinaryWorkflowError.targetNotFound(targetID)
        }
        selectedTargetID = targetID
    }

    public func analysis(targetID: String) throws -> BinaryTargetAnalysis {
        let target = try requireTarget(targetID)
        guard MachOIdentifier.isMachO(fileAt: target.fileURL) else {
            throw BinaryWorkflowError.unsupportedInput(target.fileURL.path)
        }
        return BinaryTargetAnalysis(
            target: target,
            fileType: try BinaryService.fileType(fileAt: target.fileURL),
            machHeader: try BinaryService.machHeader(fileAt: target.fileURL),
            linkedLibraries: (try? ExternalTool.otool.run(["-L", target.fileURL.path]).combinedOutput) ?? "",
            signatureInfo: (try? BinaryService.codesignInfo(fileAt: target.fileURL))
                ?? L("machobundle.analysis.noSignatureInfo")
        )
    }

    @discardableResult
    public func extractSelected(targetID: String, to output: URL) throws -> URL {
        let target = try requireTarget(targetID)
        guard !FileManager.default.fileExists(atPath: output.path) else {
            throw BinaryWorkflowError.outputExists(output.path)
        }
        try FileManager.default.createDirectory(
            at: output.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.copyItem(at: target.fileURL, to: output)
        guard try DylibService.sha256(fileAt: target.fileURL) == DylibService.sha256(fileAt: output) else {
            try? FileManager.default.removeItem(at: output)
            throw BinaryWorkflowError.hashMismatch(output.path)
        }
        return output
    }

    public func extractAll(to parent: URL, flatten: Bool) throws -> BinaryExtractionResult {
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let stem = sourceURL.deletingPathExtension().lastPathComponent
        let proposed = parent.appendingPathComponent("\(stem)-MachO", isDirectory: true)
        let outputRoot = FileSystemHelper.uniqueOutputURL(basedOn: proposed)
        try FileManager.default.createDirectory(
            at: outputRoot,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        do {
            var entries: [BinaryExtractionManifestEntry] = []
            for target in targets {
                let relativeOutput: String
                let output: URL
                if flatten {
                    output = FileSystemHelper.uniqueOutputURL(
                        basedOn: outputRoot.appendingPathComponent(target.fileURL.lastPathComponent)
                    )
                    relativeOutput = output.lastPathComponent
                } else {
                    relativeOutput = target.relativePath
                    output = outputRoot.appendingPathComponent(relativeOutput)
                }
                try FileManager.default.createDirectory(
                    at: output.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                guard !FileManager.default.fileExists(atPath: output.path) else {
                    throw BinaryWorkflowError.outputExists(output.path)
                }
                try FileManager.default.copyItem(at: target.fileURL, to: output)
                let sourceHash = try DylibService.sha256(fileAt: target.fileURL)
                guard sourceHash == (try DylibService.sha256(fileAt: output)) else {
                    throw BinaryWorkflowError.hashMismatch(output.path)
                }
                entries.append(BinaryExtractionManifestEntry(
                    targetID: target.id,
                    kind: target.kind,
                    relativePath: target.relativePath,
                    exportedRelativePath: relativeOutput,
                    architectures: target.architectures,
                    cryptid: target.cryptid,
                    size: target.size,
                    sha256: sourceHash
                ))
            }
            let manifest = outputRoot.appendingPathComponent("manifest.json")
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try encoder.encode(entries).write(to: manifest, options: .atomic)
            return BinaryExtractionResult(directoryURL: outputRoot, manifestURL: manifest, entries: entries)
        } catch {
            try? FileManager.default.removeItem(at: outputRoot)
            throw error
        }
    }

    private func requireTarget(_ id: String) throws -> BundleMachOTarget {
        guard let target = targets.first(where: { $0.id == id }) else {
            throw BinaryWorkflowError.targetNotFound(id)
        }
        return target
    }
}
