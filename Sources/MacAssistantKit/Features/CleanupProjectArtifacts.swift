import Darwin
import Foundation

/// 工程里可重新生成的目录。只扫开发者常用根目录，家目录本身永远不当工程。
/// 规则只提议路径；符号链接、拒绝名单和删除前的占用检查仍然生效。
enum CleanupProjectArtifacts {
    struct Activity: Sendable {
        /// `nil` 表示进程工作目录读不清，这时一项都不列。
        var workingDirectories: Set<String>?

        static var live: Activity {
            Activity(workingDirectories: CleanupProcessTable.workingDirectories())
        }
    }

    private struct Rule {
        let kind: String
        let folder: String
        let markers: [String]
        let lockfiles: [String]
        let refuseNames: [String]
        let requiresPyvenvCfg: Bool
        let kindKey: String
        let reinstallKey: String
    }

    private static let rules: [Rule] = [
        Rule(
            kind: "node",
            folder: "node_modules",
            markers: ["package.json"],
            lockfiles: [
                "package-lock.json", "pnpm-lock.yaml", "yarn.lock",
                "bun.lock", "bun.lockb", "npm-shrinkwrap.json"
            ],
            refuseNames: [],
            requiresPyvenvCfg: false,
            kindKey: "cleanup.project-artifact.kind.node",
            reinstallKey: "cleanup.project-artifact.reinstall.node"
        ),
        Rule(
            kind: "cargo",
            folder: "target",
            markers: ["Cargo.toml"],
            lockfiles: [],
            refuseNames: [],
            requiresPyvenvCfg: false,
            kindKey: "cleanup.project-artifact.kind.cargo",
            reinstallKey: "cleanup.project-artifact.reinstall.cargo"
        ),
        Rule(
            kind: "pods",
            folder: "Pods",
            markers: ["Podfile"],
            lockfiles: [],
            refuseNames: [],
            requiresPyvenvCfg: false,
            kindKey: "cleanup.project-artifact.kind.pods",
            reinstallKey: "cleanup.project-artifact.reinstall.pods"
        ),
        Rule(
            kind: "gradle",
            folder: ".gradle",
            markers: ["settings.gradle", "settings.gradle.kts", "build.gradle", "build.gradle.kts"],
            lockfiles: [],
            refuseNames: ["gradle.properties", "init.d"],
            requiresPyvenvCfg: false,
            kindKey: "cleanup.project-artifact.kind.gradle",
            reinstallKey: "cleanup.project-artifact.reinstall.gradle"
        ),
        Rule(
            kind: "android-gradle",
            folder: "android/.gradle",
            markers: ["settings.gradle", "settings.gradle.kts", "android/build.gradle", "android/build.gradle.kts"],
            lockfiles: [],
            refuseNames: ["gradle.properties", "init.d"],
            requiresPyvenvCfg: false,
            kindKey: "cleanup.project-artifact.kind.gradle",
            reinstallKey: "cleanup.project-artifact.reinstall.gradle"
        ),
        Rule(
            kind: "venv",
            folder: ".venv",
            markers: ["pyproject.toml", "requirements.txt"],
            lockfiles: [],
            refuseNames: [],
            requiresPyvenvCfg: true,
            kindKey: "cleanup.project-artifact.kind.venv",
            reinstallKey: "cleanup.project-artifact.reinstall.venv"
        ),
        Rule(
            kind: "venv-named",
            folder: "venv",
            markers: ["pyproject.toml", "requirements.txt"],
            lockfiles: [],
            refuseNames: [],
            requiresPyvenvCfg: true,
            kindKey: "cleanup.project-artifact.kind.venv",
            reinstallKey: "cleanup.project-artifact.reinstall.venv"
        ),
        Rule(
            kind: "flutter",
            folder: ".dart_tool",
            markers: ["pubspec.yaml"],
            lockfiles: ["pubspec.lock"],
            refuseNames: [],
            requiresPyvenvCfg: false,
            kindKey: "cleanup.project-artifact.kind.flutter",
            reinstallKey: "cleanup.project-artifact.reinstall.flutter"
        )
    ]

    /// 这些名字出现在主目录下才扫描。Documents、Desktop、Downloads 不在其中。
    static let rootNames = [
        "Developer", "Projects", "src", "code", "repos", "workspace", "dev", "Work", "work"
    ]

    private static let skippedDirectoryNames: Set<String> = [
        "node_modules", "Pods", "target", ".git", ".gradle", ".venv", "venv",
        ".dart_tool", "DerivedData", "Carthage", "vendor", ".build", "dist", "build"
    ]

    private static let maxDepth = 5
    private static let visitLimit = 4_000
    private static let resultLimit = 200

    static func definitions(home: URL, activity: Activity) -> [CleanupTargetDefinition] {
        guard let workingDirectories = activity.workingDirectories else { return [] }
        let home = home.standardizedFileURL
        var found: [CleanupTargetDefinition] = []
        var seenPaths = Set<String>()
        var seenInodes = Set<String>()
        var visits = 0

        for root in scanRoots(home: home) {
            walk(
                directory: root,
                depth: 0,
                home: home,
                workingDirectories: workingDirectories,
                found: &found,
                seenPaths: &seenPaths,
                seenInodes: &seenInodes,
                visits: &visits
            )
            if found.count >= resultLimit || visits >= visitLimit { break }
        }
        return found.sorted {
            $0.paths.first?.path ?? $0.id < $1.paths.first?.path ?? $1.id
        }
    }

    static func isInUse(projectRoot: URL, workingDirectories: Set<String>) -> Bool {
        let root = projectRoot.standardizedFileURL.path
        if workingDirectories.contains(where: { pathIsSameOrInside($0, root: root) }) {
            return true
        }
        return gitLock(at: projectRoot) == .locked
    }

    static func pathIsSameOrInside(_ directory: String, root: String) -> Bool {
        let dir = directory.lowercased()
        let root = root.lowercased()
        if dir == root { return true }
        let prefix = root.hasSuffix("/") ? root : root + "/"
        return dir.hasPrefix(prefix)
    }

    private static func scanRoots(home: URL) -> [URL] {
        var roots: [URL] = []
        var seen = Set<String>()
        for name in rootNames {
            let candidate = home.appendingPathComponent(name, isDirectory: true)
            guard let real = CleanupDiscovery.realDirectory(candidate) else { continue }
            guard real.standardizedFileURL.path != home.path else { continue }
            guard !CleanupDeniedPaths.contains(real, homeDirectory: home) else { continue }
            guard let key = inodeKey(real), seen.insert(key).inserted else { continue }
            roots.append(real)
        }
        return roots
    }

    private static func walk(
        directory: URL,
        depth: Int,
        home: URL,
        workingDirectories: Set<String>,
        found: inout [CleanupTargetDefinition],
        seenPaths: inout Set<String>,
        seenInodes: inout Set<String>,
        visits: inout Int
    ) {
        guard visits < visitLimit, found.count < resultLimit else { return }
        guard let key = inodeKey(directory), seenInodes.insert(key).inserted else { return }
        visits += 1
        let project = directory.standardizedFileURL
        guard project.path != home.path else { return }
        guard !CleanupDeniedPaths.contains(project, homeDirectory: home) else { return }

        if !isInUse(projectRoot: project, workingDirectories: workingDirectories) {
            for rule in rules {
                guard found.count < resultLimit else { return }
                guard let item = definition(
                    rule: rule,
                    project: project,
                    home: home,
                    seenPaths: &seenPaths
                ) else { continue }
                found.append(item)
            }
        }

        guard depth < maxDepth else { return }
        for child in CleanupDiscovery.listChildren(of: project) {
            let name = child.lastPathComponent
            if name.hasPrefix(".") || skippedDirectoryNames.contains(name) { continue }
            guard let real = CleanupDiscovery.realDirectory(child) else { continue }
            walk(
                directory: real,
                depth: depth + 1,
                home: home,
                workingDirectories: workingDirectories,
                found: &found,
                seenPaths: &seenPaths,
                seenInodes: &seenInodes,
                visits: &visits
            )
        }
    }

    private static func definition(
        rule: Rule,
        project: URL,
        home: URL,
        seenPaths: inout Set<String>
    ) -> CleanupTargetDefinition? {
        guard rule.markers.contains(where: { regularFile(relativeURL(project, $0)) }) else {
            return nil
        }
        if !rule.lockfiles.isEmpty,
           !rule.lockfiles.contains(where: { regularFile(relativeURL(project, $0)) }) {
            return nil
        }
        let artifact = relativeURL(project, rule.folder)
        guard let real = CleanupDiscovery.realDirectory(artifact) else { return nil }
        let path = real.standardizedFileURL.path
        guard path.hasPrefix(project.path + "/") else { return nil }
        guard path.hasPrefix(home.path + "/") else { return nil }
        guard !CleanupDeniedPaths.contains(real, homeDirectory: home) else { return nil }
        guard !isUserGradleHome(real, home: home) else { return nil }
        guard !rule.refuseNames.contains(where: { exists(real.appendingPathComponent($0)) }) else {
            return nil
        }
        if rule.requiresPyvenvCfg, !regularFile(real.appendingPathComponent("pyvenv.cfg")) {
            return nil
        }
        guard !isEmptyDirectory(real) else { return nil }
        guard seenPaths.insert(path).inserted else { return nil }

        let relative = String(path.dropFirst(home.path.count + 1))
        let reinstall = L(rule.reinstallKey)
        let display = "~/" + relative
        return CleanupTargetDefinition(
            id: "project-artifact:\(rule.kind):\(relative)",
            name: L("cleanup.project-artifact.name", project.lastPathComponent, L(rule.kindKey)),
            detail: L("cleanup.project-artifact.detail", display, reinstall),
            paths: [real],
            risk: .caution,
            action: .moveContentsToTrash,
            defaultSelected: false,
            category: .packageManager,
            systemImage: "folder",
            safetyDetails: CleanupSafetyDetails(
                removes: L("cleanup.project-artifact.removes"),
                keeps: L("cleanup.project-artifact.keeps"),
                note: reinstall
            ),
            activityRoot: project
        )
    }

    private static func isUserGradleHome(_ url: URL, home: URL) -> Bool {
        let root = home.appendingPathComponent(".gradle").standardizedFileURL.path
        let path = url.standardizedFileURL.path
        return path == root || path.hasPrefix(root + "/")
    }

    private static func relativeURL(_ base: URL, _ relative: String) -> URL {
        relative.split(separator: "/").reduce(base) {
            $0.appendingPathComponent(String($1), isDirectory: true)
        }
    }

    private static func regularFile(_ url: URL) -> Bool {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return false }
        return (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG)
    }

    private static func exists(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0
    }

    private static func isEmptyDirectory(_ url: URL) -> Bool {
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: nil,
            options: []
        ) else {
            return true
        }
        return children.isEmpty
    }

    private static func inodeKey(_ url: URL) -> String? {
        var info = stat()
        guard stat(url.path, &info) == 0 else { return nil }
        return "\(info.st_dev):\(info.st_ino)"
    }

    private enum GitLock {
        case unlocked
        case locked
    }

    private static func gitLock(at project: URL) -> GitLock {
        let git = project.appendingPathComponent(".git")
        var info = stat()
        guard lstat(git.path, &info) == 0 else { return .unlocked }
        let kind = info.st_mode & mode_t(S_IFMT)
        if kind == mode_t(S_IFLNK) { return .locked }
        if kind == mode_t(S_IFDIR) {
            return lockExists(in: git) ? .locked : .unlocked
        }
        if kind == mode_t(S_IFREG) {
            guard let directory = gitDirectory(from: git, project: project) else { return .locked }
            return lockExists(in: directory) ? .locked : .unlocked
        }
        return .locked
    }

    private static func lockExists(in gitDirectory: URL) -> Bool {
        ["index.lock", "HEAD.lock"].contains { exists(gitDirectory.appendingPathComponent($0)) }
    }

    private static func gitDirectory(from gitFile: URL, project: URL) -> URL? {
        guard let text = try? String(contentsOf: gitFile, encoding: .utf8) else { return nil }
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let prefix = "gitdir:"
        guard line.lowercased().hasPrefix(prefix) else { return nil }
        let raw = line.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty, !raw.contains("\0") else { return nil }
        if raw.hasPrefix("/") {
            return URL(fileURLWithPath: raw, isDirectory: true).standardizedFileURL
        }
        return URL(fileURLWithPath: raw, relativeTo: project).standardizedFileURL
    }
}
