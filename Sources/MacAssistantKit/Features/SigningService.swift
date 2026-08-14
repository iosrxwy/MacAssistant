import Foundation
import CryptoKit
import Security

/// 钥匙串中的一个签名身份。
public struct SigningIdentity: Identifiable, Sendable, Hashable {
    public let id: String     // 证书 SHA-1
    public let name: String   // 如 "Apple Development: Name (TEAMID)"
    public init(id: String, name: String) { self.id = id; self.name = name }
}

/// 从 .mobileprovision 解析出的描述文件信息。
public struct ProfileInfo: Sendable {
    public var name: String?
    public var teamID: String?
    public var appID: String?          // application-identifier(含 TeamID 前缀)
    public var expirationDate: Date?
    public var provisionedDevices: [String]
    public var entitlementsXML: String
    public var isExpired: Bool {
        guard let expirationDate else { return false }
        return expirationDate < Date()
    }
}

public enum SigningError: LocalizedError {
    case commandFailed(String)
    case noIdentitySelected
    case profileParse(String)
    case toolMissing(String)
    case profileExpired
    case teamMismatch(expected: String, actual: String)
    case bundleIDMismatch(profile: String, bundleID: String)
    case entitlementNotAllowed(String)
    case unsupportedExtensions([String])
    case missingProfileMappings([String])

    public var errorDescription: String? {
        switch self {
        case let .commandFailed(o): return L("signing.error.commandFailed", o)
        case .noIdentitySelected: return L("signing.error.noIdentitySelected")
        case let .profileParse(o): return L("signing.error.profileParse", o)
        case let .toolMissing(t): return L("signing.error.toolMissing", t)
        case .profileExpired: return L("signing.error.profileExpired")
        case let .teamMismatch(expected, actual): return L("signing.error.teamMismatch", actual, expected)
        case let .bundleIDMismatch(profile, bundleID):
            return L("signing.error.bundleIDMismatch", bundleID, profile)
        case let .entitlementNotAllowed(key): return L("signing.error.entitlementNotAllowed", key)
        case let .unsupportedExtensions(items):
            return L("signing.error.unsupportedExtensions", items.joined(separator: "、"))
        case let .missingProfileMappings(bundleIDs):
            return L("signing.error.missingProfileMappings", bundleIDs.joined(separator: "、"))
        }
    }
}

/// 代码签名:越狱(ldid / ad-hoc)与真机(真实证书由内向外逐层重签)。
public enum SigningService {

    // MARK: 身份

    public static func identities() -> [SigningIdentity] {
        guard let r = try? ExternalTool.security.run(["find-identity", "-v", "-p", "codesigning"]) else { return [] }
        return parseIdentities(r.stdout)
    }

    public static func storedDeveloperCertificateURL() -> URL? {
        let url = certificateStorageURL()
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    public static func rememberedDeveloperCertificatePassword() -> String? {
        guard let data = try? keychainValue(for: passwordService),
              let value = String(data: data, encoding: .utf8)
        else { return nil }
        return value
    }

    public static func rememberedDeveloperCertificateIdentityID() -> String? {
        guard let data = try? keychainValue(for: identityService),
              let value = String(data: data, encoding: .utf8)
        else { return nil }
        return value
    }

    @discardableResult
    public static func importDeveloperCertificate(
        p12At url: URL,
        password: String
    ) throws -> SigningIdentity {
        let before = Set(identities().map(\.id))
        let result = try ExternalTool.security.run([
            "import", url.path,
            "-P", password,
            "-T", ExternalTool.codesign.path ?? "/usr/bin/codesign",
            "-T", ExternalTool.security.path ?? "/usr/bin/security"
        ])
        try requireSuccess(result, step: L("signing.step.importP12"))
        let imported = identities().first { !before.contains($0.id) } ?? identities().first
        guard let imported else { throw SigningError.noIdentitySelected }

        let stored = certificateStorageURL()
        try FileManager.default.createDirectory(
            at: stored.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if url.standardizedFileURL.path != stored.standardizedFileURL.path {
            if FileManager.default.fileExists(atPath: stored.path) {
                try FileManager.default.removeItem(at: stored)
            }
            try FileManager.default.copyItem(at: url, to: stored)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stored.path)
        try saveKeychainValue(Data(password.utf8), for: passwordService)
        try saveKeychainValue(Data(imported.id.utf8), for: identityService)
        return imported
    }

    public static func exportDeveloperCertificate(
        identity: SigningIdentity,
        to url: URL,
        password: String
    ) throws {
        guard let reference = try keychainIdentity(for: identity.id) else {
            throw SigningError.noIdentitySelected
        }
        var parameters = SecItemImportExportKeyParameters(
            version: 0,
            flags: [],
            passphrase: Unmanaged.passUnretained(password as CFString),
            alertTitle: nil,
            alertPrompt: nil,
            accessRef: nil,
            keyUsage: nil,
            keyAttributes: nil
        )
        var exported: CFData?
        let status = SecItemExport(
            reference,
            SecExternalFormat(rawValue: 12)!, // kSecFormatPKCS12
            [],
            &parameters,
            &exported
        )
        guard status == errSecSuccess, let exported else {
            throw SigningError.commandFailed("SecItemExport: \(status)")
        }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(exported as Data).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    static func parseIdentities(_ output: String) -> [SigningIdentity] {
        var result: [SigningIdentity] = []
        for line in output.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard let paren = t.firstIndex(of: ")") else { continue }
            let rest = t[t.index(after: paren)...].trimmingCharacters(in: .whitespaces)
            let parts = rest.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true).map(String.init)
            guard parts.count == 2, parts[0].allSatisfy({ $0.isHexDigit }) else { continue }
            var name = parts[1].trimmingCharacters(in: .whitespaces)
            if name.hasPrefix("\"") && name.hasSuffix("\"") && name.count >= 2 {
                name = String(name.dropFirst().dropLast())
            }
            result.append(SigningIdentity(id: parts[0], name: name))
        }
        return result
    }

    private static let passwordService = "com.opensource.macassistant.signing.p12.password"
    private static let identityService = "com.opensource.macassistant.signing.p12.identity"

    private static func certificateStorageURL() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MacAssistant/SigningCertificate.p12")
    }

    private static func keychainQuery(for service: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: NSUserName()
        ]
    }

    private static func keychainValue(for service: String) throws -> Data {
        var query = keychainQuery(for: service)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            throw SigningError.commandFailed("Keychain read: \(status)")
        }
        return data
    }

    private static func saveKeychainValue(_ data: Data, for service: String) throws {
        let query = keychainQuery(for: service)
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = data
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw SigningError.commandFailed("Keychain write: \(status)")
        }
    }

    private static func keychainIdentity(for sha1: String) throws -> SecIdentity? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassIdentity,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnRef as String: true
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else {
            if status == errSecItemNotFound { return nil }
            throw SigningError.commandFailed("Keychain identity read: \(status)")
        }
        for item in (result as? [SecIdentity]) ?? [] {
            var certificate: SecCertificate?
            guard SecIdentityCopyCertificate(item, &certificate) == errSecSuccess,
                  let certificate
            else { continue }
            let digest = Insecure.SHA1.hash(data: SecCertificateCopyData(certificate) as Data)
                .map { String(format: "%02X", $0) }
                .joined()
            if digest.caseInsensitiveCompare(sha1) == .orderedSame { return item }
        }
        return nil
    }

    // MARK: 描述文件

    public static func readProfile(at url: URL) throws -> ProfileInfo {
        guard ExternalTool.security.isAvailable else { throw SigningError.toolMissing("security") }
        let r = try ExternalTool.security.run(["cms", "-D", "-i", url.path])
        guard r.succeeded, !r.stdout.isEmpty else { throw SigningError.profileParse(r.combinedOutput) }
        return try parseProfile(plistData: Data(r.stdout.utf8))
    }

    static func parseProfile(plistData: Data) throws -> ProfileInfo {
        guard let dict = try? PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any] else {
            throw SigningError.profileParse(L("signing.profileParse.invalidPlist"))
        }
        var info = ProfileInfo(name: dict["Name"] as? String,
                               teamID: (dict["TeamIdentifier"] as? [String])?.first,
                               appID: nil,
                               expirationDate: dict["ExpirationDate"] as? Date,
                               provisionedDevices: (dict["ProvisionedDevices"] as? [String]) ?? [],
                               entitlementsXML: "")
        if let ent = dict["Entitlements"] as? [String: Any] {
            info.appID = ent["application-identifier"] as? String
            let data = try PropertyListSerialization.data(fromPropertyList: ent, format: .xml, options: 0)
            info.entitlementsXML = String(decoding: data, as: UTF8.self)
        }
        return info
    }

    public static func validateProfile(
        _ profile: ProfileInfo,
        identityName: String,
        bundleID: String,
        now: Date = Date()
    ) throws {
        guard let expiration = profile.expirationDate, expiration >= now else {
            throw SigningError.profileExpired
        }
        guard let expectedTeam = profile.teamID, !expectedTeam.isEmpty else {
            throw SigningError.profileParse(L("signing.profileParse.missingTeamIdentifier"))
        }
        let identityTeam = identityName.range(
            of: #"\(([A-Z0-9]{5,})\)\s*$"#,
            options: .regularExpression
        ).map { range in
            String(identityName[range]).dropFirst().dropLast()
                .trimmingCharacters(in: .whitespaces)
        } ?? ""
        guard identityTeam == expectedTeam else {
            throw SigningError.teamMismatch(expected: expectedTeam, actual: String(identityTeam))
        }
        guard let appID = profile.appID, let dot = appID.firstIndex(of: ".") else {
            throw SigningError.profileParse(L("signing.profileParse.missingApplicationIdentifier"))
        }
        let allowedBundle = String(appID[appID.index(after: dot)...])
        let matches = allowedBundle.hasSuffix(".*")
            ? bundleID.hasPrefix(String(allowedBundle.dropLast()))
            : bundleID == allowedBundle
        guard matches else {
            throw SigningError.bundleIDMismatch(profile: appID, bundleID: bundleID)
        }
    }

    public static func validateEntitlementsSubset(
        requested: [String: Any],
        allowed: [String: Any]
    ) throws {
        for (key, value) in requested {
            guard let allowedValue = allowed[key] else {
                throw SigningError.entitlementNotAllowed(key)
            }
            if ["application-identifier", "com.apple.developer.team-identifier", "keychain-access-groups"]
                .contains(key) {
                continue
            }
            guard propertyListEqual(value, allowedValue) else { throw SigningError.entitlementNotAllowed(key) }
        }
    }

    private static func propertyListEqual(_ lhs: Any, _ rhs: Any) -> Bool {
        switch (lhs, rhs) {
        case let (left as [String: Any], right as [String: Any]):
            return left.count == right.count && left.allSatisfy {
                guard let other = right[$0.key] else { return false }
                return propertyListEqual($0.value, other)
            }
        case let (left as [Any], right as [Any]):
            return left.count == right.count && zip(left, right).allSatisfy { propertyListEqual($0, $1) }
        case let (left as NSObject, right as NSObject):
            return left.isEqual(right)
        default:
            return false
        }
    }

    public static func requireSuccess(_ result: CommandResult, step: String) throws {
        guard result.succeeded else {
            throw SigningError.commandFailed(
                L("signing.error.stepFailed", step, result.exitCode, result.combinedOutput)
            )
        }
    }

    public static func rejectUnsupportedExtensions(in app: URL) throws {
        let extensions = FileSystemHelper.allFiles(in: app) {
            ["appex"].contains($0.pathExtension.lowercased())
        }
        guard extensions.isEmpty else {
            throw SigningError.unsupportedExtensions(extensions.map(\.lastPathComponent).sorted())
        }
    }

    static func parsePlistDictionary(_ text: String) throws -> [String: Any] {
        guard let start = text.range(of: "<?xml"),
              let end = text.range(of: "</plist>", options: .backwards)
        else {
            throw SigningError.profileParse(L("signing.profileParse.entitlementsPlistNotFound"))
        }
        let xml = String(text[start.lowerBound..<end.upperBound])
        let object = try PropertyListSerialization.propertyList(from: Data(xml.utf8), format: nil)
        guard let dictionary = object as? [String: Any] else {
            throw SigningError.profileParse(L("signing.profileParse.entitlementsRootNotDictionary"))
        }
        return dictionary
    }

    static func signedEntitlements(at app: URL) throws -> [String: Any] {
        let result = try ExternalTool.codesign.run(["-d", "--entitlements", ":-", app.path])
        try requireSuccess(result, step: L("signing.step.readEntitlements"))
        return try parsePlistDictionary(result.combinedOutput)
    }

    // MARK: 越狱 / 本地(伪签名),由内向外

    @discardableResult
    public static func resignJailbreak(app: URL, method: SignMethod, entitlements: URL? = nil,
                                       log: inout [String]) throws -> Bool {
        let order = signingOrder(app: app)
        for file in order {
            let r: CommandResult
            switch method {
            case .ldid:
                guard ExternalTool.ldid.isAvailable else { throw SigningError.toolMissing("ldid(brew install ldid)") }
                r = (file == app && entitlements != nil)
                    ? try BinaryService.ldidSign(fileAt: file, entitlements: entitlements)
                    : try BinaryService.ldidSign(fileAt: file)
            case .codesignAdhoc:
                r = (file == app && entitlements != nil)
                    ? try BinaryService.adhocSign(fileAt: file, entitlements: entitlements)
                    : try BinaryService.adhocSign(fileAt: file)
            case .none:
                log.append(L("signing.log.skipped", file.lastPathComponent))
                continue
            }
            try requireSuccess(r, step: L("signing.step.signFile", file.lastPathComponent))
            log.append(L("signing.log.signed", file.lastPathComponent))
        }
        if method == .codesignAdhoc {
            let verify = try ExternalTool.codesign.run(["--verify", "--strict", "--verbose=4", app.path])
            try requireSuccess(verify, step: L("signing.step.finalVerify"))
            log.append(L("signing.log.strictVerifyPassed"))
        }
        return true
    }

    // MARK: 真机(真实证书,由内向外逐层)

    public struct RealResignOptions: Sendable {
        public var identity: SigningIdentity
        public var profileURL: URL
        public var overrideBundleID: String?
        public init(identity: SigningIdentity, profileURL: URL, overrideBundleID: String? = nil) {
            self.identity = identity
            self.profileURL = profileURL
            self.overrideBundleID = overrideBundleID
        }
    }

    /// 真机重签:删旧签名 → 装 embedded.mobileprovision → (可选)改 bundle id →
    /// 先签 Frameworks/PlugIns(不带主 App entitlements)→ 最后签主 App(带 entitlements)→ 校验。
    public static func resignRealDevice(app: URL, options: RealResignOptions, log: inout [String]) throws {
        guard ExternalTool.codesign.isAvailable else { throw SigningError.toolMissing("codesign") }

        let profile = try readProfile(at: options.profileURL)
        try rejectUnsupportedExtensions(in: app)
        let originalPlist = try IpaService.infoPlist(appBundle: app)
        let originalBundleID = originalPlist["CFBundleIdentifier"] as? String ?? ""
        let targetBundleID = options.overrideBundleID ?? originalBundleID
        try validateProfile(
            profile,
            identityName: options.identity.name,
            bundleID: targetBundleID
        )
        let requestedEntitlements = try signedEntitlements(at: app)
        let allowedEntitlements = try parsePlistDictionary(profile.entitlementsXML)
        try validateEntitlementsSubset(requested: requestedEntitlements, allowed: allowedEntitlements)
        log.append(L("signing.log.profileInfo", profile.name ?? "?", profile.appID ?? "?"))

        // 写 entitlements 到临时文件
        let entDir = try FileSystemHelper.makeTemporaryDirectory(prefix: "ent")
        defer { try? FileManager.default.removeItem(at: entDir) } // 非关键清理，不覆盖主错误。
        let entURL = entDir.appendingPathComponent("entitlements.plist")
        try profile.entitlementsXML.write(to: entURL, atomically: true, encoding: .utf8)

        // 删除所有旧 _CodeSignature
        for dir in FileSystemHelper.allFiles(in: app, where: { $0.lastPathComponent == "_CodeSignature" && FileSystemHelper.isDirectory($0) }) {
            try FileManager.default.removeItem(at: dir)
        }
        let rootSignature = app.appendingPathComponent("_CodeSignature")
        if FileManager.default.fileExists(atPath: rootSignature.path) {
            try FileManager.default.removeItem(at: rootSignature)
        }

        // 装描述文件
        let embedded = app.appendingPathComponent("embedded.mobileprovision")
        if FileManager.default.fileExists(atPath: embedded.path) {
            try FileManager.default.removeItem(at: embedded)
        }
        try FileManager.default.copyItem(at: options.profileURL, to: embedded)
        log.append(L("signing.log.embeddedWritten"))

        // 可选改 bundle id
        if let bid = options.overrideBundleID {
            guard ExternalTool.plistBuddy.isAvailable else { throw SigningError.toolMissing("PlistBuddy") }
            let update = try ExternalTool.plistBuddy.run(["-c", "Set :CFBundleIdentifier \(bid)",
                                                          app.appendingPathComponent("Info.plist").path])
            try requireSuccess(update, step: L("signing.step.updateBundleID"))
            log.append(L("signing.log.bundleIDSet", bid))
        }

        // 由内向外:先内层(不带 entitlements),appex 带自身 entitlements(此处统一用 profile entitlements),最后主 App 带 entitlements
        let inner = signingOrder(app: app).filter { $0 != app }
        for file in inner {
            let isAppex = file.pathExtension == "appex"
            let r = try codesign(identity: options.identity, fileAt: file,
                                 entitlements: isAppex ? entURL : nil)
            if !r.succeeded {
                let hints = diagnose(r.combinedOutput)
                throw SigningError.commandFailed(
                    L("signing.error.signFileFailed", file.lastPathComponent, r.combinedOutput)
                        + "\n" + hints.joined(separator: "\n")
                )
            }
            log.append(L("signing.log.signed", file.lastPathComponent))
        }
        let mainResult = try codesign(identity: options.identity, fileAt: app, entitlements: entURL)
        if !mainResult.succeeded {
            let hints = diagnose(mainResult.combinedOutput)
            throw SigningError.commandFailed(
                L("signing.error.signMainAppFailed", mainResult.combinedOutput)
                    + "\n" + hints.joined(separator: "\n")
            )
        }
        log.append(L("signing.log.signedMainApp"))

        let verify = try ExternalTool.codesign.run(["--verify", "--strict", "--verbose=4", app.path])
        try requireSuccess(verify, step: L("signing.step.finalVerify"))
        log.append(L("signing.log.strictVerifyPassed"))
    }

    public static func profileBundleIDs(
        in app: URL,
        overridingRootBundleID: String? = nil,
        excludingRelativePaths: Set<String> = []
    ) throws -> [String] {
        try bundleIDEntries(in: app, overridingRootBundleID: overridingRootBundleID)
            .filter { !isExcluded($0.url, from: app, relativePaths: excludingRelativePaths) }
            .map(\.effectiveID)
    }

    public static func missingProfileBundleIDs(
        in app: URL,
        profilesByBundleID: [String: URL],
        overridingRootBundleID: String? = nil,
        excludingRelativePaths: Set<String> = []
    ) throws -> [String] {
        let entries = try bundleIDEntries(
            in: app,
            overridingRootBundleID: overridingRootBundleID,
            excludingRelativePaths: excludingRelativePaths
        )
        return entries.compactMap { entry in
            profilesByBundleID[entry.effectiveID] == nil ? entry.effectiveID : nil
        }.sorted()
    }

    /// 真机签名图：主 App 与每个 appex/Watch App/AppClip/XPC 都必须有独立 profile。
    public static func resignRealDeviceGraph(
        app: URL,
        identity: SigningIdentity,
        profilesByBundleID: [String: URL],
        overrideBundleID: String? = nil,
        log: inout [String]
    ) throws {
        guard ExternalTool.codesign.isAvailable else { throw SigningError.toolMissing("codesign") }
        if let overrideBundleID {
            try rewriteBundleIDGraph(in: app, rootBundleID: overrideBundleID)
        }
        let bundles = try profileBundles(in: app)
        let missing = try missingProfileBundleIDs(
            in: app,
            profilesByBundleID: profilesByBundleID,
            overridingRootBundleID: overrideBundleID
        )
        guard missing.isEmpty else { throw SigningError.missingProfileMappings(missing) }

        let bundleIDs = try bundleIDsByURL(in: app)
        var profilesByPath: [String: (bundleID: String, url: URL, info: ProfileInfo)] = [:]
        for bundle in bundles {
            let plist = try IpaService.infoPlist(appBundle: bundle)
            let bundleID = bundleIDs[bundle.standardizedFileURL] ?? (plist["CFBundleIdentifier"] as? String ?? "")
            guard let profileURL = profilesByBundleID[bundleID] else {
                throw SigningError.missingProfileMappings([bundleID])
            }
            let profile = try readProfile(at: profileURL)
            try validateProfile(profile, identityName: identity.name, bundleID: bundleID)
            let requestedEntitlements = try signedEntitlements(at: bundle)
            let allowedEntitlements = try parsePlistDictionary(profile.entitlementsXML)
            try validateEntitlementsSubset(
                requested: requestedEntitlements,
                allowed: allowedEntitlements
            )
            profilesByPath[bundle.standardizedFileURL.path] = (bundleID, profileURL, profile)
        }

        if let overrideBundleID {
            try updateInfoPlist(
                in: app,
                values: ["CFBundleIdentifier": overrideBundleID]
            )
            log.append(L("signing.log.mainBundleIDSet", overrideBundleID))
        }

        for directory in FileSystemHelper.allFiles(in: app, where: {
            $0.lastPathComponent == "_CodeSignature" && FileSystemHelper.isDirectory($0)
        }) {
            try FileManager.default.removeItem(at: directory)
        }

        let entitlementsDirectory = try FileSystemHelper.makeTemporaryDirectory(prefix: "sign-graph")
        defer { try? FileManager.default.removeItem(at: entitlementsDirectory) }
        var entitlementsByPath: [String: URL] = [:]
        for bundle in bundles {
            guard let mapping = profilesByPath[bundle.standardizedFileURL.path] else { continue }
            let embedded = bundle.appendingPathComponent("embedded.mobileprovision")
            if FileManager.default.fileExists(atPath: embedded.path) {
                try FileManager.default.removeItem(at: embedded)
            }
            try FileManager.default.copyItem(at: mapping.url, to: embedded)
            let entitlements = entitlementsDirectory
                .appendingPathComponent("\(stableFileName(mapping.bundleID)).plist")
            try mapping.info.entitlementsXML.write(to: entitlements, atomically: true, encoding: .utf8)
            entitlementsByPath[bundle.standardizedFileURL.path] = entitlements
            log.append(L("signing.log.profileMapped", mapping.bundleID))
        }

        for node in signingOrder(app: app) {
            let entitlement = entitlementsByPath[node.standardizedFileURL.path]
            let result = try codesign(identity: identity, fileAt: node, entitlements: entitlement)
            try requireSuccess(result, step: L("signing.step.signFile", node.lastPathComponent))
            log.append(L("signing.log.signedNode", node.lastPathComponent))
        }
        let verify = try ExternalTool.codesign.run(["--verify", "--strict", "--verbose=4", app.path])
        try requireSuccess(verify, step: L("signing.step.finalVerify"))
        log.append(L("signing.log.graphVerifyPassed"))
    }

    /// 返回主 App 与嵌套 bundle 的最终 Bundle ID。改主 ID 时，沿用原主 ID 前缀的组件同步改名。
    public static func bundleIDsByURL(
        in app: URL,
        overridingRootBundleID: String? = nil
    ) throws -> [URL: String] {
        try bundleIDEntries(in: app, overridingRootBundleID: overridingRootBundleID)
            .reduce(into: [URL: String]()) { result, entry in
                result[entry.url.standardizedFileURL] = entry.effectiveID
            }
    }

    private struct BundleIDEntry {
        let url: URL
        let effectiveID: String
    }

    private static func bundleIDEntries(
        in app: URL,
        overridingRootBundleID: String?,
        excludingRelativePaths: Set<String> = []
    ) throws -> [BundleIDEntry] {
        let bundles = try profileBundles(in: app)
        let rootPlist = try IpaService.infoPlist(appBundle: app)
        let originalRootID = rootPlist["CFBundleIdentifier"] as? String ?? ""
        return try bundles.compactMap { bundle in
            guard !isExcluded(bundle, from: app, relativePaths: excludingRelativePaths) else { return nil }
            let plist = try IpaService.infoPlist(appBundle: bundle)
            guard let originalID = plist["CFBundleIdentifier"] as? String, !originalID.isEmpty else {
                throw SigningError.profileParse(
                    L("signing.profileParse.missingBundleIdentifier", bundle.lastPathComponent)
                )
            }
            return BundleIDEntry(
                url: bundle,
                effectiveID: transformedBundleID(
                    originalID,
                    rootOriginalID: originalRootID,
                    rootBundleID: overridingRootBundleID
                )
            )
        }
    }

    public static func transformedBundleID(
        _ originalID: String,
        rootOriginalID: String,
        rootBundleID: String?
    ) -> String {
        guard let rootBundleID, !rootOriginalID.isEmpty else { return originalID }
        if originalID == rootOriginalID { return rootBundleID }
        guard originalID.hasPrefix(rootOriginalID + ".") else { return originalID }
        return rootBundleID + String(originalID.dropFirst(rootOriginalID.count))
    }

    /// 同步修改主 App 及其以主 Bundle ID 为前缀的嵌套组件。
    @discardableResult
    public static func rewriteBundleIDGraph(in app: URL, rootBundleID: String) throws -> [String] {
        let rootPlist = try IpaService.infoPlist(appBundle: app)
        let originalRootID = rootPlist["CFBundleIdentifier"] as? String ?? ""
        var changed: [String] = []
        for bundle in try profileBundles(in: app) {
            let plist = try IpaService.infoPlist(appBundle: bundle)
            guard let originalID = plist["CFBundleIdentifier"] as? String else { continue }
            let finalID = transformedBundleID(
                originalID,
                rootOriginalID: originalRootID,
                rootBundleID: rootBundleID
            )
            guard finalID != originalID else { continue }
            try updateInfoPlist(in: bundle, values: ["CFBundleIdentifier": finalID])
            changed.append("\(originalID) → \(finalID)")
        }
        return changed
    }

    private static func profileBundles(in app: URL) throws -> [URL] {
        var bundles = FileSystemHelper.allFiles(in: app) {
            let ext = $0.pathExtension.lowercased()
            return FileSystemHelper.isDirectory($0) && ["appex", "app", "xpc"].contains(ext)
        }
        bundles.removeAll { $0.standardizedFileURL == app.standardizedFileURL }
        bundles.sort { $0.pathComponents.count > $1.pathComponents.count }
        bundles.append(app)
        return bundles
    }

    private static func isExcluded(
        _ bundle: URL,
        from app: URL,
        relativePaths: Set<String>
    ) -> Bool {
        guard !relativePaths.isEmpty else { return false }
        let root = app.standardizedFileURL.path + "/"
        let path = bundle.standardizedFileURL.path
        guard path.hasPrefix(root) else { return false }
        let relative = String(path.dropFirst(root.count))
        return relativePaths.contains { relative == $0 || relative.hasPrefix($0 + "/") }
    }

    private static func updateInfoPlist(in bundle: URL, values: [String: String]) throws {
        let plistURL = IpaService.infoPlistURL(appBundle: bundle)
        let data = try Data(contentsOf: plistURL)
        var format = PropertyListSerialization.PropertyListFormat.binary
        guard var plist = try PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: &format
        ) as? [String: Any] else {
            throw SigningError.profileParse(
                L("signing.profileParse.invalidInfoPlist", bundle.lastPathComponent)
            )
        }
        for (key, value) in values { plist[key] = value }
        try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: format,
            options: 0
        ).write(to: plistURL, options: .atomic)
    }

    private static func stableFileName(_ value: String) -> String {
        value.map { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" ? $0 : "_" }
            .reduce(into: "") { $0.append($1) }
    }

    @discardableResult
    static func codesign(identity: SigningIdentity, fileAt url: URL, entitlements: URL?) throws -> CommandResult {
        var args = ["-f", "-s", identity.name]
        if let entitlements { args += ["--entitlements", entitlements.path] }
        args.append(url.path)
        return try ExternalTool.codesign.run(args)
    }

    // MARK: 由内向外的签名顺序

    /// 返回签名顺序：动态库/Framework → PlugIns、Watch、AppClips 等嵌套 bundle → 主 App。
    public static func signingOrder(app: URL) -> [URL] {
        var files = FileSystemHelper.allFiles(in: app) {
            let ext = $0.pathExtension.lowercased()
            return ext == "dylib" || ["framework", "appex", "app", "xpc"].contains(ext)
        }
        // 深度倒序:路径组件多的先签
        files.sort { $0.pathComponents.count > $1.pathComponents.count }
        files.append(app)   // 主 App 最后
        return files
    }

    // MARK: IPA 级封装(解包 → 逐层重签 → 重打包)

    private static func repackage(extractDir: URL, to output: URL) throws {
        guard !FileManager.default.fileExists(atPath: output.path) else {
            throw SigningError.commandFailed(L("signing.error.outputExists", output.path))
        }
        try IpaService.validatePayloadStructure(in: extractDir)
        let temporaryOutput = output.deletingLastPathComponent()
            .appendingPathComponent(".sign-\(UUID().uuidString).ipa")
        defer { try? FileManager.default.removeItem(at: temporaryOutput) } // 失败时删除未发布归档。
        let topItems = try FileManager.default.contentsOfDirectory(atPath: extractDir.path)
        let r = try ExternalTool.zip.run(["-qry", "-X", temporaryOutput.path] + topItems, currentDirectory: extractDir)
        guard r.succeeded else { throw SigningError.commandFailed(r.combinedOutput) }
        _ = try ArchiveSafety.validateZIP(at: temporaryOutput)
        try FileManager.default.moveItem(at: temporaryOutput, to: output)
    }

    public static func resignIPAJailbreak(ipaAt url: URL, method: SignMethod,
                                          entitlements: URL? = nil, output: URL? = nil) throws -> (URL, [String]) {
        var log: [String] = []
        let work = try FileSystemHelper.makeTemporaryDirectory(prefix: "sign-ipa")
        defer { try? FileManager.default.removeItem(at: work) }
        let extractDir = work.appendingPathComponent("x")
        try IpaService.unzip(url, to: extractDir)
        try IpaService.validatePayloadStructure(in: extractDir)
        let app = try IpaService.locateApp(in: extractDir)
        _ = try resignJailbreak(app: app, method: method, entitlements: entitlements, log: &log)
        let proposed = url.deletingPathExtension().appendingPathExtension("signed").appendingPathExtension("ipa")
        let out = output ?? FileSystemHelper.uniqueOutputURL(basedOn: proposed)
        try repackage(extractDir: extractDir, to: out)
        log.append(L("signing.log.repackaged", out.lastPathComponent))
        return (out, log)
    }

    public static func resignIPARealDevice(ipaAt url: URL, options: RealResignOptions,
                                           output: URL? = nil) throws -> (URL, [String]) {
        var log: [String] = []
        let work = try FileSystemHelper.makeTemporaryDirectory(prefix: "sign-ipa")
        defer { try? FileManager.default.removeItem(at: work) }
        let extractDir = work.appendingPathComponent("x")
        try IpaService.unzip(url, to: extractDir)
        try IpaService.validatePayloadStructure(in: extractDir)
        let app = try IpaService.locateApp(in: extractDir)
        try resignRealDevice(app: app, options: options, log: &log)
        let proposed = url.deletingPathExtension().appendingPathExtension("signed").appendingPathExtension("ipa")
        let out = output ?? FileSystemHelper.uniqueOutputURL(basedOn: proposed)
        try repackage(extractDir: extractDir, to: out)
        log.append(L("signing.log.repackaged", out.lastPathComponent))
        return (out, log)
    }

    /// IPA 真机签名图：主 App、appex、Watch App、App Clip、XPC 分别使用对应 profile。
    public static func resignIPARealDeviceGraph(
        ipaAt url: URL,
        recipe: RealDeviceSigningRecipe,
        overrideBundleID: String? = nil,
        output: URL? = nil
    ) throws -> (URL, [String]) {
        var log: [String] = []
        let work = try FileSystemHelper.makeTemporaryDirectory(prefix: "sign-ipa-graph")
        defer { try? FileManager.default.removeItem(at: work) }
        let extractDir = work.appendingPathComponent("x")
        try IpaService.unzip(url, to: extractDir)
        try IpaService.validatePayloadStructure(in: extractDir)
        let app = try IpaService.locateApp(in: extractDir)
        try resignRealDeviceGraph(
            app: app,
            identity: SigningIdentity(id: recipe.identityID, name: recipe.identityName),
            profilesByBundleID: recipe.profilesByBundleID,
            overrideBundleID: overrideBundleID,
            log: &log
        )
        let proposed = url.deletingPathExtension().appendingPathExtension("signed").appendingPathExtension("ipa")
        let out = output ?? FileSystemHelper.uniqueOutputURL(basedOn: proposed)
        try repackage(extractDir: extractDir, to: out)
        log.append(L("signing.log.repackaged", out.lastPathComponent))
        return (out, log)
    }

    // MARK: 错误诊断

    /// 根据 codesign 输出给出常见失败中文提示。
    public static func diagnose(_ output: String) -> [String] {
        let o = output.lowercased()
        var hints: [String] = []
        if o.contains("entitlement") && (o.contains("not allowed") || o.contains("do not match") || o.contains("invalid")) {
            hints.append(L("signing.hint.entitlements"))
        }
        if o.contains("bundle") && o.contains("identifier") || o.contains("does not match") && o.contains("identifier") {
            hints.append(L("signing.hint.bundleID"))
        }
        if o.contains("expired") || o.contains("has expired") {
            hints.append(L("signing.hint.expired"))
        }
        if o.contains("no identity found") || o.contains("unable to find") && o.contains("identity") {
            hints.append(L("signing.hint.noIdentity"))
        }
        if o.contains("resource fork") || o.contains("resource envelope") {
            hints.append(L("signing.hint.resourceFork"))
        }
        if hints.isEmpty { hints.append(L("signing.hint.generic")) }
        return hints
    }
}
