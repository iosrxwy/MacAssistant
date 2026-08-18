import Foundation

/// App Store 搜索与官方 IPA 下载（走本机 `ipatool`）。包仍是 FairPlay 加密，不脱壳。
public enum IpaStorePlatform: String, CaseIterable, Sendable, Identifiable {
    case iphone
    case ipad
    case appletv

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .iphone: return L("ipastore.platform.iphone")
        case .ipad: return L("ipastore.platform.ipad")
        case .appletv: return L("ipastore.platform.appletv")
        }
    }
}

public struct IpaStoreAccount: Equatable, Sendable {
    public var name: String
    public var email: String

    public init(name: String, email: String) {
        self.name = name
        self.email = email
    }

    public var summary: String {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedName.isEmpty { return email }
        return "\(trimmedName) · \(email)"
    }
}

public struct IpaStoreApp: Identifiable, Equatable, Sendable {
    public var storeID: Int64
    public var bundleIdentifier: String
    public var name: String
    public var version: String
    public var price: Double?

    public var id: Int64 { storeID }

    public init(
        storeID: Int64,
        bundleIdentifier: String,
        name: String,
        version: String,
        price: Double? = nil
    ) {
        self.storeID = storeID
        self.bundleIdentifier = bundleIdentifier
        self.name = name
        self.version = version
        self.price = price
    }

    public var summary: String {
        var parts = [bundleIdentifier]
        if !version.isEmpty { parts.append(version) }
        if let price {
            parts.append(price == 0 ? L("ipastore.price.free") : String(format: "%.2f", price))
        }
        return parts.joined(separator: " · ")
    }
}

public struct IpaStoreVersion: Identifiable, Equatable, Sendable {
    public var externalVersionID: String
    public var displayVersion: String?
    public var releaseDate: String?

    public var id: String { externalVersionID }

    public init(externalVersionID: String, displayVersion: String? = nil, releaseDate: String? = nil) {
        self.externalVersionID = externalVersionID
        self.displayVersion = displayVersion
        self.releaseDate = releaseDate
    }

    public var summary: String {
        let version = displayVersion?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if version.isEmpty { return externalVersionID }
        if let releaseDate, !releaseDate.isEmpty {
            return "\(version) · \(releaseDate) · \(externalVersionID)"
        }
        return "\(version) · \(externalVersionID)"
    }
}

public struct IpaStoreDownload: Sendable {
    public var ipaURL: URL
    public var purchased: Bool
    public var identity: IpaIdentity?
    public var log: [String]

    public init(ipaURL: URL, purchased: Bool, identity: IpaIdentity?, log: [String]) {
        self.ipaURL = ipaURL
        self.purchased = purchased
        self.identity = identity
        self.log = log
    }
}

public enum IpaStoreError: LocalizedError {
    case toolMissing
    case notLoggedIn
    case twoFactorRequired
    case emptyQuery
    case noSelection
    case invalidJSON(String)
    case commandFailed(String)
    case noOutput

    public var errorDescription: String? {
        switch self {
        case .toolMissing: return L("ipastore.error.toolMissing")
        case .notLoggedIn: return L("ipastore.error.notLoggedIn")
        case .twoFactorRequired: return L("ipastore.error.twoFactorRequired")
        case .emptyQuery: return L("ipastore.error.emptyQuery")
        case .noSelection: return L("ipastore.error.noSelection")
        case let .invalidJSON(output): return L("ipastore.error.invalidJSON", output)
        case let .commandFailed(output): return L("ipastore.error.commandFailed", output)
        case .noOutput: return L("ipastore.error.noOutput")
        }
    }
}

public enum IpaStoreService {
    public static var isAvailable: Bool { ExternalTool.ipatool.isAvailable }

    public static func currentAccount() -> IpaStoreAccount? {
        try? accountInfo()
    }

    public static func accountInfo() throws -> IpaStoreAccount {
        let payload = try run(["auth", "info"])
        return try account(from: payload, fallback: payload.raw)
    }

    public static func login(email: String, password: String, authCode: String? = nil) throws -> IpaStoreAccount {
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPassword = password
        let code = authCode?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmedEmail.isEmpty, !trimmedPassword.isEmpty else {
            throw IpaStoreError.notLoggedIn
        }
        var arguments = ["auth", "login", "--email", trimmedEmail, "--password", trimmedPassword]
        if !code.isEmpty {
            arguments += ["--auth-code", code]
        }
        let payload = try run(arguments, treatTwoFactorAsError: true)
        if let account = try? account(from: payload, fallback: payload.raw) {
            return account
        }
        return IpaStoreAccount(name: "", email: trimmedEmail)
    }

    public static func revoke() throws {
        _ = try run(["auth", "revoke"])
    }

    public static func search(
        _ term: String,
        limit: Int = 10,
        platform: IpaStorePlatform = .iphone
    ) throws -> [IpaStoreApp] {
        let query = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { throw IpaStoreError.emptyQuery }
        let bounded = min(max(limit, 1), 50)
        let arguments = ["search", query, "--limit", "\(bounded)", "--platform", platform.rawValue]
        let payload = try run(arguments)
        return try apps(from: payload)
    }

    public static func listVersionIDs(app: IpaStoreApp) throws -> [String] {
        let payload = try run(appArguments(["list-versions"], app: app))
        return try versionIDs(from: payload)
    }

    public static func versionMetadata(app: IpaStoreApp, externalVersionID: String) throws -> IpaStoreVersion {
        let versionID = externalVersionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !versionID.isEmpty else { throw IpaStoreError.noSelection }
        let payload = try run(
            appArguments(["get-version-metadata", "--external-version-id", versionID], app: app)
        )
        return try version(from: payload, fallbackID: versionID)
    }

    public static func download(
        app: IpaStoreApp,
        externalVersionID: String? = nil,
        platform: IpaStorePlatform = .iphone,
        toDirectory directory: URL,
        purchaseIfNeeded: Bool = false
    ) throws -> IpaStoreDownload {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileName = suggestedFileName(app: app, externalVersionID: externalVersionID)
        let proposed = FileSystemHelper.uniqueOutputURL(
            basedOn: directory.appendingPathComponent(fileName)
        )
        var arguments = appArguments(["download", "--output", proposed.path, "--platform", platform.rawValue], app: app)
        if let versionID = externalVersionID?.trimmingCharacters(in: .whitespacesAndNewlines), !versionID.isEmpty {
            arguments += ["--external-version-id", versionID]
        }
        if purchaseIfNeeded {
            arguments.append("--purchase")
        }
        let payload = try run(arguments)
        let parsed = try downloadResult(from: payload, fallback: proposed)
        guard FileManager.default.fileExists(atPath: parsed.url.path) else {
            throw IpaStoreError.noOutput
        }
        var log = [L("ipastore.log.downloaded", parsed.url.lastPathComponent)]
        if parsed.purchased {
            log.append(L("ipastore.log.purchased"))
        }
        log.append(L("ipastore.log.encrypted"))
        let identity = try? IpaService.identity(ipaAt: parsed.url)
        if let identity {
            log.append(L("ipastore.log.identity", identity.appName, identity.versionLabel))
        }
        return IpaStoreDownload(
            ipaURL: parsed.url,
            purchased: parsed.purchased,
            identity: identity,
            log: log
        )
    }

    // MARK: - 解析（单测直接喂 ipatool JSON）

    public static func parseApps(from output: String) throws -> [IpaStoreApp] {
        try apps(from: try decode(output))
    }

    public static func parseAccount(from output: String) throws -> IpaStoreAccount {
        try account(from: try decode(output), fallback: output)
    }

    public static func parseVersionIDs(from output: String) throws -> [String] {
        try versionIDs(from: try decode(output))
    }

    public static func parseVersionMetadata(from output: String, fallbackID: String = "") throws -> IpaStoreVersion {
        try version(from: try decode(output), fallbackID: fallbackID)
    }

    public static func parseDownload(from output: String, fallback: URL? = nil) throws -> (url: URL, purchased: Bool) {
        try downloadResult(from: try decode(output), fallback: fallback)
    }

    public static func requiresTwoFactor(_ output: String) -> Bool {
        let text = output.lowercased()
        return text.contains("2fa")
            || text.contains("auth-code")
            || text.contains("auth code")
            || text.contains("two-factor")
            || text.contains("two factor")
    }

    // MARK: - 私有

    private struct Payload {
        var object: [String: Any]
        var raw: String
        var succeeded: Bool
    }

    private static func run(_ arguments: [String], treatTwoFactorAsError: Bool = false) throws -> Payload {
        guard ExternalTool.ipatool.isAvailable else { throw IpaStoreError.toolMissing }
        let result = try ExternalTool.ipatool.run(arguments + ["--format", "json", "--non-interactive"])
        let combined = result.combinedOutput
        if treatTwoFactorAsError, requiresTwoFactor(combined) {
            throw IpaStoreError.twoFactorRequired
        }
        if let payload = try? decode(combined) {
            if !result.succeeded || payload.succeeded == false {
                throw mappedFailure(payload, fallback: combined)
            }
            return payload
        }
        if !result.succeeded {
            throw mappedFailure(
                Payload(object: [:], raw: combined, succeeded: false),
                fallback: combined
            )
        }
        throw IpaStoreError.invalidJSON(String(combined.prefix(400)))
    }

    private static func mappedFailure(_ payload: Payload, fallback: String) -> IpaStoreError {
        let message = payloadMessage(payload.object) ?? fallback
        if requiresTwoFactor(message) || requiresTwoFactor(fallback) {
            return .twoFactorRequired
        }
        let lowered = (message + "\n" + fallback).lowercased()
        if lowered.contains("not logged")
            || lowered.contains("no account")
            || lowered.contains("failed to get account")
            || lowered.contains("keychain")
            || lowered.contains("keyring") {
            return .notLoggedIn
        }
        return .commandFailed(message)
    }

    private static func decode(_ output: String) throws -> Payload {
        let objects = jsonObjects(in: output)
        guard let object = preferredObject(in: objects) else {
            if requiresTwoFactor(output) { throw IpaStoreError.twoFactorRequired }
            throw IpaStoreError.invalidJSON(String(output.prefix(400)))
        }
        let failed = object["success"] as? Bool == false
        return Payload(object: object, raw: output, succeeded: !failed)
    }

    private static func jsonObjects(in text: String) -> [[String: Any]] {
        var objects: [[String: Any]] = []
        let candidates = [text] + text.split(whereSeparator: \.isNewline).map(String.init)
        var seen = Set<String>()
        for candidate in candidates {
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("{"), !seen.contains(trimmed) else { continue }
            seen.insert(trimmed)
            guard let data = trimmed.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            objects.append(object)
        }
        return objects
    }

    private static func preferredObject(in objects: [[String: Any]]) -> [String: Any]? {
        let keys = ["apps", "results", "externalVersionIdentifiers", "output", "email", "displayVersion"]
        return objects.last { object in
            keys.contains { object[$0] != nil } || object["success"] != nil
        } ?? objects.last
    }

    private static func apps(from payload: Payload) throws -> [IpaStoreApp] {
        let rows: [[String: Any]]
        if let apps = payload.object["apps"] as? [[String: Any]] {
            rows = apps
        } else if let results = payload.object["results"] as? [[String: Any]] {
            rows = results
        } else if payload.object["count"] as? Int == 0 {
            return []
        } else {
            throw IpaStoreError.invalidJSON(String(payload.raw.prefix(400)))
        }
        return rows.compactMap(app(from:))
    }

    private static func app(from json: [String: Any]) -> IpaStoreApp? {
        let storeID = int64(json["id"]) ?? int64(json["trackId"])
        let bundle = string(json["bundleID"]) ?? string(json["bundleId"]) ?? ""
        let name = string(json["name"]) ?? string(json["trackName"]) ?? ""
        guard let storeID, !bundle.isEmpty || !name.isEmpty else { return nil }
        return IpaStoreApp(
            storeID: storeID,
            bundleIdentifier: bundle,
            name: name.isEmpty ? bundle : name,
            version: string(json["version"]) ?? "",
            price: double(json["price"])
        )
    }

    private static func account(from payload: Payload, fallback: String) throws -> IpaStoreAccount {
        let email = string(payload.object["email"]) ?? ""
        let name = string(payload.object["name"]) ?? ""
        guard !email.isEmpty || !name.isEmpty else {
            if requiresTwoFactor(fallback) { throw IpaStoreError.twoFactorRequired }
            throw IpaStoreError.notLoggedIn
        }
        return IpaStoreAccount(name: name, email: email)
    }

    private static func versionIDs(from payload: Payload) throws -> [String] {
        guard let value = payload.object["externalVersionIdentifiers"] else {
            throw IpaStoreError.invalidJSON(String(payload.raw.prefix(400)))
        }
        if let strings = value as? [String] {
            return strings.filter { !$0.isEmpty }
        }
        if let numbers = value as? [NSNumber] {
            return numbers.map(\.stringValue)
        }
        if let any = value as? [Any] {
            return any.compactMap { item in
                if let text = item as? String, !text.isEmpty { return text }
                if let number = item as? NSNumber { return number.stringValue }
                return nil
            }
        }
        throw IpaStoreError.invalidJSON(String(payload.raw.prefix(400)))
    }

    private static func version(from payload: Payload, fallbackID: String) throws -> IpaStoreVersion {
        let id = string(payload.object["externalVersionID"]) ?? fallbackID
        guard !id.isEmpty else { throw IpaStoreError.invalidJSON(String(payload.raw.prefix(400))) }
        return IpaStoreVersion(
            externalVersionID: id,
            displayVersion: string(payload.object["displayVersion"]),
            releaseDate: string(payload.object["releaseDate"])
        )
    }

    private static func downloadResult(from payload: Payload, fallback: URL?) throws -> (url: URL, purchased: Bool) {
        let purchased = bool(payload.object["purchased"]) ?? false
        if let path = string(payload.object["output"]), !path.isEmpty {
            return (URL(fileURLWithPath: path), purchased)
        }
        if let fallback, FileManager.default.fileExists(atPath: fallback.path) {
            return (fallback, purchased)
        }
        throw IpaStoreError.noOutput
    }

    private static func appArguments(_ command: [String], app: IpaStoreApp) -> [String] {
        var arguments = command
        if app.storeID > 0 {
            arguments += ["--app-id", "\(app.storeID)"]
        }
        let bundle = app.bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        if !bundle.isEmpty {
            arguments += ["--bundle-identifier", bundle]
        }
        return arguments
    }

    private static func suggestedFileName(app: IpaStoreApp, externalVersionID: String?) -> String {
        let bundle = app.bundleIdentifier.isEmpty ? "app-\(app.storeID)" : app.bundleIdentifier
        if let versionID = externalVersionID?.trimmingCharacters(in: .whitespacesAndNewlines), !versionID.isEmpty {
            return "\(bundle)_\(versionID).ipa"
        }
        if !app.version.isEmpty {
            return "\(bundle)_\(app.version).ipa"
        }
        return "\(bundle).ipa"
    }

    private static func payloadMessage(_ object: [String: Any]) -> String? {
        string(object["error"]) ?? string(object["err"]) ?? string(object["message"])
    }

    private static func string(_ value: Any?) -> String? {
        if let text = value as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let number = value as? NSNumber {
            return number.stringValue
        }
        return nil
    }

    private static func int64(_ value: Any?) -> Int64? {
        if let number = value as? NSNumber { return number.int64Value }
        if let text = value as? String { return Int64(text) }
        return nil
    }

    private static func double(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let text = value as? String { return Double(text) }
        return nil
    }

    private static func bool(_ value: Any?) -> Bool? {
        if let flag = value as? Bool { return flag }
        if let number = value as? NSNumber { return number.boolValue }
        return nil
    }
}
