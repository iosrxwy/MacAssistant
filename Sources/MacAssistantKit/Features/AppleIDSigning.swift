import Foundation
import Security

public enum AppleIDSigningError: LocalizedError {
    case anisetteUnavailable
    case twoFactorRequired
    case invalidCredentials
    case noTeam
    case srpInvalidServer
    case developerAPI(String)
    case certificateFailed
    case profileFailed
    case network(String)
    case noAccount
    case noIPA
    case noDevice
    case xtoolFailed(String)

    public var errorDescription: String? {
        switch self {
        case .anisetteUnavailable: return L("appleid.error.anisetteUnavailable")
        case .twoFactorRequired: return L("appleid.error.twoFactorRequired")
        case .invalidCredentials: return L("appleid.error.invalidCredentials")
        case .noTeam: return L("appleid.error.noTeam")
        case .srpInvalidServer: return L("appleid.error.srpInvalidServer")
        case let .developerAPI(message): return L("appleid.error.developerAPI", message)
        case .certificateFailed: return L("appleid.error.certificateFailed")
        case .profileFailed: return L("appleid.error.profileFailed")
        case let .network(message): return L("appleid.error.network", message)
        case .noAccount: return L("appleid.error.noAccount")
        case .noIPA: return L("appleid.error.noIPA")
        case .noDevice: return L("appleid.error.noDevice")
        case let .xtoolFailed(message): return L("appleid.error.xtoolFailed", message)
        }
    }
}

public struct AppleIDAccount: Sendable, Equatable {
    public var appleID: String
    public var hasPassword: Bool
}

public struct AppleIDRenewalJob: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var appleID: String
    public var displayName: String
    public var bundleID: String
    public var deviceUDID: String
    public var deviceName: String
    public var ipaPath: String
    public var ipaBookmark: Data?
    public var lastOutputPath: String?
    public var lastSignedAt: Date
    public var expiresAt: Date
    public var autoRenew: Bool

    public init(
        id: UUID = UUID(),
        appleID: String,
        displayName: String,
        bundleID: String,
        deviceUDID: String,
        deviceName: String,
        ipaPath: String,
        ipaBookmark: Data? = nil,
        lastOutputPath: String? = nil,
        lastSignedAt: Date = Date(),
        expiresAt: Date,
        autoRenew: Bool = true
    ) {
        self.id = id
        self.appleID = appleID
        self.displayName = displayName
        self.bundleID = bundleID
        self.deviceUDID = deviceUDID
        self.deviceName = deviceName
        self.ipaPath = ipaPath
        self.ipaBookmark = ipaBookmark
        self.lastOutputPath = lastOutputPath
        self.lastSignedAt = lastSignedAt
        self.expiresAt = expiresAt
        self.autoRenew = autoRenew
    }

    public func isDue(now: Date = Date(), lead: TimeInterval = 24 * 60 * 60) -> Bool {
        expiresAt <= now.addingTimeInterval(lead)
    }

    public func remaining(now: Date = Date()) -> TimeInterval {
        expiresAt.timeIntervalSince(now)
    }
}

public struct AppleIDSigningRecipe: Codable, Hashable, Sendable {
    public var appleID: String
    public var teamID: String
    public var teamName: String
    public var deviceUDID: String
    public var deviceName: String
    public var rewriteBundleIDOnConflict: Bool

    public init(
        appleID: String,
        teamID: String = "",
        teamName: String = "",
        deviceUDID: String = "",
        deviceName: String = "",
        rewriteBundleIDOnConflict: Bool = true
    ) {
        self.appleID = appleID
        self.teamID = teamID
        self.teamName = teamName
        self.deviceUDID = deviceUDID
        self.deviceName = deviceName
        self.rewriteBundleIDOnConflict = rewriteBundleIDOnConflict
    }

    public var isComplete: Bool {
        !appleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !teamID.isEmpty
            && !deviceUDID.isEmpty
    }

    public var isPartial: Bool {
        !appleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isComplete
    }

    public var device: ConnectedDevice {
        ConnectedDevice(
            udid: deviceUDID,
            name: deviceName.isEmpty ? deviceUDID : deviceName
        )
    }
}

public struct AppleIDSignRequest: Sendable {
    public var ipaURL: URL
    public var appleID: String
    public var password: String
    public var twoFactorCode: String?
    public var device: ConnectedDevice
    public var teamID: String?
    public var installToDevice: Bool
    public var addRenewal: Bool
    public var rememberAccount: Bool
    public var rewriteBundleIDOnConflict: Bool

    public init(
        ipaURL: URL,
        appleID: String,
        password: String,
        twoFactorCode: String? = nil,
        device: ConnectedDevice,
        teamID: String? = nil,
        installToDevice: Bool = true,
        addRenewal: Bool = true,
        rememberAccount: Bool = true,
        rewriteBundleIDOnConflict: Bool = true
    ) {
        self.ipaURL = ipaURL
        self.appleID = appleID
        self.password = password
        self.twoFactorCode = twoFactorCode
        self.device = device
        self.teamID = teamID
        self.installToDevice = installToDevice
        self.addRenewal = addRenewal
        self.rememberAccount = rememberAccount
        self.rewriteBundleIDOnConflict = rewriteBundleIDOnConflict
    }
}

public struct AppleIDSignResult: Sendable {
    public var outputURL: URL
    public var expiresAt: Date
    public var installed: Bool
    public var job: AppleIDRenewalJob?
    public var log: [String]
}

/// Apple ID 签名：登录 → 注册设备 → 申请 7 天开发证书 / 描述文件 → 由内向外重签 → 可选装机。
///
/// 免费 Apple ID 的开发证书与描述文件约 7 天过期，续签会走同一条链路。
/// 实现参考 AltSign、xtool / XKit、libimobiledevice，不捆绑第三方二进制。
public enum AppleIDSigningService {

    public static func rememberedAccount() -> AppleIDAccount? {
        AppleIDAccountStore.rememberedAccount()
    }

    public static func rememberedPassword(for appleID: String) -> String? {
        AppleIDAccountStore.password(for: appleID)
    }

    public static func forgetAccount() {
        AppleIDAccountStore.clear()
    }

    public static func login(
        appleID: String,
        password: String,
        twoFactorCode: String? = nil,
        remember: Bool = true
    ) throws -> AppleDeveloperServices.LoginToken {
        let trimmed = appleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !password.isEmpty else { throw AppleIDSigningError.noAccount }
        if remember {
            AppleIDAccountStore.save(appleID: trimmed, password: password)
        }
        if let cached = AppleIDAccountStore.session(for: trimmed), !cached.isExpired {
            return cached
        }
        let token = try AppleDeveloperServices.login(
            appleID: trimmed,
            password: password,
            twoFactorCode: twoFactorCode
        )
        AppleIDAccountStore.saveSession(token)
        return token
    }

    public static func selectTeam(
        _ team: AppleDeveloperServices.Team,
        token: AppleDeveloperServices.LoginToken
    ) -> AppleDeveloperServices.LoginToken {
        let next = AppleDeveloperServices.selectTeam(team, token: token)
        AppleIDAccountStore.saveSession(next)
        return next
    }

    public static func currentSession(for appleID: String) -> AppleDeveloperServices.LoginToken? {
        guard let token = AppleIDAccountStore.session(for: appleID), !token.isExpired else { return nil }
        return token
    }

    public static func fetchSnapshot(
        token: AppleDeveloperServices.LoginToken
    ) throws -> DeveloperPortalSnapshot {
        try AppleDeveloperServices.fetchSnapshot(token: token)
    }

    public static func provision(
        token: AppleDeveloperServices.LoginToken,
        bundleIDs: [String],
        device: ConnectedDevice,
        rewriteOnConflict: Bool = true,
        log: inout [String]
    ) throws -> AppleDeveloperServices.ProvisionedIdentity {
        do {
            return try AppleDeveloperServices.provision(
                token: token,
                bundleIDs: bundleIDs,
                device: device,
                revokeExistingCertificates: false,
                log: &log
            )
        } catch {
            guard rewriteOnConflict else { throw error }
            let rewritten = bundleIDs.map {
                AppleDeveloperServices.teamPrefixedBundleID(original: $0, teamID: token.teamID)
            }
            log.append(L("appleid.log.rewriteBundleID", rewritten.joined(separator: ", ")))
            return try AppleDeveloperServices.provision(
                token: token,
                bundleIDs: rewritten,
                device: device,
                revokeExistingCertificates: false,
                log: &log
            )
        }
    }

    /// 工作台 / 注入计划：登录（或复用会话）→ 选团队 → 申请/复用证书 → 刷 profile → 由内向外重签。
    public static func applyToApp(
        _ app: URL,
        recipe: AppleIDSigningRecipe,
        overrideBundleID: String? = nil,
        twoFactorCode: String? = nil,
        log: inout [String]
    ) throws -> AppleDeveloperServices.ProvisionedIdentity {
        guard !recipe.appleID.isEmpty else { throw AppleIDSigningError.noAccount }
        guard !recipe.deviceUDID.isEmpty else { throw AppleIDSigningError.noDevice }
        guard let password = AppleIDAccountStore.password(for: recipe.appleID) else {
            throw AppleIDSigningError.noAccount
        }
        var token = try login(
            appleID: recipe.appleID,
            password: password,
            twoFactorCode: twoFactorCode,
            remember: true
        )
        if !recipe.teamID.isEmpty {
            let team = token.teams.first(where: { $0.id == recipe.teamID })
                ?? AppleDeveloperServices.Team(id: recipe.teamID, name: recipe.teamName)
            token = selectTeam(team, token: token)
        }
        var bundleIDs = try SigningService.profileBundleIDs(in: app)
        if bundleIDs.isEmpty {
            let plist = try IpaService.infoPlist(appBundle: app)
            if let bundleID = plist["CFBundleIdentifier"] as? String { bundleIDs = [bundleID] }
        }
        if let override = overrideBundleID?.trimmingCharacters(in: .whitespacesAndNewlines), !override.isEmpty {
            bundleIDs = [override]
        }
        guard !bundleIDs.isEmpty else { throw AppleIDSigningError.noIPA }
        let provisioned = try provision(
            token: token,
            bundleIDs: bundleIDs,
            device: recipe.device,
            rewriteOnConflict: recipe.rewriteBundleIDOnConflict,
            log: &log
        )
        let usedBundleIDs = Array(provisioned.profilesByBundleID.keys)
        if usedBundleIDs != bundleIDs, let root = usedBundleIDs.first {
            try SigningService.rewriteBundleIDGraph(in: app, rootBundleID: root)
        }
        try SigningService.resignRealDeviceGraph(
            app: app,
            identity: provisioned.identity,
            profilesByBundleID: provisioned.profilesByBundleID,
            overrideBundleID: usedBundleIDs.first,
            entitlementsPolicy: .replaceWithProfile,
            log: &log
        )
        return provisioned
    }

    public static func sign(_ request: AppleIDSignRequest) throws -> AppleIDSignResult {
        var log: [String] = []
        let appleID = request.appleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !appleID.isEmpty, !request.password.isEmpty else { throw AppleIDSigningError.noAccount }
        if request.rememberAccount {
            AppleIDAccountStore.save(appleID: appleID, password: request.password)
        }

        log.append(L("appleid.log.start", request.ipaURL.lastPathComponent, request.device.name))
        if let xtool = try? signWithXTool(request, log: &log) {
            return xtool
        }
        var token = try login(
            appleID: appleID,
            password: request.password,
            twoFactorCode: request.twoFactorCode,
            remember: request.rememberAccount
        )
        if let teamID = request.teamID, !teamID.isEmpty,
           let team = token.teams.first(where: { $0.id == teamID }) {
            token = selectTeam(team, token: token)
        }
        log.append(L("appleid.log.loggedIn", token.teamName, token.teamID))

        let work = try FileSystemHelper.makeTemporaryDirectory(prefix: "appleid-ipa")
        defer { try? FileManager.default.removeItem(at: work) }
        let extract = work.appendingPathComponent("x")
        try IpaService.unzip(request.ipaURL, to: extract)
        try IpaService.validatePayloadStructure(in: extract)
        let app = try IpaService.locateApp(in: extract)
        var bundleIDs = try SigningService.profileBundleIDs(in: app)
        if bundleIDs.isEmpty {
            let plist = try IpaService.infoPlist(appBundle: app)
            if let bundleID = plist["CFBundleIdentifier"] as? String { bundleIDs = [bundleID] }
        }
        guard !bundleIDs.isEmpty else { throw AppleIDSigningError.noIPA }

        let provisioned = try provision(
            token: token,
            bundleIDs: bundleIDs,
            device: request.device,
            rewriteOnConflict: request.rewriteBundleIDOnConflict,
            log: &log
        )
        let usedBundleIDs = Array(provisioned.profilesByBundleID.keys)
        if Set(usedBundleIDs) != Set(bundleIDs), let root = usedBundleIDs.first {
            try SigningService.rewriteBundleIDGraph(in: app, rootBundleID: root)
            bundleIDs = usedBundleIDs
        } else {
            bundleIDs = usedBundleIDs.isEmpty ? bundleIDs : usedBundleIDs
        }

        let recipe = RealDeviceSigningRecipe(
            identityID: provisioned.identity.id,
            identityName: provisioned.identity.name,
            profilesByBundleID: provisioned.profilesByBundleID
        )
        let proposed = request.ipaURL
            .deletingPathExtension()
            .appendingPathExtension("id-signed")
            .appendingPathExtension("ipa")
        let output = FileSystemHelper.uniqueOutputURL(basedOn: proposed)
        let (signed, signLog) = try SigningService.resignIPARealDeviceGraph(
            ipaAt: request.ipaURL,
            recipe: recipe,
            overrideBundleID: bundleIDs.first,
            entitlementsPolicy: .replaceWithProfile,
            output: output
        )
        log.append(contentsOf: signLog)
        try? FileManager.default.removeItem(at: provisioned.workDirectory)

        var installed = false
        if request.installToDevice {
            log.append(L("appleid.log.installing", request.device.name))
            try ConnectedDeviceService.install(ipaAt: signed, to: request.device)
            installed = true
            log.append(L("appleid.log.installed"))
        }

        var job: AppleIDRenewalJob?
        if request.addRenewal {
            job = AppleIDRenewalStore.upsert(
                AppleIDRenewalJob(
                    appleID: appleID,
                    displayName: request.ipaURL.deletingPathExtension().lastPathComponent,
                    bundleID: bundleIDs.first ?? "",
                    deviceUDID: request.device.udid,
                    deviceName: request.device.name,
                    ipaPath: request.ipaURL.path,
                    ipaBookmark: try? request.ipaURL.bookmarkData(
                        options: .withSecurityScope,
                        includingResourceValuesForKeys: nil,
                        relativeTo: nil
                    ),
                    lastOutputPath: signed.path,
                    lastSignedAt: Date(),
                    expiresAt: provisioned.expiresAt,
                    autoRenew: true
                )
            )
            log.append(L("appleid.log.renewalSaved", Self.shortDate(provisioned.expiresAt)))
        }
        return AppleIDSignResult(
            outputURL: signed,
            expiresAt: provisioned.expiresAt,
            installed: installed,
            job: job,
            log: log
        )
    }

    public static func renew(_ job: AppleIDRenewalJob, twoFactorCode: String? = nil) throws -> AppleIDSignResult {
        guard let password = AppleIDAccountStore.password(for: job.appleID) else {
            throw AppleIDSigningError.noAccount
        }
        let ipa = try resolveIPA(for: job)
        let devices = (try? ConnectedDeviceService.listDevices()) ?? []
        let device = devices.first { $0.udid.caseInsensitiveCompare(job.deviceUDID) == .orderedSame }
            ?? ConnectedDevice(udid: job.deviceUDID, name: job.deviceName)
        return try sign(AppleIDSignRequest(
            ipaURL: ipa,
            appleID: job.appleID,
            password: password,
            twoFactorCode: twoFactorCode,
            device: device,
            installToDevice: true,
            addRenewal: true,
            rememberAccount: true
        ))
    }

    public static func renewDueJobs(now: Date = Date()) -> [(AppleIDRenewalJob, Result<AppleIDSignResult, Error>)] {
        AppleIDRenewalStore.load()
            .filter { $0.autoRenew && $0.isDue(now: now) }
            .map { job in
                do {
                    return (job, .success(try renew(job)))
                } catch {
                    return (job, .failure(error))
                }
            }
    }

    private static func resolveIPA(for job: AppleIDRenewalJob) throws -> URL {
        if let bookmark = job.ipaBookmark {
            var stale = false
            if let url = try? URL(
                resolvingBookmarkData: bookmark,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            ) {
                _ = url.startAccessingSecurityScopedResource()
                if FileManager.default.fileExists(atPath: url.path) { return url }
            }
        }
        let url = URL(fileURLWithPath: job.ipaPath)
        guard FileManager.default.fileExists(atPath: url.path) else { throw AppleIDSigningError.noIPA }
        return url
    }

    private static func signWithXTool(
        _ request: AppleIDSignRequest,
        log: inout [String]
    ) throws -> AppleIDSignResult? {
        guard ExternalTool.xtool.isAvailable else { return nil }
        log.append(L("appleid.log.usingXTool"))
        let login = try ExternalTool.xtool.run([
            "auth", "login",
            "--username", request.appleID,
            "--password", request.password
        ])
        if !login.succeeded {
            let output = login.combinedOutput.lowercased()
            if output.contains("two") || output.contains("2fa") || output.contains("code") {
                if let code = request.twoFactorCode, !code.isEmpty {
                    let retry = try ExternalTool.xtool.run([
                        "auth", "login",
                        "--username", request.appleID,
                        "--password", request.password,
                        "--2fa-code", code
                    ])
                    guard retry.succeeded else { throw AppleIDSigningError.xtoolFailed(retry.combinedOutput) }
                } else {
                    throw AppleIDSigningError.twoFactorRequired
                }
            } else {
                throw AppleIDSigningError.xtoolFailed(login.combinedOutput)
            }
        }
        let install = try ExternalTool.xtool.run(["install", request.ipaURL.path])
        guard install.succeeded else { throw AppleIDSigningError.xtoolFailed(install.combinedOutput) }
        log.append(L("appleid.log.xtoolInstalled"))
        let expires = Date().addingTimeInterval(AppleDeveloperServices.freeProfileLifetime)
        let job = request.addRenewal
            ? AppleIDRenewalStore.upsert(
                AppleIDRenewalJob(
                    appleID: request.appleID,
                    displayName: request.ipaURL.deletingPathExtension().lastPathComponent,
                    bundleID: "",
                    deviceUDID: request.device.udid,
                    deviceName: request.device.name,
                    ipaPath: request.ipaURL.path,
                    lastOutputPath: request.ipaURL.path,
                    expiresAt: expires,
                    autoRenew: true
                )
            )
            : nil
        return AppleIDSignResult(
            outputURL: request.ipaURL,
            expiresAt: expires,
            installed: true,
            job: job,
            log: log
        )
    }

    private static func shortDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

enum AppleIDAccountStore {
    private static let passwordService = "com.opensource.macassistant.appleid.password"
    private static let sessionService = "com.opensource.macassistant.appleid.session"
    private static let accountKey = "com.opensource.macassistant.appleid.account"

    static func rememberedAccount() -> AppleIDAccount? {
        let appleID = UserDefaults.standard.string(forKey: accountKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !appleID.isEmpty else { return nil }
        return AppleIDAccount(appleID: appleID, hasPassword: password(for: appleID) != nil)
    }

    static func save(appleID: String, password: String) {
        UserDefaults.standard.set(appleID, forKey: accountKey)
        try? saveKeychain(Data(password.utf8), service: passwordService, account: appleID)
    }

    static func password(for appleID: String) -> String? {
        guard let data = try? keychain(service: passwordService, account: appleID) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func saveSession(_ token: AppleDeveloperServices.LoginToken) {
        guard let data = try? JSONEncoder().encode(token) else { return }
        try? saveKeychain(data, service: sessionService, account: token.appleID)
    }

    static func session(for appleID: String) -> AppleDeveloperServices.LoginToken? {
        guard let data = try? keychain(service: sessionService, account: appleID),
              let token = try? JSONDecoder().decode(AppleDeveloperServices.LoginToken.self, from: data)
        else { return nil }
        return token
    }

    static func clear() {
        if let appleID = UserDefaults.standard.string(forKey: accountKey) {
            deleteKeychain(service: passwordService, account: appleID)
            deleteKeychain(service: sessionService, account: appleID)
        }
        UserDefaults.standard.removeObject(forKey: accountKey)
    }

    private static func keychainQuery(service: String, account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    private static func keychain(service: String, account: String) throws -> Data {
        var query = keychainQuery(service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            throw AppleIDSigningError.noAccount
        }
        return data
    }

    private static func saveKeychain(_ data: Data, service: String, account: String) throws {
        let query = keychainQuery(service: service, account: account)
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = data
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw AppleIDSigningError.noAccount }
    }

    private static func deleteKeychain(service: String, account: String) {
        SecItemDelete(keychainQuery(service: service, account: account) as CFDictionary)
    }
}

public enum AppleIDRenewalStore {
    private static var fileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MacAssistant/AppleIDRenewal.json")
    }

    public static func load() -> [AppleIDRenewalJob] {
        guard let data = try? Data(contentsOf: fileURL),
              let jobs = try? JSONDecoder().decode([AppleIDRenewalJob].self, from: data)
        else { return [] }
        return jobs.sorted { $0.expiresAt < $1.expiresAt }
    }

    @discardableResult
    public static func upsert(_ job: AppleIDRenewalJob) -> AppleIDRenewalJob {
        var jobs = load()
        if let index = jobs.firstIndex(where: {
            $0.ipaPath == job.ipaPath && $0.deviceUDID == job.deviceUDID && $0.appleID == job.appleID
        }) {
            var merged = job
            merged.id = jobs[index].id
            jobs[index] = merged
            save(jobs)
            return merged
        }
        jobs.append(job)
        save(jobs)
        return job
    }

    public static func remove(id: UUID) {
        save(load().filter { $0.id != id })
    }

    public static func setAutoRenew(id: UUID, enabled: Bool) {
        var jobs = load()
        if let index = jobs.firstIndex(where: { $0.id == id }) {
            jobs[index].autoRenew = enabled
            save(jobs)
        }
    }

    public static func dueJobs(now: Date = Date()) -> [AppleIDRenewalJob] {
        load().filter { $0.autoRenew && $0.isDue(now: now) }
    }

    static func save(_ jobs: [AppleIDRenewalJob]) {
        let url = fileURL
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(jobs) else { return }
        try? data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
