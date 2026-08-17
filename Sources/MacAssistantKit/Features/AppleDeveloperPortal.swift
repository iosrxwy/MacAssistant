import Foundation

/// QH65B2 响应解析。与网络无关，便于用固定字典做单测。
public enum DeveloperPortalParser {

    public static func teams(from root: [String: Any]) -> [AppleDeveloperServices.Team] {
        let items = AppleDeveloperServices.array(root["teams"])
            ?? AppleDeveloperServices.array(root["team"])
            ?? []
        return items.compactMap { item in
            guard let dict = item as? [String: Any] else { return nil }
            let id = AppleDeveloperServices.string(dict["teamId"])
                ?? AppleDeveloperServices.string(dict["teamID"])
                ?? ""
            let name = AppleDeveloperServices.string(dict["name"]) ?? id
            return id.isEmpty ? nil : AppleDeveloperServices.Team(id: id, name: name)
        }
    }

    public static func devices(from root: [String: Any]) -> [AppleDeveloperServices.RemoteDevice] {
        let items = AppleDeveloperServices.array(root["devices"]) ?? []
        return items.compactMap { item in
            guard let dict = item as? [String: Any] else { return nil }
            let udid = AppleDeveloperServices.string(dict["deviceNumber"])
                ?? AppleDeveloperServices.string(dict["udid"])
                ?? ""
            let id = AppleDeveloperServices.string(dict["deviceId"])
                ?? AppleDeveloperServices.string(dict["deviceID"])
                ?? udid
            let name = AppleDeveloperServices.string(dict["name"]) ?? udid
            return udid.isEmpty ? nil : AppleDeveloperServices.RemoteDevice(id: id, name: name, udid: udid)
        }
    }

    public static func certificates(from root: [String: Any]) -> [AppleDeveloperServices.RemoteCertificate] {
        let items = AppleDeveloperServices.array(root["certificates"])
            ?? AppleDeveloperServices.array(root["certificate"])
            ?? []
        return items.compactMap { item in
            guard let dict = item as? [String: Any] else { return nil }
            let id = AppleDeveloperServices.string(dict["certificateId"])
                ?? AppleDeveloperServices.string(dict["id"])
                ?? ""
            guard !id.isEmpty else { return nil }
            return AppleDeveloperServices.RemoteCertificate(
                id: id,
                name: AppleDeveloperServices.string(dict["name"]) ?? "Apple Development",
                expiration: AppleDeveloperServices.date(dict["expirationDate"])
                    ?? AppleDeveloperServices.date(dict["expirationDateString"]),
                content: AppleDeveloperServices.data(dict["certContent"])
                    ?? AppleDeveloperServices.data(dict["certificateContent"])
                    ?? Data()
            )
        }
    }

    public static func appIDs(from root: [String: Any]) -> [AppleDeveloperServices.RemoteAppID] {
        let items = AppleDeveloperServices.array(root["appIds"])
            ?? AppleDeveloperServices.array(root["appId"])
            ?? []
        return items.compactMap { item in
            guard let dict = item as? [String: Any] else { return nil }
            let identifier = AppleDeveloperServices.string(dict["identifier"]) ?? ""
            let id = AppleDeveloperServices.string(dict["appIdId"])
                ?? AppleDeveloperServices.string(dict["appIdID"])
                ?? identifier
            guard !identifier.isEmpty || !id.isEmpty else { return nil }
            return AppleDeveloperServices.RemoteAppID(
                id: id,
                identifier: identifier.isEmpty ? id : identifier,
                name: AppleDeveloperServices.string(dict["name"]) ?? identifier
            )
        }
    }

    public static func appID(from root: [String: Any], fallbackIdentifier: String) -> AppleDeveloperServices.RemoteAppID {
        let dict = AppleDeveloperServices.dictionary(root["appId"]) ?? root
        let identifier = AppleDeveloperServices.string(dict["identifier"]) ?? fallbackIdentifier
        let id = AppleDeveloperServices.string(dict["appIdId"])
            ?? AppleDeveloperServices.string(dict["appIdID"])
            ?? identifier
        return AppleDeveloperServices.RemoteAppID(
            id: id,
            identifier: identifier,
            name: AppleDeveloperServices.string(dict["name"]) ?? identifier
        )
    }

    public static func appGroups(from root: [String: Any]) -> [AppleDeveloperServices.RemoteAppGroup] {
        let items = AppleDeveloperServices.array(root["applicationGroupList"])
            ?? AppleDeveloperServices.array(root["applicationGroups"])
            ?? AppleDeveloperServices.array(root["appGroups"])
            ?? []
        return items.compactMap { item in
            guard let dict = item as? [String: Any] else { return nil }
            let identifier = AppleDeveloperServices.string(dict["identifier"])
                ?? AppleDeveloperServices.string(dict["applicationGroup"])
                ?? ""
            let id = AppleDeveloperServices.string(dict["applicationGroupId"])
                ?? AppleDeveloperServices.string(dict["applicationGroupID"])
                ?? identifier
            guard !identifier.isEmpty || !id.isEmpty else { return nil }
            return AppleDeveloperServices.RemoteAppGroup(
                id: id,
                identifier: identifier.isEmpty ? id : identifier,
                name: AppleDeveloperServices.string(dict["name"]) ?? identifier
            )
        }
    }

    public static func profiles(from root: [String: Any]) -> [AppleDeveloperServices.RemoteProvisioningProfile] {
        let items = AppleDeveloperServices.array(root["provisioningProfiles"])
            ?? AppleDeveloperServices.array(root["provisioningProfile"])
            ?? []
        return items.compactMap { item in
            guard let dict = item as? [String: Any] else { return nil }
            let id = AppleDeveloperServices.string(dict["provisioningProfileId"])
                ?? AppleDeveloperServices.string(dict["UUID"])
                ?? AppleDeveloperServices.string(dict["id"])
                ?? ""
            guard !id.isEmpty else { return nil }
            let app = AppleDeveloperServices.dictionary(dict["appId"])
            return AppleDeveloperServices.RemoteProvisioningProfile(
                id: id,
                name: AppleDeveloperServices.string(dict["name"]) ?? id,
                appID: AppleDeveloperServices.string(app?["appIdId"])
                    ?? AppleDeveloperServices.string(app?["identifier"])
                    ?? AppleDeveloperServices.string(dict["appIdId"])
            )
        }
    }

    public static func encodedProfile(from root: [String: Any]) -> Data? {
        let profile = AppleDeveloperServices.dictionary(root["provisioningProfile"]) ?? root
        return AppleDeveloperServices.data(profile["encodedProfile"])
            ?? AppleDeveloperServices.data(root["encodedProfile"])
    }

    public static func certificate(fromSubmit root: [String: Any]) -> AppleDeveloperServices.RemoteCertificate? {
        let dict = AppleDeveloperServices.dictionary(root["certRequest"])
            ?? AppleDeveloperServices.dictionary(root["certificate"])
            ?? root
        let content = AppleDeveloperServices.data(dict["certContent"])
            ?? AppleDeveloperServices.data(root["certContent"])
            ?? Data()
        guard !content.isEmpty else { return nil }
        return AppleDeveloperServices.RemoteCertificate(
            id: AppleDeveloperServices.string(dict["certificateId"])
                ?? AppleDeveloperServices.string(dict["certRequestId"])
                ?? "development",
            name: AppleDeveloperServices.string(dict["name"]) ?? "Apple Development",
            expiration: AppleDeveloperServices.date(dict["expirationDate"]),
            content: content
        )
    }
}

/// 本地已保存的开发证书是否还能继续用。
public enum CertificateReuseDecision: Equatable, Sendable {
    /// 钥匙串 / Application Support 里的 key+cert 仍有效，且门户上还能看到同一张证。
    case reuseStored
    /// 名额未满，申请新证，不吊销已有的。
    case requestNew
    /// 免费账号名额已满，先吊销再申请。
    case revokeThenRequest(ids: [String])
}

public enum CertificateReusePlanner {
    /// 免费 Apple ID 的 iOS 开发证书上限（与 Xcode / AltSign 一致）。
    public static let freeAccountSlotLimit = 2

    public static func decide(
        stored: StoredDevelopmentCertificate?,
        remote: [AppleDeveloperServices.RemoteCertificate],
        now: Date = Date(),
        slotLimit: Int = freeAccountSlotLimit
    ) -> CertificateReuseDecision {
        if let stored, stored.isUnexpired(at: now) {
            let stillRemote = remote.contains {
                $0.id.caseInsensitiveCompare(stored.certificateID) == .orderedSame
            }
            if stillRemote { return .reuseStored }
        }
        if remote.count >= slotLimit {
            return .revokeThenRequest(ids: remote.map(\.id))
        }
        return .requestNew
    }
}

public struct StoredDevelopmentCertificate: Equatable, Sendable, Codable {
    public var teamID: String
    public var certificateID: String
    public var name: String
    public var expiration: Date?
    public var keyPath: String
    public var certPath: String

    public var keyURL: URL { URL(fileURLWithPath: keyPath) }
    public var certURL: URL { URL(fileURLWithPath: certPath) }

    public func filesExist() -> Bool {
        FileManager.default.fileExists(atPath: keyPath)
            && FileManager.default.fileExists(atPath: certPath)
    }

    public func isUnexpired(at now: Date = Date()) -> Bool {
        if let expiration { return expiration > now }
        return true
    }

    public func isReusable(at now: Date = Date()) -> Bool {
        filesExist() && isUnexpired(at: now)
    }
}

enum DevelopmentCertificateStore {
    private static var root: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MacAssistant/AppleIDCerts", isDirectory: true)
    }

    static func directory(teamID: String) -> URL {
        root.appendingPathComponent(teamID, isDirectory: true)
    }

    static func load(teamID: String) -> StoredDevelopmentCertificate? {
        let meta = directory(teamID: teamID).appendingPathComponent("meta.json")
        guard let data = try? Data(contentsOf: meta),
              let stored = try? JSONDecoder().decode(StoredDevelopmentCertificate.self, from: data),
              stored.isReusable()
        else { return nil }
        return stored
    }

    static func save(
        teamID: String,
        keyURL: URL,
        certURL: URL,
        certificate: AppleDeveloperServices.RemoteCertificate
    ) {
        let dir = directory(teamID: teamID)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let storedKey = dir.appendingPathComponent("key.pem")
        let storedCert = dir.appendingPathComponent("dev.cer")
        try? FileManager.default.removeItem(at: storedKey)
        try? FileManager.default.removeItem(at: storedCert)
        try? FileManager.default.copyItem(at: keyURL, to: storedKey)
        try? FileManager.default.copyItem(at: certURL, to: storedCert)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: storedKey.path)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: storedCert.path)
        let stored = StoredDevelopmentCertificate(
            teamID: teamID,
            certificateID: certificate.id,
            name: certificate.name,
            expiration: certificate.expiration,
            keyPath: storedKey.path,
            certPath: storedCert.path
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(stored) else { return }
        let meta = dir.appendingPathComponent("meta.json")
        try? data.write(to: meta, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: meta.path)
    }
}

public struct DeveloperPortalSnapshot: Sendable {
    public var teams: [AppleDeveloperServices.Team]
    public var devices: [AppleDeveloperServices.RemoteDevice]
    public var certificates: [AppleDeveloperServices.RemoteCertificate]
    public var appIDs: [AppleDeveloperServices.RemoteAppID]
    public var appGroups: [AppleDeveloperServices.RemoteAppGroup]
}

extension AppleDeveloperServices {

    static func developerSession(from token: LoginToken) throws -> (GSASession, AnisetteHeaders) {
        let anisette = try fetchAnisette()
        return (GSASession(adsid: token.adsid, token: token.token, expiry: token.expiry), anisette)
    }

    public static func fetchTeams(token: LoginToken) throws -> [Team] {
        let (session, anisette) = try developerSession(from: token)
        return try listTeams(token: session, anisette: anisette)
    }

    public static func fetchDevices(token: LoginToken) throws -> [RemoteDevice] {
        let (session, anisette) = try developerSession(from: token)
        let root = try sendDeveloper(
            action: "listDevices.action",
            parameters: ["teamId": token.teamID],
            token: session,
            anisette: anisette
        )
        return DeveloperPortalParser.devices(from: root)
    }

    public static func registerDevice(
        _ device: ConnectedDevice,
        token: LoginToken,
        log: inout [String]
    ) throws {
        let existing = try fetchDevices(token: token)
        if existing.contains(where: { $0.udid.caseInsensitiveCompare(device.udid) == .orderedSame }) {
            log.append(L("appleid.log.deviceAlreadyRegistered", device.udid))
            return
        }
        let (session, anisette) = try developerSession(from: token)
        _ = try sendDeveloper(
            action: "addDevice.action",
            parameters: [
                "teamId": token.teamID,
                "deviceNumber": device.udid,
                "name": device.name.isEmpty ? device.udid : device.name
            ],
            token: session,
            anisette: anisette
        )
        log.append(L("appleid.log.deviceRegistered", device.name, device.udid))
    }

    public static func fetchCertificates(token: LoginToken) throws -> [RemoteCertificate] {
        let (session, anisette) = try developerSession(from: token)
        let root = try sendDeveloper(
            action: "listAllDevelopmentCerts.action",
            parameters: ["teamId": token.teamID],
            token: session,
            anisette: anisette
        )
        return DeveloperPortalParser.certificates(from: root)
    }

    public static func addCertificate(
        machineName: String,
        csrURL: URL,
        token: LoginToken
    ) throws -> RemoteCertificate {
        let (session, anisette) = try developerSession(from: token)
        let csr = try String(contentsOf: csrURL, encoding: .utf8)
        let submitted = try sendDeveloper(
            action: "submitDevelopmentCSR.action",
            parameters: [
                "teamId": token.teamID,
                "csrContent": csr,
                "machineName": machineName,
                "machineId": Host.current().localizedName ?? machineName
            ],
            token: session,
            anisette: anisette
        )
        guard let certificate = DeveloperPortalParser.certificate(fromSubmit: submitted) else {
            throw AppleIDSigningError.certificateFailed
        }
        return certificate
    }

    public static func revokeCertificate(_ certificate: RemoteCertificate, token: LoginToken) throws {
        try revokeCertificate(id: certificate.id, token: token)
    }

    public static func revokeCertificate(id: String, token: LoginToken) throws {
        let (session, anisette) = try developerSession(from: token)
        _ = try sendDeveloper(
            action: "revokeDevelopmentCert.action",
            parameters: ["teamId": token.teamID, "certificateId": id],
            token: session,
            anisette: anisette
        )
    }

    public static func fetchAppIDs(token: LoginToken) throws -> [RemoteAppID] {
        let (session, anisette) = try developerSession(from: token)
        let root = try sendDeveloper(
            action: "listAppIds.action",
            parameters: ["teamId": token.teamID],
            token: session,
            anisette: anisette
        )
        return DeveloperPortalParser.appIDs(from: root)
    }

    public static func addAppID(bundleID: String, name: String? = nil, token: LoginToken) throws -> RemoteAppID {
        let (session, anisette) = try developerSession(from: token)
        let created = try sendDeveloper(
            action: "addAppId.action",
            parameters: [
                "teamId": token.teamID,
                "identifier": bundleID,
                "name": name ?? appIDName(from: bundleID)
            ],
            token: session,
            anisette: anisette
        )
        return DeveloperPortalParser.appID(from: created, fallbackIdentifier: bundleID)
    }

    public static func updateAppID(_ appID: RemoteAppID, name: String, token: LoginToken) throws -> RemoteAppID {
        let (session, anisette) = try developerSession(from: token)
        let updated = try sendDeveloper(
            action: "updateAppId.action",
            parameters: [
                "teamId": token.teamID,
                "appIdId": appID.id,
                "name": name
            ],
            token: session,
            anisette: anisette
        )
        return DeveloperPortalParser.appID(from: updated, fallbackIdentifier: appID.identifier)
    }

    public static func deleteAppID(_ appID: RemoteAppID, token: LoginToken) throws {
        let (session, anisette) = try developerSession(from: token)
        _ = try sendDeveloper(
            action: "deleteAppId.action",
            parameters: [
                "teamId": token.teamID,
                "appIdId": appID.id
            ],
            token: session,
            anisette: anisette
        )
    }

    public static func ensureAppID(
        bundleID: String,
        token: LoginToken,
        log: inout [String]
    ) throws -> RemoteAppID {
        let listed = try fetchAppIDs(token: token)
        if let match = listed.first(where: {
            $0.identifier.caseInsensitiveCompare(bundleID) == .orderedSame
        }) {
            log.append(L("appleid.log.appIDExists", bundleID))
            return match
        }
        let created = try addAppID(bundleID: bundleID, token: token)
        log.append(L("appleid.log.appIDCreated", bundleID))
        return created
    }

    public static func fetchAppGroups(token: LoginToken) throws -> [RemoteAppGroup] {
        let (session, anisette) = try developerSession(from: token)
        let root = try sendDeveloper(
            action: "listApplicationGroups.action",
            parameters: ["teamId": token.teamID],
            token: session,
            anisette: anisette
        )
        return DeveloperPortalParser.appGroups(from: root)
    }

    public static func addAppGroup(
        identifier: String,
        name: String,
        token: LoginToken
    ) throws -> RemoteAppGroup {
        let (session, anisette) = try developerSession(from: token)
        let created = try sendDeveloper(
            action: "addApplicationGroup.action",
            parameters: [
                "teamId": token.teamID,
                "identifier": identifier,
                "name": name
            ],
            token: session,
            anisette: anisette
        )
        let groups = DeveloperPortalParser.appGroups(from: created)
        if let match = groups.first(where: {
            $0.identifier.caseInsensitiveCompare(identifier) == .orderedSame
        }) {
            return match
        }
        let dict = dictionary(created["applicationGroup"]) ?? created
        return RemoteAppGroup(
            id: string(dict["applicationGroupId"]) ?? identifier,
            identifier: identifier,
            name: string(dict["name"]) ?? name
        )
    }

    public static func assignAppID(
        _ appID: RemoteAppID,
        to groups: [RemoteAppGroup],
        token: LoginToken
    ) throws {
        let (session, anisette) = try developerSession(from: token)
        for group in groups {
            _ = try sendDeveloper(
                action: "assignApplicationGroupToAppId.action",
                parameters: [
                    "teamId": token.teamID,
                    "appIdId": appID.id,
                    "applicationGroupId": group.id
                ],
                token: session,
                anisette: anisette
            )
        }
    }

    public static func fetchProvisioningProfiles(token: LoginToken) throws -> [RemoteProvisioningProfile] {
        let (session, anisette) = try developerSession(from: token)
        let root = try sendDeveloper(
            action: "listProvisioningProfiles.action",
            parameters: ["teamId": token.teamID],
            token: session,
            anisette: anisette
        )
        return DeveloperPortalParser.profiles(from: root)
    }

    public static func fetchProvisioningProfile(
        for appID: RemoteAppID,
        token: LoginToken
    ) throws -> Data {
        let (session, anisette) = try developerSession(from: token)
        let root = try sendDeveloper(
            action: "downloadTeamProvisioningProfile.action",
            parameters: [
                "teamId": token.teamID,
                "appIdId": appID.id
            ],
            token: session,
            anisette: anisette
        )
        guard let encoded = DeveloperPortalParser.encodedProfile(from: root) else {
            throw AppleIDSigningError.profileFailed
        }
        return encoded
    }

    public static func deleteProvisioningProfile(
        _ profile: RemoteProvisioningProfile,
        token: LoginToken
    ) throws {
        let (session, anisette) = try developerSession(from: token)
        _ = try sendDeveloper(
            action: "deleteProvisioningProfile.action",
            parameters: [
                "teamId": token.teamID,
                "provisioningProfileId": profile.id
            ],
            token: session,
            anisette: anisette
        )
    }

    public static func fetchSnapshot(token: LoginToken) throws -> DeveloperPortalSnapshot {
        DeveloperPortalSnapshot(
            teams: token.teams.isEmpty ? (try fetchTeams(token: token)) : token.teams,
            devices: (try? fetchDevices(token: token)) ?? [],
            certificates: (try? fetchCertificates(token: token)) ?? [],
            appIDs: (try? fetchAppIDs(token: token)) ?? [],
            appGroups: (try? fetchAppGroups(token: token)) ?? []
        )
    }
}
