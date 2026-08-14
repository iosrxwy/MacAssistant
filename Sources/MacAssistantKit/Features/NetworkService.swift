import Foundation

public struct NetworkInterface: Identifiable, Sendable {
    public let id = UUID()
    public let name: String
    public let ipv4: String
}

public struct ListeningPort: Identifiable, Sendable {
    public let id = UUID()
    public let command: String
    public let pid: String
    public let name: String
    public let node: String
}

public enum NetworkService {

    /// 通过 getifaddrs 读取本机各网卡的 IPv4 地址(排除回环)。
    public static func localInterfaces() -> [NetworkInterface] {
        var result: [NetworkInterface] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return [] }
        defer { freeifaddrs(ifaddr) }

        var pointer: UnsafeMutablePointer<ifaddrs>? = first
        while let current = pointer {
            let addr = current.pointee.ifa_addr
            if let addr, addr.pointee.sa_family == UInt8(AF_INET) {
                let name = String(cString: current.pointee.ifa_name)
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(addr, socklen_t(addr.pointee.sa_len),
                               &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                    let ip = String(cString: host)
                    if ip != "127.0.0.1" {
                        result.append(NetworkInterface(name: name, ipv4: ip))
                    }
                }
            }
            pointer = current.pointee.ifa_next
        }
        return result
    }

    /// 列出处于 LISTEN 状态的 TCP 端口(基于 lsof)。
    public static func listeningPorts() -> [ListeningPort] {
        guard let result = try? Shell.run("/usr/sbin/lsof",
                                          ["-nP", "-iTCP", "-sTCP:LISTEN"]),
              result.succeeded || !result.stdout.isEmpty else { return [] }
        var ports: [ListeningPort] = []
        for line in result.stdout.split(separator: "\n").dropFirst() {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard parts.count >= 9 else { continue }
            ports.append(ListeningPort(command: parts[0], pid: parts[1],
                                       name: parts[8], node: parts[7]))
        }
        return ports
    }

    /// 尝试获取公网 IP(需要网络访问,可能失败)。
    public static func publicIP() -> String? {
        for host in ["https://api.ipify.org", "https://ifconfig.me/ip"] {
            if let result = try? Shell.run("/usr/bin/curl", ["-s", "--max-time", "6", host]),
               result.succeeded {
                let ip = result.trimmedOutput
                if !ip.isEmpty, ip.count < 64 { return ip }
            }
        }
        return nil
    }

    public static func ping(host: String, count: Int = 4) throws -> CommandResult {
        try Shell.run("/sbin/ping", ["-c", "\(count)", host])
    }

    /// 刷新 DNS 缓存需要 sudo,这里返回可复制的命令。
    public static let flushDNSCommand = "sudo dscacheutil -flushcache; sudo killall -HUP mDNSResponder"
}
