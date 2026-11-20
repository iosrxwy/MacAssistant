import Foundation
import Darwin
import Security

public struct ProcessOpenFile: Identifiable, Hashable, Sendable {
    public let path: String
    public var id: String { path }

    public init(path: String) {
        self.path = path
    }
}

public struct ProcessListenPort: Identifiable, Hashable, Sendable {
    public let transport: String
    public let address: String
    public let port: Int

    public var id: String { "\(transport) \(address):\(port)" }
    public var display: String { id }

    public init(transport: String, address: String, port: Int) {
        self.transport = transport
        self.address = address
        self.port = port
    }
}

public struct ProcessCodeSignature: Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable {
        case apple
        case developerID
        case adHoc
        case other
        case unsigned
        case unavailable
    }

    public let kind: Kind
    /// 读不到权利信息时为空，不把「不知道」写成未沙盒。
    public let teamID: String?
    public let authority: String?
    public let isSandboxed: Bool?
    /// 只看本地钉住的公证票据。Apple 与临时签名没有这项，保持空。
    public let hasNotarizationTicket: Bool?

    public init(
        kind: Kind,
        teamID: String?,
        authority: String?,
        isSandboxed: Bool?,
        hasNotarizationTicket: Bool?
    ) {
        self.kind = kind
        self.teamID = teamID
        self.authority = authority
        self.isSandboxed = isSandboxed
        self.hasNotarizationTicket = hasNotarizationTicket
    }
}

public struct ProcessInspection: Identifiable, Sendable {
    public let pid: Int32
    public let displayName: String
    public let userName: String
    public let parentPID: Int32
    public let parentName: String?
    public let startTime: Date?
    public let executablePath: String
    public let commandLine: String
    public let signature: ProcessCodeSignature
    public let listeningPorts: [ProcessListenPort]
    public let openFiles: [ProcessOpenFile]
    public let openFileCount: Int

    public var id: Int32 { pid }
    public var omittedFileCount: Int { max(0, openFileCount - openFiles.count) }

    public init(
        pid: Int32,
        displayName: String,
        userName: String,
        parentPID: Int32,
        parentName: String?,
        startTime: Date?,
        executablePath: String,
        commandLine: String,
        signature: ProcessCodeSignature,
        listeningPorts: [ProcessListenPort],
        openFiles: [ProcessOpenFile],
        openFileCount: Int
    ) {
        self.pid = pid
        self.displayName = displayName
        self.userName = userName
        self.parentPID = parentPID
        self.parentName = parentName
        self.startTime = startTime
        self.executablePath = executablePath
        self.commandLine = commandLine
        self.signature = signature
        self.listeningPorts = listeningPorts
        self.openFiles = openFiles
        self.openFileCount = openFileCount
    }
}

public enum ProcessSocketFormatting {
    /// `insi_lport` 是网络字节序。80 在小端机器上的原始 int 是 20480。
    public static func hostPort(fromNetworkOrder value: Int32) -> Int {
        Int(UInt16(truncatingIfNeeded: value).bigEndian)
    }

    public static func isListening(tcpState: Int32?, localPort: Int, remotePort: Int) -> Bool {
        guard localPort > 0, localPort < 65_536 else { return false }
        if let tcpState {
            return tcpState == TSI_S_LISTEN
        }
        return remotePort == 0
    }
}

public enum ProcessSignatureClassifier {
    public static let adHocFlag: UInt32 = 0x0002

    public static func kind(
        flags: UInt32,
        teamID: String?,
        authority: String?,
        appleAnchored: Bool
    ) -> ProcessCodeSignature.Kind {
        if flags & Self.adHocFlag != 0 { return .adHoc }
        if appleAnchored { return .apple }
        if authority?.contains("Developer ID Application") == true { return .developerID }
        if teamID?.isEmpty == false || authority?.isEmpty == false { return .other }
        return .unsigned
    }
}

public enum ProcessInspectionService {
    public static let maximumListedFiles = 120

    public static func inspect(
        _ process: ProcessMemoryInfo,
        among processes: [ProcessMemoryInfo]
    ) -> ProcessInspection {
        let arguments = ProcessArguments.read(pid: process.pid) ?? []
        let command = ProcessArguments.commandLine(arguments)
        let parentName = processes.first { $0.pid == process.parentPID }?.displayName
        let files = openFiles(pid: process.pid)
        return ProcessInspection(
            pid: process.pid,
            displayName: process.displayName,
            userName: userName(for: process.userID),
            parentPID: process.parentPID,
            parentName: parentName,
            startTime: process.startTime,
            executablePath: process.executablePath,
            commandLine: command.isEmpty ? process.executablePath : command,
            signature: signature(forExecutablePath: process.executablePath),
            listeningPorts: listeningPorts(pid: process.pid),
            openFiles: files.shown,
            openFileCount: files.total
        )
    }

    public static func userName(for uid: uid_t) -> String {
        var password = passwd()
        var buffer = [CChar](repeating: 0, count: 4096)
        var result: UnsafeMutablePointer<passwd>?
        let status = getpwuid_r(uid, &password, &buffer, buffer.count, &result)
        if status == 0, let name = result?.pointee.pw_name {
            let text = String(cString: name)
            if !text.isEmpty { return text }
        }
        return String(uid)
    }

    public static func signature(forExecutablePath path: String) -> ProcessCodeSignature {
        guard path.hasPrefix("/") else {
            return ProcessCodeSignature(
                kind: .unavailable,
                teamID: nil,
                authority: nil,
                isSandboxed: nil,
                hasNotarizationTicket: nil
            )
        }
        var staticCode: SecStaticCode?
        let created = SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &staticCode)
        guard created == errSecSuccess, let staticCode else {
            return ProcessCodeSignature(
                kind: .unavailable,
                teamID: nil,
                authority: nil,
                isSandboxed: nil,
                hasNotarizationTicket: nil
            )
        }

        var signingInfo: CFDictionary?
        // kSecCSNoNetworkAccess = 1 << 29. 部署目标上的 Swift 覆盖层没有导出这个名字。
        let signingFlags = SecCSFlags(rawValue: kSecCSSigningInformation | (1 << 29))
        var infoStatus = SecCodeCopySigningInformation(staticCode, signingFlags, &signingInfo)
        if infoStatus != errSecSuccess, infoStatus != errSecCSUnsigned {
            infoStatus = SecCodeCopySigningInformation(
                staticCode,
                SecCSFlags(rawValue: kSecCSSigningInformation),
                &signingInfo
            )
        }
        if infoStatus == errSecCSUnsigned {
            return ProcessCodeSignature(
                kind: .unsigned,
                teamID: nil,
                authority: nil,
                isSandboxed: nil,
                hasNotarizationTicket: nil
            )
        }
        guard infoStatus == errSecSuccess, let signingInfo else {
            return ProcessCodeSignature(
                kind: .unavailable,
                teamID: nil,
                authority: nil,
                isSandboxed: nil,
                hasNotarizationTicket: nil
            )
        }

        let dict = signingInfo as NSDictionary
        let flags = (dict[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0
        let team = nonEmpty(dict[kSecCodeInfoTeamIdentifier as String] as? String)
        let authority = certificateSummary(dict[kSecCodeInfoCertificates as String])
        let apple = requirementMatches(staticCode, "anchor apple")
        let kind = ProcessSignatureClassifier.kind(
            flags: flags,
            teamID: team,
            authority: authority,
            appleAnchored: apple
        )
        let ticket: Bool?
        switch kind {
        case .developerID, .other:
            ticket = hasStapledTicket(staticCode)
        case .apple, .adHoc, .unsigned, .unavailable:
            ticket = nil
        }
        return ProcessCodeSignature(
            kind: kind,
            teamID: team,
            authority: authority,
            isSandboxed: sandboxEntitlement(for: staticCode),
            hasNotarizationTicket: ticket
        )
    }

    static func listeningPorts(pid: Int32) -> [ProcessListenPort] {
        var seen: Set<String> = []
        var ports: [ProcessListenPort] = []
        for descriptor in fileDescriptors(pid: pid) where descriptor.type == UInt32(PROX_FDTYPE_SOCKET) {
            guard let port = listenPort(pid: pid, fd: descriptor.fd) else { continue }
            if seen.insert(port.id).inserted {
                ports.append(port)
            }
        }
        return ports.sorted { lhs, rhs in
            if lhs.port != rhs.port { return lhs.port < rhs.port }
            return lhs.display < rhs.display
        }
    }

    static func openFiles(pid: Int32) -> (shown: [ProcessOpenFile], total: Int) {
        var paths: [String] = []
        var seen: Set<String> = []
        var unread = 0
        for descriptor in fileDescriptors(pid: pid) where descriptor.type == UInt32(PROX_FDTYPE_VNODE) {
            if paths.count >= maximumListedFiles {
                unread += 1
                continue
            }
            guard let path = vnodePath(pid: pid, fd: descriptor.fd), path.hasPrefix("/") else { continue }
            guard seen.insert(path).inserted else { continue }
            paths.append(path)
        }
        return (paths.map(ProcessOpenFile.init(path:)), paths.count + unread)
    }

    private struct FileDescriptor {
        let fd: Int32
        let type: UInt32
    }

    private static func fileDescriptors(pid: Int32) -> [FileDescriptor] {
        guard pid > 0 else { return [] }
        let needed = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard needed > 0 else { return [] }
        let stride = MemoryLayout<proc_fdinfo>.stride
        let capped = min(Int(needed), 4096 * stride)
        let count = capped / stride
        var buffer = [proc_fdinfo](repeating: proc_fdinfo(), count: count)
        let written = buffer.withUnsafeMutableBytes { raw in
            proc_pidinfo(pid, PROC_PIDLISTFDS, 0, raw.baseAddress, Int32(raw.count))
        }
        guard written > 0 else { return [] }
        let filled = min(count, Int(written) / stride)
        return buffer.prefix(filled).map {
            FileDescriptor(fd: $0.proc_fd, type: $0.proc_fdtype)
        }
    }

    private static func vnodePath(pid: Int32, fd: Int32) -> String? {
        var info = vnode_fdinfowithpath()
        let written = withUnsafeMutablePointer(to: &info) { pointer in
            proc_pidfdinfo(pid, fd, PROC_PIDFDVNODEPATHINFO, pointer, Int32(MemoryLayout<vnode_fdinfowithpath>.stride))
        }
        guard written > 0 else { return nil }
        let pathLength = Int(MAXPATHLEN)
        return withUnsafeBytes(of: info) { raw in
            guard raw.count >= pathLength else { return nil }
            let bytes = raw.suffix(pathLength).prefix { $0 != 0 }
            guard !bytes.isEmpty else { return nil }
            return String(bytes: bytes, encoding: .utf8)
        }
    }

    private static func listenPort(pid: Int32, fd: Int32) -> ProcessListenPort? {
        var info = socket_fdinfo()
        let written = withUnsafeMutablePointer(to: &info) { pointer in
            proc_pidfdinfo(pid, fd, PROC_PIDFDSOCKETINFO, pointer, Int32(MemoryLayout<socket_fdinfo>.stride))
        }
        guard written > 0 else { return nil }
        let socket = info.psi
        if socket.soi_kind == SOCKINFO_TCP {
            let tcp = socket.soi_proto.pri_tcp
            let local = ProcessSocketFormatting.hostPort(fromNetworkOrder: tcp.tcpsi_ini.insi_lport)
            let remote = ProcessSocketFormatting.hostPort(fromNetworkOrder: tcp.tcpsi_ini.insi_fport)
            guard ProcessSocketFormatting.isListening(tcpState: tcp.tcpsi_state, localPort: local, remotePort: remote) else {
                return nil
            }
            return ProcessListenPort(
                transport: "TCP",
                address: address(of: tcp.tcpsi_ini),
                port: local
            )
        }
        if socket.soi_kind == SOCKINFO_IN, socket.soi_protocol == IPPROTO_UDP {
            let endpoint = socket.soi_proto.pri_in
            let local = ProcessSocketFormatting.hostPort(fromNetworkOrder: endpoint.insi_lport)
            let remote = ProcessSocketFormatting.hostPort(fromNetworkOrder: endpoint.insi_fport)
            guard ProcessSocketFormatting.isListening(tcpState: nil, localPort: local, remotePort: remote) else {
                return nil
            }
            return ProcessListenPort(
                transport: "UDP",
                address: address(of: endpoint),
                port: local
            )
        }
        return nil
    }

    private static func address(of endpoint: in_sockinfo) -> String {
        var endpoint = endpoint
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        let formatted: UnsafePointer<CChar>?
        if endpoint.insi_vflag & UInt8(INI_IPV6) != 0 {
            formatted = inet_ntop(AF_INET6, &endpoint.insi_laddr.ina_6, &buffer, socklen_t(buffer.count))
        } else {
            formatted = inet_ntop(AF_INET, &endpoint.insi_laddr.ina_46.i46a_addr4, &buffer, socklen_t(buffer.count))
        }
        guard formatted != nil else { return "*" }
        let text = String(cString: buffer)
        return text.isEmpty || text == "0.0.0.0" || text == "::" ? "*" : text
    }

    private static func requirementMatches(_ code: SecStaticCode, _ text: String) -> Bool {
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess,
              let requirement
        else { return false }
        let flags = SecCSFlags(rawValue: 1 << 29)
        return SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess
    }

    private static func hasStapledTicket(_ code: SecStaticCode) -> Bool {
        var info: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSContentInformation | (1 << 29))
        guard SecCodeCopySigningInformation(code, flags, &info) == errSecSuccess,
              let info
        else { return false }
        let dict = info as NSDictionary
        if let data = dict[kSecCodeInfoStapledNotarizationTicket as String] as? Data {
            return !data.isEmpty
        }
        return false
    }

    private static func sandboxEntitlement(for code: SecStaticCode) -> Bool? {
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, [], &info) == errSecSuccess, let info else {
            return nil
        }
        let dict = info as NSDictionary
        guard let entitlements = dict[kSecCodeInfoEntitlementsDict as String] as? NSDictionary else {
            return nil
        }
        let value = entitlements["com.apple.security.app-sandbox"]
        if let flag = value as? Bool { return flag }
        if let number = value as? NSNumber { return number.boolValue }
        return false
    }

    private static func certificateSummary(_ value: Any?) -> String? {
        let certificates = value as? [SecCertificate]
        guard let certificate = certificates?.first else { return nil }
        guard let summary = SecCertificateCopySubjectSummary(certificate) else { return nil }
        return nonEmpty(summary as String)
    }

    private static func nonEmpty(_ text: String?) -> String? {
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}
