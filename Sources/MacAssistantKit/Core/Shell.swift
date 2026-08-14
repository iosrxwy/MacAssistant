import Foundation

/// 命令执行结果。
public struct CommandResult: Sendable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String

    public init(exitCode: Int32, stdout: String, stderr: String) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }

    public var succeeded: Bool { exitCode == 0 }

    /// stdout 去除首尾空白后的内容。
    public var trimmedOutput: String {
        stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 合并输出，优先 stdout，失败时补充 stderr，方便直接展示。
    public var combinedOutput: String {
        var text = stdout
        if !stderr.isEmpty {
            if !text.isEmpty { text += "\n" }
            text += stderr
        }
        return text
    }
}

/// 执行外部命令时抛出的错误。
public enum ShellError: LocalizedError {
    case launchFailed(path: String, underlying: String)
    case executableNotFound(String)

    public var errorDescription: String? {
        switch self {
        case let .launchFailed(path, underlying):
            return L("shell.error.launchFailed", path, underlying)
        case let .executableNotFound(name):
            return L("shell.error.executableNotFound", name)
        }
    }
}

/// 封装 `Process`,提供同步执行命令并安全读取 stdout/stderr 的能力。
///
/// 使用后台队列并发读取两个管道,避免大输出时的管道死锁问题。
public enum Shell {

    /// 直接执行指定路径的可执行文件。
    @discardableResult
    public static func run(
        _ launchPath: String,
        _ arguments: [String] = [],
        input: Data? = nil,
        currentDirectory: URL? = nil,
        environment: [String: String]? = nil
    ) throws -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        if let currentDirectory {
            process.currentDirectoryURL = currentDirectory
        }
        if let environment {
            process.environment = environment
        }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let stdinPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        if input != nil {
            process.standardInput = stdinPipe
        }

        // 并发读取,防止管道缓冲区写满导致的死锁。
        var stdoutData = Data()
        var stderrData = Data()
        let group = DispatchGroup()
        let ioQueue = DispatchQueue(label: "shell.io", attributes: .concurrent)

        group.enter()
        ioQueue.async {
            stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        group.enter()
        ioQueue.async {
            stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }

        do {
            try process.run()
        } catch {
            throw ShellError.launchFailed(path: launchPath, underlying: error.localizedDescription)
        }

        if let input {
            stdinPipe.fileHandleForWriting.write(input)
            try? stdinPipe.fileHandleForWriting.close()
        }

        process.waitUntilExit()
        group.wait()

        return CommandResult(
            exitCode: process.terminationStatus,
            stdout: String(decoding: stdoutData, as: UTF8.self),
            stderr: String(decoding: stderrData, as: UTF8.self)
        )
    }

    /// 通过 `/usr/bin/env` 在 PATH 中查找并执行命令。
    @discardableResult
    public static func env(
        _ tool: String,
        _ arguments: [String] = [],
        input: Data? = nil,
        currentDirectory: URL? = nil
    ) throws -> CommandResult {
        try run("/usr/bin/env", [tool] + arguments, input: input, currentDirectory: currentDirectory)
    }

    /// 使用 `/bin/zsh -lc` 执行一段 shell 脚本文本。
    @discardableResult
    public static func script(
        _ command: String,
        currentDirectory: URL? = nil
    ) throws -> CommandResult {
        try run("/bin/zsh", ["-lc", command], currentDirectory: currentDirectory)
    }

    /// 在常见目录中查找工具的绝对路径,找不到返回 nil。
    public static func which(_ tool: String) -> String? {
        if let result = try? run("/usr/bin/which", [tool]), result.succeeded {
            let path = result.trimmedOutput
            if !path.isEmpty { return path }
        }
        let candidates = HostArchitecture.homebrewBinaryPaths(tool) + [
            "/usr/bin/\(tool)",
            "/bin/\(tool)"
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// 判断某个工具是否可用。
    public static func isAvailable(_ tool: String) -> Bool {
        which(tool) != nil
    }
}
