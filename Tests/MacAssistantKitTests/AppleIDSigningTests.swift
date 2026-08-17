import XCTest
@testable import MacAssistantKit

final class AppleIDSigningTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        LocalizationSettings.override = .simplifiedChinese
    }

    func testParseIdeviceIDListIgnoresNoise() {
        let output = """
        00008030-001A2B3C4D5E6F70
        ERROR: skip me
        40hexcharactersudid00008030001A2B3C4D

        """
        let ids = ConnectedDeviceService.parseIdeviceIDList(output)
        XCTAssertTrue(ids.contains("00008030-001A2B3C4D5E6F70"))
        XCTAssertEqual(ids.count, 2)
    }

    func testParseXCTraceLineReadsPhoneAndSkipsMac() {
        let phone = ConnectedDeviceService.parseXCTraceLine(
            "君临的 iPhone (18.5) (00008030-001A2B3C4D5E6F70)"
        )
        XCTAssertEqual(phone?.name, "君临的 iPhone")
        XCTAssertEqual(phone?.osVersion, "18.5")
        XCTAssertEqual(phone?.udid, "00008030-001A2B3C4D5E6F70")
        XCTAssertTrue(ConnectedDeviceService.isInstallablePhone(phone!))

        let mac = ConnectedDeviceService.parseXCTraceLine(
            "君临的MacBook Pro (4F6E589E-6826-565D-8E98-D4B9D81FB9B7)"
        )
        XCTAssertNotNil(mac)
        XCTAssertFalse(ConnectedDeviceService.isInstallablePhone(mac!))

        let simulator = ConnectedDeviceService.parseXCTraceLine(
            "iPhone 16 Simulator (18.0) (AABBCCDD-1111-2222-3333-444455556666)"
        )
        XCTAssertNotNil(simulator)
        XCTAssertFalse(ConnectedDeviceService.isInstallablePhone(simulator!))
    }

    func testParseXCTraceDevicesSection() {
        let output = """
        == Simulators ==
        iPhone 16 Simulator (18.0) (AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE)
        == Devices ==
        Demo iPhone (18.5) (00008030-001A2B3C4D5E6F70)
        君临的MacBook Pro (4F6E589E-6826-565D-8E98-D4B9D81FB9B7)
        """
        let devices = ConnectedDeviceService.parseXCTraceDevices(output)
            .filter(ConnectedDeviceService.isInstallablePhone)
        XCTAssertEqual(devices.map(\.udid), ["00008030-001A2B3C4D5E6F70"])
    }

    func testParseDeviceCtlJSON() throws {
        let json = """
        {
          "result": {
            "devices": [
              {
                "identifier": "core-1",
                "deviceProperties": { "name": "Demo iPhone" },
                "hardwareProperties": {
                  "udid": "00008030-001A2B3C4D5E6F70",
                  "platform": "iOS",
                  "marketingName": "iPhone 15",
                  "osVersionNumber": "18.5"
                },
                "connectionProperties": { "transportType": "wired" }
              },
              {
                "identifier": "mac-1",
                "deviceProperties": { "name": "MacBook Pro" },
                "hardwareProperties": {
                  "udid": "4F6E589E-6826-565D-8E98-D4B9D81FB9B7",
                  "platform": "macOS"
                }
              }
            ]
          }
        }
        """.data(using: .utf8)!
        let devices = try ConnectedDeviceService.parseDeviceCtlJSON(json)
            .filter(ConnectedDeviceService.isInstallablePhone)
        XCTAssertEqual(devices.count, 1)
        XCTAssertEqual(devices[0].name, "Demo iPhone")
        XCTAssertEqual(devices[0].coreDeviceIdentifier, "core-1")
        XCTAssertEqual(devices[0].transport, .usb)
    }

    func testUDIDValidation() {
        XCTAssertTrue(ConnectedDeviceService.isLikelyUDID("00008030-001A2B3C4D5E6F70"))
        XCTAssertTrue(ConnectedDeviceService.isLikelyUDID(String(repeating: "A", count: 40)))
        XCTAssertFalse(ConnectedDeviceService.isLikelyUDID("not-a-udid"))
        XCTAssertFalse(ConnectedDeviceService.isLikelyUDID("123"))
    }

    func testRenewalJobDueWindow() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let due = AppleIDRenewalJob(
            appleID: "a@b.com",
            displayName: "Demo",
            bundleID: "com.demo",
            deviceUDID: "UDID",
            deviceName: "iPhone",
            ipaPath: "/tmp/a.ipa",
            expiresAt: now.addingTimeInterval(12 * 60 * 60)
        )
        XCTAssertTrue(due.isDue(now: now))
        XCTAssertFalse(due.isDue(now: now, lead: 60 * 60))
        XCTAssertEqual(due.remaining(now: now), 12 * 60 * 60, accuracy: 1)

        let fresh = AppleIDRenewalJob(
            appleID: "a@b.com",
            displayName: "Demo",
            bundleID: "com.demo",
            deviceUDID: "UDID",
            deviceName: "iPhone",
            ipaPath: "/tmp/a.ipa",
            expiresAt: now.addingTimeInterval(AppleDeveloperServices.freeProfileLifetime)
        )
        XCTAssertFalse(fresh.isDue(now: now))
        XCTAssertEqual(AppleDeveloperServices.freeProfileLifetime, 7 * 24 * 60 * 60)
    }

    func testTeamPrefixedBundleIDIsStableAndTeamScoped() {
        let first = AppleDeveloperServices.teamPrefixedBundleID(original: "com.example.app", teamID: "TEAM123")
        let second = AppleDeveloperServices.teamPrefixedBundleID(original: "com.example.app", teamID: "TEAM123")
        XCTAssertEqual(first, second)
        XCTAssertTrue(first.hasPrefix("i.team123."))
        XCTAssertNotEqual(
            first,
            AppleDeveloperServices.teamPrefixedBundleID(original: "com.other.app", teamID: "TEAM123")
        )
    }

    func testAppIDNameStripsPunctuation() {
        XCTAssertEqual(AppleDeveloperServices.appIDName(from: "com.example.app"), "com example app")
        XCTAssertFalse(AppleDeveloperServices.appIDName(from: "com.foo_bar!").contains("!"))
    }

    func testSRPPasswordKeyAndPadding() {
        let passwordKey = AppleDeveloperServices.SRP.derivePasswordKey(
            password: "secret",
            salt: Data("salt".utf8),
            iterations: 1,
            protocolName: "s2k"
        )
        XCTAssertEqual(passwordKey.count, 32)
        let padded = AppleDeveloperServices.SRP.pad(BigUInt(1))
        XCTAssertEqual(padded.count, (AppleDeveloperServices.SRP.N.bitWidth + 7) / 8)
        XCTAssertEqual(padded.last, 1)
        let fo = AppleDeveloperServices.SRP.derivePasswordKey(
            password: "ab",
            salt: Data("salt".utf8),
            iterations: 1,
            protocolName: "s2k_fo"
        )
        XCTAssertEqual(fo.count, 32)
        XCTAssertNotEqual(passwordKey, fo)
    }

    func testEntitlementsPolicyExistsForAppleID() {
        XCTAssertEqual(SigningEntitlementsPolicy.replaceWithProfile.rawValue, "replaceWithProfile")
        XCTAssertNotEqual(
            SigningEntitlementsPolicy.replaceWithProfile,
            SigningEntitlementsPolicy.requireAppSubsetOfProfile
        )
    }

    func testParseTeamsDevicesCertificatesAppIDsAndGroups() {
        let teams = DeveloperPortalParser.teams(from: [
            "teams": [
                ["teamId": "TEAM1", "name": "Personal"],
                ["teamID": "TEAM2", "name": "Work"]
            ]
        ])
        XCTAssertEqual(teams.map(\.id), ["TEAM1", "TEAM2"])

        let devices = DeveloperPortalParser.devices(from: [
            "devices": [
                ["deviceId": "d1", "name": "Phone", "deviceNumber": "00008030-001A2B3C4D5E6F70"],
                ["name": "NoUDID"]
            ]
        ])
        XCTAssertEqual(devices.count, 1)
        XCTAssertEqual(devices[0].udid, "00008030-001A2B3C4D5E6F70")

        let certs = DeveloperPortalParser.certificates(from: [
            "certificates": [
                ["certificateId": "C1", "name": "Apple Development: A", "certContent": Data("cer".utf8)]
            ]
        ])
        XCTAssertEqual(certs.map(\.id), ["C1"])

        let appIDs = DeveloperPortalParser.appIDs(from: [
            "appIds": [
                ["appIdId": "A1", "identifier": "com.demo.app", "name": "Demo"]
            ]
        ])
        XCTAssertEqual(appIDs[0].identifier, "com.demo.app")

        let groups = DeveloperPortalParser.appGroups(from: [
            "applicationGroupList": [
                ["applicationGroupId": "G1", "identifier": "group.com.demo", "name": "Demo Group"]
            ]
        ])
        XCTAssertEqual(groups[0].identifier, "group.com.demo")

        let profile = DeveloperPortalParser.encodedProfile(from: [
            "provisioningProfile": ["encodedProfile": Data("mobileprovision".utf8)]
        ])
        XCTAssertEqual(profile, Data("mobileprovision".utf8))
    }

    func testCertificateReuseWhenStoredIsStillOnPortal() {
        let stored = StoredDevelopmentCertificate(
            teamID: "TEAM",
            certificateID: "C1",
            name: "Dev",
            expiration: Date().addingTimeInterval(86_400),
            keyPath: "/tmp/key.pem",
            certPath: "/tmp/dev.cer"
        )
        let remote = [
            AppleDeveloperServices.RemoteCertificate(id: "C1", name: "Dev", expiration: Date().addingTimeInterval(86_400), content: Data("x".utf8))
        ]
        XCTAssertEqual(
            CertificateReusePlanner.decide(stored: stored, remote: remote),
            .reuseStored
        )
    }

    func testCertificateReuseRequestsNewWhenSlotsRemain() {
        XCTAssertEqual(
            CertificateReusePlanner.decide(stored: nil, remote: [
                AppleDeveloperServices.RemoteCertificate(id: "C1", name: "Old")
            ]),
            .requestNew
        )
    }

    func testCertificateReuseRevokesWhenFreeSlotIsFull() {
        let remote = [
            AppleDeveloperServices.RemoteCertificate(id: "C1", name: "A"),
            AppleDeveloperServices.RemoteCertificate(id: "C2", name: "B")
        ]
        XCTAssertEqual(
            CertificateReusePlanner.decide(stored: nil, remote: remote),
            .revokeThenRequest(ids: ["C1", "C2"])
        )
    }

    func testCertificateReuseDoesNotReuseMissingRemoteCert() {
        let stored = StoredDevelopmentCertificate(
            teamID: "TEAM",
            certificateID: "GONE",
            name: "Dev",
            expiration: Date().addingTimeInterval(86_400),
            keyPath: "/tmp/key.pem",
            certPath: "/tmp/dev.cer"
        )
        let remote = [
            AppleDeveloperServices.RemoteCertificate(id: "C1", name: "Other")
        ]
        XCTAssertEqual(
            CertificateReusePlanner.decide(stored: stored, remote: remote),
            .requestNew
        )
    }

    func testLoginTokenSelectsTeamAndDecodesLegacySessions() throws {
        let token = AppleDeveloperServices.LoginToken(
            appleID: "a@b.com",
            adsid: "ads",
            token: "tok",
            expiry: Date().addingTimeInterval(3600),
            teamID: "T1",
            teamName: "First",
            teams: [
                .init(id: "T1", name: "First"),
                .init(id: "T2", name: "Second")
            ]
        )
        let selected = token.selecting(.init(id: "T2", name: "Second"))
        XCTAssertEqual(selected.teamID, "T2")
        XCTAssertEqual(selected.teamName, "Second")
        XCTAssertEqual(selected.teams.count, 2)

        let legacy = """
        {"appleID":"a@b.com","adsid":"ads","token":"tok","expiry":0,"teamID":"OLD","teamName":"Legacy"}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(AppleDeveloperServices.LoginToken.self, from: legacy)
        XCTAssertEqual(decoded.teams.map(\.id), ["OLD"])
    }

    func testAppleIDSigningRecipeCompleteness() {
        var recipe = AppleIDSigningRecipe(appleID: "a@b.com")
        XCTAssertTrue(recipe.isPartial)
        XCTAssertFalse(recipe.isComplete)
        recipe.teamID = "TEAM"
        recipe.deviceUDID = "00008030-001A2B3C4D5E6F70"
        XCTAssertTrue(recipe.isComplete)
        XCTAssertEqual(recipe.device.udid, "00008030-001A2B3C4D5E6F70")
    }

    func testInjectionSigningModeAppleIDRoundTrip() throws {
        let recipe = AppleIDSigningRecipe(
            appleID: "a@b.com",
            teamID: "TEAM",
            teamName: "Personal",
            deviceUDID: "00008030-001A2B3C4D5E6F70",
            deviceName: "iPhone",
            rewriteBundleIDOnConflict: false
        )
        let encoded = try JSONEncoder().encode(InjectionSigningMode.appleID(recipe))
        let decoded = try JSONDecoder().decode(InjectionSigningMode.self, from: encoded)
        XCTAssertEqual(decoded, .appleID(recipe))
    }
}
