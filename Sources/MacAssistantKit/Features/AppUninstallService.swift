import Foundation
#if canImport(Darwin)
import Darwin
#endif

public enum AppUninstallBlock: String, Sendable, Equatable {
    case notAnApp
    case missing
    case systemLocation
    case appleBundle
    case currentApp
}

public enum AppUninstallKind: String, Sendable, Equatable, CaseIterable {
    case application
    case support
    case cache
    case preferences
    case container
    case groupContainer
    case logs
    case savedState
    case webData
    case launchAgent
    case other
}

public enum AppUninstallMatch: String, Sendable, Equatable {
    case bundleIdentifier
    case applicationName
    case launchAgent
}

public struct AppUninstallItem: Identifiable, Hashable, Sendable {
    public let id: String
    public let path: String
    public let kind: AppUninstallKind
    public let match: AppUninstallMatch
    public let bytes: Int64

    public init(
        id: String,
        path: String,
        kind: AppUninstallKind,
        match: AppUninstallMatch,
        bytes: Int64
    ) {
        self.id = id
        self.path = path
        self.kind = kind
        self.match = match
        self.bytes = bytes
    }
}

public struct AppUninstallSurvey: Sendable, Equatable {
    public let appPath: String
    public let displayName: String
    public let bundleID: String?
    public let version: String?
    public let block: AppUninstallBlock?
    public let items: [AppUninstallItem]
    public let unreadableRoots: [String]

    public var totalBytes: Int64 {
        items.reduce(0) { $0 + $1.bytes }
    }
}

public struct AppUninstallFailure: Sendable, Equatable {
    public let path: String
    public let message: String
}

public struct AppUninstallResult: Sendable, Equatable {
    public let trashed: [String]
    public let failures: [AppUninstallFailure]
}

public enum AppUninstallError: LocalizedError, Equatable {
    case protected(AppUninstallBlock)
    case nothingSelected

    public var errorDescription: String? {
        switch self {
        case let .protected(block):
            return L("appuninstall.block.\(block.rawValue)")
        case .nothingSelected:
            return L("appuninstall.error.nothingSelected")
        }
    }
}

/// 卸载普通 macOS App：只把应用本体和能对上身份的个人资料库残留移入废纸篓。
public enum AppUninstallService {
    public static func survey(
        app: URL,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> AppUninstallSurvey {
        let original = app.standardizedFileURL
        let resolved = original.resolvingSymlinksInPath().standardizedFileURL
        let displayName = MacAppLibrary.displayName(of: original)
        let bundleID = MacAppLibrary.bundleID(of: resolved.pathExtension.lowercased() == "app" ? resolved : original)
        let version = MacAppLibrary.marketingVersion(of: original)
        let block = protection(original: original, resolved: resolved, bundleID: bundleID)
        if let block {
            return AppUninstallSurvey(
                appPath: original.path,
                displayName: displayName,
                bundleID: bundleID,
                version: version,
                block: block,
                items: [],
                unreadableRoots: []
            )
        }

        var items: [AppUninstallItem] = []
        if !isSymlink(original) {
            items.append(appItem(at: original))
        } else {
            items.append(appItem(at: resolved))
            if original.path != resolved.path {
                items.append(
                    AppUninstallItem(
                        id: original.path,
                        path: original.path,
                        kind: .application,
                        match: .bundleIdentifier,
                        bytes: 0
                    )
                )
            }
        }

        let identity = Identity(app: resolved, bundleID: bundleID)
        var unreadable: [String] = []
        let home = home.standardizedFileURL
        for spec in libraryRoots {
            let root = home.appendingPathComponent(spec.relative, isDirectory: true)
            switch listChildren(root) {
            case let .denied(path):
                unreadable.append(path)
            case let .entries(entries):
                items.append(contentsOf: matches(in: entries, root: root, spec: spec, identity: identity, home: home))
            }
        }
        items.append(contentsOf: launchAgents(home: home, identity: identity, unreadable: &unreadable))

        let unique = dedupe(items.filter { !CleanupDeniedPaths.contains(URL(fileURLWithPath: $0.path), homeDirectory: home) })
        return AppUninstallSurvey(
            appPath: original.path,
            displayName: displayName,
            bundleID: bundleID,
            version: version,
            block: nil,
            items: unique.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending },
            unreadableRoots: unreadable.sorted()
        )
    }

    public static func uninstall(
        app: URL,
        paths: [String],
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) throws -> AppUninstallResult {
        let fresh = survey(app: app, home: home)
        if let block = fresh.block {
            throw AppUninstallError.protected(block)
        }
        let allowed = Dictionary(uniqueKeysWithValues: fresh.items.map { ($0.path, $0) })
        let chosen = Array(Set(paths)).compactMap { allowed[$0] }.sorted { lhs, rhs in
            if lhs.kind == .application { return false }
            if rhs.kind == .application { return true }
            return lhs.path.count > rhs.path.count
        }
        guard !chosen.isEmpty else { throw AppUninstallError.nothingSelected }

        var trashed: [String] = []
        var failures: [AppUninstallFailure] = []
        for item in chosen {
            if item.kind == .launchAgent {
                bootoutLaunchAgent(at: item.path)
            }
            var resultURL: NSURL?
            do {
                let url = URL(fileURLWithPath: item.path)
                guard !isSymlink(url) || item.kind == .application else {
                    failures.append(AppUninstallFailure(path: item.path, message: L("appuninstall.error.symlink")))
                    continue
                }
                try FileManager.default.trashItem(at: url, resultingItemURL: &resultURL)
                trashed.append(item.path)
            } catch {
                failures.append(AppUninstallFailure(path: item.path, message: error.localizedDescription))
            }
        }
        return AppUninstallResult(trashed: trashed, failures: failures)
    }

    // MARK: - Protection

    private static func protection(original: URL, resolved: URL, bundleID: String?) -> AppUninstallBlock? {
        guard original.pathExtension.lowercased() == "app" || resolved.pathExtension.lowercased() == "app" else {
            return .notAnApp
        }
        guard FileSystemHelper.isDirectory(resolved) || FileSystemHelper.isDirectory(original) else {
            return .missing
        }
        if isSystemLocation(resolved) || isSystemLocation(original) {
            return .systemLocation
        }
        if let bundleID, bundleID.lowercased().hasPrefix("com.apple.") {
            return .appleBundle
        }
        let current = Bundle.main.bundleURL.standardizedFileURL.resolvingSymlinksInPath()
        if resolved.path == current.path || resolved.path.hasPrefix(current.path + "/") {
            return .currentApp
        }
        if let bundleID, let own = Bundle.main.bundleIdentifier,
           bundleID.caseInsensitiveCompare(own) == .orderedSame {
            return .currentApp
        }
        return nil
    }

    private static func isSystemLocation(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        let blocked = ["/System", "/usr", "/bin", "/sbin", "/Library/Apple"]
        return blocked.contains { path == $0 || path.hasPrefix($0 + "/") }
    }

    // MARK: - Matching

    private struct Identity {
        let appPath: String
        let bundleID: String?
        let strictNames: [String]
        let looseNames: [String]

        init(app: URL, bundleID: String?) {
            appPath = app.path
            self.bundleID = bundleID
            let folder = app.deletingPathExtension().lastPathComponent
            let plist = (try? IpaService.infoPlist(appBundle: app)) ?? [:]
            let raw = [
                folder,
                plist["CFBundleName"] as? String,
                plist["CFBundleDisplayName"] as? String,
                plist["CFBundleExecutable"] as? String
            ].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            strictNames = Array(Set(raw.filter { isSafeName($0, loose: false) }))
            looseNames = Array(Set(raw.filter { isSafeName($0, loose: true) }))
        }
    }

    private struct RootSpec {
        let relative: String
        let kind: AppUninstallKind
        let allowName: Bool
        let allowNested: Bool
    }

    private static let libraryRoots: [RootSpec] = [
        RootSpec(relative: "Library/Application Support", kind: .support, allowName: true, allowNested: true),
        RootSpec(relative: "Library/Caches", kind: .cache, allowName: true, allowNested: true),
        RootSpec(relative: "Library/Logs", kind: .logs, allowName: true, allowNested: true),
        RootSpec(relative: "Library/Preferences", kind: .preferences, allowName: false, allowNested: false),
        RootSpec(relative: "Library/Preferences/ByHost", kind: .preferences, allowName: false, allowNested: false),
        RootSpec(relative: "Library/Containers", kind: .container, allowName: false, allowNested: false),
        RootSpec(relative: "Library/Group Containers", kind: .groupContainer, allowName: false, allowNested: false),
        RootSpec(relative: "Library/Saved Application State", kind: .savedState, allowName: false, allowNested: false),
        RootSpec(relative: "Library/HTTPStorages", kind: .webData, allowName: false, allowNested: false),
        RootSpec(relative: "Library/WebKit", kind: .webData, allowName: false, allowNested: false),
        RootSpec(relative: "Library/Cookies", kind: .webData, allowName: false, allowNested: false),
        RootSpec(relative: "Library/Application Scripts", kind: .other, allowName: false, allowNested: false)
    ]

    private static let vendorNames: Set<String> = [
        "adobe", "apple", "google", "microsoft", "mozilla", "jetbrains", "oracle", "meta",
        "library", "shared", "common", "default", "support", "cache", "caches", "data",
        "temp", "tmp", "user", "users", "system", "crashreporter"
    ]

    private static let genericNames: Set<String> = [
        "notes", "mail", "safari", "chrome", "firefox", "finder", "preview", "photos",
        "music", "podcasts", "books", "maps", "messages", "calendar", "contacts",
        "reminders", "terminal", "settings", "utilities", "code"
    ]

    private static func isSafeName(_ name: String, loose: Bool) -> Bool {
        guard !name.isEmpty, !name.contains("/"), name != ".", name != ".." else { return false }
        let key = name.lowercased()
        if vendorNames.contains(key) { return false }
        if !loose && genericNames.contains(key) { return false }
        let ascii = name.unicodeScalars.allSatisfy { $0.isASCII }
        if ascii {
            return name.count >= (loose ? 4 : 5)
        }
        return name.count >= 2
    }

    private enum Listing {
        case entries([URL])
        case denied(String)
    }

    private static func listChildren(_ directory: URL) -> Listing {
        do {
            let children = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            )
            return .entries(children)
        } catch {
            let nsError = error as NSError
            if nsError.domain == NSCocoaErrorDomain, nsError.code == CocoaError.fileReadNoSuchFile.rawValue {
                return .entries([])
            }
            return .denied(directory.path)
        }
    }

    private static func matches(
        in entries: [URL],
        root: URL,
        spec: RootSpec,
        identity: Identity,
        home: URL
    ) -> [AppUninstallItem] {
        var found: [AppUninstallItem] = []
        for entry in entries {
            if isSymlink(entry) { continue }
            if let item = match(entry, spec: spec, identity: identity, nested: false) {
                found.append(item)
                continue
            }
            guard spec.allowNested, FileSystemHelper.isDirectory(entry) else { continue }
            guard case let .entries(children) = listChildren(entry) else { continue }
            for child in children where !isSymlink(child) {
                if let item = match(child, spec: spec, identity: identity, nested: true) {
                    found.append(item)
                }
            }
        }
        return found.filter {
            !CleanupDeniedPaths.contains(URL(fileURLWithPath: $0.path), homeDirectory: home)
                && $0.path != root.path
        }
    }

    private static func match(
        _ url: URL,
        spec: RootSpec,
        identity: Identity,
        nested: Bool
    ) -> AppUninstallItem? {
        let name = url.lastPathComponent
        guard let bundleID = identity.bundleID else {
            guard spec.allowName, nameMatches(name, identity: identity, nested: nested) else { return nil }
            return item(url, kind: spec.kind, match: .applicationName)
        }
        if spec.relative.hasSuffix("ByHost") {
            guard isByHostPreference(name, bundleID: bundleID) else { return nil }
            return item(url, kind: spec.kind, match: .bundleIdentifier)
        }
        if spec.kind == .groupContainer {
            guard nameEquals(name, bundleID) || name.lowercased().hasSuffix("." + bundleID.lowercased()) else {
                return nil
            }
            return item(url, kind: spec.kind, match: .bundleIdentifier)
        }
        if spec.kind == .preferences {
            guard nameEquals(name, bundleID + ".plist") else { return nil }
            return item(url, kind: spec.kind, match: .bundleIdentifier)
        }
        if spec.kind == .savedState {
            guard nameEquals(name, bundleID + ".savedState") else { return nil }
            return item(url, kind: spec.kind, match: .bundleIdentifier)
        }
        if spec.kind == .webData, spec.relative.hasSuffix("Cookies") {
            guard nameEquals(name, bundleID + ".binarycookies") else { return nil }
            return item(url, kind: spec.kind, match: .bundleIdentifier)
        }
        if nameEquals(name, bundleID) {
            return item(url, kind: spec.kind, match: .bundleIdentifier)
        }
        guard spec.allowName, nameMatches(name, identity: identity, nested: nested) else { return nil }
        return item(url, kind: spec.kind, match: .applicationName)
    }

    private static func nameMatches(_ name: String, identity: Identity, nested: Bool) -> Bool {
        let tokens = nested ? identity.looseNames : identity.strictNames
        return tokens.contains { nameEquals(name, $0) }
    }

    private static func isByHostPreference(_ name: String, bundleID: String) -> Bool {
        let prefix = bundleID + "."
        guard name.lowercased().hasPrefix(prefix.lowercased()), name.lowercased().hasSuffix(".plist") else {
            return false
        }
        let middle = name.dropFirst(prefix.count).dropLast(".plist".count)
        let pattern = #"^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$"#
        return middle.range(of: pattern, options: .regularExpression) != nil
    }

    private static func launchAgents(
        home: URL,
        identity: Identity,
        unreadable: inout [String]
    ) -> [AppUninstallItem] {
        let root = home.appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        switch listChildren(root) {
        case let .denied(path):
            unreadable.append(path)
            return []
        case let .entries(entries):
            return entries.compactMap { url -> AppUninstallItem? in
                guard url.pathExtension.lowercased() == "plist", !isSymlink(url) else { return nil }
                guard launchAgentMatches(url, identity: identity) else { return nil }
                return item(url, kind: .launchAgent, match: .launchAgent)
            }
        }
    }

    private static func launchAgentMatches(_ url: URL, identity: Identity) -> Bool {
        if let bundleID = identity.bundleID, nameEquals(url.lastPathComponent, bundleID + ".plist") {
            return true
        }
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]),
              data.count < 1_000_000,
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return false }
        if let bundleID = identity.bundleID,
           let label = plist["Label"] as? String,
           label.caseInsensitiveCompare(bundleID) == .orderedSame {
            return true
        }
        if let program = plist["Program"] as? String, programBelongsToApp(program, appPath: identity.appPath) {
            return true
        }
        if let arguments = plist["ProgramArguments"] as? [String],
           let program = arguments.first,
           programBelongsToApp(program, appPath: identity.appPath) {
            return true
        }
        return false
    }

    private static func programBelongsToApp(_ program: String, appPath: String) -> Bool {
        guard program.hasPrefix("/") else { return false }
        let path = URL(fileURLWithPath: program).standardizedFileURL.resolvingSymlinksInPath().path
        return path == appPath || path.hasPrefix(appPath + "/")
    }

    private static func bootoutLaunchAgent(at path: String) {
        #if canImport(Darwin)
        let target = "gui/\(getuid())"
        _ = try? Shell.run("/bin/launchctl", ["bootout", target, path])
        #endif
    }

    // MARK: - Helpers

    private static func appItem(at url: URL) -> AppUninstallItem {
        AppUninstallItem(
            id: url.path,
            path: url.path,
            kind: .application,
            match: .bundleIdentifier,
            bytes: FileSystemHelper.size(at: url)
        )
    }

    private static func item(_ url: URL, kind: AppUninstallKind, match: AppUninstallMatch) -> AppUninstallItem {
        AppUninstallItem(
            id: url.path,
            path: url.path,
            kind: kind,
            match: match,
            bytes: FileSystemHelper.size(at: url)
        )
    }

    private static func dedupe(_ items: [AppUninstallItem]) -> [AppUninstallItem] {
        var byPath: [String: AppUninstallItem] = [:]
        for item in items {
            if let existing = byPath[item.path] {
                if existing.match != .bundleIdentifier && item.match == .bundleIdentifier {
                    byPath[item.path] = item
                }
            } else {
                byPath[item.path] = item
            }
        }
        let sorted = byPath.values.sorted { $0.path.count < $1.path.count }
        var kept: [AppUninstallItem] = []
        for item in sorted {
            let nested = kept.contains { parent in
                item.path != parent.path && item.path.hasPrefix(parent.path + "/")
            }
            if !nested { kept.append(item) }
        }
        return kept
    }

    private static func nameEquals(_ lhs: String, _ rhs: String) -> Bool {
        lhs.caseInsensitiveCompare(rhs) == .orderedSame
    }

    private static func isSymlink(_ url: URL) -> Bool {
        #if canImport(Darwin)
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return false }
        return (info.st_mode & S_IFMT) == S_IFLNK
        #else
        return false
        #endif
    }
}
