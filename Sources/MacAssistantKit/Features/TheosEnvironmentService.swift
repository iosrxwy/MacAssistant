import Foundation

/// 本机 Theos 工具链的只读健康快照。不会改动 shell 配置、SDK 或项目文件。
public struct TheosEnvironmentSnapshot: Sendable {
    public let root: URL?
    public let hasNIC: Bool
    public let hasTemplates: Bool
    public let availableSDKs: [String]
    public let hasMake: Bool
    public let hasGit: Bool
    public let hasPerl: Bool
    public let hasXcodeTools: Bool
    public let hasDpkgDeb: Bool
    public let hasLdid: Bool

    public var isInstalled: Bool { root != nil && hasNIC && hasTemplates }
    public var isReadyToBuild: Bool {
        isInstalled && !availableSDKs.isEmpty && hasMake && hasGit && hasPerl && hasXcodeTools && hasDpkgDeb && hasLdid
    }

    public var missingRequirements: [String] {
        var result: [String] = []
        if root == nil { result.append("THEOS") }
        if root != nil && !hasNIC { result.append("nic.pl") }
        if root != nil && !hasTemplates { result.append("templates") }
        if availableSDKs.isEmpty { result.append("iPhoneOS SDK") }
        if !hasMake { result.append("make") }
        if !hasGit { result.append("git") }
        if !hasPerl { result.append("perl") }
        if !hasXcodeTools { result.append("Xcode Command Line Tools") }
        if !hasDpkgDeb { result.append("dpkg-deb") }
        if !hasLdid { result.append("ldid") }
        return result
    }
}

public enum TheosManagedError: LocalizedError {
    case gitMissing
    case occupiedPath(String)

    public var errorDescription: String? {
        switch self {
        case .gitMissing: return "缺少 git，请先安装 Xcode Command Line Tools"
        case let .occupiedPath(path): return "内置 Theos 目录已被其他文件占用：\(path)"
        }
    }
}

/// 检测 Theos，并管理 App Support 中由用户确认安装的官方副本。
public enum TheosEnvironmentService {
    public static let officialInstallationURL = URL(string: "https://theos.dev/docs/installation")!
    public static let officialRepositoryURL = "https://github.com/theos/theos.git"
    public static var managedRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Mac小助手/Toolchains/theos")
    }

    public static func inspect(
        preferredRoot: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> TheosEnvironmentSnapshot {
        let root = findRoot(preferredRoot: preferredRoot, environment: environment, homeDirectory: homeDirectory)
        let fm = FileManager.default
        let hasNIC = root.map { fm.fileExists(atPath: $0.appendingPathComponent("bin/nic.pl").path) } ?? false
        let hasTemplates = root.map { fm.fileExists(atPath: $0.appendingPathComponent("templates").path) } ?? false
        let bundledSDKs = (root.flatMap {
            try? fm.contentsOfDirectory(atPath: $0.appendingPathComponent("sdks").path)
        } ?? []).filter { $0.hasPrefix("iPhoneOS") && $0.hasSuffix(".sdk") }
        let xcodeSDK = (try? ExternalTool.xcrun.run(["--sdk", "iphoneos", "--show-sdk-path"]))?.succeeded == true
        return TheosEnvironmentSnapshot(
            root: root,
            hasNIC: hasNIC,
            hasTemplates: hasTemplates,
            availableSDKs: bundledSDKs.sorted() + (xcodeSDK ? ["Xcode iPhoneOS.sdk"] : []),
            hasMake: Shell.which("make") != nil,
            hasGit: Shell.which("git") != nil,
            hasPerl: Shell.which("perl") != nil,
            hasXcodeTools: ExternalTool.xcrun.isAvailable,
            hasDpkgDeb: ExternalTool.dpkgDeb.isAvailable,
            hasLdid: ExternalTool.ldid.isAvailable
        )
    }

    /// 返回固定 argv 的安装/更新计划，供 UI 在执行前展示。
    public static func managedCommands(root: URL = managedRoot) throws -> [InstallCommand] {
        guard let git = Shell.which("git") else { throw TheosManagedError.gitMissing }
        let fm = FileManager.default
        if fm.fileExists(atPath: root.path) {
            guard fm.fileExists(atPath: root.appendingPathComponent(".git").path) else {
                throw TheosManagedError.occupiedPath(root.path)
            }
            return [
                InstallCommand(
                    executable: git,
                    arguments: ["-C", root.path, "pull", "--ff-only"],
                    preview: "\(EnvironmentInstaller.shellQuote(git)) -C \(EnvironmentInstaller.shellQuote(root.path)) pull --ff-only"
                ),
                InstallCommand(
                    executable: git,
                    arguments: ["-C", root.path, "submodule", "update", "--init", "--recursive"],
                    preview: "\(EnvironmentInstaller.shellQuote(git)) -C \(EnvironmentInstaller.shellQuote(root.path)) submodule update --init --recursive"
                )
            ]
        }
        return [
            InstallCommand(
                executable: git,
                arguments: ["clone", "--recursive", officialRepositoryURL, root.path],
                preview: "\(EnvironmentInstaller.shellQuote(git)) clone --recursive \(EnvironmentInstaller.shellQuote(officialRepositoryURL)) \(EnvironmentInstaller.shellQuote(root.path))"
            )
        ]
    }

    @discardableResult
    public static func installOrUpdateManagedCopy(root: URL = managedRoot) throws -> [CommandResult] {
        let commands = try managedCommands(root: root)
        if !FileManager.default.fileExists(atPath: root.path) {
            try FileManager.default.createDirectory(
                at: root.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        }
        return try commands.map { command in
            let result = try Shell.run(command.executable, command.arguments)
            guard result.succeeded else { throw EnvironmentInstallError.commandFailed(result.combinedOutput) }
            return result
        }
    }

    private static func findRoot(
        preferredRoot: URL?,
        environment: [String: String],
        homeDirectory: URL
    ) -> URL? {
        let candidates = [
            preferredRoot,
            environment["THEOS"].map(URL.init(fileURLWithPath:)),
            managedRoot,
            homeDirectory.appendingPathComponent("theos"),
            URL(fileURLWithPath: "/opt/theos")
        ].compactMap { $0 }
        let fm = FileManager.default
        return candidates.first { fm.fileExists(atPath: $0.appendingPathComponent("makefiles").path) }
    }
}
