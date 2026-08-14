import Foundation

public enum ToolInstallStrategy: Equatable, Sendable {
    case homebrewFormula(String)
    case xcodeCommandLineTools
    case systemProvided
    case openProjectPage(URL)
    case builtInFallback(description: String, projectURL: URL?)
}

public struct InstallCommand: Equatable, Sendable {
    public let executable: String
    public let arguments: [String]
    public let preview: String

    public init(executable: String, arguments: [String], preview: String) {
        self.executable = executable
        self.arguments = arguments
        self.preview = preview
    }
}

public enum EnvironmentInstallError: LocalizedError {
    case invalidFormula
    case homebrewMissing
    case noCommand
    case commandFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidFormula: return L("tool.error.invalidFormula")
        case .homebrewMissing: return L("tool.error.homebrewMissing")
        case .noCommand: return L("tool.error.noAutomaticInstall")
        case let .commandFailed(output): return L("tool.error.installFailed", output)
        }
    }
}

public enum EnvironmentInstaller {
    public static let allowedFormulae: Set<String> = ["dpkg", "ldid", "zsign"]
    public static let homebrewInstructionsURL = URL(string: "https://brew.sh/")!

    public static func makeCommand(
        for strategy: ToolInstallStrategy,
        brewPath: String? = ExternalTool.brew.path
    ) throws -> InstallCommand {
        switch strategy {
        case let .homebrewFormula(formula):
            guard allowedFormulae.contains(formula) else {
                throw EnvironmentInstallError.invalidFormula
            }
            guard let brewPath else { throw EnvironmentInstallError.homebrewMissing }
            guard brewPath.hasPrefix("/"), URL(fileURLWithPath: brewPath).lastPathComponent == "brew" else {
                throw EnvironmentInstallError.homebrewMissing
            }
            return InstallCommand(
                executable: brewPath,
                arguments: ["install", formula],
                preview: "\(shellQuote(brewPath)) install \(shellQuote(formula))"
            )
        case .xcodeCommandLineTools:
            return InstallCommand(
                executable: "/usr/bin/xcode-select",
                arguments: ["--install"],
                preview: "/usr/bin/xcode-select --install"
            )
        case .systemProvided, .openProjectPage, .builtInFallback:
            throw EnvironmentInstallError.noCommand
        }
    }

    public static func homebrewGuidance(macOSMajorVersion: Int) -> String {
        if macOSMajorVersion <= 13 {
            return L("tool.homebrew.guidance.legacy")
        }
        return L("tool.homebrew.guidance.current")
    }

    @discardableResult
    public static func run(_ command: InstallCommand) throws -> CommandResult {
        let result = try Shell.run(command.executable, command.arguments)
        guard result.succeeded else {
            throw EnvironmentInstallError.commandFailed(result.combinedOutput)
        }
        return result
    }

    public static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

}

/// 项目依赖的外部命令行工具。集中管理路径解析与可用性检查。
public enum ExternalTool: String, CaseIterable, Sendable {
    case brew        // Homebrew 包管理器
    case ar          // /usr/bin/ar          解包 .deb(ar 归档)
    case tar         // /usr/bin/tar         解/打包 tarball
    case dpkgDeb     // dpkg-deb             deb 的解包/打包(Homebrew)
    case otool       // /usr/bin/otool       查看 Mach-O 依赖/头
    case lipo        // /usr/bin/lipo        胖二进制拆分/合并
    case installNameTool // /usr/bin/install_name_tool  修改 dylib 路径
    case codesign    // /usr/bin/codesign    代码签名
    case ldid        // ldid                 伪签名(Homebrew)
    case zip         // /usr/bin/zip
    case unzip       // /usr/bin/unzip
    case file        // /usr/bin/file        文件类型探测
    case xcrun       // /usr/bin/xcrun
    case swiftc      // 编译器(测试用)
    case clang       // 编译器(测试用)
    case strip       // /usr/bin/strip       瘦身去符号
    case security    // /usr/bin/security    列签名身份 / 解 mobileprovision
    case plistBuddy  // /usr/libexec/PlistBuddy  取 entitlements / 改 bundle id
    case vtool       // /usr/bin/vtool       去架构后修平台标记(可选)
    case ditto       // /usr/bin/ditto       保留软链的干净打包
    case classDump   // class-dump           导出 ObjC 头文件(需安装)
    case dsdump      // dsdump               ObjC/Swift 符号与类型(需安装)
    case zsign       // zsign                一步注入+重签(可选)

    /// 命令名(用于 which 查找)。
    public var commandName: String {
        switch self {
        case .brew: return "brew"
        case .dpkgDeb: return "dpkg-deb"
        case .installNameTool: return "install_name_tool"
        case .plistBuddy: return "PlistBuddy"
        case .classDump: return "class-dump"
        default: return rawValue
        }
    }

    /// 优先尝试的固定路径,提高解析速度与稳定性。
    var preferredPaths: [String] {
        switch self {
        case .brew: return HostArchitecture.homebrewBinaryPaths("brew")
        case .ar: return ["/usr/bin/ar"]
        case .tar: return ["/usr/bin/tar"]
        case .dpkgDeb: return HostArchitecture.homebrewBinaryPaths("dpkg-deb")
        case .otool: return ["/usr/bin/otool"]
        case .lipo: return ["/usr/bin/lipo"]
        case .installNameTool: return ["/usr/bin/install_name_tool"]
        case .codesign: return ["/usr/bin/codesign"]
        case .ldid: return HostArchitecture.homebrewBinaryPaths("ldid")
        case .zip: return ["/usr/bin/zip"]
        case .unzip: return ["/usr/bin/unzip"]
        case .file: return ["/usr/bin/file"]
        case .xcrun: return ["/usr/bin/xcrun"]
        case .swiftc: return ["/usr/bin/swiftc"]
        case .clang: return ["/usr/bin/clang"]
        case .strip: return ["/usr/bin/strip"]
        case .security: return ["/usr/bin/security"]
        case .plistBuddy: return ["/usr/libexec/PlistBuddy"]
        case .vtool: return ["/usr/bin/vtool"]
        case .ditto: return ["/usr/bin/ditto"]
        case .classDump: return HostArchitecture.homebrewBinaryPaths("class-dump")
        case .dsdump: return HostArchitecture.homebrewBinaryPaths("dsdump")
        case .zsign: return HostArchitecture.homebrewBinaryPaths("zsign")
        }
    }

    /// 解析工具的绝对路径。
    public var path: String? {
        for candidate in preferredPaths where FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }
        return Shell.which(commandName)
    }

    public var isAvailable: Bool { path != nil }

    public var installStrategy: ToolInstallStrategy {
        switch self {
        case .brew:
            return .openProjectPage(EnvironmentInstaller.homebrewInstructionsURL)
        case .dpkgDeb:
            return .homebrewFormula("dpkg")
        case .ldid:
            return .homebrewFormula("ldid")
        case .zsign:
            return .homebrewFormula("zsign")
        case .classDump:
            return .builtInFallback(
                description: L("tool.classDump.builtInFallback"),
                projectURL: URL(string: "https://github.com/nygard/class-dump")
            )
        case .dsdump:
            return .builtInFallback(
                description: L("tool.dsdump.builtInFallback"),
                projectURL: URL(string: "https://github.com/DerekSelander/dsdump")
            )
        case .otool, .lipo, .installNameTool, .xcrun, .swiftc, .clang, .strip, .vtool:
            return .xcodeCommandLineTools
        case .ar, .tar, .codesign, .zip, .unzip, .file, .security, .plistBuddy, .ditto:
            return .systemProvided
        }
    }

    /// 执行该工具。工具不存在时抛出 `ShellError.executableNotFound`。
    @discardableResult
    public func run(
        _ arguments: [String] = [],
        input: Data? = nil,
        currentDirectory: URL? = nil
    ) throws -> CommandResult {
        guard let path else { throw ShellError.executableNotFound(commandName) }
        return try Shell.run(path, arguments, input: input, currentDirectory: currentDirectory)
    }
}

/// 工具可用性快照,供 UI 展示环境检查结果。
public struct ToolAvailability: Identifiable, Sendable {
    public let tool: ExternalTool
    public let path: String?
    public let installStrategy: ToolInstallStrategy
    public var id: String { tool.rawValue }
    public var isAvailable: Bool { path != nil }
    public var installHint: String? {
        switch installStrategy {
        case let .homebrewFormula(formula): return "brew install \(formula)"
        case .xcodeCommandLineTools: return "xcode-select --install"
        case .systemProvided: return nil
        case .openProjectPage: return L("tool.installHint.openProjectPage")
        case let .builtInFallback(description, _): return description
        }
    }

    public init(tool: ExternalTool) {
        self.tool = tool
        self.path = tool.path
        self.installStrategy = tool.installStrategy
    }
}

public enum Environment {
    /// 返回全部工具的可用性快照。
    public static func toolAvailabilities() -> [ToolAvailability] {
        ExternalTool.allCases.map(ToolAvailability.init)
    }
}
