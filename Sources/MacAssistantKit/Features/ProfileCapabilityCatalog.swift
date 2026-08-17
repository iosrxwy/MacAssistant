import Foundation

/// 描述文件 entitlement 是否授予某项能力。
public enum ProfileCapabilityPresence: Equatable, Sendable {
    case present
    case absent
    /// 不在已知能力表里，但描述文件里出现了该 key。
    case presentOther
}

/// 一项已知 iOS 能力：稳定 id、展示名、对应的 entitlement key。
public struct ProfileCapabilityDefinition: Equatable, Sendable, Identifiable {
    public var id: String
    public var entitlementKeys: [String]

    public init(id: String, entitlementKeys: [String]) {
        self.id = id
        self.entitlementKeys = entitlementKeys
    }
}

/// 解析结果里的一行：已知能力的有/无，或未知 key 的「其他」。
public struct ProfileCapabilityStatus: Equatable, Sendable, Identifiable {
    public var id: String
    public var entitlementKeys: [String]
    public var presence: ProfileCapabilityPresence
    public var detail: String?

    public init(
        id: String,
        entitlementKeys: [String],
        presence: ProfileCapabilityPresence,
        detail: String? = nil
    ) {
        self.id = id
        self.entitlementKeys = entitlementKeys
        self.presence = presence
        self.detail = detail
    }

    public var isGranted: Bool {
        presence == .present || presence == .presentOther
    }

    public var displayName: String {
        ProfileCapabilityCatalog.localizedName(for: id)
    }
}

/// 从 entitlements 字典对照已知能力表，得到可测试、可展示的有/无列表。
public enum ProfileCapabilityCatalog {

    /// 常见 iOS / 描述文件能力。一项可对应多个 key（任一授予即视为有）。
    public static let known: [ProfileCapabilityDefinition] = [
        .init(id: "get-task-allow", entitlementKeys: ["get-task-allow"]),
        .init(id: "app-id", entitlementKeys: [
            "application-identifier",
            "com.apple.application-identifier"
        ]),
        .init(id: "team", entitlementKeys: ["com.apple.developer.team-identifier"]),
        .init(id: "push", entitlementKeys: ["aps-environment"]),
        .init(id: "icloud", entitlementKeys: [
            "com.apple.developer.icloud-container-identifiers",
            "com.apple.developer.icloud-services",
            "com.apple.developer.icloud-container-environment",
            "com.apple.developer.icloud-container-development-container-identifiers",
            "com.apple.developer.ubiquity-container-identifiers",
            "com.apple.developer.ubiquity-kvstore-identifier"
        ]),
        .init(id: "app-groups", entitlementKeys: ["com.apple.security.application-groups"]),
        .init(id: "associated-domains", entitlementKeys: ["com.apple.developer.associated-domains"]),
        .init(id: "keychain", entitlementKeys: ["keychain-access-groups"]),
        .init(id: "increased-memory", entitlementKeys: [
            "com.apple.developer.kernel.increased-memory-limit"
        ]),
        .init(id: "time-sensitive", entitlementKeys: [
            "com.apple.developer.usernotifications.time-sensitive"
        ]),
        .init(id: "personal-vpn", entitlementKeys: [
            "com.apple.developer.networking.vpn.api",
            "com.apple.developer.networking.networkextension"
        ]),
        .init(id: "hotspot", entitlementKeys: [
            "com.apple.developer.networking.HotspotHelper",
            "com.apple.developer.networking.HotspotConfiguration"
        ]),
        .init(id: "healthkit", entitlementKeys: [
            "com.apple.developer.healthkit",
            "com.apple.developer.healthkit.access",
            "com.apple.developer.healthkit.background-delivery"
        ]),
        .init(id: "homekit", entitlementKeys: ["com.apple.developer.homekit"]),
        .init(id: "siri", entitlementKeys: ["com.apple.developer.siri"]),
        .init(id: "wireless-accessory", entitlementKeys: [
            "com.apple.external-accessory.wireless-configuration"
        ]),
        .init(id: "inter-app-audio", entitlementKeys: ["inter-app-audio"]),
        .init(id: "data-protection", entitlementKeys: [
            "com.apple.developer.default-data-protection"
        ]),
        .init(id: "sandbox", entitlementKeys: ["com.apple.security.app-sandbox"]),
        .init(id: "beta-reports", entitlementKeys: ["beta-reports-active"]),
        .init(id: "sign-in-apple", entitlementKeys: ["com.apple.developer.applesignin"]),
        .init(id: "wallet", entitlementKeys: ["com.apple.developer.pass-type-identifiers"]),
        .init(id: "apple-pay", entitlementKeys: ["com.apple.developer.in-app-payments"]),
        .init(id: "game-center", entitlementKeys: ["com.apple.developer.game-center"]),
        .init(id: "nfc", entitlementKeys: ["com.apple.developer.nfc.readersession.formats"]),
        .init(id: "wifi-info", entitlementKeys: ["com.apple.developer.networking.wifi-info"]),
        .init(id: "multipath", entitlementKeys: ["com.apple.developer.networking.multipath"]),
        .init(id: "push-to-talk", entitlementKeys: ["com.apple.developer.push-to-talk"]),
        .init(id: "critical-alerts", entitlementKeys: [
            "com.apple.developer.usernotifications.critical-alerts"
        ]),
        .init(id: "communication-notifications", entitlementKeys: [
            "com.apple.developer.usernotifications.communication"
        ]),
        .init(id: "app-attest", entitlementKeys: [
            "com.apple.developer.devicecheck.appattest-environment"
        ]),
        .init(id: "autofill", entitlementKeys: [
            "com.apple.developer.authentication-services.autofill-credential-provider"
        ]),
        .init(id: "classkit", entitlementKeys: ["com.apple.developer.classkit"]),
        .init(id: "weatherkit", entitlementKeys: ["com.apple.developer.weatherkit"]),
        .init(id: "family-controls", entitlementKeys: ["com.apple.developer.family-controls"]),
        .init(id: "shared-with-you", entitlementKeys: ["com.apple.developer.shared-with-you"]),
        .init(id: "user-fonts", entitlementKeys: ["com.apple.developer.user-fonts"]),
        .init(id: "maps", entitlementKeys: ["com.apple.developer.maps"]),
        .init(id: "carplay", entitlementKeys: [
            "com.apple.developer.carplay-audio",
            "com.apple.developer.carplay-messaging",
            "com.apple.developer.carplay-calling",
            "com.apple.developer.carplay-maps",
            "com.apple.developer.carplay-parking",
            "com.apple.developer.carplay-charging",
            "com.apple.developer.carplay-quick-ordering"
        ]),
        .init(id: "extended-virtual-addressing", entitlementKeys: [
            "com.apple.developer.kernel.extended-virtual-addressing"
        ]),
        .init(id: "increased-debugging-memory", entitlementKeys: [
            "com.apple.developer.kernel.increased-debugging-memory-limit"
        ])
    ]

    public static func inspect(entitlements: [String: Any]) -> [ProfileCapabilityStatus] {
        let knownKeys = Set(known.flatMap(\.entitlementKeys))
        var rows: [ProfileCapabilityStatus] = known.map { definition in
            let grantedKey = definition.entitlementKeys.first { key in
                guard let value = entitlements[key] else { return false }
                return isGranted(value)
            }
            return ProfileCapabilityStatus(
                id: definition.id,
                entitlementKeys: definition.entitlementKeys,
                presence: grantedKey == nil ? .absent : .present,
                detail: grantedKey.flatMap { summarize(entitlements[$0]) }
            )
        }
        let extras = entitlements.keys
            .filter { !knownKeys.contains($0) }
            .sorted()
            .map { key in
                ProfileCapabilityStatus(
                    id: key,
                    entitlementKeys: [key],
                    presence: isGranted(entitlements[key] as Any) ? .presentOther : .absent,
                    detail: summarize(entitlements[key])
                )
            }
            .filter(\.isGranted)
        rows.append(contentsOf: extras)
        return rows
    }

    public static func inspect(entitlementsXML: String) throws -> [ProfileCapabilityStatus] {
        let trimmed = entitlementsXML.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return inspect(entitlements: [:]) }
        return inspect(entitlements: try SigningService.parsePlistDictionary(trimmed))
    }

    public static func inspect(profile: ProfileInfo) throws -> [ProfileCapabilityStatus] {
        try inspect(entitlementsXML: profile.entitlementsXML)
    }

    /// 展示名用字面量本地化调用，方便 LocalizationTests 扫到；未知 id 走「其他」。
    public static func localizedName(for id: String) -> String {
        switch id {
        case "get-task-allow": return L("signing.capability.getTaskAllow")
        case "app-id": return L("signing.capability.appID")
        case "team": return L("signing.capability.team")
        case "push": return L("signing.capability.push")
        case "icloud": return L("signing.capability.icloud")
        case "app-groups": return L("signing.capability.appGroups")
        case "associated-domains": return L("signing.capability.associatedDomains")
        case "keychain": return L("signing.capability.keychain")
        case "increased-memory": return L("signing.capability.increasedMemory")
        case "time-sensitive": return L("signing.capability.timeSensitive")
        case "personal-vpn": return L("signing.capability.personalVPN")
        case "hotspot": return L("signing.capability.hotspot")
        case "healthkit": return L("signing.capability.healthKit")
        case "homekit": return L("signing.capability.homeKit")
        case "siri": return L("signing.capability.siri")
        case "wireless-accessory": return L("signing.capability.wirelessAccessory")
        case "inter-app-audio": return L("signing.capability.interAppAudio")
        case "data-protection": return L("signing.capability.dataProtection")
        case "sandbox": return L("signing.capability.sandbox")
        case "beta-reports": return L("signing.capability.betaReports")
        case "sign-in-apple": return L("signing.capability.signInApple")
        case "wallet": return L("signing.capability.wallet")
        case "apple-pay": return L("signing.capability.applePay")
        case "game-center": return L("signing.capability.gameCenter")
        case "nfc": return L("signing.capability.nfc")
        case "wifi-info": return L("signing.capability.wifiInfo")
        case "multipath": return L("signing.capability.multipath")
        case "push-to-talk": return L("signing.capability.pushToTalk")
        case "critical-alerts": return L("signing.capability.criticalAlerts")
        case "communication-notifications": return L("signing.capability.communicationNotifications")
        case "app-attest": return L("signing.capability.appAttest")
        case "autofill": return L("signing.capability.autofill")
        case "classkit": return L("signing.capability.classKit")
        case "weatherkit": return L("signing.capability.weatherKit")
        case "family-controls": return L("signing.capability.familyControls")
        case "shared-with-you": return L("signing.capability.sharedWithYou")
        case "user-fonts": return L("signing.capability.userFonts")
        case "maps": return L("signing.capability.maps")
        case "carplay": return L("signing.capability.carPlay")
        case "extended-virtual-addressing": return L("signing.capability.extendedVirtualAddressing")
        case "increased-debugging-memory": return L("signing.capability.increasedDebuggingMemory")
        default: return L("signing.capability.other", id)
        }
    }

    static func isGranted(_ value: Any) -> Bool {
        switch value {
        case let flag as Bool:
            return flag
        case let text as String:
            return !text.isEmpty
        case let items as [Any]:
            return !items.isEmpty
        case let dictionary as [String: Any]:
            return !dictionary.isEmpty
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return number.boolValue
            }
            return number != 0
        default:
            return true
        }
    }

    static func summarize(_ value: Any?) -> String? {
        switch value {
        case let text as String:
            return text.isEmpty ? nil : text
        case let items as [Any]:
            let texts = items.compactMap { $0 as? String }
            if texts.isEmpty { return items.isEmpty ? nil : "\(items.count)" }
            return texts.joined(separator: ", ")
        default:
            return nil
        }
    }
}

/// 选中证书时展示的主题 / Team / 序列号（权限本身在描述文件里）。
public struct SigningCertificateDetails: Equatable, Sendable {
    public var subject: String
    public var teamID: String?
    public var serial: String?

    public init(subject: String, teamID: String? = nil, serial: String? = nil) {
        self.subject = subject
        self.teamID = teamID
        self.serial = serial
    }
}
