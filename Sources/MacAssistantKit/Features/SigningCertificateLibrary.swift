import Foundation
import Security

/// 钥匙串 / 本机证书库里一张开发证书的到期状态。
public enum CertificateExpiryStatus: Equatable, Sendable {
    case unknown
    case valid(daysRemaining: Int)
    case expiringSoon(daysRemaining: Int)
    case expired

    public static let soonLead: TimeInterval = 7 * 24 * 60 * 60

    public static func of(expiration: Date?, now: Date = Date(), soonLead: TimeInterval = soonLead) -> CertificateExpiryStatus {
        guard let expiration else { return .unknown }
        if expiration <= now { return .expired }
        let days = Int(ceil(expiration.timeIntervalSince(now) / 86_400))
        if expiration <= now.addingTimeInterval(soonLead) { return .expiringSoon(daysRemaining: max(days, 1)) }
        return .valid(daysRemaining: days)
    }

    public var isUsable: Bool {
        switch self {
        case .expired: return false
        case .unknown, .valid, .expiringSoon: return true
        }
    }
}

/// 用户导入的一套 p12。密码在钥匙串，文件在 Application Support（0600）。
public struct StoredSigningCertificate: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var identityID: String
    public var name: String
    public var expiration: Date?
    public var importedAt: Date

    public init(
        id: UUID = UUID(),
        identityID: String,
        name: String,
        expiration: Date? = nil,
        importedAt: Date = Date()
    ) {
        self.id = id
        self.identityID = identityID
        self.name = name
        self.expiration = expiration
        self.importedAt = importedAt
    }

    public var expiryStatus: CertificateExpiryStatus { .of(expiration: expiration) }
}

struct CertificateLibraryIndex: Codable {
    var selectedID: UUID?
    var certificates: [StoredSigningCertificate]
}

/// 多套开发证书：导入、切换、删除。不替代钥匙串里的 codesign 身份，只记住用户自己的 p12。
public enum SigningCertificateLibrary {
    static var directoryOverride: URL?

    private static var root: URL {
        directoryOverride
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("MacAssistant/CertificateLibrary", isDirectory: true)
    }

    private static var indexURL: URL { root.appendingPathComponent("index.json") }

    public static func load() -> [StoredSigningCertificate] {
        readIndex().certificates
    }

    public static func selected() -> StoredSigningCertificate? {
        let index = readIndex()
        if let id = index.selectedID {
            return index.certificates.first { $0.id == id }
        }
        return index.certificates.first
    }

    public static func p12URL(for certificate: StoredSigningCertificate) -> URL {
        root.appendingPathComponent("\(certificate.id.uuidString).p12")
    }

    @discardableResult
    public static func remember(
        identity: SigningIdentity,
        p12At url: URL,
        password: String
    ) throws -> StoredSigningCertificate {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var index = readIndex()
        let expiration = identity.expiration ?? SigningService.certificateExpiration(for: identity.id)
        var entry = index.certificates.first { $0.identityID.caseInsensitiveCompare(identity.id) == .orderedSame }
            ?? StoredSigningCertificate(identityID: identity.id, name: identity.name, expiration: expiration)
        entry.identityID = identity.id
        entry.name = identity.name
        entry.expiration = expiration
        entry.importedAt = Date()
        let stored = p12URL(for: entry)
        if url.standardizedFileURL.path != stored.standardizedFileURL.path {
            if FileManager.default.fileExists(atPath: stored.path) {
                try FileManager.default.removeItem(at: stored)
            }
            try FileManager.default.copyItem(at: url, to: stored)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stored.path)
        try SigningService.saveCertificatePassword(password, for: entry.id)
        if let existing = index.certificates.firstIndex(where: { $0.id == entry.id }) {
            index.certificates[existing] = entry
        } else {
            index.certificates.append(entry)
        }
        index.selectedID = entry.id
        writeIndex(index)
        return entry
    }

    public static func select(_ certificate: StoredSigningCertificate) {
        var index = readIndex()
        guard index.certificates.contains(where: { $0.id == certificate.id }) else { return }
        index.selectedID = certificate.id
        writeIndex(index)
        SigningService.rememberSelectedIdentity(certificate.identityID)
    }

    public static func remove(id: UUID) {
        var index = readIndex()
        if let entry = index.certificates.first(where: { $0.id == id }) {
            try? FileManager.default.removeItem(at: p12URL(for: entry))
            SigningService.deleteCertificatePassword(for: id)
        }
        index.certificates.removeAll { $0.id == id }
        if index.selectedID == id {
            index.selectedID = index.certificates.first?.id
            if let next = index.certificates.first {
                SigningService.rememberSelectedIdentity(next.identityID)
            }
        }
        writeIndex(index)
    }

    public static func password(for id: UUID) -> String? {
        SigningService.certificatePassword(for: id)
    }

    static func readIndex() -> CertificateLibraryIndex {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: indexURL),
              let index = try? decoder.decode(CertificateLibraryIndex.self, from: data)
        else {
            return CertificateLibraryIndex(selectedID: nil, certificates: [])
        }
        return index
    }

    static func writeIndex(_ index: CertificateLibraryIndex) {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(index) else { return }
        try? data.write(to: indexURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: indexURL.path)
    }
}

extension SigningIdentity {
    public var expiryStatus: CertificateExpiryStatus { .of(expiration: expiration) }
}
