import Darwin
import Foundation

public struct CleanupScanPlan: Sendable {
    public let definitions: [CleanupTargetDefinition]
    public let policy: CleanupPathPolicy
    public let fullDiskAccess: CleanupFullDiskAccessStatus
    public let blockedItems: [CleanupScanItem]

    public init(
        definitions: [CleanupTargetDefinition],
        policy: CleanupPathPolicy,
        fullDiskAccess: CleanupFullDiskAccessStatus,
        blockedItems: [CleanupScanItem]
    ) {
        self.definitions = definitions
        self.policy = policy
        self.fullDiskAccess = fullDiskAccess
        self.blockedItems = blockedItems
    }
}

public struct CleanupPackageCacheResolver: Sendable {
    public var npmCache: @Sendable (URL) -> URL?
    public var yarnCache: @Sendable (URL) -> URL?
    public var pnpmStore: @Sendable (URL) -> URL?

    public init(
        npmCache: @escaping @Sendable (URL) -> URL?,
        yarnCache: @escaping @Sendable (URL) -> URL?,
        pnpmStore: @escaping @Sendable (URL) -> URL?
    ) {
        self.npmCache = npmCache
        self.yarnCache = yarnCache
        self.pnpmStore = pnpmStore
    }

    public static let disabled = CleanupPackageCacheResolver(
        npmCache: { _ in nil },
        yarnCache: { _ in nil },
        pnpmStore: { _ in nil }
    )

    public static let live = CleanupPackageCacheResolver(
        npmCache: { home in CleanupDiscovery.commandPath(["npm", "config", "get", "cache"], home: home) },
        yarnCache: { home in CleanupDiscovery.commandPath(["yarn", "cache", "dir"], home: home) },
        pnpmStore: { home in CleanupDiscovery.commandPath(["pnpm", "store", "path"], home: home) }
    )
}

enum CleanupDiscovery {
    static let minimumDynamicCacheBytes: Int64 = 4_096
    /// macos-sysdata `AppDataProbe` 对 `~/Library/Caches` 的门槛：更大的单独成行，其余折进一行。
    static let prominentDynamicCacheBytes: Int64 = 100_000_000

    static func makeScanPlan(
        seed: [CleanupTargetDefinition],
        homeDirectory: URL,
        packageResolver: CleanupPackageCacheResolver,
        fullDiskAccessProbe: CleanupFullDiskAccessProbe,
        projectActivity: CleanupProjectArtifacts.Activity = .live
    ) -> CleanupScanPlan {
        let home = homeDirectory.standardizedFileURL
        let fda = fullDiskAccessProbe.probe(homeDirectory: home)
        let packages = resolvedPackageDefinitions(
            seed: seed,
            home: home,
            resolver: packageResolver
        )
        let browsers = CleanupBrowserCaches.expand(packages, home: home)
        let derived = CleanupDerivedData.expand(browsers, home: home)
        let expanded = CleanupSystemData.expand(derived, home: home)
        let coveredCaches = coveredUserCacheNames(from: expanded, home: home)
        let userCaches = userCacheItems(home: home, skipping: coveredCaches)
        let containers = containerCacheItems(home: home, fullDiskAccess: fda)

        let systemData = expanded.filter { $0.category == .systemData }
        let apps = expanded.filter { $0.category == .apps }
        let system = expanded.filter { $0.category == .system }
        let rest = expanded.filter {
            $0.category != .systemData && $0.category != .system && $0.category != .apps
        }
        let projects = CleanupProjectArtifacts.definitions(home: home, activity: projectActivity)
        let definitions = systemData + userCaches + containers.definitions + apps + system + rest + projects
        return CleanupScanPlan(
            definitions: definitions,
            policy: CleanupService.makePolicy(definitions: definitions, homeDirectory: home),
            fullDiskAccess: fda,
            blockedItems: containers.blocked
        )
    }

    static func shouldOmitDynamicItem(_ item: CleanupScanItem) -> Bool {
        let id = item.id
        let expandable = id.hasPrefix("user-cache:")
            || id.hasPrefix("container-cache:")
            || id.hasPrefix("group-cache:")
            || id == "user-caches"
            || id == "container-cache-rest"
            || id == "group-cache-rest"
            || id.hasPrefix("ios-backup:")
            || id.hasPrefix("firmware:")
            || id.hasPrefix("android-avd:")
            || id.hasPrefix("android-sdk:")
            || id.hasPrefix("android-studio-cache:")
            || id.hasPrefix("vm:")
        // 系统数据只列实际存在的项，避免一排「不存在」占住分组。
        guard expandable || item.definition.category == .systemData else {
            return false
        }
        switch item.status {
        case .missing:
            return true
        case let .measured(bytes) where bytes <= minimumDynamicCacheBytes:
            return true
        default:
            return false
        }
    }

    /// 扫描出体积后，把小于 100 MB 的用户/容器缓存折成一行。大项仍单独列出，和 macos-sysdata 一致。
    static func coalesceSmallDynamicCaches(
        _ items: [CleanupScanItem],
        prominentBytes: Int64 = prominentDynamicCacheBytes
    ) -> [CleanupScanItem] {
        let groups = DynamicCacheMergeGroup.all
        var smallByPrefix: [String: [CleanupScanItem]] = [:]
        for item in items {
            guard let group = groups.first(where: { item.id.hasPrefix($0.idPrefix) }) else { continue }
            guard isSmallMeasuredCache(item, prominentBytes: prominentBytes) else { continue }
            smallByPrefix[group.idPrefix, default: []].append(item)
        }
        let mergeable = Set(smallByPrefix.compactMap { prefix, members in
            members.count >= 2 ? prefix : nil
        })
        guard !mergeable.isEmpty else { return items }

        var result: [CleanupScanItem] = []
        var inserted: Set<String> = []
        result.reserveCapacity(items.count)
        for item in items {
            guard let group = groups.first(where: { item.id.hasPrefix($0.idPrefix) }),
                  mergeable.contains(group.idPrefix),
                  isSmallMeasuredCache(item, prominentBytes: prominentBytes)
            else {
                result.append(item)
                continue
            }
            if inserted.insert(group.mergedID).inserted {
                result.append(mergedCacheItem(smallByPrefix[group.idPrefix] ?? [], group: group))
            }
        }
        return result
    }

    static func resolvedPackageDefinitions(
        seed: [CleanupTargetDefinition],
        home: URL,
        resolver: CleanupPackageCacheResolver
    ) -> [CleanupTargetDefinition] {
        seed.map { definition in
            switch definition.id {
            case "npm":
                return withAcceptedPaths(
                    definition,
                    extras: [resolver.npmCache(home)],
                    home: home
                )
            case "yarn":
                return withAcceptedPaths(
                    definition,
                    extras: [resolver.yarnCache(home)],
                    home: home
                )
            case "pnpm":
                return withAcceptedPaths(
                    definition,
                    extras: [
                        resolver.pnpmStore(home),
                        home.appendingPathComponent("Library/pnpm/store"),
                        home.appendingPathComponent(".cache/pnpm")
                    ],
                    home: home
                )
            case "pip":
                return withAcceptedPaths(
                    definition,
                    extras: [home.appendingPathComponent(".cache/pip")],
                    home: home
                )
            case "uv":
                return withAcceptedPaths(
                    definition,
                    extras: [home.appendingPathComponent(".cache/uv")],
                    home: home
                )
            default:
                return definition
            }
        }
    }

    static func coveredUserCacheNames(from definitions: [CleanupTargetDefinition], home: URL) -> Set<String> {
        let cachesRoot = home.appendingPathComponent("Library/Caches", isDirectory: true).standardizedFileURL.path
        var names = Set<String>()
        for path in definitions.flatMap(\.paths) {
            let candidate = path.standardizedFileURL.path
            guard candidate == cachesRoot || candidate.hasPrefix(cachesRoot + "/") else { continue }
            let rest = String(candidate.dropFirst(cachesRoot.count + 1))
            if let first = rest.split(separator: "/").first {
                names.insert(String(first))
            }
        }
        return names
    }

    static func userCacheItems(home: URL, skipping: Set<String> = []) -> [CleanupTargetDefinition] {
        let cachesRoot = home.appendingPathComponent("Library/Caches", isDirectory: true)
        guard let root = realDirectory(cachesRoot) else { return [] }
        guard !CleanupDeniedPaths.contains(root, homeDirectory: home) else { return [] }

        return listChildren(of: root).compactMap { child in
            guard let directory = realDirectory(child) else { return nil }
            if CleanupDeniedPaths.contains(directory, homeDirectory: home) { return nil }
            if isEmptyDirectory(directory) { return nil }
            let name = directory.lastPathComponent
            if skipping.contains(name) { return nil }
            return CleanupTargetDefinition(
                id: "user-cache:\(name)",
                name: L("cleanup.user-cache-item.name", name),
                detail: L("cleanup.user-cache-item.detail", name),
                paths: [directory],
                risk: riskForUserCache(named: name),
                action: .moveContentsToTrash,
                defaultSelected: false,
                category: .systemData,
                systemImage: "internaldrive"
            )
        }
    }

    static func containerCacheItems(
        home: URL,
        fullDiskAccess: CleanupFullDiskAccessStatus
    ) -> (definitions: [CleanupTargetDefinition], blocked: [CleanupScanItem]) {
        if fullDiskAccess == .denied {
            return ([], [blockedContainerItem()])
        }

        var definitions: [CleanupTargetDefinition] = []
        var sawPermissionDenial = false
        var listedAnyRoot = false

        let containerRoot = home.appendingPathComponent("Library/Containers", isDirectory: true)
        switch listContainerCaches(
            at: containerRoot,
            home: home,
            idPrefix: "container-cache",
            nameKey: "cleanup.container-cache-item.name",
            detailKey: "cleanup.container-cache-item.detail",
            cachesSuffix: ["Data", "Library", "Caches"]
        ) {
        case let .listed(items):
            listedAnyRoot = true
            definitions.append(contentsOf: items)
        case .permissionDenied:
            sawPermissionDenial = true
        case .missing:
            break
        }

        let groupRoot = home.appendingPathComponent("Library/Group Containers", isDirectory: true)
        switch listContainerCaches(
            at: groupRoot,
            home: home,
            idPrefix: "group-cache",
            nameKey: "cleanup.group-cache-item.name",
            detailKey: "cleanup.group-cache-item.detail",
            cachesSuffix: ["Library", "Caches"]
        ) {
        case let .listed(items):
            listedAnyRoot = true
            definitions.append(contentsOf: items)
        case .permissionDenied:
            sawPermissionDenial = true
        case .missing:
            break
        }

        if sawPermissionDenial && definitions.isEmpty {
            return ([], [blockedContainerItem()])
        }
        if !listedAnyRoot && sawPermissionDenial {
            return ([], [blockedContainerItem()])
        }
        return (definitions, [])
    }

    static func commandPath(_ arguments: [String], home: URL) -> URL? {
        guard let tool = arguments.first else { return nil }
        let rest = Array(arguments.dropFirst())
        guard let executable = Shell.which(tool) else { return nil }
        guard let result = try? Shell.run(executable, rest), result.succeeded else { return nil }
        return expandPath(result.trimmedOutput, home: home)
    }

    static func acceptPackagePath(_ url: URL, home: URL) -> URL? {
        let candidate = url.standardizedFileURL
        guard !isCollapsedPackagePath(candidate, home: home) else { return nil }
        guard isWithinPackageCacheAllowlist(candidate, home: home) else { return nil }
        guard !CleanupDeniedPaths.contains(candidate, homeDirectory: home) else { return nil }
        let policy = CleanupPathPolicy(homeDirectory: home, allowedRoots: [candidate])
        return try? policy.validate(candidate).requestedURL
    }

    static func isCollapsedPackagePath(_ url: URL, home: URL) -> Bool {
        let path = url.standardizedFileURL.path
        let forbidden = [
            home,
            home.appendingPathComponent("Library/Caches"),
            home.appendingPathComponent(".cache")
        ]
        return forbidden.contains { $0.standardizedFileURL.path == path }
    }

    /// CLI 探测只许落在已知包管理器缓存前缀下，禁止把 Documents / Library / .ssh 收成可删根。
    static func isWithinPackageCacheAllowlist(_ url: URL, home: URL) -> Bool {
        let path = url.standardizedFileURL.path
        return packageCacheAllowlist(home: home).contains { prefix in
            let root = prefix.standardizedFileURL.path
            return path == root || path.hasPrefix(root + "/")
        }
    }

    static func packageCacheAllowlist(home: URL) -> [URL] {
        [
            home.appendingPathComponent(".npm", isDirectory: true),
            home.appendingPathComponent(".cache", isDirectory: true),
            home.appendingPathComponent("Library/Caches", isDirectory: true),
            home.appendingPathComponent("Library/pnpm", isDirectory: true),
            home.appendingPathComponent(".yarn", isDirectory: true),
            home.appendingPathComponent(".local/share/pnpm", isDirectory: true),
            home.appendingPathComponent(".pnpm-store", isDirectory: true),
            home.appendingPathComponent(".bun", isDirectory: true),
            home.appendingPathComponent(".m2", isDirectory: true),
            home.appendingPathComponent(".pub-cache", isDirectory: true),
            home.appendingPathComponent("go/pkg", isDirectory: true)
        ]
    }

    static func expandPath(_ raw: String, home: URL) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "undefined", !trimmed.hasPrefix("npm ERR") else {
            return nil
        }
        guard !trimmed.contains(where: \.isNewline) else { return nil }
        if trimmed == "~" {
            return home
        }
        if trimmed.hasPrefix("~/") {
            return home.appendingPathComponent(String(trimmed.dropFirst(2)))
        }
        guard trimmed.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: trimmed, isDirectory: true)
    }

    private enum ContainerListResult {
        case listed([CleanupTargetDefinition])
        case permissionDenied
        case missing
    }

    private static func listContainerCaches(
        at root: URL,
        home: URL,
        idPrefix: String,
        nameKey: String,
        detailKey: String,
        cachesSuffix: [String]
    ) -> ContainerListResult {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory) else {
            return .missing
        }
        guard let realRoot = realDirectory(root) else { return .missing }

        let children: [URL]
        do {
            children = try FileManager.default.contentsOfDirectory(
                at: realRoot,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: []
            )
        } catch {
            return FileSystemHelper.isAccessPermissionError(error) ? .permissionDenied : .missing
        }

        var items: [CleanupTargetDefinition] = []
        for child in children {
            guard let container = realDirectory(child) else { continue }
            var caches = container
            for part in cachesSuffix {
                caches.appendPathComponent(part, isDirectory: true)
            }
            guard let cacheDir = realDirectory(caches) else { continue }
            if CleanupDeniedPaths.contains(cacheDir, homeDirectory: home) { continue }
            if isEmptyDirectory(cacheDir) { continue }
            let name = container.lastPathComponent
            items.append(
                CleanupTargetDefinition(
                    id: "\(idPrefix):\(name)",
                    name: L(nameKey, name),
                    detail: L(detailKey, name),
                    paths: [cacheDir],
                    risk: .caution,
                    action: .moveContentsToTrash,
                    defaultSelected: false,
                    category: .systemData,
                    systemImage: "app"
                )
            )
        }
        return .listed(items)
    }

    private struct DynamicCacheMergeGroup {
        let idPrefix: String
        let mergedID: String
        let nameKey: String
        let detailKey: String
        let systemImage: String

        static let all: [DynamicCacheMergeGroup] = [
            DynamicCacheMergeGroup(
                idPrefix: "user-cache:",
                mergedID: "user-caches",
                nameKey: "cleanup.user-caches.name",
                detailKey: "cleanup.user-caches-merged.detail",
                systemImage: "internaldrive"
            ),
            DynamicCacheMergeGroup(
                idPrefix: "container-cache:",
                mergedID: "container-cache-rest",
                nameKey: "cleanup.container-caches-rest.name",
                detailKey: "cleanup.container-caches-rest.detail",
                systemImage: "app"
            ),
            DynamicCacheMergeGroup(
                idPrefix: "group-cache:",
                mergedID: "group-cache-rest",
                nameKey: "cleanup.group-caches-rest.name",
                detailKey: "cleanup.group-caches-rest.detail",
                systemImage: "app"
            )
        ]
    }

    private static func isSmallMeasuredCache(_ item: CleanupScanItem, prominentBytes: Int64) -> Bool {
        guard let bytes = item.status.measuredBytes else { return false }
        return bytes < prominentBytes
    }

    private static func mergedCacheItem(
        _ items: [CleanupScanItem],
        group: DynamicCacheMergeGroup
    ) -> CleanupScanItem {
        let bytes = items.compactMap(\.status.measuredBytes).reduce(0, +)
        let partialMessages = items.compactMap { item -> [String]? in
            if case let .partial(_, messages) = item.status { return messages }
            return nil
        }.flatMap { $0 }
        let risk: CleanupRisk = items.contains(where: { $0.definition.risk != .safe }) ? .caution : .safe
        let definition = CleanupTargetDefinition(
            id: group.mergedID,
            name: L(group.nameKey),
            detail: L(group.detailKey, items.count),
            paths: items.flatMap(\.definition.paths),
            risk: risk,
            action: .moveContentsToTrash,
            defaultSelected: false,
            category: .systemData,
            systemImage: group.systemImage
        )
        let status: CleanupScanStatus = partialMessages.isEmpty
            ? .measured(bytes)
            : .partial(bytes, partialMessages)
        return CleanupScanItem(
            definition: definition,
            status: status,
            validatedPaths: items.flatMap(\.validatedPaths)
        )
    }

    private static func blockedContainerItem() -> CleanupScanItem {
        let definition = CleanupTargetDefinition(
            id: "container-caches",
            name: L("cleanup.container-caches.name"),
            detail: L("cleanup.container-caches.detail"),
            paths: [],
            risk: .caution,
            action: .moveContentsToTrash,
            defaultSelected: false,
            category: .system,
            systemImage: "lock.trianglebadge.exclamationmark"
        )
        return CleanupScanItem(
            definition: definition,
            status: .permissionDenied(L("cleanup.message.no-read-permission.generic")),
            validatedPaths: []
        )
    }

    private static func withAcceptedPaths(
        _ definition: CleanupTargetDefinition,
        extras: [URL?],
        home: URL
    ) -> CleanupTargetDefinition {
        var paths = definition.paths
        var seen = Set(paths.map { $0.standardizedFileURL.path })
        for extra in extras.compactMap({ $0 }) {
            guard let accepted = acceptPackagePath(extra, home: home) else { continue }
            let key = accepted.standardizedFileURL.path
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            paths.append(accepted)
        }
        let detail = paths.map { displayPath($0, home: home) }.joined(separator: ", ")
        return CleanupTargetDefinition(
            id: definition.id,
            name: definition.name,
            detail: detail,
            paths: paths,
            risk: definition.risk,
            action: definition.action,
            defaultSelected: false,
            category: definition.category,
            systemImage: definition.systemImage,
            safetyDetails: definition.safetyDetails,
            activityRoot: definition.activityRoot
        )
    }

    private static func displayPath(_ url: URL, home: URL) -> String {
        let path = url.standardizedFileURL.path
        let homePath = home.standardizedFileURL.path
        if path == homePath { return "~" }
        if path.hasPrefix(homePath + "/") {
            return "~" + String(path.dropFirst(homePath.count))
        }
        return path
    }

    private static func riskForUserCache(named name: String) -> CleanupRisk {
        let lowered = name.lowercased()
        let regenerable = [
            "google", "chrome", "firefox", "brave", "microsoft edge",
            "com.apple.safari", "go-build", "pnpm", "yarn", "cocoapods", "pip",
            "org.swift.swiftpm", "com.apple.dt.xcode", "ms-playwright",
            "jetbrains", "node-gyp", "deno", "typescript", "cursor"
        ]
        if regenerable.contains(where: { lowered.contains($0) }) {
            return .safe
        }
        return .caution
    }

    static func listChildren(of directory: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: []
        )) ?? []
    }

    private static func isEmptyDirectory(_ url: URL) -> Bool {
        let children = (try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        return children.isEmpty
    }

    /// 目录必须真实存在，且 resolved == requested，防止容器路径 symlink 逃逸。
    static func realDirectory(_ url: URL) -> URL? {
        realItem(url, directory: true)
    }

    /// 普通文件必须真实存在，且不是 symlink。
    static func realFile(_ url: URL) -> URL? {
        realItem(url, directory: false)
    }

    private static func realItem(_ url: URL, directory: Bool) -> URL? {
        let requested = url.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: requested.path, isDirectory: &isDirectory),
              isDirectory.boolValue == directory
        else {
            return nil
        }
        var info = stat()
        guard lstat(requested.path, &info) == 0 else { return nil }
        guard (info.st_mode & mode_t(S_IFMT)) != mode_t(S_IFLNK) else { return nil }
        let resolved = requested.resolvingSymlinksInPath().standardizedFileURL
        guard resolved.path == requested.path else { return nil }
        return requested
    }
}
