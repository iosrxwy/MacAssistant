import XCTest
@testable import MacAssistantKit

final class ProfileCapabilityTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        LocalizationSettings.override = .simplifiedChinese
    }

    func testInspectMarksPushICloudDebugAndAppGroups() {
        let entitlements: [String: Any] = [
            "get-task-allow": true,
            "application-identifier": "TEAM123.com.example.app",
            "aps-environment": "development",
            "com.apple.developer.icloud-container-identifiers": ["iCloud.com.example.app"],
            "com.apple.security.application-groups": ["group.com.example.app"],
            "com.apple.developer.exotic-unknown": true
        ]
        let statuses = ProfileCapabilityCatalog.inspect(entitlements: entitlements)
        XCTAssertEqual(presence("push", in: statuses), .present)
        XCTAssertEqual(presence("icloud", in: statuses), .present)
        XCTAssertEqual(presence("get-task-allow", in: statuses), .present)
        XCTAssertEqual(presence("app-groups", in: statuses), .present)
        XCTAssertEqual(presence("healthkit", in: statuses), .absent)
        XCTAssertEqual(presence("homekit", in: statuses), .absent)
        XCTAssertEqual(presence("com.apple.developer.exotic-unknown", in: statuses), .presentOther)

        let push = statuses.first { $0.id == "push" }
        XCTAssertEqual(push?.detail, "development")
        XCTAssertTrue(statuses.first { $0.id == "push" }?.isGranted == true)
        XCTAssertFalse(statuses.first { $0.id == "healthkit" }?.isGranted == true)
    }

    func testBooleanFalseAndEmptyArrayCountAsAbsent() {
        let entitlements: [String: Any] = [
            "get-task-allow": false,
            "com.apple.security.application-groups": [String](),
            "aps-environment": ""
        ]
        let statuses = ProfileCapabilityCatalog.inspect(entitlements: entitlements)
        XCTAssertEqual(presence("get-task-allow", in: statuses), .absent)
        XCTAssertEqual(presence("app-groups", in: statuses), .absent)
        XCTAssertEqual(presence("push", in: statuses), .absent)
    }

    func testInspectEntitlementsXMLFixture() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>get-task-allow</key>
            <true/>
            <key>aps-environment</key>
            <string>production</string>
            <key>com.apple.developer.ubiquity-kvstore-identifier</key>
            <string>TEAM123.com.example.app</string>
            <key>com.apple.security.application-groups</key>
            <array>
                <string>group.com.example.shared</string>
            </array>
        </dict>
        </plist>
        """
        let statuses = try ProfileCapabilityCatalog.inspect(entitlementsXML: xml)
        XCTAssertEqual(presence("get-task-allow", in: statuses), .present)
        XCTAssertEqual(presence("push", in: statuses), .present)
        XCTAssertEqual(presence("icloud", in: statuses), .present)
        XCTAssertEqual(presence("app-groups", in: statuses), .present)
        XCTAssertEqual(presence("siri", in: statuses), .absent)
    }

    func testEveryKnownCapabilityHasALocalizedName() {
        LocalizationSettings.override = .simplifiedChinese
        for definition in ProfileCapabilityCatalog.known {
            let name = ProfileCapabilityCatalog.localizedName(for: definition.id)
            XCTAssertFalse(
                name.hasPrefix("signing.capability."),
                "缺少词条：\(definition.id)"
            )
            XCTAssertNotEqual(
                name,
                L("signing.capability.other", definition.id),
                "已知能力 \(definition.id) 不该落到「其他」"
            )
        }
        LocalizationSettings.override = .english
        XCTAssertEqual(ProfileCapabilityCatalog.localizedName(for: "push"), "Push notifications")
    }

    func testTeamIDFromIdentityName() {
        XCTAssertEqual(
            SigningService.teamID(fromIdentityName: "Apple Development: Jane Doe (TEAM12345X)"),
            "TEAM12345X"
        )
        XCTAssertNil(SigningService.teamID(fromIdentityName: "Apple Development: Jane Doe"))
        let details = SigningService.certificateDetails(
            for: SigningIdentity(id: "DEADBEEF", name: "Apple Distribution: ACME (TEAMABCDE9)")
        )
        XCTAssertEqual(details.subject, "Apple Distribution: ACME (TEAMABCDE9)")
        XCTAssertEqual(details.teamID, "TEAMABCDE9")
    }

    func testExportRejectsBlankPasswordWithoutTouchingKeychain() {
        let identity = SigningIdentity(id: "DEADBEEF", name: "Apple Development: Test (TEAM1)")
        let url = URL(fileURLWithPath: "/tmp/should-not-write.p12")
        XCTAssertThrowsError(
            try SigningService.exportDeveloperCertificate(identity: identity, to: url, password: "   ")
        ) { error in
            guard let signing = error as? SigningError else {
                return XCTFail("期望 SigningError，得到 \(error)")
            }
            guard case .emptyExportPassword = signing else {
                return XCTFail("期望 emptyExportPassword，得到 \(signing)")
            }
        }
    }

    private func presence(_ id: String, in statuses: [ProfileCapabilityStatus]) -> ProfileCapabilityPresence? {
        statuses.first { $0.id == id }?.presence
    }
}
