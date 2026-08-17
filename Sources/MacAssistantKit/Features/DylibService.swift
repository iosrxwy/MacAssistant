import CryptoKit
import Foundation

/// 一条 dylib 依赖记录。
public struct DylibDependency: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public let path: String
    public let compatibilityVersion: String?
    public let currentVersion: String?

    public init(
        id: UUID = UUID(),
        path: String,
        compatibilityVersion: String?,
        currentVersion: String?
    ) {
        self.id = id
        self.path = path
        self.compatibilityVersion = compatibilityVersion
        self.currentVersion = currentVersion
    }
}

public enum DylibSignatureState: String, Codable, Hashable, Sendable {
    case valid
    case invalid
    case unsigned
    case unavailable
}

public struct DylibAnalysisSnapshot: Codable, Hashable, Sendable {
    public let fileURL: URL
    public let fileSize: Int64
    public let sha256: String
    public let architectures: [String]
    public let uuids: [String]
    public let installName: String?
    public let dependencies: [DylibDependency]
    public let rpaths: [String]
    public let minimumOSVersions: [String]
    public let signature: DylibSignatureState
    public let isFat: Bool
    public let isEncrypted: Bool
    public let hasChainedFixups: Bool
    public let hasSwift: Bool
    public let isArm64e: Bool
}

/// dylib 相关操作:依赖查看、install name / rpath 修改、从 app/deb 提取。
public enum DylibService {

    public static func analyze(fileAt url: URL) throws -> DylibAnalysisSnapshot {
        guard MachOIdentifier.isMachO(fileAt: url) else { throw DylibError.notMachO(url.path) }
        let facts = MachOInspector.facts(fileAt: url)
        let architectures = facts?.archs.isEmpty == false
            ? facts?.archs ?? []
            : ((try? BinaryService.architectures(fileAt: url)) ?? [])
        let loadCommands = ExternalTool.otool.isAvailable
            ? (try? ExternalTool.otool.run(["-l", url.path]).stdout) ?? ""
            : ""
        let metadata = parseLoadCommandMetadata(loadCommands)
        var allDependencies = ExternalTool.otool.isAvailable
            ? (try? dependencies(fileAt: url)) ?? []
            : []
        if allDependencies.isEmpty,
           let native = try? DylibInjector.inspectLoadCommands(fileAt: url) {
            var seen = Set<String>()
            allDependencies = native.flatMap(\.commands).compactMap {
                guard seen.insert($0.path).inserted else { return nil }
                return DylibDependency(
                    path: $0.path,
                    compatibilityVersion: nil,
                    currentVersion: nil
                )
            }
        }
        let dependencies = allDependencies.filter { $0.path != metadata.installName }
        let signature = signatureState(fileAt: url)
        return DylibAnalysisSnapshot(
            fileURL: url,
            fileSize: FileSystemHelper.size(at: url),
            sha256: try sha256(fileAt: url),
            architectures: architectures,
            uuids: metadata.uuids,
            installName: metadata.installName,
            dependencies: dependencies,
            rpaths: metadata.rpaths,
            minimumOSVersions: metadata.minimumOSVersions,
            signature: signature,
            isFat: facts?.isFat ?? (architectures.count > 1),
            isEncrypted: facts?.isEncrypted ?? false,
            hasChainedFixups: facts?.hasChainedFixups ?? false,
            hasSwift: facts?.hasSwift ?? false,
            isArm64e: facts?.isArm64e ?? architectures.contains("arm64e")
        )
    }

    public static func sha256(fileAt url: URL) throws -> String {
        let digest = SHA256.hash(data: try Data(contentsOf: url, options: .mappedIfSafe))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func parseLoadCommandMetadata(
        _ text: String
    ) -> (installName: String?, uuids: [String], rpaths: [String], minimumOSVersions: [String]) {
        var installName: String?
        var uuids: [String] = []
        var rpaths: [String] = []
        var minimumOSVersions: [String] = []
        var currentCommand = ""
        for line in text.split(separator: "\n") {
            let value = line.trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("cmd ") {
                currentCommand = String(value.dropFirst(4))
                continue
            }
            if currentCommand == "LC_ID_DYLIB", value.hasPrefix("name ") {
                installName = loadCommandValue(value, prefix: "name ")
                currentCommand = ""
            } else if currentCommand == "LC_RPATH", value.hasPrefix("path ") {
                if let path = loadCommandValue(value, prefix: "path ") { rpaths.append(path) }
                currentCommand = ""
            } else if currentCommand == "LC_UUID", value.hasPrefix("uuid ") {
                let uuid = String(value.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                if !uuid.isEmpty { uuids.append(uuid) }
                currentCommand = ""
            } else if currentCommand == "LC_BUILD_VERSION", value.hasPrefix("minos ") {
                let version = String(value.dropFirst("minos ".count))
                    .trimmingCharacters(in: .whitespaces)
                if !version.isEmpty { minimumOSVersions.append(version) }
            } else if currentCommand.hasPrefix("LC_VERSION_MIN_"), value.hasPrefix("version ") {
                let version = String(value.dropFirst("version ".count))
                    .trimmingCharacters(in: .whitespaces)
                if !version.isEmpty { minimumOSVersions.append(version) }
            }
        }
        return (installName, uuids, rpaths, Array(Set(minimumOSVersions)).sorted())
    }

    private static func loadCommandValue(_ line: String, prefix: String) -> String? {
        var value = String(line.dropFirst(prefix.count))
        if let range = value.range(of: " (offset") {
            value = String(value[..<range.lowerBound])
        }
        let result = value.trimmingCharacters(in: .whitespaces)
        return result.isEmpty ? nil : result
    }

    private static func signatureState(fileAt url: URL) -> DylibSignatureState {
        guard ExternalTool.codesign.isAvailable else { return .unavailable }
        guard let result = try? BinaryService.codesignVerify(fileAt: url) else { return .unavailable }
        if result.succeeded { return .valid }
        let output = result.combinedOutput.lowercased()
        if output.contains("not signed") || output.contains("code object is not signed") {
            return .unsigned
        }
        return .invalid
    }

    // MARK: 依赖查看(otool -L)

    public static func dependencies(fileAt url: URL) throws -> [DylibDependency] {
        let result = try ExternalTool.otool.run(["-L", url.path])
        guard result.succeeded else { throw DylibError.commandFailed(result.combinedOutput) }
        return parseOtoolL(result.stdout)
    }

    static func parseOtoolL(_ text: String) -> [DylibDependency] {
        var deps: [DylibDependency] = []
        for line in text.split(separator: "\n").dropFirst() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            if let paren = trimmed.range(of: " (compatibility version ") {
                let path = String(trimmed[..<paren.lowerBound])
                let rest = String(trimmed[paren.upperBound...]).replacingOccurrences(of: ")", with: "")
                let parts = rest.components(separatedBy: ", current version ")
                deps.append(DylibDependency(path: path,
                                            compatibilityVersion: parts.first,
                                            currentVersion: parts.count > 1 ? parts[1] : nil))
            } else {
                deps.append(DylibDependency(path: trimmed, compatibilityVersion: nil, currentVersion: nil))
            }
        }
        return deps
    }

    // MARK: install_name_tool 操作

    @discardableResult
    public static func setInstallID(_ newID: String, fileAt url: URL) throws -> CommandResult {
        let result = try ExternalTool.installNameTool.run(["-id", newID, url.path])
        guard result.succeeded else { throw DylibError.commandFailed(result.combinedOutput) }
        guard try analyze(fileAt: url).installName == newID else {
            throw DylibError.noExpectedChange(L("dylib.error.installNameUnchanged", newID))
        }
        return result
    }

    @discardableResult
    public static func changeDependency(from old: String, to new: String, fileAt url: URL) throws -> CommandResult {
        let result = try ExternalTool.installNameTool.run(["-change", old, new, url.path])
        guard result.succeeded else { throw DylibError.commandFailed(result.combinedOutput) }
        let paths = try dependencies(fileAt: url).map(\.path)
        guard paths.contains(new), !paths.contains(old) else {
            throw DylibError.noExpectedChange(L("dylib.error.dependencyUnchanged", old, new))
        }
        return result
    }

    @discardableResult
    public static func addRPath(_ path: String, fileAt url: URL) throws -> CommandResult {
        let result = try ExternalTool.installNameTool.run(["-add_rpath", path, url.path])
        guard result.succeeded else { throw DylibError.commandFailed(result.combinedOutput) }
        guard try rpaths(fileAt: url).contains(path) else {
            throw DylibError.noExpectedChange(L("dylib.error.rpathNotAdded", path))
        }
        return result
    }

    @discardableResult
    public static func deleteRPath(_ path: String, fileAt url: URL) throws -> CommandResult {
        let result = try ExternalTool.installNameTool.run(["-delete_rpath", path, url.path])
        guard result.succeeded else { throw DylibError.commandFailed(result.combinedOutput) }
        guard !(try rpaths(fileAt: url).contains(path)) else {
            throw DylibError.noExpectedChange(L("dylib.error.rpathNotDeleted", path))
        }
        return result
    }

    // MARK: LC_RPATH 查看

    public static func rpaths(fileAt url: URL) throws -> [String] {
        let result = try ExternalTool.otool.run(["-l", url.path])
        guard result.succeeded else { throw DylibError.commandFailed(result.combinedOutput) }
        return parseLoadCommandMetadata(result.stdout).rpaths
    }

    static func parseRPaths(_ text: String) -> [String] {
        var result: [String] = []
        var inRpath = false
        for line in text.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.contains("cmd LC_RPATH") { inRpath = true; continue }
            if inRpath, t.hasPrefix("path ") {
                var value = String(t.dropFirst("path ".count))
                if let r = value.range(of: " (offset") { value = String(value[..<r.lowerBound]) }
                result.append(value)
                inRpath = false
            } else if t.hasPrefix("cmd ") {
                inRpath = false
            }
        }
        return result
    }

    // MARK: 从 app / deb / 目录 提取 dylib、framework、bundle、资源包

    /// 从 .app 目录、.deb 包、任意目录或单个文件中提取所有 Mach-O(常用于抽取 dylib)。
    /// 完整包(framework / bundle / 资源目录)会整份拷出,不再拆成内部二进制。
    @discardableResult
    public static func extractMachOFiles(from source: URL, to destination: URL) throws -> [URL] {
        try extractPayloads(from: source, to: destination).items.map(\.outputURL)
    }

    /// 批量提取。每个来源写到自己旁边的 `*.extracted` 目录。
    /// 单个来源失败不会中断其余来源,失败写在对应结果的 `error` 里。
    @discardableResult
    public static func extractPayloads(from sources: [URL]) -> [PayloadExtractionResult] {
        sources.map { source in
            let proposed = source.deletingPathExtension().appendingPathExtension("extracted")
            let dest = FileSystemHelper.uniqueOutputURL(basedOn: proposed)
            do {
                return try extractPayloads(from: source, to: dest)
            } catch {
                try? FileManager.default.removeItem(at: dest)
                return PayloadExtractionResult(
                    source: source,
                    destination: dest,
                    items: [],
                    error: error.localizedDescription
                )
            }
        }
    }

    /// 从单个 .app / .ipa / .deb / 目录 / Mach-O 提取 dylib、framework、bundle 和资源包。
    @discardableResult
    public static func extractPayloads(from source: URL, to destination: URL) throws -> PayloadExtractionResult {
        let existed = FileManager.default.fileExists(atPath: destination.path)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        do {
            let items = try collectAndCopyPayloads(from: source, to: destination)
            if items.isEmpty, !existed {
                try? FileManager.default.removeItem(at: destination)
            }
            return PayloadExtractionResult(source: source, destination: destination, items: items)
        } catch {
            if !existed { try? FileManager.default.removeItem(at: destination) }
            throw error
        }
    }

    private static func collectAndCopyPayloads(from source: URL, to destination: URL) throws -> [ExtractedPayload] {
        let ext = source.pathExtension.lowercased()
        if ext == "deb" {
            let unpacked = try FileSystemHelper.makeTemporaryDirectory(prefix: "deb-payload")
            defer { try? FileManager.default.removeItem(at: unpacked) }
            try DebService.extract(debAt: source, to: unpacked, dataOnly: true)
            return try copyPayloads(from: unpacked, to: destination)
        }
        if ext == "ipa" {
            let unpacked = try FileSystemHelper.makeTemporaryDirectory(prefix: "ipa-payload")
            defer { try? FileManager.default.removeItem(at: unpacked) }
            try IpaService.unzip(source, to: unpacked)
            return try copyPayloads(from: unpacked, to: destination)
        }
        if FileSystemHelper.isDirectory(source) {
            return try copyPayloads(from: source, to: destination)
        }
        if MachOIdentifier.isMachO(fileAt: source) {
            let kind: ExtractedPayloadKind =
                ext == "dylib" || MachOIdentifier.isDylib(fileAt: source) ? .dylib : .machO
            return [try copyPayload(source, kind: kind, relativePath: source.lastPathComponent, to: destination)]
        }
        return []
    }

    private static func copyPayloads(from root: URL, to destination: URL) throws -> [ExtractedPayload] {
        // 来源本身就是 framework / bundle / 资源包时,整份拷走,不要拆内部文件。
        // .app 当作容器往里找,不把整个 App 再拷一份。
        if root.pathExtension.lowercased() != "app", let kind = packageKind(of: root) {
            return [try copyPayload(root, kind: kind, relativePath: root.lastPathComponent, to: destination)]
        }

        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var collected: [(url: URL, kind: ExtractedPayloadKind, relativePath: String)] = []
        var consumed: [String] = []
        for case let url as URL in enumerator {
            let isDirectory = FileSystemHelper.isDirectory(url)
            if isDirectory, url.lastPathComponent == "DEBIAN" {
                enumerator.skipDescendants()
                continue
            }
            if isDirectory, let kind = packageKind(of: url) {
                collected.append((url, kind, relativePath(of: url, under: root)))
                consumed.append(normalizedPath(url))
                enumerator.skipDescendants()
                continue
            }
            guard !isDirectory else { continue }
            if url.pathExtension.lowercased() == "dylib" || MachOIdentifier.isMachO(fileAt: url) {
                let kind: ExtractedPayloadKind =
                    url.pathExtension.lowercased() == "dylib" || MachOIdentifier.isDylib(fileAt: url)
                    ? .dylib : .machO
                collected.append((url, kind, relativePath(of: url, under: root)))
                consumed.append(normalizedPath(url))
            }
        }

        for directory in resourcePackageDirectories(in: root, consumed: consumed) {
            collected.append((directory, .resourcePackage, relativePath(of: directory, under: root)))
            consumed.append(normalizedPath(directory))
        }

        var extras: [(url: URL, kind: ExtractedPayloadKind, relativePath: String)] = []
        var seen = Set(collected.map { normalizedPath($0.url) })
        for item in collected where item.kind == .dylib || item.kind == .machO {
            let plist = item.url.deletingPathExtension().appendingPathExtension("plist")
            let path = normalizedPath(plist)
            guard fm.fileExists(atPath: plist.path),
                  !FileSystemHelper.isDirectory(plist),
                  seen.insert(path).inserted else { continue }
            extras.append((plist, .resource, relativePath(of: plist, under: root)))
        }

        let ordered = (collected + extras).sorted {
            if $0.kind.sortOrder != $1.kind.sortOrder { return $0.kind.sortOrder < $1.kind.sortOrder }
            return $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending
        }
        return try ordered.map {
            try copyPayload($0.url, kind: $0.kind, relativePath: $0.relativePath, to: destination)
        }
    }

    /// 只认扩展名包(framework / bundle / theme 等)和 PreferenceLoader。
    /// Application Support / Themes 下的资源目录走第二遍,避免包名目录把里面的 .bundle 一起吞掉。
    private static func packageKind(of url: URL) -> ExtractedPayloadKind? {
        guard FileSystemHelper.isDirectory(url) else { return nil }
        switch url.pathExtension.lowercased() {
        case "framework": return .framework
        case "bundle", "appex", "xpc": return .bundle
        case "theme": return .resourcePackage
        default: break
        }
        if url.lastPathComponent == "PreferenceLoader" { return .resourcePackage }
        return nil
    }

    private static func resourcePackageDirectories(in root: URL, consumed: [String]) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        let containerNames: Set<String> = ["Application Support", "Resources", "Library", "Themes"]
        var result: [URL] = []
        for case let url as URL in enumerator {
            guard FileSystemHelper.isDirectory(url) else { continue }
            let path = normalizedPath(url)
            if consumed.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) {
                enumerator.skipDescendants()
                continue
            }
            if containerNames.contains(url.lastPathComponent) { continue }
            guard isResourceSearchRoot(url) else { continue }
            if consumed.contains(where: { $0.hasPrefix(path + "/") }) { continue }
            result.append(url)
            enumerator.skipDescendants()
        }
        return result
    }

    private static func isResourceSearchRoot(_ url: URL) -> Bool {
        isUnderNamedContainer(url, "Application Support") || isUnderNamedContainer(url, "Themes")
    }

    private static func isUnderNamedContainer(_ url: URL, _ name: String) -> Bool {
        url.pathComponents.contains(name) && url.lastPathComponent != name
    }

    private static func normalizedPath(_ url: URL) -> String {
        url.standardizedFileURL.path.precomposedStringWithCanonicalMapping
    }

    private static func copyPayload(
        _ source: URL,
        kind: ExtractedPayloadKind,
        relativePath: String,
        to destination: URL
    ) throws -> ExtractedPayload {
        let dest = uniqueDestination(for: source, in: destination)
        try FileManager.default.copyItem(at: source, to: dest)
        return ExtractedPayload(kind: kind, sourceRelativePath: relativePath, outputURL: dest)
    }

    private static func relativePath(of url: URL, under root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        if path == rootPath { return url.lastPathComponent }
        if path.hasPrefix(rootPath + "/") {
            return String(path.dropFirst(rootPath.count + 1))
        }
        return url.lastPathComponent
    }

    private static func uniqueDestination(for file: URL, in directory: URL) -> URL {
        let base = directory.appendingPathComponent(file.lastPathComponent)
        if !FileManager.default.fileExists(atPath: base.path) { return base }
        let name = file.deletingPathExtension().lastPathComponent
        let ext = file.pathExtension
        var index = 1
        while true {
            let candidate = directory.appendingPathComponent("\(name)-\(index)\(ext.isEmpty ? "" : ".\(ext)")")
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            index += 1
        }
    }
}

public enum ExtractedPayloadKind: String, Codable, Hashable, Sendable {
    case dylib
    case framework
    case bundle
    case resourcePackage
    case resource
    case machO

    fileprivate var sortOrder: Int {
        switch self {
        case .dylib: return 0
        case .framework: return 1
        case .bundle: return 2
        case .resourcePackage: return 3
        case .resource: return 4
        case .machO: return 5
        }
    }
}

public struct ExtractedPayload: Hashable, Sendable {
    public let kind: ExtractedPayloadKind
    public let sourceRelativePath: String
    public let outputURL: URL
}

public struct PayloadExtractionResult: Sendable {
    public let source: URL
    public let destination: URL
    public let items: [ExtractedPayload]
    public let error: String?

    public init(source: URL, destination: URL, items: [ExtractedPayload], error: String? = nil) {
        self.source = source
        self.destination = destination
        self.items = items
        self.error = error
    }
}

public enum DylibError: LocalizedError {
    case commandFailed(String)
    case notMachO(String)
    case noExpectedChange(String)

    public var errorDescription: String? {
        switch self {
        case let .commandFailed(output): return L("dylib.error.commandFailed", output)
        case let .notMachO(path): return L("dylib.error.notMachO", path)
        case let .noExpectedChange(message): return L("dylib.error.noExpectedChange", message)
        }
    }
}
