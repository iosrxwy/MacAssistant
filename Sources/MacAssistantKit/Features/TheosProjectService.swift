import Foundation

public struct TheosBuildResult: Sendable {
    public let command: String
    public let log: String
    public let package: URL
}

public struct TheosTweakTemplateRequest: Sendable {
    public var name: String
    public var packageID: String
    public var author: String
    public var description: String
    public var targetBundleID: String
    public var minimumIOS: String
    public var layout: DebPackageLayout

    public init(
        name: String,
        packageID: String,
        author: String,
        description: String,
        targetBundleID: String,
        minimumIOS: String,
        layout: DebPackageLayout
    ) {
        self.name = name
        self.packageID = packageID
        self.author = author
        self.description = description
        self.targetBundleID = targetBundleID
        self.minimumIOS = minimumIOS
        self.layout = layout
    }
}

public enum TheosProjectError: LocalizedError {
    case invalidProject
    case fileOutsideProject
    case fileTooLarge
    case makeMissing
    case buildFailed(String)
    case packageMissing
    case missingBuildTool(String)
    case invalidTemplateField(String)
    case templateFileExists(String)

    public var errorDescription: String? {
        switch self {
        case .invalidProject: return "所选目录缺少 Theos Makefile"
        case .fileOutsideProject: return "文件不在所选 Theos 项目中"
        case .fileTooLarge: return "源码文件超过 2 MB 编辑上限"
        case .makeMissing: return "缺少 make"
        case let .buildFailed(log): return "Theos 构建失败：\n\(log)"
        case .packageMissing: return "构建结束后未发现本次生成的 packages/*.deb"
        case let .missingBuildTool(tool): return "Theos 构建依赖缺失：\(tool)；请在环境检测页安装后重试"
        case let .invalidTemplateField(field): return "项目字段格式有误：\(field)"
        case let .templateFileExists(path): return "基础文件已存在：\(path)"
        }
    }
}

public enum TheosProjectService {
    private static let editableExtensions: Set<String> = [
        "xm", "x", "m", "mm", "h", "swift", "plist", "strings", "json", "yaml", "yml"
    ]
    private static let editableNames: Set<String> = ["Makefile", "control"]

    @discardableResult
    public static func createTweakProject(
        in directory: URL,
        request: TheosTweakTemplateRequest
    ) throws -> [URL] {
        let name = request.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let packageID = request.packageID.trimmingCharacters(in: .whitespacesAndNewlines)
        let bundleID = request.targetBundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        let targetName = name.filter { $0.isLetter || $0.isNumber || $0 == "_" }
        guard !name.isEmpty, let first = targetName.first, first.isLetter || first == "_" else {
            throw TheosProjectError.invalidTemplateField("名称")
        }
        guard packageID.range(of: #"^[a-z0-9][a-z0-9.+-]+$"#, options: .regularExpression) != nil else {
            throw TheosProjectError.invalidTemplateField("Package ID")
        }
        guard !bundleID.isEmpty else { throw TheosProjectError.invalidTemplateField("目标 Bundle ID") }
        guard request.minimumIOS.range(of: #"^\d+(\.\d+){1,2}$"#, options: .regularExpression) != nil else {
            throw TheosProjectError.invalidTemplateField("最低 iOS")
        }

        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let filterName = "\(targetName).plist"
        let destinations = ["Makefile", "control", "Tweak.xm", filterName].map(directory.appendingPathComponent)
        if let existing = destinations.first(where: { fm.fileExists(atPath: $0.path) }) {
            throw TheosProjectError.templateFileExists(existing.path)
        }

        let scheme: String
        switch request.layout {
        case .rootful: scheme = ""
        case .rootless: scheme = "THEOS_PACKAGE_SCHEME = rootless\n"
        case .roothide: scheme = "THEOS_PACKAGE_SCHEME = roothide\n"
        }
        let archs = request.layout == .roothide ? "arm64e" : "arm64 arm64e"
        let makefile = """
        ARCHS = \(archs)
        TARGET = iphone:clang:latest:\(request.minimumIOS)
        \(scheme)include $(THEOS)/makefiles/common.mk

        TWEAK_NAME = \(targetName)
        \(targetName)_FILES = Tweak.xm
        \(targetName)_CFLAGS = -fobjc-arc

        include $(THEOS_MAKE_PATH)/tweak.mk
        """ + "\n"
        let control = """
        Package: \(packageID)
        Name: \(name)
        Version: 1.0.0
        Architecture: \(request.layout.defaultArchitecture)
        Description: \(request.description.trimmingCharacters(in: .whitespacesAndNewlines))
        Maintainer: \(request.author.trimmingCharacters(in: .whitespacesAndNewlines))
        Author: \(request.author.trimmingCharacters(in: .whitespacesAndNewlines))
        Section: Tweaks
        Depends: mobilesubstrate
        """ + "\n"
        let tweak = """
        #import <UIKit/UIKit.h>

        %hook SpringBoard

        - (void)applicationDidFinishLaunching:(id)application {
            %orig;
            // 在这里编写 tweak 逻辑
        }

        %end
        """ + "\n"
        try makefile.write(to: destinations[0], atomically: true, encoding: .utf8)
        try control.write(to: destinations[1], atomically: true, encoding: .utf8)
        try tweak.write(to: destinations[2], atomically: true, encoding: .utf8)
        let filter = try PropertyListSerialization.data(
            fromPropertyList: ["Filter": ["Bundles": [bundleID]]],
            format: .xml,
            options: 0
        )
        try filter.write(to: destinations[3], options: .atomic)
        return try editableFiles(in: directory)
    }

    public static func editableFiles(in project: URL) throws -> [URL] {
        guard FileManager.default.fileExists(atPath: project.appendingPathComponent("Makefile").path) else {
            throw TheosProjectError.invalidProject
        }
        guard let enumerator = FileManager.default.enumerator(
            at: project,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var files: [URL] = []
        let rootPath = project.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        for case let file as URL in enumerator {
            let resolvedPath = file.resolvingSymlinksInPath().standardizedFileURL.path
            guard resolvedPath.hasPrefix(rootPath) else { continue }
            let relative = String(resolvedPath.dropFirst(rootPath.count))
            if let first = relative.split(separator: "/").first,
               [".theos", "packages", ".git"].contains(String(first)) {
                if !relative.contains("/") { enumerator.skipDescendants() }
                continue
            }
            let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values?.isRegularFile == true, (values?.fileSize ?? 0) <= 2 * 1024 * 1024 else { continue }
            if editableNames.contains(file.lastPathComponent)
                || editableExtensions.contains(file.pathExtension.lowercased()) {
                files.append(file)
            }
        }
        return files.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    public static func read(_ file: URL, in project: URL) throws -> String {
        try validate(file, in: project)
        let size = (try file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= 2 * 1024 * 1024 else { throw TheosProjectError.fileTooLarge }
        return try String(contentsOf: file, encoding: .utf8)
    }

    public static func save(_ text: String, to file: URL, in project: URL) throws {
        try validate(file, in: project)
        try text.write(to: file, atomically: true, encoding: .utf8)
    }

    public static func build(
        project: URL,
        theosRoot: URL,
        layout: DebPackageLayout = .rootless,
        clean: Bool = false
    ) throws -> TheosBuildResult {
        guard FileManager.default.fileExists(atPath: project.appendingPathComponent("Makefile").path) else {
            throw TheosProjectError.invalidProject
        }
        guard let make = Shell.which("make") else { throw TheosProjectError.makeMissing }
        guard let ldid = ExternalTool.ldid.path else { throw TheosProjectError.missingBuildTool("ldid") }
        guard let dpkgDeb = ExternalTool.dpkgDeb.path else { throw TheosProjectError.missingBuildTool("dpkg-deb") }
        let before = packageModificationDates(in: project)
        let environment = buildEnvironment(
            theosRoot: theosRoot,
            ldidPath: ldid,
            dpkgDebPath: dpkgDeb,
            base: ProcessInfo.processInfo.environment
        )
        let commands = makeArgumentGroups(clean: clean, layout: layout)
        var logs: [String] = []
        for arguments in commands {
            let result = try Shell.run(
                make,
                arguments,
                currentDirectory: project,
                environment: environment
            )
            logs.append(result.combinedOutput)
            guard result.succeeded else {
                throw TheosProjectError.buildFailed(strippingANSI(logs.joined(separator: "\n")))
            }
        }
        let cleanLog = strippingANSI(logs.joined(separator: "\n"))
        let after = packageModificationDates(in: project)
        let changed = after.filter { before[$0.key] != $0.value }
            .map(\.key)
            .sorted { (after[$0] ?? .distantPast) > (after[$1] ?? .distantPast) }
        guard let package = changed.first else { throw TheosProjectError.packageMissing }
        let preview = commands.map {
            ([make] + $0).map(EnvironmentInstaller.shellQuote).joined(separator: " ")
        }.joined(separator: " && ")
        return TheosBuildResult(command: preview, log: cleanLog, package: package)
    }

    static func makeArgumentGroups(clean: Bool, layout: DebPackageLayout = .rootless) -> [[String]] {
        let profile: [String]
        switch layout {
        case .rootful: profile = []
        case .rootless: profile = ["THEOS_PACKAGE_SCHEME=rootless", "SCHEME=rootless"]
        case .roothide: profile = ["THEOS_PACKAGE_SCHEME=roothide", "SCHEME=roothide"]
        }
        let package = ["package"] + profile
        return clean ? [["clean"], package] : [package]
    }

    static func buildEnvironment(
        theosRoot: URL,
        ldidPath: String,
        dpkgDebPath: String,
        base: [String: String]
    ) -> [String: String] {
        var environment = base
        environment["THEOS"] = theosRoot.path
        environment["TARGET_CODESIGN"] = ldidPath
        let original = base["PATH"]?.split(separator: ":").map(String.init) ?? []
        let preferred = [
            URL(fileURLWithPath: ldidPath).deletingLastPathComponent().path,
            URL(fileURLWithPath: dpkgDebPath).deletingLastPathComponent().path,
            theosRoot.appendingPathComponent("bin").path,
            "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"
        ]
        var seen = Set<String>()
        environment["PATH"] = (preferred + original)
            .filter { seen.insert($0).inserted }
            .joined(separator: ":")
        return environment
    }

    static func strippingANSI(_ text: String) -> String {
        text.replacingOccurrences(
            of: "\u{001B}\\[[0-?]*[ -/]*[@-~]",
            with: "",
            options: .regularExpression
        )
    }

    private static func validate(_ file: URL, in project: URL) throws {
        let root = project.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        let candidate = file.resolvingSymlinksInPath().standardizedFileURL.path
        guard candidate.hasPrefix(root) else {
            throw TheosProjectError.fileOutsideProject
        }
    }

    private static func packageModificationDates(in project: URL) -> [URL: Date] {
        let packages = project.appendingPathComponent("packages")
        let files = (try? FileManager.default.contentsOfDirectory(
            at: packages,
            includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []
        return Dictionary(uniqueKeysWithValues: files.compactMap { file in
            guard file.pathExtension.lowercased() == "deb" else { return nil }
            let date = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            return date.map { (file, $0) }
        })
    }
}
