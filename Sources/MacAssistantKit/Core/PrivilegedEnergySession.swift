import Darwin
import Foundation

/// 快捷导航里的能耗模式。`pmset` 必须由 root 执行，系统授权框每次 `osascript` 都会再问一次。
/// 这里只在第一次切换时拉起一个常驻 root 辅助进程，之后切模式只往它的套接字写一行。
public final class PrivilegedEnergySession {
    public static let shared = PrivilegedEnergySession()

    public enum Outcome: Equatable {
        case applied
        case cancelled
        case failed
    }

    private let lock = NSLock()
    private var launcher: Process?
    private var client: Int32 = -1
    private var outputPipe: Pipe?
    private var errorPipe: Pipe?
    private var notes = ""

    private init() {}

    /// 改当前电源的能耗模式。0 自动，1 低电量，2 高电量。
    public func apply(onBattery: Bool, mode: Int) -> Outcome {
        lock.lock()
        defer { lock.unlock() }
        guard let line = Self.commandLine(onBattery: onBattery, mode: mode) else {
            return .failed
        }
        if !isReady {
            invalidate()
            switch openSession() {
            case .ready:
                break
            case .cancelled:
                return .cancelled
            case .failed:
                invalidate()
                return .failed
            }
        }
        drainPipes()
        guard client >= 0, PrivilegedEnergyIO.writeLine(client, line) else {
            invalidate()
            return .failed
        }
        do {
            switch try PrivilegedEnergyIO.readLine(client, timeout: 20) {
            case "ok":
                return .applied
            case "no":
                return .failed
            default:
                invalidate()
                return .failed
            }
        } catch {
            invalidate()
            return .failed
        }
    }

    /// 退出应用时关掉 root 辅助进程，避免它留在后台。
    public func stop() {
        lock.lock()
        defer { lock.unlock() }
        invalidate()
    }

    /// 和 `MacAssistantEnergyHelper` 里的 `strcmp` 是同一组指令。改文案时两边一起改。
    static func commandLine(onBattery: Bool, mode: Int) -> String? {
        let flag = onBattery ? "-b" : "-c"
        let line = "\(flag) \(mode)"
        let arguments = [flag, "powermode", String(mode)]
        guard AdminRunner.isAllowedPmsetInvocation(arguments) else { return nil }
        return line
    }

    static func launchShellCommand(helper: String, socketPath: String) -> String? {
        guard helper.hasPrefix("/"), socketPath.hasPrefix("/"),
              !helper.contains("\n"), !socketPath.contains("\n"),
              !helper.contains("\0"), !socketPath.contains("\0")
        else { return nil }
        return [
            "/usr/bin/env",
            "-i",
            "PATH=/usr/bin:/bin:/usr/sbin:/sbin",
            helper,
            socketPath
        ].map(AdminRunner.shellQuote).joined(separator: " ")
    }

    static func helperPath() -> String? {
        guard let executable = Bundle.main.executableURL else { return nil }
        let name = "MacAssistantEnergyHelper"
        let helpers = executable
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Helpers")
            .appendingPathComponent(name)
        let sibling = executable
            .deletingLastPathComponent()
            .appendingPathComponent(name)
        let files = FileManager.default
        for url in [helpers, sibling] where files.isExecutableFile(atPath: url.path) {
            return url.path
        }
        return nil
    }

    private var isReady: Bool {
        client >= 0 && launcher?.isRunning == true
    }

    private enum Start {
        case ready
        case cancelled
        case failed
    }

    private func openSession() -> Start {
        guard let helper = Self.helperPath(),
              let listener = PrivilegedEnergyIO.makeListener()
        else { return .failed }
        defer { PrivilegedEnergyIO.closeListener(listener) }
        guard let command = Self.launchShellCommand(helper: helper, socketPath: listener.socketPath) else {
            return .failed
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", AdminRunner.makeScript(for: command, prompt: L("energy.auth.once"))]
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        PrivilegedEnergyIO.setNonblocking(output)
        PrivilegedEnergyIO.setNonblocking(errors)
        outputPipe = output
        errorPipe = errors
        do {
            try process.run()
        } catch {
            return .failed
        }
        launcher = process

        let deadline = Date().addingTimeInterval(180)
        while true {
            drainPipes()
            if !process.isRunning {
                drainPipes()
                let text = notes
                if AdminRunner.isCancelled(CommandResult(exitCode: process.terminationStatus, stdout: text, stderr: text)) {
                    return .cancelled
                }
                return .failed
            }
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 {
                process.terminate()
                return .failed
            }
            do {
                let fd = try PrivilegedEnergyIO.acceptOne(listener.fd, timeout: min(0.2, remaining))
                if PrivilegedEnergyIO.isRootPeer(fd) {
                    client = fd
                    return .ready
                }
                Darwin.close(fd)
            } catch EnergyPipeError.timeout {
                continue
            } catch {
                process.terminate()
                return .failed
            }
        }
    }

    private func invalidate() {
        let fd = client
        client = -1
        if fd >= 0 {
            Darwin.close(fd)
        }
        if let launcher, launcher.isRunning {
            launcher.terminate()
        }
        launcher = nil
        drainPipes()
        outputPipe = nil
        errorPipe = nil
        notes = ""
    }

    private func drainPipes() {
        if let outputPipe {
            notes += PrivilegedEnergyIO.drain(outputPipe)
        }
        if let errorPipe {
            notes += PrivilegedEnergyIO.drain(errorPipe)
        }
        if notes.count > 4000 {
            notes = String(notes.suffix(2000))
        }
    }
}

enum EnergyPipeError: Error {
    case timeout
    case failed
    case eof
}

enum PrivilegedEnergyIO {
    struct Listener {
        var fd: Int32
        var directory: String
        var socketPath: String
    }

    static func makeListener() -> Listener? {
        guard let directory = makeDirectory() else { return nil }
        let socketPath = directory + "/s"
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            removeDirectory(directory)
            return nil
        }
        guard configure(fd), bindUnix(fd, socketPath), Darwin.listen(fd, 8) == 0 else {
            Darwin.close(fd)
            unlinkPath(socketPath)
            removeDirectory(directory)
            return nil
        }
        _ = socketPath.withCString { chmod($0, mode_t(0o600)) }
        return Listener(fd: fd, directory: directory, socketPath: socketPath)
    }

    static func closeListener(_ listener: Listener) {
        if listener.fd >= 0 {
            Darwin.close(listener.fd)
        }
        unlinkPath(listener.socketPath)
        removeDirectory(listener.directory)
    }

    static func connect(_ path: String) -> Int32 {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return -1 }
        guard configure(fd), varAddress(path, connect: fd) else {
            Darwin.close(fd)
            return -1
        }
        return fd
    }

    static func acceptOne(_ listener: Int32, timeout: TimeInterval) throws -> Int32 {
        var item = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
        let milliseconds = Int32((timeout * 1000).rounded(.up))
        while true {
            let ready = poll(&item, 1, max(milliseconds, 0))
            if ready == 0 { throw EnergyPipeError.timeout }
            if ready < 0 {
                if errno == EINTR { continue }
                throw EnergyPipeError.failed
            }
            let fd = Darwin.accept(listener, nil, nil)
            if fd < 0 {
                if errno == EINTR { continue }
                throw EnergyPipeError.failed
            }
            if !configure(fd) {
                Darwin.close(fd)
                throw EnergyPipeError.failed
            }
            return fd
        }
    }

    static func isRootPeer(_ fd: Int32) -> Bool {
        var uid: uid_t = 1
        var gid: gid_t = 1
        return getpeereid(fd, &uid, &gid) == 0 && uid == 0
    }

    static func writeLine(_ fd: Int32, _ line: String) -> Bool {
        let bytes = Array(line.utf8) + [UInt8(10)]
        var sent = 0
        while sent < bytes.count {
            let count = bytes.withUnsafeBytes { buffer -> Int in
                guard let base = buffer.baseAddress else { return -1 }
                return Darwin.write(fd, base.advanced(by: sent), bytes.count - sent)
            }
            if count < 0 {
                if errno == EINTR { continue }
                return false
            }
            if count == 0 { return false }
            sent += count
        }
        return true
    }

    static func readLine(_ fd: Int32, timeout: TimeInterval?) throws -> String {
        var data = Data()
        let deadline = timeout.map { Date().addingTimeInterval($0) }
        while data.count <= 32 {
            if let deadline {
                let left = deadline.timeIntervalSinceNow
                if left <= 0 { throw EnergyPipeError.timeout }
                var item = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                let ready = poll(&item, 1, Int32((left * 1000).rounded(.up)))
                if ready == 0 { throw EnergyPipeError.timeout }
                if ready < 0 {
                    if errno == EINTR { continue }
                    throw EnergyPipeError.failed
                }
            }
            var byte: UInt8 = 0
            let count = Darwin.read(fd, &byte, 1)
            if count == 0 { throw EnergyPipeError.eof }
            if count < 0 {
                if errno == EINTR { continue }
                throw EnergyPipeError.failed
            }
            if byte == 10 {
                return String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            }
            if byte != 13 {
                data.append(byte)
            }
        }
        throw EnergyPipeError.failed
    }

    static func setNonblocking(_ pipe: Pipe) {
        let fd = pipe.fileHandleForReading.fileDescriptor
        let flags = fcntl(fd, F_GETFL)
        if flags >= 0 {
            _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        }
    }

    static func drain(_ pipe: Pipe) -> String {
        let fd = pipe.fileHandleForReading.fileDescriptor
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 512)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count > 0 {
                data.append(contentsOf: buffer.prefix(count))
                continue
            }
            if count < 0 && errno == EINTR { continue }
            break
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    private static func configure(_ fd: Int32) -> Bool {
        var nosigpipe: Int32 = 1
        let flags = fcntl(fd, F_GETFD)
        guard flags >= 0, fcntl(fd, F_SETFD, flags | FD_CLOEXEC) >= 0 else { return false }
        return setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &nosigpipe, socklen_t(MemoryLayout.size(ofValue: nosigpipe))) == 0
    }

    private static func makeDirectory() -> String? {
        let bases = [FileManager.default.temporaryDirectory.path, "/tmp"]
        for base in bases {
            let template = base + "/macassistant-energy.XXXXXX"
            guard template.utf8.count < 80 else { continue }
            var buffer = Array(template.utf8CString)
            let created = buffer.withUnsafeMutableBufferPointer { pointer -> Bool in
                guard let address = pointer.baseAddress else { return false }
                return mkdtemp(address) != nil
            }
            guard created else { continue }
            let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
            let path = String(decoding: bytes, as: UTF8.self)
            if !path.isEmpty { return path }
        }
        return nil
    }

    private static func bindUnix(_ fd: Int32, _ path: String) -> Bool {
        varAddress(path, bind: fd)
    }

    private static func varAddress(_ path: String, bind fd: Int32) -> Bool {
        var addr = sockaddr_un()
        guard fill(&addr, path) else { return false }
        return withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.bind(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
            }
        }
    }

    private static func varAddress(_ path: String, connect fd: Int32) -> Bool {
        var addr = sockaddr_un()
        guard fill(&addr, path) else { return false }
        return withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.connect(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
            }
        }
    }

    private static func fill(_ addr: inout sockaddr_un, _ path: String) -> Bool {
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { return false }
        addr.sun_family = sa_family_t(AF_UNIX)
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutablePointer(to: &addr.sun_path) { raw in
            raw.withMemoryRebound(to: UInt8.self, capacity: bytes.count + 1) { destination in
                for (index, byte) in bytes.enumerated() {
                    destination[index] = byte
                }
                destination[bytes.count] = 0
            }
        }
        return true
    }

    private static func unlinkPath(_ path: String) {
        _ = path.withCString { unlink($0) }
    }

    private static func removeDirectory(_ path: String) {
        _ = path.withCString { rmdir($0) }
    }
}
