import Foundation
import CryptoKit
import Security
import Darwin
import CommonCrypto

/// Apple ID 开发者服务客户端。
///
/// 协议对齐开源实现，而不是凭空发明：
/// - Anisette：macOS AuthKit（AltServer / AltSign 同路）
/// - GrandSlam / GSA：xtool XKit、AltSign `ALTAppleAPI+Authentication`
/// - 开发者门户 QH65B2：Xcode 对免费 Apple ID 使用的同一套接口（7 天开发证书 + 描述文件）
public enum AppleDeveloperServices {

    public static let xcodeClientID = "XABBG36SBA"
    public static let xcodeAppInfo = "com.apple.gs.xcode.auth"
    public static let developerToolsToken = "com.apple.gs.os.developertools"
    public static let freeProfileLifetime: TimeInterval = 7 * 24 * 60 * 60

    // MARK: - 模型

    public struct AnisetteHeaders: Sendable {
        public var oneTimePassword: String
        public var machineID: String
        public var routingInfo: String
        public var localUserID: String
        public var deviceID: String
        public var serialNumber: String
        public var clientTime: String
        public var timeZone: String
        public var locale: String
        public var clientInfo: String

        public var dictionary: [String: String] {
            [
                "X-Apple-I-MD": oneTimePassword,
                "X-Apple-I-MD-M": machineID,
                "X-Apple-I-MD-RINFO": routingInfo,
                "X-Apple-I-MD-LU": localUserID,
                "X-Mme-Device-Id": deviceID,
                "X-Apple-I-SRL-NO": serialNumber,
                "X-Apple-I-Client-Time": clientTime,
                "X-Apple-I-TimeZone": timeZone,
                "X-Apple-Locale": locale,
                "X-Mme-Client-Info": clientInfo
            ]
        }
    }

    public struct LoginToken: Sendable, Codable {
        public var appleID: String
        public var adsid: String
        public var token: String
        public var expiry: Date
        public var teamID: String
        public var teamName: String
        public var teams: [Team]

        public var isExpired: Bool { expiry <= Date() }

        public init(
            appleID: String,
            adsid: String,
            token: String,
            expiry: Date,
            teamID: String,
            teamName: String,
            teams: [Team] = []
        ) {
            self.appleID = appleID
            self.adsid = adsid
            self.token = token
            self.expiry = expiry
            self.teamID = teamID
            self.teamName = teamName
            self.teams = teams.isEmpty && !teamID.isEmpty
                ? [Team(id: teamID, name: teamName)]
                : teams
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            appleID = try container.decode(String.self, forKey: .appleID)
            adsid = try container.decode(String.self, forKey: .adsid)
            token = try container.decode(String.self, forKey: .token)
            expiry = try container.decode(Date.self, forKey: .expiry)
            teamID = try container.decode(String.self, forKey: .teamID)
            teamName = try container.decode(String.self, forKey: .teamName)
            teams = try container.decodeIfPresent([Team].self, forKey: .teams) ?? []
            if teams.isEmpty, !teamID.isEmpty {
                teams = [Team(id: teamID, name: teamName)]
            }
        }

        public func selecting(_ team: Team) -> LoginToken {
            LoginToken(
                appleID: appleID,
                adsid: adsid,
                token: token,
                expiry: expiry,
                teamID: team.id,
                teamName: team.name,
                teams: teams.isEmpty ? [team] : teams
            )
        }
    }

    public struct Team: Sendable, Hashable, Codable, Identifiable {
        public var id: String
        public var name: String

        public init(id: String, name: String) {
            self.id = id
            self.name = name
        }
    }

    public struct RemoteDevice: Sendable, Hashable, Codable, Identifiable {
        public var id: String
        public var name: String
        public var udid: String

        public init(id: String, name: String, udid: String) {
            self.id = id
            self.name = name
            self.udid = udid
        }
    }

    public struct RemoteAppID: Sendable, Hashable, Codable, Identifiable {
        public var id: String
        public var identifier: String
        public var name: String

        public init(id: String, identifier: String, name: String) {
            self.id = id
            self.identifier = identifier
            self.name = name
        }
    }

    public struct RemoteCertificate: Sendable, Hashable, Codable, Identifiable {
        public var id: String
        public var name: String
        public var expiration: Date?
        public var content: Data

        public init(id: String, name: String, expiration: Date? = nil, content: Data = Data()) {
            self.id = id
            self.name = name
            self.expiration = expiration
            self.content = content
        }

        public func isValid(at now: Date = Date()) -> Bool {
            guard let expiration else { return !content.isEmpty }
            return expiration > now && !content.isEmpty
        }
    }

    public struct RemoteAppGroup: Sendable, Hashable, Codable, Identifiable {
        public var id: String
        public var identifier: String
        public var name: String

        public init(id: String, identifier: String, name: String) {
            self.id = id
            self.identifier = identifier
            self.name = name
        }
    }

    public struct RemoteProvisioningProfile: Sendable, Hashable, Codable, Identifiable {
        public var id: String
        public var name: String
        public var appID: String?

        public init(id: String, name: String, appID: String? = nil) {
            self.id = id
            self.name = name
            self.appID = appID
        }
    }

    public struct ProvisionedIdentity: Sendable {
        public var identity: SigningIdentity
        public var profilesByBundleID: [String: URL]
        public var teamID: String
        public var expiresAt: Date
        public var workDirectory: URL
    }

    // MARK: - Anisette

    public static func fetchAnisette() throws -> AnisetteHeaders {
        if let native = try? fetchAnisetteFromAuthKit() { return native }
        throw AppleIDSigningError.anisetteUnavailable
    }

    static func fetchAnisetteFromAuthKit() throws -> AnisetteHeaders {
        let framework = "/System/Library/PrivateFrameworks/AuthKit.framework/AuthKit"
        guard dlopen(framework, RTLD_NOW) != nil else {
            throw AppleIDSigningError.anisetteUnavailable
        }
        guard let controllerClass = NSClassFromString("AKAnisetteProvisioningController") as? NSObject.Type else {
            throw AppleIDSigningError.anisetteUnavailable
        }
        let controller = controllerClass.init()
        let data = try requestAnisetteData(from: controller)
        let otp = stringValue(data, keys: ["oneTimePassword", "otp"]) ?? ""
        let machine = stringValue(data, keys: ["machineID", "machineId"]) ?? ""
        guard !otp.isEmpty, !machine.isEmpty else {
            throw AppleIDSigningError.anisetteUnavailable
        }
        let routing = stringValue(data, keys: ["routingInfo"]) ?? "17106176"
        let localUser = stringValue(data, keys: ["localUserID", "localUserId"])
            ?? UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let deviceID = stringValue(data, keys: ["deviceUniqueIdentifier", "uniqueDeviceIdentifier"])
            ?? Host.current().localizedName ?? UUID().uuidString
        let serial = stringValue(data, keys: ["deviceSerialNumber", "serialNumber"]) ?? "0"
        return AnisetteHeaders(
            oneTimePassword: otp,
            machineID: machine,
            routingInfo: routing,
            localUserID: localUser,
            deviceID: deviceID,
            serialNumber: serial,
            clientTime: iso8601Now(),
            timeZone: TimeZone.current.abbreviation() ?? "UTC",
            locale: Locale.current.identifier,
            clientInfo: "<MacBookPro18,1> <macOS;15.0;24A335> <com.apple.AuthKit/1 (com.apple.dt.Xcode/16.0)>"
        )
    }

    private static func requestAnisetteData(from controller: NSObject) throws -> NSObject {
        let semaphore = DispatchSemaphore(value: 0)
        var result: NSObject?
        var caught: Error?
        let completion: @convention(block) (NSObject?, NSError?) -> Void = { data, error in
            result = data
            caught = error
            semaphore.signal()
        }
        let selector = Selector(("anisetteDataWithCompletion:"))
        if controller.responds(to: selector) {
            controller.perform(selector, with: completion)
            _ = semaphore.wait(timeout: .now() + 8)
        }
        if result == nil {
            let alt = Selector(("anisetteDataForDevice:withCompletion:"))
            if controller.responds(to: alt),
               let deviceClass = NSClassFromString("AKDevice") as? NSObject.Type {
                let device = deviceClass.perform(Selector(("currentDevice")))?.takeUnretainedValue()
                controller.perform(Selector(("anisetteDataForDevice:withCompletion:")), with: device, with: completion)
                _ = semaphore.wait(timeout: .now() + 8)
            }
        }
        if let caught { throw caught }
        guard let result else { throw AppleIDSigningError.anisetteUnavailable }
        return result
    }

    private static func stringValue(_ object: NSObject, keys: [String]) -> String? {
        for key in keys {
            if let value = object.value(forKey: key) as? String, !value.isEmpty { return value }
            if let value = object.value(forKey: key) as? NSNumber { return value.stringValue }
        }
        return nil
    }

    private static func iso8601Now() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }

    // MARK: - SRP-6a（RFC 5054 2048-bit，Apple GSA 用 SHA-256）

    enum SRP {
        static let g = BigUInt(2)
        // RFC 5054 2048-bit Group（g = 2）。Apple GSA / AltSign / xtool 使用同一组。
        static let N = BigUInt(hex:
            "AC6BDB41324A9A9BF166DE5E1389582FAF72B6651987EE07FC319294" +
            "3DB56050A37329CBB4A099ED8193E0757767A13DD52312AB4B03310D" +
            "CD7F48A9DA04FD50E8083969EDB767B0CF6095179A163AB3661A05FB" +
            "D5FAAAE82918A9962F0B93B855F97993EC975EEAA80D740ADBF4FF74" +
            "7359D041D5C33EA71D281E446B14773BCA97B43A23FB801676BD207A" +
            "436C6481F1D2B9078717461A5B9D32E688F87748544523B524B0D57D" +
            "5EA77A2775D2ECFA032CFBDBF52FB3786160279004E57AE6AF874E73" +
            "03CE53299CCC041C7BC308D82A5698F3A8D0C38271AE35F8E9DBFBB6" +
            "94B5C803D89F7AE435DE236D525F54759B65E372FCD68EF20FA7111F" +
            "9E4AFF73"
        )!

        static func sha256(_ pieces: [Data]) -> Data {
            var hash = SHA256()
            for piece in pieces { hash.update(data: piece) }
            return Data(hash.finalize())
        }

        static func pad(_ value: BigUInt) -> Data {
            var data = value.beData
            let width = (N.bitWidth + 7) / 8
            if data.count < width {
                data = Data(repeating: 0, count: width - data.count) + data
            }
            return data
        }

        static func derivePasswordKey(password: String, salt: Data, iterations: Int, protocolName: String) -> Data {
            let secret: Data
            if protocolName == "s2k_fo" {
                secret = Data(password.utf8).map { String(format: "%02x", $0) }.joined().data(using: .utf8) ?? Data()
            } else {
                secret = Data(password.utf8)
            }
            return pbkdf2(password: secret, salt: salt, iterations: max(iterations, 1), length: 32)
        }

        static func clientProof(
            username: String,
            passwordKey: Data,
            salt: Data,
            serverB: Data,
            secretA: BigUInt
        ) throws -> (publicA: Data, m1: Data, sessionKey: Data) {
            let A = g.modPow(secretA, modulus: N)
            let B = BigUInt(serverB)
            guard B != BigUInt.zero, B % N != BigUInt.zero else { throw AppleIDSigningError.srpInvalidServer }
            let k = BigUInt(sha256([pad(N), pad(g)]))
            let u = BigUInt(sha256([pad(A), pad(B)]))
            let x = BigUInt(sha256([salt, sha256([Data("\(username):".utf8), passwordKey])]))
            let gx = g.modPow(x, modulus: N)
            let base = (B + N - (k * gx % N)) % N
            let S = base.modPow(secretA + u * x, modulus: N)
            let K = sha256([pad(S)])
            let xorNG = xor(sha256([pad(N)]), sha256([pad(g)]))
            let m1 = sha256([
                xorNG,
                sha256([Data(username.utf8)]),
                salt,
                pad(A),
                pad(B),
                K
            ])
            return (pad(A), m1, K)
        }

        private static func xor(_ lhs: Data, _ rhs: Data) -> Data {
            Data(zip(lhs, rhs).map { $0 ^ $1 })
        }

        private static func pbkdf2(password: Data, salt: Data, iterations: Int, length: Int) -> Data {
            let passwordBytes = [UInt8](password)
            let saltBytes = [UInt8](salt)
            var derived = [UInt8](repeating: 0, count: length)
            let status = CCKeyDerivationPBKDF(
                CCPBKDFAlgorithm(kCCPBKDF2),
                passwordBytes,
                passwordBytes.count,
                saltBytes,
                saltBytes.count,
                CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                UInt32(iterations),
                &derived,
                derived.count
            )
            guard status == kCCSuccess else { return Data() }
            return Data(derived)
        }
    }

    // MARK: - GrandSlam

    public static func login(
        appleID: String,
        password: String,
        twoFactorCode: String?
    ) throws -> LoginToken {
        let anisette = try fetchAnisette()
        let gsa = try grandSlamLogin(
            appleID: appleID,
            password: password,
            twoFactorCode: twoFactorCode,
            anisette: anisette
        )
        let session = (try? fetchXcodeAppToken(gsa: gsa, appleID: appleID, anisette: anisette)) ?? gsa
        let teams = try listTeams(token: session, anisette: anisette)
        guard let team = teams.first else { throw AppleIDSigningError.noTeam }
        return LoginToken(
            appleID: appleID,
            adsid: session.adsid,
            token: session.token,
            expiry: session.expiry,
            teamID: team.id,
            teamName: team.name,
            teams: teams
        )
    }

    public static func selectTeam(_ team: Team, token: LoginToken) -> LoginToken {
        token.selecting(team)
    }

    /// AltSign `o=apptokens`：用 GSA 会话换 Xcode (`com.apple.gs.xcode.auth`) 令牌。
    /// 失败时返回 nil，调用方回退到 GSA 令牌。
    static func fetchXcodeAppToken(
        gsa: GSASession,
        appleID: String,
        anisette: AnisetteHeaders
    ) throws -> GSASession? {
        let checksum = SRP.sha256([Data(gsa.adsid.utf8)])
        let body = try gsaEnvelope(
            operation: "apptokens",
            fields: [
                "u": appleID,
                "app": [xcodeAppInfo],
                "t": gsa.token,
                "checksum": checksum
            ],
            anisette: anisette
        )
        let complete = try postGSA(body: body, anisette: anisette)
        let result = try gsaRequestDictionary(complete)
        if let errorCode = int(dictionary(result["Status"])?["ec"] ?? result["ec"]), errorCode != 0 {
            return nil
        }
        let tokens = dictionary(result["t"]) ?? dictionary(result["tokens"]) ?? dictionary(result["appTokens"])
        let xcode = string(tokens?[xcodeAppInfo])
            ?? string(tokens?["com.apple.gs.xcode.auth"])
            ?? string(result["token"])
        guard let xcode, !xcode.isEmpty else { return nil }
        return GSASession(adsid: gsa.adsid, token: xcode, expiry: gsa.expiry)
    }

    struct GSASession {
        var adsid: String
        var token: String
        var expiry: Date
    }

    static func grandSlamLogin(
        appleID: String,
        password: String,
        twoFactorCode: String?,
        anisette: AnisetteHeaders
    ) throws -> GSASession {
        let a = BigUInt.random(bytes: 32)
        let initBody = try gsaEnvelope(
            operation: "init",
            fields: [
                "A2k": SRP.pad(SRP.g.modPow(a, modulus: SRP.N)),
                "ps": ["s2k", "s2k_fo"],
                "u": appleID
            ],
            anisette: anisette
        )
        let initResponse = try postGSA(body: initBody, anisette: anisette)
        let challenge = try gsaRequestDictionary(initResponse)
        if needsTwoFactor(challenge), (twoFactorCode ?? "").isEmpty {
            throw AppleIDSigningError.twoFactorRequired
        }
        let protocolName = string(challenge["sp"]) ?? "s2k"
        let salt = data(challenge["s"]) ?? Data()
        let iterations = int(challenge["i"]) ?? 20_000
        let serverB = data(challenge["B"]) ?? Data()
        let cookie = string(challenge["c"]) ?? ""
        let passwordKey = SRP.derivePasswordKey(
            password: password,
            salt: salt,
            iterations: iterations,
            protocolName: protocolName
        )
        let proof = try SRP.clientProof(
            username: appleID,
            passwordKey: passwordKey,
            salt: salt,
            serverB: serverB,
            secretA: a
        )
        var completeFields: [String: Any] = [
            "M1": proof.m1,
            "c": cookie,
            "u": appleID
        ]
        if let twoFactorCode, !twoFactorCode.isEmpty {
            completeFields["security-code"] = twoFactorCode
        }
        let completeBody = try gsaEnvelope(operation: "complete", fields: completeFields, anisette: anisette)
        let complete = try postGSA(body: completeBody, anisette: anisette)
        let result = try gsaRequestDictionary(complete)
        if needsTwoFactor(result), (twoFactorCode ?? "").isEmpty {
            throw AppleIDSigningError.twoFactorRequired
        }
        if let errorCode = int(dictionary(result["Status"])?["ec"] ?? result["ec"]), errorCode != 0 {
            let message = string(dictionary(result["Status"])?["em"]) ?? string(result["em"]) ?? "\(errorCode)"
            if errorCode == -20101 || errorCode == -22406 {
                throw AppleIDSigningError.invalidCredentials
            }
            throw AppleIDSigningError.developerAPI(message)
        }
        let spd = dictionary(result["spd"]) ?? result
        let adsid = string(spd["adsid"]) ?? string(spd["DsPrsId"]) ?? ""
        let token = string(spd["GsIdmsToken"])
            ?? string(spd["t"])
            ?? string(spd["token"])
            ?? ""
        guard !adsid.isEmpty, !token.isEmpty else {
            throw AppleIDSigningError.developerAPI(L("appleid.error.gsaMissingToken"))
        }
        let expiry = date(spd["expiry"]) ?? Date().addingTimeInterval(6 * 60 * 60)
        return GSASession(adsid: adsid, token: token, expiry: expiry)
    }

    private static func needsTwoFactor(_ dict: [String: Any]) -> Bool {
        let status = dictionary(dict["Status"]) ?? dict
        let au = (string(status["au"]) ?? string(dict["au"]) ?? "").lowercased()
        if au.contains("secondary") || au.contains("trusteddevice") || au.contains("2fa") {
            return true
        }
        if let code = int(status["ec"]), [-21631, -20101].contains(code) == false,
           (string(status["em"]) ?? "").lowercased().contains("two") {
            return true
        }
        return false
    }

    static func gsaEnvelope(
        operation: String,
        fields: [String: Any],
        anisette: AnisetteHeaders
    ) throws -> Data {
        var request = fields
        request["o"] = operation
        request["cpd"] = clientProvidedData(anisette)
        let root: [String: Any] = [
            "Header": ["Version": "1.0.1"],
            "Request": request
        ]
        return try PropertyListSerialization.data(fromPropertyList: root, format: .xml, options: 0)
    }

    private static func clientProvidedData(_ anisette: AnisetteHeaders) -> [String: Any] {
        [
            "bootstrap": true,
            "ckgen": true,
            "loc": anisette.locale,
            "X-Apple-I-Client-Time": anisette.clientTime,
            "X-Apple-I-MD": anisette.oneTimePassword,
            "X-Apple-I-MD-M": anisette.machineID,
            "X-Apple-I-MD-RINFO": anisette.routingInfo,
            "X-Apple-I-SRL-NO": anisette.serialNumber,
            "X-Mme-Device-Id": anisette.deviceID,
            "X-Apple-I-TimeZone": anisette.timeZone
        ]
    }

    static func postGSA(body: Data, anisette: AnisetteHeaders) throws -> [String: Any] {
        var request = URLRequest(url: URL(string: "https://gsa.apple.com/grandslam/GsService2")!)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("text/x-xml-plist", forHTTPHeaderField: "Content-Type")
        request.setValue("text/x-xml-plist", forHTTPHeaderField: "Accept")
        request.setValue("akd/1.0 CFNetwork/1410.0.3 Darwin/22.6.0", forHTTPHeaderField: "User-Agent")
        apply(anisette, to: &request)
        return try sendPlist(request)
    }

    static func gsaRequestDictionary(_ root: [String: Any]) throws -> [String: Any] {
        if let request = dictionary(root["Response"]) { return request }
        if let request = dictionary(root["Request"]) { return request }
        return root
    }

    // MARK: - QH65B2 开发者门户

    static func listTeams(token: GSASession, anisette: AnisetteHeaders) throws -> [Team] {
        let root = try sendDeveloper(
            action: "listTeams.action",
            parameters: [:],
            token: token,
            anisette: anisette
        )
        return DeveloperPortalParser.teams(from: root)
    }

    public static func provision(
        token: LoginToken,
        bundleIDs: [String],
        device: ConnectedDevice,
        revokeExistingCertificates: Bool = false,
        log: inout [String]
    ) throws -> ProvisionedIdentity {
        try registerDevice(device, token: token, log: &log)

        let work = try FileSystemHelper.makeTemporaryDirectory(prefix: "appleid-sign")
        let identity = try resolveSigningIdentity(
            token: token,
            work: work,
            forceRevoke: revokeExistingCertificates,
            log: &log
        )

        var profiles: [String: URL] = [:]
        var earliestExpiry = Date.distantFuture
        for bundleID in bundleIDs {
            let appID = try ensureAppID(bundleID: bundleID, token: token, log: &log)
            let existing = (try? fetchProvisioningProfiles(token: token)) ?? []
            for profile in existing where profile.appID == appID.id || profile.appID == appID.identifier {
                try? deleteProvisioningProfile(profile, token: token)
                log.append(L("appleid.log.profileDeleted", profile.name))
            }
            let profileData = try fetchProvisioningProfile(for: appID, token: token)
            let profileURL = work.appendingPathComponent("\(safeFileName(bundleID)).mobileprovision")
            try profileData.write(to: profileURL, options: .atomic)
            let info = try SigningService.readProfile(at: profileURL)
            if let expiration = info.expirationDate, expiration < earliestExpiry {
                earliestExpiry = expiration
            }
            profiles[bundleID] = profileURL
            log.append(L("appleid.log.profileReady", bundleID, info.expirationDate.map(Self.shortDate) ?? "?"))
        }
        if earliestExpiry == Date.distantFuture {
            earliestExpiry = Date().addingTimeInterval(Self.freeProfileLifetime)
        }
        return ProvisionedIdentity(
            identity: identity,
            profilesByBundleID: profiles,
            teamID: token.teamID,
            expiresAt: earliestExpiry,
            workDirectory: work
        )
    }

    static func resolveSigningIdentity(
        token: LoginToken,
        work: URL,
        forceRevoke: Bool,
        log: inout [String]
    ) throws -> SigningIdentity {
        let remote = (try? fetchCertificates(token: token)) ?? []
        let stored = DevelopmentCertificateStore.load(teamID: token.teamID)
        let action = forceRevoke
            ? CertificateReuseDecision.revokeThenRequest(ids: remote.map(\.id))
            : CertificateReusePlanner.decide(stored: stored, remote: remote)
        switch action {
        case .reuseStored:
            guard let stored else { throw AppleIDSigningError.certificateFailed }
            log.append(L("appleid.log.reusedCertificate", stored.certificateID))
            return try importStoredCertificate(stored, work: work)
        case .requestNew:
            log.append(L("appleid.log.requestingCertificate"))
            return try issueAndStoreCertificate(token: token, work: work, revokeIDs: [], log: &log)
        case let .revokeThenRequest(ids):
            for id in ids {
                try? revokeCertificate(id: id, token: token)
                log.append(L("appleid.log.revokedCertificate", id))
            }
            log.append(L("appleid.log.requestingCertificateAfterRevoke", ids.count))
            return try issueAndStoreCertificate(token: token, work: work, revokeIDs: [], log: &log)
        }
    }

    private static func importStoredCertificate(
        _ stored: StoredDevelopmentCertificate,
        work: URL
    ) throws -> SigningIdentity {
        let p12URL = work.appendingPathComponent("dev.p12")
        let p12Password = UUID().uuidString
        try exportP12(keyURL: stored.keyURL, certURL: stored.certURL, p12URL: p12URL, password: p12Password)
        return try SigningService.importDeveloperCertificate(p12At: p12URL, password: p12Password)
    }

    private static func issueAndStoreCertificate(
        token: LoginToken,
        work: URL,
        revokeIDs: [String],
        log: inout [String]
    ) throws -> SigningIdentity {
        let keyURL = work.appendingPathComponent("key.pem")
        let csrURL = work.appendingPathComponent("req.csr")
        let certURL = work.appendingPathComponent("dev.cer")
        let p12URL = work.appendingPathComponent("dev.p12")
        let p12Password = UUID().uuidString
        let machine = Host.current().localizedName ?? "MacAssistant"
        try generateCSR(keyURL: keyURL, csrURL: csrURL)
        let certificate = try addCertificate(machineName: machine, csrURL: csrURL, token: token)
        try certificate.content.write(to: certURL)
        try exportP12(keyURL: keyURL, certURL: certURL, p12URL: p12URL, password: p12Password)
        let identity = try SigningService.importDeveloperCertificate(p12At: p12URL, password: p12Password)
        DevelopmentCertificateStore.save(
            teamID: token.teamID,
            keyURL: keyURL,
            certURL: certURL,
            certificate: certificate
        )
        log.append(L("appleid.log.importedIdentity", identity.name))
        _ = revokeIDs
        return identity
    }

    static func sendDeveloper(
        action: String,
        parameters: [String: String],
        token: GSASession,
        anisette: AnisetteHeaders
    ) throws -> [String: Any] {
        var items = parameters
        items["clientId"] = xcodeClientID
        let query = items
            .map { "\(urlEncode($0.key))=\(urlEncode($0.value))" }
            .joined(separator: "&")
        let url = URL(string: "https://developerservices2.apple.com/services/QH65B2/ios/\(action)?clientId=\(xcodeClientID)")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = Data(query.utf8)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("text/x-xml-plist", forHTTPHeaderField: "Accept")
        request.setValue("Xcode", forHTTPHeaderField: "User-Agent")
        request.setValue("16.0 (16A242d)", forHTTPHeaderField: "X-Xcode-Version")
        request.setValue(token.adsid, forHTTPHeaderField: "X-Apple-I-Identity-Id")
        request.setValue(xcodeClientID, forHTTPHeaderField: "X-Apple-App-Info")
        request.setValue(token.token, forHTTPHeaderField: "X-Apple-GS-Token")
        apply(anisette, to: &request)
        let root = try sendPlist(request)
        if let resultCode = int(root["resultCode"]) ?? int(dictionary(root["userString"])?["resultCode"]),
           resultCode != 0 {
            let message = string(root["userString"]) ?? string(root["resultString"]) ?? "\(resultCode)"
            throw AppleIDSigningError.developerAPI(message)
        }
        return root
    }

    // MARK: - CSR / p12

    static func generateCSR(keyURL: URL, csrURL: URL) throws {
        let openssl = "/usr/bin/openssl"
        guard FileManager.default.isExecutableFile(atPath: openssl) else {
            throw SigningError.toolMissing("openssl")
        }
        let result = try Shell.run(openssl, [
            "req", "-new", "-newkey", "rsa:2048", "-nodes",
            "-keyout", keyURL.path,
            "-out", csrURL.path,
            "-subj", "/CN=MacAssistant Apple ID Signing"
        ])
        guard result.succeeded,
              FileManager.default.fileExists(atPath: keyURL.path),
              FileManager.default.fileExists(atPath: csrURL.path)
        else {
            throw AppleIDSigningError.certificateFailed
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyURL.path)
    }

    static func exportP12(keyURL: URL, certURL: URL, p12URL: URL, password: String) throws {
        let openssl = "/usr/bin/openssl"
        var arguments = [
            "pkcs12", "-export",
            "-inkey", keyURL.path,
            "-in", certURL.path,
            "-out", p12URL.path,
            "-passout", "pass:\(password)"
        ]
        var result = try Shell.run(openssl, arguments)
        if !result.succeeded {
            arguments.insert("-legacy", at: 1)
            result = try Shell.run(openssl, arguments)
        }
        guard result.succeeded else { throw AppleIDSigningError.certificateFailed }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: p12URL.path)
    }

    static func appIDName(from bundleID: String) -> String {
        let compact = bundleID.replacingOccurrences(of: ".", with: " ")
            .replacingOccurrences(of: "_", with: " ")
        let filtered = compact.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) || $0 == " " ? Character($0) : " " }
        let name = String(filtered).split(separator: " ").joined(separator: " ")
        return name.isEmpty ? "App" : String(name.prefix(50))
    }

    static func teamPrefixedBundleID(original: String, teamID: String) -> String {
        let suffix = original.replacingOccurrences(of: ".", with: "")
            .replacingOccurrences(of: "-", with: "")
            .lowercased()
        let trimmed = suffix.isEmpty ? "app" : String(suffix.suffix(24))
        return "i.\(teamID.lowercased()).\(trimmed)"
    }

    // MARK: - HTTP

    static func apply(_ anisette: AnisetteHeaders, to request: inout URLRequest) {
        for (key, value) in anisette.dictionary {
            request.setValue(value, forHTTPHeaderField: key)
        }
    }

    static func sendPlist(_ request: URLRequest) throws -> [String: Any] {
        let semaphore = DispatchSemaphore(value: 0)
        var data: Data?
        var error: Error?
        let task = URLSession.shared.dataTask(with: request) { body, _, caught in
            data = body
            error = caught
            semaphore.signal()
        }
        task.resume()
        _ = semaphore.wait(timeout: .now() + 45)
        if let error { throw AppleIDSigningError.network(error.localizedDescription) }
        guard let data, !data.isEmpty else { throw AppleIDSigningError.network(L("appleid.error.emptyResponse")) }
        let object = try PropertyListSerialization.propertyList(from: data, format: nil)
        guard let dictionary = object as? [String: Any] else {
            throw AppleIDSigningError.developerAPI(L("appleid.error.invalidPlist"))
        }
        return dictionary
    }

    private static func urlEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private static func safeFileName(_ value: String) -> String {
        value.map { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" ? $0 : "_" }
            .reduce(into: "") { $0.append($1) }
    }

    private static func shortDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    static func dictionary(_ value: Any?) -> [String: Any]? { value as? [String: Any] }
    static func array(_ value: Any?) -> [Any]? { value as? [Any] }
    static func string(_ value: Any?) -> String? {
        if let text = value as? String { return text }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }
    static func int(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let text = value as? String { return Int(text) }
        return nil
    }
    static func data(_ value: Any?) -> Data? {
        if let data = value as? Data { return data }
        if let text = value as? String, let decoded = Data(base64Encoded: text) { return decoded }
        return nil
    }
    static func date(_ value: Any?) -> Date? {
        if let date = value as? Date { return date }
        if let text = value as? String {
            let iso = ISO8601DateFormatter()
            if let parsed = iso.date(from: text) { return parsed }
        }
        return nil
    }
}

// MARK: - 最小大整数（SRP 模幂）

struct BigUInt: Equatable {
    static let zero = BigUInt(UInt64(0))
    private var words: [UInt64] // little-endian

    init(_ value: UInt64) {
        self.words = value == 0 ? [] : [value]
    }

    init(_ data: Data) {
        var words: [UInt64] = []
        var index = data.count
        while index > 0 {
            var word: UInt64 = 0
            let start = max(0, index - 8)
            for byte in data[start..<index] {
                word = (word << 8) | UInt64(byte)
            }
            words.append(word)
            index = start
        }
        while words.last == 0 { words.removeLast() }
        self.words = words
    }

    init?(hex: String) {
        let clean = hex.replacingOccurrences(of: " ", with: "")
        guard clean.count % 2 == 0, let data = Data(hexString: clean) else { return nil }
        self.init(data)
    }

    var bitWidth: Int {
        guard let last = words.last else { return 0 }
        return (words.count - 1) * 64 + (64 - last.leadingZeroBitCount)
    }

    var beData: Data {
        guard let last = words.last else { return Data([0]) }
        var data = Data()
        let leading = last
        var started = false
        for shift in stride(from: 56, through: 0, by: -8) {
            let byte = UInt8(truncatingIfNeeded: leading >> UInt64(shift))
            if started || byte != 0 || shift == 0 {
                started = true
                data.append(byte)
            }
        }
        for word in words.dropLast().reversed() {
            for shift in stride(from: 56, through: 0, by: -8) {
                data.append(UInt8(truncatingIfNeeded: word >> UInt64(shift)))
            }
        }
        return data
    }

    static func random(bytes: Int) -> BigUInt {
        var data = Data(count: bytes)
        data.withUnsafeMutableBytes { buffer in
            _ = SecRandomCopyBytes(kSecRandomDefault, bytes, buffer.baseAddress!)
        }
        return BigUInt(data)
    }

    static func + (lhs: BigUInt, rhs: BigUInt) -> BigUInt {
        let count = max(lhs.words.count, rhs.words.count)
        var words = [UInt64](repeating: 0, count: count)
        var carry: UInt64 = 0
        for index in 0..<count {
            let (sum, next) = add(lhs.word(index), rhs.word(index), carry)
            words[index] = sum
            carry = next
        }
        if carry != 0 { words.append(carry) }
        return BigUInt(words: words)
    }

    static func - (lhs: BigUInt, rhs: BigUInt) -> BigUInt {
        precondition(lhs >= rhs)
        var words = lhs.words
        var borrow: UInt64 = 0
        for index in 0..<words.count {
            let (diff, next) = sub(lhs.word(index), rhs.word(index), borrow)
            words[index] = diff
            borrow = next
        }
        return BigUInt(words: words)
    }

    static func * (lhs: BigUInt, rhs: BigUInt) -> BigUInt {
        if lhs.words.isEmpty || rhs.words.isEmpty { return .zero }
        var words = [UInt64](repeating: 0, count: lhs.words.count + rhs.words.count)
        for i in 0..<lhs.words.count {
            var carry: UInt64 = 0
            for j in 0..<rhs.words.count {
                let index = i + j
                let (lo, hi) = lhs.words[i].multipliedFullWidth(by: rhs.words[j])
                let (sum1, c1) = add(words[index], lo, carry)
                words[index] = sum1
                carry = hi &+ c1
            }
            words[i + rhs.words.count] = carry
        }
        return BigUInt(words: words)
    }

    private static func add(_ a: UInt64, _ b: UInt64, _ carry: UInt64) -> (UInt64, UInt64) {
        let (s1, o1) = a.addingReportingOverflow(b)
        let (s2, o2) = s1.addingReportingOverflow(carry)
        return (s2, (o1 ? 1 : 0) + (o2 ? 1 : 0))
    }

    private static func sub(_ a: UInt64, _ b: UInt64, _ borrow: UInt64) -> (UInt64, UInt64) {
        let (s1, o1) = a.subtractingReportingOverflow(b)
        let (s2, o2) = s1.subtractingReportingOverflow(borrow)
        return (s2, (o1 || o2) ? 1 : 0)
    }

    static func % (lhs: BigUInt, rhs: BigUInt) -> BigUInt {
        lhs.divmod(rhs).1
    }

    static func >= (lhs: BigUInt, rhs: BigUInt) -> Bool {
        compare(lhs, rhs) != .orderedAscending
    }

    static func == (lhs: BigUInt, rhs: BigUInt) -> Bool {
        lhs.words == rhs.words
    }

    func modPow(_ exponent: BigUInt, modulus: BigUInt) -> BigUInt {
        if let fast = pythonModPow(exponent, modulus: modulus) { return fast }
        var result = BigUInt(1)
        var base = self % modulus
        var exp = exponent
        while !exp.words.isEmpty {
            if exp.words[0] & 1 == 1 {
                result = (result * base) % modulus
            }
            exp = exp.shiftedRightOne()
            if exp.words.isEmpty { break }
            base = (base * base) % modulus
        }
        return result
    }

    /// 2048-bit SRP 用纯 Swift 除法会慢到不可用；macOS 自带 python3 的 pow(a,b,c) 足够快。
    private func pythonModPow(_ exponent: BigUInt, modulus: BigUInt) -> BigUInt? {
        let script = "print(pow(int('\(hexString)',16),int('\(exponent.hexString)',16),int('\(modulus.hexString)',16)))"
        guard let result = try? Shell.run("/usr/bin/python3", ["-c", script]), result.succeeded else {
            return nil
        }
        let text = result.trimmedOutput
        guard !text.isEmpty, let value = BigUInt(decimal: text) else { return nil }
        return value
    }

    var hexString: String {
        beData.map { String(format: "%02x", $0) }.joined()
    }

    init?(decimal: String) {
        let digits = decimal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !digits.isEmpty, digits.allSatisfy(\.isNumber) else { return nil }
        var value = BigUInt.zero
        let ten = BigUInt(10)
        for character in digits {
            guard let digit = UInt64(String(character)) else { return nil }
            value = value * ten + BigUInt(digit)
        }
        self = value
    }

    private init(words: [UInt64]) {
        var trimmed = words
        while trimmed.last == 0 { trimmed.removeLast() }
        self.words = trimmed
    }

    private func word(_ index: Int) -> UInt64 {
        index < words.count ? words[index] : 0
    }

    private func shiftedRightOne() -> BigUInt {
        var words = self.words
        var carry: UInt64 = 0
        for index in stride(from: words.count - 1, through: 0, by: -1) {
            let current = words[index]
            words[index] = (current >> 1) | (carry << 63)
            carry = current & 1
        }
        return BigUInt(words: words)
    }

    private func divmod(_ divisor: BigUInt) -> (BigUInt, BigUInt) {
        precondition(!divisor.words.isEmpty)
        if Self.compare(self, divisor) == .orderedAscending { return (.zero, self) }
        var rem = BigUInt.zero
        var quotientWords = [UInt64](repeating: 0, count: words.count)
        for index in stride(from: words.count - 1, through: 0, by: -1) {
            rem = rem.shiftedLeft(64)
            rem = rem + BigUInt(words[index])
            var digit: UInt64 = 0
            if rem >= divisor {
                var low: UInt64 = 0
                var high: UInt64 = .max
                while low <= high {
                    let mid = low &+ (high &- low) / 2
                    let product = divisor * BigUInt(mid)
                    if product > rem {
                        if mid == 0 { break }
                        high = mid &- 1
                    } else {
                        digit = mid
                        if mid == .max { break }
                        low = mid &+ 1
                    }
                }
                rem = rem - (divisor * BigUInt(digit))
            }
            quotientWords[index] = digit
        }
        return (BigUInt(words: quotientWords), rem)
    }

    private func shiftedLeft(_ bits: Int) -> BigUInt {
        guard bits > 0, !words.isEmpty else { return self }
        let wordShift = bits / 64
        let bitShift = bits % 64
        var result = [UInt64](repeating: 0, count: words.count + wordShift + 1)
        if bitShift == 0 {
            for index in 0..<words.count { result[index + wordShift] = words[index] }
        } else {
            var carry: UInt64 = 0
            for index in 0..<words.count {
                let current = words[index]
                result[index + wordShift] = (current << bitShift) | carry
                carry = current >> (64 - bitShift)
            }
            result[words.count + wordShift] = carry
        }
        return BigUInt(words: result)
    }

    private static func compare(_ lhs: BigUInt, _ rhs: BigUInt) -> ComparisonResult {
        if lhs.words.count != rhs.words.count {
            return lhs.words.count > rhs.words.count ? .orderedDescending : .orderedAscending
        }
        for index in stride(from: lhs.words.count - 1, through: 0, by: -1) {
            if lhs.words[index] != rhs.words[index] {
                return lhs.words[index] > rhs.words[index] ? .orderedDescending : .orderedAscending
            }
        }
        return .orderedSame
    }

    static func > (lhs: BigUInt, rhs: BigUInt) -> Bool {
        compare(lhs, rhs) == .orderedDescending
    }
}

private extension Data {
    init?(hexString: String) {
        let clean = hexString.lowercased()
        guard clean.count % 2 == 0 else { return nil }
        var data = Data(capacity: clean.count / 2)
        var index = clean.startIndex
        while index < clean.endIndex {
            let next = clean.index(index, offsetBy: 2)
            guard let byte = UInt8(clean[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        self = data
    }
}
