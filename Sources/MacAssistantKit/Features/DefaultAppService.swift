#if canImport(AppKit)
import AppKit
#endif
import CoreServices
import Foundation
import UniformTypeIdentifiers

// MARK: - 扩展名与类型范围

public enum DefaultAppPresetGroup: String, CaseIterable, Sendable {
    case image
    case document
    case design
    case archive
    case media
}

public struct DefaultAppPreset: Equatable, Sendable, Identifiable {
    public var id: String { fileExtension }
    public let fileExtension: String
    public let group: DefaultAppPresetGroup

    public init(fileExtension: String, group: DefaultAppPresetGroup) {
        self.fileExtension = fileExtension
        self.group = group
    }
}

public enum DefaultAppCatalog {
    public static let presets: [DefaultAppPreset] = [
        DefaultAppPreset(fileExtension: "png", group: .image),
        DefaultAppPreset(fileExtension: "jpg", group: .image),
        DefaultAppPreset(fileExtension: "jpeg", group: .image),
        DefaultAppPreset(fileExtension: "gif", group: .image),
        DefaultAppPreset(fileExtension: "heic", group: .image),
        DefaultAppPreset(fileExtension: "webp", group: .image),
        DefaultAppPreset(fileExtension: "tif", group: .image),
        DefaultAppPreset(fileExtension: "tiff", group: .image),
        DefaultAppPreset(fileExtension: "bmp", group: .image),
        DefaultAppPreset(fileExtension: "ico", group: .image),
        DefaultAppPreset(fileExtension: "svg", group: .image),
        DefaultAppPreset(fileExtension: "pdf", group: .document),
        DefaultAppPreset(fileExtension: "txt", group: .document),
        DefaultAppPreset(fileExtension: "rtf", group: .document),
        DefaultAppPreset(fileExtension: "md", group: .document),
        DefaultAppPreset(fileExtension: "html", group: .document),
        DefaultAppPreset(fileExtension: "csv", group: .document),
        DefaultAppPreset(fileExtension: "json", group: .document),
        DefaultAppPreset(fileExtension: "doc", group: .document),
        DefaultAppPreset(fileExtension: "docx", group: .document),
        DefaultAppPreset(fileExtension: "xls", group: .document),
        DefaultAppPreset(fileExtension: "xlsx", group: .document),
        DefaultAppPreset(fileExtension: "ppt", group: .document),
        DefaultAppPreset(fileExtension: "pptx", group: .document),
        DefaultAppPreset(fileExtension: "ai", group: .design),
        DefaultAppPreset(fileExtension: "psd", group: .design),
        DefaultAppPreset(fileExtension: "eps", group: .design),
        DefaultAppPreset(fileExtension: "sketch", group: .design),
        DefaultAppPreset(fileExtension: "fig", group: .design),
        DefaultAppPreset(fileExtension: "zip", group: .archive),
        DefaultAppPreset(fileExtension: "gz", group: .archive),
        DefaultAppPreset(fileExtension: "7z", group: .archive),
        DefaultAppPreset(fileExtension: "dmg", group: .archive),
        DefaultAppPreset(fileExtension: "mp3", group: .media),
        DefaultAppPreset(fileExtension: "m4a", group: .media),
        DefaultAppPreset(fileExtension: "wav", group: .media),
        DefaultAppPreset(fileExtension: "mp4", group: .media),
        DefaultAppPreset(fileExtension: "mov", group: .media),
        DefaultAppPreset(fileExtension: "mkv", group: .media)
    ]
}

public enum DefaultAppExtensionRules {
    /// 只接受一个扩展名。`tar.gz` 这种复合后缀不收，避免把路径或通配符写进 Launch Services。
    public static func normalize(_ raw: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if text.hasPrefix(".") {
            text.removeFirst()
        }
        guard (1...32).contains(text.count) else { return nil }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "+-_"))
        guard text.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
        return text
    }
}

public enum DefaultAppTypeScope: Equatable, Sendable {
    case specific(String)
    case shared(String)
    case unsafe(String)
    case unknown

    public var contentTypeIdentifier: String? {
        switch self {
        case .specific(let identifier), .shared(let identifier), .unsafe(let identifier):
            return identifier
        case .unknown:
            return nil
        }
    }

    public var allowsChange: Bool {
        switch self {
        case .specific, .shared: return true
        case .unsafe, .unknown: return false
        }
    }

    public var needsSharedConfirmation: Bool {
        if case .shared = self { return true }
        return false
    }

    /// `public.png` 只影响 png。`public.plain-text` 会连带 txt 以外的纯文本。
    /// `public.data` 几乎是所有文件，直接拒绝。
    public static func classify(_ identifier: String?) -> DefaultAppTypeScope {
        guard let identifier, !identifier.isEmpty else { return .unknown }
        if identifier.hasPrefix("dyn.") { return .specific(identifier) }
        if unsafeIdentifiers.contains(identifier) { return .unsafe(identifier) }
        if sharedIdentifiers.contains(identifier) { return .shared(identifier) }
        return .specific(identifier)
    }

    private static let unsafeIdentifiers: Set<String> = [
        "public.data", "public.content", "public.item",
        "public.directory", "public.folder", "public.volume"
    ]

    private static let sharedIdentifiers: Set<String> = [
        "public.text", "public.plain-text", "public.utf8-plain-text", "public.utf16-plain-text",
        "public.image", "public.movie", "public.video", "public.audio", "public.archive",
        "public.composite-content", "public.source-code", "public.executable", "public.script"
    ]
}

// MARK: - 系统默认应用

public enum DefaultAppHandlerRank: String, Equatable, Sendable {
    case owner
    case `default`
    case alternate
    case none
    case unspecified
}

public struct DefaultAppTypeClaim: Equatable, Sendable {
    public let contentTypeIdentifier: String
    public let appleDefault: Bool
    public let rank: DefaultAppHandlerRank
    public let role: String?

    public init(
        contentTypeIdentifier: String,
        appleDefault: Bool,
        rank: DefaultAppHandlerRank,
        role: String?
    ) {
        self.contentTypeIdentifier = contentTypeIdentifier
        self.appleDefault = appleDefault
        self.rank = rank
        self.role = role
    }
}

public struct DefaultAppBundleInfo: Equatable, Sendable {
    public let url: URL
    public let bundleID: String?
    public let claims: [DefaultAppTypeClaim]

    public init(url: URL, bundleID: String?, claims: [DefaultAppTypeClaim]) {
        self.url = url
        self.bundleID = bundleID
        self.claims = claims
    }

    public var isAppleBundle: Bool {
        bundleID?.hasPrefix("com.apple.") == true
    }
}

public enum DefaultAppClaimReader {
    /// 从 Info.plist 读文档声明。系统应用经常不写 `LSHandlerRank`，
    /// 而用 `LSIsAppleDefaultForType` 标明自己才是这个类型的默认应用，例如预览对 png。
    public static func claims(from info: [String: Any]) -> [DefaultAppTypeClaim] {
        let documents = info["CFBundleDocumentTypes"] as? [[String: Any]] ?? []
        var claims: [DefaultAppTypeClaim] = []
        for document in documents {
            let types = document["LSItemContentTypes"] as? [String] ?? []
            let appleDefault = (document["LSIsAppleDefaultForType"] as? Bool) == true
            let rank = handlerRank(document["LSHandlerRank"] as? String)
            let role = document["CFBundleTypeRole"] as? String
            for type in types where !type.isEmpty {
                claims.append(
                    DefaultAppTypeClaim(
                        contentTypeIdentifier: type,
                        appleDefault: appleDefault,
                        rank: rank,
                        role: role
                    )
                )
            }
        }
        return claims
    }

    /// 恢复目标：先看 Apple 标成默认的应用，再看精确声明为 Owner / Default 的应用。
    /// 只匹配这个 UTI 本身，不用 `public.data` 这种父类型去兜底。
    public static func preferredDefault(
        identifier: String,
        among bundles: [DefaultAppBundleInfo]
    ) -> URL? {
        struct Candidate {
            let url: URL
            let bundleID: String
            let score: Int
            let apple: Bool
            let editor: Bool
        }

        func isBetter(_ candidate: Candidate, than current: Candidate) -> Bool {
            if candidate.score != current.score { return candidate.score > current.score }
            if candidate.apple != current.apple { return candidate.apple }
            if candidate.editor != current.editor { return candidate.editor }
            return candidate.bundleID < current.bundleID
        }

        var best: Candidate?
        for bundle in bundles {
            let matches = bundle.claims.filter { $0.contentTypeIdentifier == identifier }
            let bestScore = matches.map(score(of:)).max() ?? 0
            guard bestScore > 0 else { continue }
            let editor = matches.contains { score(of: $0) == bestScore && $0.role?.lowercased() == "editor" }
            let candidate = Candidate(
                url: bundle.url,
                bundleID: bundle.bundleID ?? bundle.url.path,
                score: bestScore,
                apple: bundle.isAppleBundle,
                editor: editor
            )
            if let current = best {
                if isBetter(candidate, than: current) { best = candidate }
            } else {
                best = candidate
            }
        }
        return best?.url
    }

    private static func handlerRank(_ raw: String?) -> DefaultAppHandlerRank {
        switch raw?.lowercased() {
        case "owner": return .owner
        case "default": return .default
        case "alternate": return .alternate
        case "none": return .none
        default: return .unspecified
        }
    }

    private static func score(of claim: DefaultAppTypeClaim) -> Int {
        if claim.appleDefault { return 3 }
        switch claim.rank {
        case .owner: return 2
        case .default: return 1
        case .alternate, .none, .unspecified: return 0
        }
    }
}

public enum DefaultAppBundleScanner {
    public static func read(at url: URL, fileManager: FileManager = .default) -> DefaultAppBundleInfo? {
        let infoURL = url.appendingPathComponent("Contents/Info.plist")
        guard fileManager.isReadableFile(atPath: infoURL.path),
              let data = try? Data(contentsOf: infoURL)
        else { return nil }
        var format = PropertyListSerialization.PropertyListFormat.xml
        guard let plist = try? PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: &format
        ) as? [String: Any] else { return nil }
        return DefaultAppBundleInfo(
            url: url.standardizedFileURL,
            bundleID: plist["CFBundleIdentifier"] as? String,
            claims: DefaultAppClaimReader.claims(from: plist)
        )
    }
}

// MARK: - 记录与错误

public struct DefaultAppOriginal: Codable, Equatable, Sendable {
    public let contentTypeIdentifier: String
    public let appPath: String?
    public let bundleID: String?
    public let capturedAt: Date

    public init(
        contentTypeIdentifier: String,
        appPath: String?,
        bundleID: String?,
        capturedAt: Date
    ) {
        self.contentTypeIdentifier = contentTypeIdentifier
        self.appPath = appPath
        self.bundleID = bundleID
        self.capturedAt = capturedAt
    }
}

public struct DefaultAppDiskState: Codable, Equatable, Sendable {
    public var originals: [String: DefaultAppOriginal]
    public var customExtensions: [String]

    public init(
        originals: [String: DefaultAppOriginal] = [:],
        customExtensions: [String] = []
    ) {
        self.originals = originals
        self.customExtensions = customExtensions
    }
}

public enum DefaultAppError: LocalizedError, Equatable {
    case invalidExtension
    case unknownType
    case unsafeType(String)
    case sharedType(String)
    case appMissing
    case notAnApp
    case nothingToRestore
    case originalMissing
    case historyUnreadable
    case applyFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidExtension: return L("defaultapp.error.invalidExtension")
        case .unknownType: return L("defaultapp.error.unknownType")
        case .unsafeType(let identifier): return L("defaultapp.error.unsafeType", identifier)
        case .sharedType(let identifier): return L("defaultapp.error.sharedType", identifier)
        case .appMissing: return L("defaultapp.error.appMissing")
        case .notAnApp: return L("defaultapp.error.notAnApp")
        case .nothingToRestore: return L("defaultapp.error.nothingToRestore")
        case .originalMissing: return L("defaultapp.error.originalMissing")
        case .historyUnreadable: return L("defaultapp.error.historyUnreadable")
        case .applyFailed(let message): return L("defaultapp.error.applyFailed", message)
        }
    }
}

public struct DefaultAppHistoryStore {
    public let fileURL: URL
    private let fileManager: FileManager

    public init(fileURL: URL, fileManager: FileManager = .default) {
        self.fileURL = fileURL
        self.fileManager = fileManager
    }

    public static func defaultFileURL(fileManager: FileManager = .default) -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("MacAssistant/default-open-apps.json")
    }

    public func load() throws -> DefaultAppDiskState {
        guard fileManager.fileExists(atPath: fileURL.path) else { return DefaultAppDiskState() }
        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(DefaultAppDiskState.self, from: data)
        } catch {
            throw DefaultAppError.historyUnreadable
        }
    }

    public func save(_ state: DefaultAppDiskState) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data: Data
        do {
            data = try encoder.encode(state)
        } catch {
            throw DefaultAppError.historyUnreadable
        }
        let directory = fileURL.deletingLastPathComponent()
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            throw DefaultAppError.historyUnreadable
        }
    }
}

// MARK: - Launch Services

public protocol DefaultAppLaunchServices {
    func contentTypeIdentifier(forExtension fileExtension: String) -> String?
    func defaultApplication(forContentType identifier: String) -> URL?
    func applications(forContentType identifier: String) -> [URL]
    func applicationURL(bundleIdentifier: String) -> URL?
    func setDefaultApplication(at app: URL, forContentType identifier: String) async throws
}

public protocol DefaultAppClaimSource {
    func bundles(forContentType identifier: String) -> [DefaultAppBundleInfo]
}

public enum DefaultAppMutationKind: Equatable, Sendable {
    case changed
    case unchanged
    case restored
}

public struct DefaultAppMutation: Equatable, Sendable {
    public let fileExtension: String
    public let appName: String
    public let kind: DefaultAppMutationKind
    public let contentTypeIdentifier: String

    public init(
        fileExtension: String,
        appName: String,
        kind: DefaultAppMutationKind,
        contentTypeIdentifier: String
    ) {
        self.fileExtension = fileExtension
        self.appName = appName
        self.kind = kind
        self.contentTypeIdentifier = contentTypeIdentifier
    }
}

public struct DefaultAppBulkRestore: Equatable, Sendable {
    public struct Failure: Equatable, Sendable {
        public let fileExtension: String
        public let message: String

        public init(fileExtension: String, message: String) {
            self.fileExtension = fileExtension
            self.message = message
        }
    }

    public let restoredExtensions: [String]
    public let failures: [Failure]

    public init(restoredExtensions: [String], failures: [Failure]) {
        self.restoredExtensions = restoredExtensions
        self.failures = failures
    }
}

public enum DefaultAppRestoreKind: Equatable, Sendable {
    case system
    case previous
    case none
}

public struct DefaultAppRowModel: Equatable, Sendable, Identifiable {
    public var id: String { fileExtension }
    public let fileExtension: String
    public let group: DefaultAppPresetGroup?
    public let isCustom: Bool
    public let contentTypeIdentifier: String?
    public let scope: DefaultAppTypeScope
    public let currentAppPath: String?
    public let currentAppName: String?
    public let restoreKind: DefaultAppRestoreKind
    public let restoreAppPath: String?
    public let restoreAppName: String?
    public let relatedExtensions: [String]
    public let canChange: Bool
    public let canRestore: Bool

    public init(
        fileExtension: String,
        group: DefaultAppPresetGroup?,
        isCustom: Bool,
        contentTypeIdentifier: String?,
        scope: DefaultAppTypeScope,
        currentAppPath: String?,
        currentAppName: String?,
        restoreKind: DefaultAppRestoreKind,
        restoreAppPath: String?,
        restoreAppName: String?,
        relatedExtensions: [String],
        canChange: Bool,
        canRestore: Bool
    ) {
        self.fileExtension = fileExtension
        self.group = group
        self.isCustom = isCustom
        self.contentTypeIdentifier = contentTypeIdentifier
        self.scope = scope
        self.currentAppPath = currentAppPath
        self.currentAppName = currentAppName
        self.restoreKind = restoreKind
        self.restoreAppPath = restoreAppPath
        self.restoreAppName = restoreAppName
        self.relatedExtensions = relatedExtensions
        self.canChange = canChange
        self.canRestore = canRestore
    }
}

public struct DefaultAppChoice: Equatable, Sendable, Identifiable {
    public var id: String { path }
    public let path: String
    public let name: String
    public let bundleID: String?
    public let isCurrent: Bool
    public let isSystemDefault: Bool

    public init(
        path: String,
        name: String,
        bundleID: String?,
        isCurrent: Bool,
        isSystemDefault: Bool
    ) {
        self.path = path
        self.name = name
        self.bundleID = bundleID
        self.isCurrent = isCurrent
        self.isSystemDefault = isSystemDefault
    }
}

public enum DefaultAppNaming {
    public static func displayName(of url: URL) -> String {
        let name = FileManager.default.displayName(atPath: url.path)
        if !name.isEmpty { return name }
        return url.deletingPathExtension().lastPathComponent
    }
}

#if canImport(AppKit)
public struct SystemDefaultAppLaunchServices: DefaultAppLaunchServices {
    public init() {}

    public func contentTypeIdentifier(forExtension fileExtension: String) -> String? {
        let ext = fileExtension.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !ext.isEmpty else { return nil }
        return UTType(filenameExtension: ext)?.identifier
    }

    public func defaultApplication(forContentType identifier: String) -> URL? {
        guard let type = UTType(identifier) else { return nil }
        return NSWorkspace.shared.urlForApplication(toOpen: type)
    }

    public func applications(forContentType identifier: String) -> [URL] {
        guard let type = UTType(identifier) else { return [] }
        return NSWorkspace.shared.urlsForApplications(toOpen: type)
    }

    public func applicationURL(bundleIdentifier: String) -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
    }

    public func setDefaultApplication(at app: URL, forContentType identifier: String) async throws {
        guard let type = UTType(identifier) else { throw DefaultAppError.unknownType }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            NSWorkspace.shared.setDefaultApplication(at: app, toOpen: type) { error in
                if error == nil {
                    continuation.resume()
                    return
                }
                // 有的应用能打开这种文件，但没有声明这个 UTI。系统接口会拒绝，
                // 再按 bundle ID 交给 Launch Services。同意框走上面的回调，这里不再卡住主线程。
                guard let bundleID = Bundle(url: app)?.bundleIdentifier else {
                    continuation.resume(throwing: error!)
                    return
                }
                let status = LSSetDefaultRoleHandlerForContentType(
                    identifier as CFString,
                    .all,
                    bundleID as CFString
                )
                if status == noErr {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: error!)
                }
            }
        }
    }
}

public final class SystemDefaultAppClaimSource: DefaultAppClaimSource {
    private let launchServices: DefaultAppLaunchServices
    private let lock = NSLock()
    private var cache: [String: DefaultAppBundleInfo] = [:]

    public init(launchServices: DefaultAppLaunchServices = SystemDefaultAppLaunchServices()) {
        self.launchServices = launchServices
    }

    public func bundles(forContentType identifier: String) -> [DefaultAppBundleInfo] {
        launchServices.applications(forContentType: identifier).compactMap(cached)
    }

    private func cached(_ url: URL) -> DefaultAppBundleInfo? {
        let key = url.standardizedFileURL.path
        lock.lock()
        if let hit = cache[key] {
            lock.unlock()
            return hit
        }
        lock.unlock()
        guard let info = DefaultAppBundleScanner.read(at: url) else { return nil }
        lock.lock()
        cache[key] = info
        lock.unlock()
        return info
    }
}
#endif

// MARK: - 服务

public struct DefaultAppService {
    private let launchServices: any DefaultAppLaunchServices
    private let claims: any DefaultAppClaimSource
    private let history: DefaultAppHistoryStore
    private let fileManager: FileManager
    private let applicationName: (URL) -> String
    private let bundleIdentifier: (URL) -> String?
    private let now: () -> Date

    public init(
        launchServices: any DefaultAppLaunchServices,
        claims: any DefaultAppClaimSource,
        history: DefaultAppHistoryStore,
        fileManager: FileManager = .default,
        applicationName: @escaping (URL) -> String = DefaultAppNaming.displayName(of:),
        bundleIdentifier: ((URL) -> String?)? = nil,
        now: @escaping () -> Date = Date.init
    ) {
        self.launchServices = launchServices
        self.claims = claims
        self.history = history
        self.fileManager = fileManager
        self.applicationName = applicationName
        self.bundleIdentifier = bundleIdentifier ?? Self.defaultBundleIdentifier
        self.now = now
    }

    public func rows() throws -> [DefaultAppRowModel] {
        var state = try history.load()
        let entries = listedExtensions(in: state)
        let identifiers = entries.map { contentIdentifier(for: $0.ext) }
        if reconcile(&state, identifiers: identifiers) {
            try history.save(state)
        }

        var bundlesByType: [String: [DefaultAppBundleInfo]] = [:]
        func bundles(for identifier: String) -> [DefaultAppBundleInfo] {
            if let cached = bundlesByType[identifier] { return cached }
            let value = claims.bundles(forContentType: identifier)
            bundlesByType[identifier] = value
            return value
        }

        var relatedByType: [String: [String]] = [:]
        for (entry, identifier) in zip(entries, identifiers) {
            guard let identifier else { continue }
            var list = relatedByType[identifier] ?? []
            list.append(entry.ext)
            relatedByType[identifier] = list
        }

        return zip(entries, identifiers).map { entry, identifier in
            let scope = DefaultAppTypeScope.classify(identifier)
            let current = identifier.flatMap { launchServices.defaultApplication(forContentType: $0) }
            let target = identifier.flatMap { restoreTarget(identifier: $0, state: state, bundles: bundles(for: $0)) }
            let related = identifier.flatMap { relatedByType[$0] }?
                .filter { $0 != entry.ext }
                .sorted() ?? []
            let same = target.map { sameApp(current, $0.url) } ?? false
            return DefaultAppRowModel(
                fileExtension: entry.ext,
                group: entry.group,
                isCustom: entry.custom,
                contentTypeIdentifier: identifier,
                scope: scope,
                currentAppPath: current?.path,
                currentAppName: current.map(applicationName),
                restoreKind: target?.kind ?? .none,
                restoreAppPath: target?.url.path,
                restoreAppName: target.map { applicationName($0.url) },
                relatedExtensions: related,
                canChange: scope.allowsChange,
                canRestore: scope.allowsChange && target != nil && !same
            )
        }
    }

    public func choices(forExtension raw: String) throws -> [DefaultAppChoice] {
        let ext = try requireExtension(raw)
        let identifier = try requireType(for: ext)
        var byPath: [String: DefaultAppChoice] = [:]
        func add(_ url: URL, isCurrent: Bool, isSystemDefault: Bool) {
            let path = url.standardizedFileURL.path
            if let existing = byPath[path] {
                byPath[path] = DefaultAppChoice(
                    path: path,
                    name: existing.name,
                    bundleID: existing.bundleID,
                    isCurrent: existing.isCurrent || isCurrent,
                    isSystemDefault: existing.isSystemDefault || isSystemDefault
                )
            } else {
                byPath[path] = DefaultAppChoice(
                    path: path,
                    name: applicationName(url),
                    bundleID: bundleIdentifier(url),
                    isCurrent: isCurrent,
                    isSystemDefault: isSystemDefault
                )
            }
        }

        for url in launchServices.applications(forContentType: identifier) {
            add(url, isCurrent: false, isSystemDefault: false)
        }
        if let current = launchServices.defaultApplication(forContentType: identifier) {
            add(current, isCurrent: true, isSystemDefault: false)
        }
        if let system = systemDefaultURL(identifier) {
            add(system, isCurrent: false, isSystemDefault: true)
        }
        return byPath.values.sorted { lhs, rhs in
            if lhs.isCurrent != rhs.isCurrent { return lhs.isCurrent }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    @discardableResult
    public func setDefault(app: URL, forExtension raw: String, allowShared: Bool) async throws -> DefaultAppMutation {
        let ext = try requireExtension(raw)
        let identifier = try requireType(for: ext)
        try validateScope(identifier, allowShared: allowShared)
        guard fileManager.fileExists(atPath: app.path) else { throw DefaultAppError.appMissing }
        guard app.pathExtension.lowercased() == "app" else { throw DefaultAppError.notAnApp }

        let current = launchServices.defaultApplication(forContentType: identifier)
        if sameApp(current, app) {
            return DefaultAppMutation(
                fileExtension: ext,
                appName: applicationName(app),
                kind: .unchanged,
                contentTypeIdentifier: identifier
            )
        }

        let snapshot = DefaultAppOriginal(
            contentTypeIdentifier: identifier,
            appPath: current?.path,
            bundleID: current.flatMap(bundleIdentifier),
            capturedAt: now()
        )
        do {
            try await launchServices.setDefaultApplication(at: app, forContentType: identifier)
        } catch let error as DefaultAppError {
            throw error
        } catch {
            throw DefaultAppError.applyFailed(error.localizedDescription)
        }

        // 按 UTI 记第一次修改前的应用。jpg 和 jpeg 都是 public.jpeg，不能各记一次，
        // 否则后改的那个会把已经换过的应用当成「原来的」。
        var state = try history.load()
        if state.originals[identifier] == nil {
            state.originals[identifier] = snapshot
            try history.save(state)
        }
        return DefaultAppMutation(
            fileExtension: ext,
            appName: applicationName(app),
            kind: .changed,
            contentTypeIdentifier: identifier
        )
    }

    @discardableResult
    public func restore(fileExtension raw: String, allowShared: Bool) async throws -> DefaultAppMutation {
        let ext = try requireExtension(raw)
        let identifier = try requireType(for: ext)
        try validateScope(identifier, allowShared: allowShared)
        var state = try history.load()
        let bundles = claims.bundles(forContentType: identifier)
        guard let target = restoreTarget(identifier: identifier, state: state, bundles: bundles) else {
            // 有记录但应用已经不在磁盘上：保留记录，等它装回来或能按 bundle ID 找到。
            if state.originals[identifier] != nil {
                throw DefaultAppError.originalMissing
            }
            throw DefaultAppError.nothingToRestore
        }
        guard fileManager.fileExists(atPath: target.url.path) else { throw DefaultAppError.originalMissing }

        let current = launchServices.defaultApplication(forContentType: identifier)
        if !sameApp(current, target.url) {
            do {
                try await launchServices.setDefaultApplication(at: target.url, forContentType: identifier)
            } catch let error as DefaultAppError {
                throw error
            } catch {
                throw DefaultAppError.applyFailed(error.localizedDescription)
            }
        }
        state.originals.removeValue(forKey: identifier)
        try history.save(state)
        return DefaultAppMutation(
            fileExtension: ext,
            appName: applicationName(target.url),
            kind: sameApp(current, target.url) ? .unchanged : .restored,
            contentTypeIdentifier: identifier
        )
    }

    /// 一次恢复所有能恢复的类型。调用方已经确认过，因此共享类型不再逐个询问。
    public func restoreAll() async throws -> DefaultAppBulkRestore {
        let snapshot = try rows()
        var restored: [String] = []
        var failures: [DefaultAppBulkRestore.Failure] = []
        var seen: Set<String> = []
        for row in snapshot where row.canRestore {
            let identifier = row.contentTypeIdentifier ?? row.fileExtension
            guard seen.insert(identifier).inserted else { continue }
            do {
                _ = try await restore(fileExtension: row.fileExtension, allowShared: true)
                restored.append(row.fileExtension)
            } catch {
                failures.append(
                    DefaultAppBulkRestore.Failure(
                        fileExtension: row.fileExtension,
                        message: error.localizedDescription
                    )
                )
            }
        }
        return DefaultAppBulkRestore(restoredExtensions: restored, failures: failures)
    }

    @discardableResult
    public func addCustomExtension(_ raw: String) throws -> String {
        let ext = try requireExtension(raw)
        if DefaultAppCatalog.presets.contains(where: { $0.fileExtension == ext }) {
            return ext
        }
        var state = try history.load()
        if !state.customExtensions.contains(ext) {
            state.customExtensions.append(ext)
            try history.save(state)
        }
        return ext
    }

    public func removeCustomExtension(_ raw: String) throws {
        let ext = try requireExtension(raw)
        var state = try history.load()
        let count = state.customExtensions.count
        state.customExtensions.removeAll { $0 == ext }
        if state.customExtensions.count != count {
            try history.save(state)
        }
    }

    // MARK: 内部

    private struct ListedExtension {
        let ext: String
        let group: DefaultAppPresetGroup?
        let custom: Bool
    }

    private struct ResolvedTarget {
        let url: URL
        let kind: DefaultAppRestoreKind
    }

    private func listedExtensions(in state: DefaultAppDiskState) -> [ListedExtension] {
        var items = DefaultAppCatalog.presets.map {
            ListedExtension(ext: $0.fileExtension, group: $0.group, custom: false)
        }
        let known = Set(items.map(\.ext))
        for ext in state.customExtensions where !known.contains(ext) {
            items.append(ListedExtension(ext: ext, group: nil, custom: true))
        }
        return items
    }

    private func contentIdentifier(for fileExtension: String) -> String? {
        launchServices.contentTypeIdentifier(forExtension: fileExtension)
    }

    private func requireExtension(_ raw: String) throws -> String {
        guard let ext = DefaultAppExtensionRules.normalize(raw) else {
            throw DefaultAppError.invalidExtension
        }
        return ext
    }

    private func requireType(for fileExtension: String) throws -> String {
        guard let identifier = contentIdentifier(for: fileExtension) else {
            throw DefaultAppError.unknownType
        }
        return identifier
    }

    private func validateScope(_ identifier: String, allowShared: Bool) throws {
        switch DefaultAppTypeScope.classify(identifier) {
        case .unsafe(let id):
            throw DefaultAppError.unsafeType(id)
        case .unknown:
            throw DefaultAppError.unknownType
        case .shared where !allowShared:
            throw DefaultAppError.sharedType(identifier)
        case .specific, .shared:
            return
        }
    }

    private func systemDefaultURL(_ identifier: String, bundles: [DefaultAppBundleInfo]? = nil) -> URL? {
        let bundles = bundles ?? claims.bundles(forContentType: identifier)
        guard let url = DefaultAppClaimReader.preferredDefault(identifier: identifier, among: bundles) else {
            return nil
        }
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        return url
    }

    private func restoreTarget(
        identifier: String,
        state: DefaultAppDiskState,
        bundles: [DefaultAppBundleInfo]
    ) -> ResolvedTarget? {
        if let system = systemDefaultURL(identifier, bundles: bundles) {
            return ResolvedTarget(url: system, kind: .system)
        }
        guard let original = state.originals[identifier], let url = resolve(original) else { return nil }
        return ResolvedTarget(url: url, kind: .previous)
    }

    private func resolve(_ original: DefaultAppOriginal) -> URL? {
        if let path = original.appPath {
            let url = URL(fileURLWithPath: path)
            if fileManager.fileExists(atPath: path), url.pathExtension.lowercased() == "app" {
                return url
            }
        }
        guard let bundleID = original.bundleID,
              let url = launchServices.applicationURL(bundleIdentifier: bundleID),
              fileManager.fileExists(atPath: url.path)
        else { return nil }
        return url
    }

    /// 用户已经在访达里改回去时，丢掉这里的记录，避免还显示「可以恢复」。
    private func reconcile(_ state: inout DefaultAppDiskState, identifiers: [String?]) -> Bool {
        var changed = false
        for identifier in Set(identifiers.compactMap { $0 }) {
            guard let original = state.originals[identifier],
                  let current = launchServices.defaultApplication(forContentType: identifier),
                  matches(current, original)
            else { continue }
            state.originals.removeValue(forKey: identifier)
            changed = true
        }
        return changed
    }

    private func sameApp(_ lhs: URL?, _ rhs: URL) -> Bool {
        guard let lhs else { return false }
        if lhs.standardizedFileURL.path == rhs.standardizedFileURL.path { return true }
        let left = bundleIdentifier(lhs)
        let right = bundleIdentifier(rhs)
        return left != nil && left == right
    }

    private func matches(_ url: URL, _ original: DefaultAppOriginal) -> Bool {
        if let path = original.appPath, URL(fileURLWithPath: path).standardizedFileURL.path == url.standardizedFileURL.path {
            return true
        }
        let current = bundleIdentifier(url)
        return current != nil && current == original.bundleID
    }

    private static func defaultBundleIdentifier(_ url: URL) -> String? {
        #if canImport(AppKit)
        return Bundle(url: url)?.bundleIdentifier
        #else
        return nil
        #endif
    }
}
