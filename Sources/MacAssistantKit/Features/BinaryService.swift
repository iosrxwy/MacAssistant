import Foundation

/// 二进制/架构/签名相关操作,基于 lipo、otool、file、codesign、ldid。
public enum BinaryService {

    // MARK: 架构

    public static func architectures(fileAt url: URL) throws -> [String] {
        let result = try ExternalTool.lipo.run(["-archs", url.path])
        if result.succeeded {
            return result.trimmedOutput.split(separator: " ").map(String.init)
        }
        // 非胖二进制时 lipo -archs 也能工作;失败则回退到 file 输出。
        return []
    }

    public static func detailedInfo(fileAt url: URL) throws -> String {
        try ExternalTool.lipo.run(["-detailed_info", url.path]).combinedOutput
    }

    /// 从胖二进制中抽取指定架构。
    @discardableResult
    public static func thin(fileAt url: URL, arch: String, to output: URL) throws -> CommandResult {
        try ExternalTool.lipo.run([url.path, "-thin", arch, "-output", output.path])
    }

    /// 合并多个瘦二进制为一个胖二进制。
    @discardableResult
    public static func createFat(from inputs: [URL], to output: URL) throws -> CommandResult {
        try ExternalTool.lipo.run(inputs.map(\.path) + ["-create", "-output", output.path])
    }

    // MARK: 头信息 / 文件类型

    public static func fileType(fileAt url: URL) throws -> String {
        try ExternalTool.file.run([url.path]).trimmedOutput
    }

    public static func machHeader(fileAt url: URL) throws -> String {
        try ExternalTool.otool.run(["-h", "-v", url.path]).combinedOutput
    }

    public static func loadCommands(fileAt url: URL) throws -> String {
        try ExternalTool.otool.run(["-l", url.path]).combinedOutput
    }

    // MARK: 代码签名

    public static func codesignInfo(fileAt url: URL) throws -> String {
        try ExternalTool.codesign.run(["-dv", "--verbose=4", url.path]).combinedOutput
    }

    @discardableResult
    public static func codesignVerify(fileAt url: URL) throws -> CommandResult {
        try ExternalTool.codesign.run(["--verify", "--verbose=2", url.path])
    }

    /// 使用 codesign 进行 ad-hoc 签名(签名标识为 `-`)。
    @discardableResult
    public static func adhocSign(fileAt url: URL, force: Bool = true,
                                 entitlements: URL? = nil) throws -> CommandResult {
        var args: [String] = []
        if force { args.append("-f") }
        if let entitlements { args.append(contentsOf: ["--entitlements", entitlements.path]) }
        args.append(contentsOf: ["-s", "-", url.path])
        return try ExternalTool.codesign.run(args)
    }

    /// 移除已有代码签名(注入前常需先去签名)。
    @discardableResult
    public static func removeSignature(fileAt url: URL) throws -> CommandResult {
        try ExternalTool.codesign.run(["--remove-signature", url.path])
    }

    /// 使用 ldid 伪签名(常用于越狱环境)。
    @discardableResult
    public static func ldidSign(fileAt url: URL, entitlements: URL? = nil) throws -> CommandResult {
        var args: [String]
        if let entitlements {
            args = ["-S\(entitlements.path)", url.path]
        } else {
            args = ["-S", url.path]
        }
        return try ExternalTool.ldid.run(args)
    }
}
