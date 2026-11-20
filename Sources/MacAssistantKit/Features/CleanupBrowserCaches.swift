import Foundation

/// 把浏览器 Application Support 里真正的缓存叶并进对应目标。
/// 只认配置目录名 + 允许叶名，不把 Cookie / 登录库 / 配置根收成可删路径。
enum CleanupBrowserCaches {
    static let chromiumProfileLeaves: Set<String> = [
        "Cache", "Code Cache", "GPUCache"
    ]
    static let chromiumRootLeaves: Set<String> = [
        "ShaderCache", "GrShaderCache", "GraphiteDawnCache"
    ]
    static let firefoxProfileLeaves: Set<String> = [
        "cache2", "startupCache"
    ]

    static func expand(
        _ definitions: [CleanupTargetDefinition],
        home: URL
    ) -> [CleanupTargetDefinition] {
        definitions.map { definition in
            let extras: [URL]
            switch definition.id {
            case "chrome":
                extras = chromiumLeaves(
                    roots: [
                        home.appendingPathComponent("Library/Application Support/Google/Chrome"),
                        home.appendingPathComponent("Library/Application Support/Google/Chrome Canary")
                    ],
                    home: home
                )
            case "edge":
                extras = chromiumLeaves(
                    roots: [
                        home.appendingPathComponent("Library/Application Support/Microsoft Edge")
                    ],
                    home: home
                )
            case "brave":
                extras = chromiumLeaves(
                    roots: [
                        home.appendingPathComponent(
                            "Library/Application Support/BraveSoftware/Brave-Browser"
                        )
                    ],
                    home: home
                )
            case "firefox":
                extras = firefoxLeaves(
                    profilesRoot: home.appendingPathComponent(
                        "Library/Application Support/Firefox/Profiles"
                    ),
                    home: home
                )
            default:
                return definition
            }
            return merging(definition, extras: extras, home: home)
        }
    }

    static func isChromiumProfileName(_ name: String) -> Bool {
        switch name {
        case "Default", "Guest Profile", "System Profile":
            return true
        default:
            guard name.hasPrefix("Profile ") else { return false }
            let number = name.dropFirst("Profile ".count)
            return !number.isEmpty && number.allSatisfy(\.isNumber)
        }
    }

    static func acceptedLeaf(_ url: URL, home: URL) -> URL? {
        guard let real = CleanupDiscovery.realDirectory(url) else { return nil }
        guard CleanupCatalog.allowedApplicationSupportLeaves.contains(real.lastPathComponent) else {
            return nil
        }
        guard !CleanupDeniedPaths.contains(real, homeDirectory: home) else { return nil }
        return real
    }

    private static func chromiumLeaves(roots: [URL], home: URL) -> [URL] {
        var urls: [URL] = []
        for root in roots {
            guard let real = CleanupDiscovery.realDirectory(root) else { continue }
            for leaf in chromiumRootLeaves.sorted() {
                if let accepted = acceptedLeaf(
                    real.appendingPathComponent(leaf, isDirectory: true),
                    home: home
                ) {
                    urls.append(accepted)
                }
            }
            for child in CleanupDiscovery.listChildren(of: real) {
                guard let directory = CleanupDiscovery.realDirectory(child) else { continue }
                guard isChromiumProfileName(directory.lastPathComponent) else { continue }
                for leaf in chromiumProfileLeaves.sorted() {
                    if let accepted = acceptedLeaf(
                        directory.appendingPathComponent(leaf, isDirectory: true),
                        home: home
                    ) {
                        urls.append(accepted)
                    }
                }
            }
        }
        return urls
    }

    private static func firefoxLeaves(profilesRoot: URL, home: URL) -> [URL] {
        guard let root = CleanupDiscovery.realDirectory(profilesRoot) else { return [] }
        var urls: [URL] = []
        for child in CleanupDiscovery.listChildren(of: root) {
            guard let profile = CleanupDiscovery.realDirectory(child) else { continue }
            if profile.lastPathComponent.hasPrefix(".") { continue }
            for leaf in firefoxProfileLeaves.sorted() {
                if let accepted = acceptedLeaf(
                    profile.appendingPathComponent(leaf, isDirectory: true),
                    home: home
                ) {
                    urls.append(accepted)
                }
            }
        }
        return urls
    }

    private static func merging(
        _ definition: CleanupTargetDefinition,
        extras: [URL],
        home: URL
    ) -> CleanupTargetDefinition {
        var paths = definition.paths
        var seen = Set(paths.map { $0.standardizedFileURL.path })
        for extra in extras {
            let key = extra.standardizedFileURL.path
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            paths.append(extra)
        }
        guard paths.count != definition.paths.count else { return definition }
        return CleanupTargetDefinition(
            id: definition.id,
            name: definition.name,
            detail: paths.map { displayPath($0, home: home) }.joined(separator: ", "),
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
}
