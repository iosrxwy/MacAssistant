import XCTest
@testable import MacAssistantKit

final class SigningServiceTests: XCTestCase {
    /// 断言里写死了中文文案,不固定语言的话在英文系统上会失败。
    override class func setUp() {
        super.setUp()
        LocalizationSettings.override = .simplifiedChinese
    }


    func testParseIdentities() {
        let output = """
        Policy: Code Signing
          Matching identities
          1) A1B2C3D4E5F6A1B2C3D4E5F6A1B2C3D4E5F6A1B2 "Apple Development: Jane Doe (TEAM12345X)"
          2) 00112233445566778899AABBCCDDEEFF00112233 "Apple Distribution: ACME (TEAMABCDE9)"
             2 valid identities found
        """
        let ids = SigningService.parseIdentities(output)
        XCTAssertEqual(ids.count, 2)
        XCTAssertEqual(ids.first?.name, "Apple Development: Jane Doe (TEAM12345X)")
        XCTAssertEqual(ids.first?.id, "A1B2C3D4E5F6A1B2C3D4E5F6A1B2C3D4E5F6A1B2")
    }

    func testParseProfile() throws {
        let future = Date().addingTimeInterval(60 * 60 * 24 * 30)
        let dict: [String: Any] = [
            "Name": "Dev Profile",
            "TeamIdentifier": ["TEAM12345X"],
            "ExpirationDate": future,
            "ProvisionedDevices": ["udid-1", "udid-2"],
            "Entitlements": [
                "application-identifier": "TEAM12345X.com.example.app",
                "get-task-allow": true
            ]
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
        let info = try SigningService.parseProfile(plistData: data)
        XCTAssertEqual(info.name, "Dev Profile")
        XCTAssertEqual(info.teamID, "TEAM12345X")
        XCTAssertEqual(info.appID, "TEAM12345X.com.example.app")
        XCTAssertEqual(info.provisionedDevices.count, 2)
        XCTAssertFalse(info.isExpired)
        XCTAssertTrue(info.entitlementsXML.contains("application-identifier"))
    }

    func testParseProfileExpired() throws {
        let past = Date().addingTimeInterval(-60)
        let dict: [String: Any] = ["ExpirationDate": past, "Entitlements": [String: Any]()]
        let data = try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
        let info = try SigningService.parseProfile(plistData: data)
        XCTAssertTrue(info.isExpired)
    }

    func testProfilePreflightRejectsExpiredTeamAndBundleMismatch() throws {
        let expired = ProfileInfo(
            name: "Expired",
            teamID: "TEAM123",
            appID: "TEAM123.com.example.*",
            expirationDate: Date(timeIntervalSince1970: 1),
            provisionedDevices: [],
            entitlementsXML: "<plist><dict/></plist>"
        )
        XCTAssertThrowsError(
            try SigningService.validateProfile(
                expired,
                identityName: "Apple Development: Tester (TEAM123)",
                bundleID: "com.example.app",
                now: Date()
            )
        )

        let valid = ProfileInfo(
            name: "Valid",
            teamID: "TEAM123",
            appID: "TEAM123.com.example.*",
            expirationDate: Date.distantFuture,
            provisionedDevices: [],
            entitlementsXML: "<plist><dict/></plist>"
        )
        XCTAssertThrowsError(
            try SigningService.validateProfile(
                valid,
                identityName: "Apple Development: Tester (OTHER999)",
                bundleID: "com.example.app"
            )
        )
        XCTAssertThrowsError(
            try SigningService.validateProfile(
                valid,
                identityName: "Apple Development: Tester (TEAM123)",
                bundleID: "org.other.app"
            )
        )
        XCTAssertNoThrow(
            try SigningService.validateProfile(
                valid,
                identityName: "Apple Development: Tester (TEAM123)",
                bundleID: "com.example.app"
            )
        )
    }

    func testEntitlementsMustBeSubsetOfProfile() throws {
        XCTAssertNoThrow(try SigningService.validateEntitlementsSubset(
            requested: ["get-task-allow": true, "aps-environment": "development"],
            allowed: ["get-task-allow": true, "aps-environment": "development", "keychain-access-groups": ["A"]]
        ))
        XCTAssertThrowsError(try SigningService.validateEntitlementsSubset(
            requested: ["com.apple.developer.healthkit": true],
            allowed: ["get-task-allow": true]
        ))
        XCTAssertThrowsError(try SigningService.validateEntitlementsSubset(
            requested: ["aps-environment": "production"],
            allowed: ["aps-environment": "development"]
        ))
    }

    func testCommandFailureCannotBeReportedAsSuccess() {
        let failure = CommandResult(exitCode: 1, stdout: "", stderr: "boom")
        XCTAssertThrowsError(try SigningService.requireSuccess(failure, step: "nested framework"))
    }

    func testDiagnose() {
        XCTAssertTrue(SigningService.diagnose("errSecInternalComponent: entitlement not allowed")
            .contains { $0.contains("entitlements") })
        XCTAssertTrue(SigningService.diagnose("bundle identifier does not match profile")
            .contains { $0.contains("bundle id") })
        XCTAssertTrue(SigningService.diagnose("The provisioning profile has expired")
            .contains { $0.contains("过期") })
    }

    func testSigningOrderInnerFirstAppLast() throws {
        let root = try FileSystemHelper.makeTemporaryDirectory(prefix: "sign-order")
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("Demo.app")
        let fw = app.appendingPathComponent("Frameworks")
        let plugins = app.appendingPathComponent("PlugIns")
        let watch = app.appendingPathComponent("Watch")
        let clips = app.appendingPathComponent("AppClips")
        try FileManager.default.createDirectory(at: fw, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: plugins, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: watch, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: clips, withIntermediateDirectories: true)
        try Data([0]).write(to: fw.appendingPathComponent("libx.dylib"))
        try FileManager.default.createDirectory(at: fw.appendingPathComponent("Foo.framework"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: plugins.appendingPathComponent("Bar.appex"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: watch.appendingPathComponent("WatchApp.app"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: clips.appendingPathComponent("Clip.app"), withIntermediateDirectories: true)

        let order = SigningService.signingOrder(app: app)
        XCTAssertEqual(order.last, app)
        XCTAssertEqual(order.count, 6)
        XCTAssertTrue(order.dropLast().contains { $0.lastPathComponent == "libx.dylib" })
        XCTAssertTrue(order.dropLast().contains { $0.lastPathComponent == "Foo.framework" })
        XCTAssertTrue(order.dropLast().contains { $0.lastPathComponent == "Bar.appex" })
        XCTAssertTrue(order.dropLast().contains { $0.lastPathComponent == "WatchApp.app" })
        XCTAssertTrue(order.dropLast().contains { $0.lastPathComponent == "Clip.app" })
    }

    func testRealDevicePreflightRejectsExtensionsWithoutProfileMap() throws {
        let root = try FileSystemHelper.makeTemporaryDirectory(prefix: "sign-extension")
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("Demo.app")
        let extensionURL = app.appendingPathComponent("PlugIns/Share.appex")
        try FileManager.default.createDirectory(at: extensionURL, withIntermediateDirectories: true)
        XCTAssertThrowsError(try SigningService.rejectUnsupportedExtensions(in: app))
    }

    func testSigningGraphRequiresProfileForEveryBundleID() throws {
        let root = try FileSystemHelper.makeTemporaryDirectory(prefix: "sign-profile-map")
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("Demo.app")
        let appex = app.appendingPathComponent("PlugIns/Share.appex")
        try FileManager.default.createDirectory(at: appex, withIntermediateDirectories: true)
        func writeInfo(_ bundle: URL, id: String) throws {
            let data = try PropertyListSerialization.data(
                fromPropertyList: ["CFBundleIdentifier": id],
                format: .xml,
                options: 0
            )
            try data.write(to: bundle.appendingPathComponent("Info.plist"))
        }
        try writeInfo(app, id: "com.example.demo")
        try writeInfo(appex, id: "com.example.demo.share")

        XCTAssertEqual(
            try SigningService.missingProfileBundleIDs(
                in: app,
                profilesByBundleID: [
                    "com.example.demo": root.appendingPathComponent("main.mobileprovision")
                ]
            ),
            ["com.example.demo.share"]
        )
        XCTAssertEqual(
            try SigningService.missingProfileBundleIDs(
                in: app,
                profilesByBundleID: [
                    "com.example.changed": root.appendingPathComponent("main.mobileprovision"),
                    "com.example.changed.share": root.appendingPathComponent("share.mobileprovision")
                ],
                overridingRootBundleID: "com.example.changed"
            ),
            []
        )
        XCTAssertEqual(
            try SigningService.missingProfileBundleIDs(
                in: app,
                profilesByBundleID: [
                    "com.example.demo": root.appendingPathComponent("main.mobileprovision")
                ],
                excludingRelativePaths: ["PlugIns"]
            ),
            []
        )
        let changed = try SigningService.rewriteBundleIDGraph(in: app, rootBundleID: "com.example.changed")
        XCTAssertEqual(
            Set(changed),
            Set([
                "com.example.demo → com.example.changed",
                "com.example.demo.share → com.example.changed.share"
            ])
        )
    }

    func testCertificateExpiryStatus() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertEqual(CertificateExpiryStatus.of(expiration: nil, now: now), .unknown)
        XCTAssertEqual(
            CertificateExpiryStatus.of(expiration: now.addingTimeInterval(-60), now: now),
            .expired
        )
        XCTAssertEqual(
            CertificateExpiryStatus.of(expiration: now.addingTimeInterval(2 * 86_400), now: now),
            .expiringSoon(daysRemaining: 2)
        )
        XCTAssertEqual(
            CertificateExpiryStatus.of(expiration: now.addingTimeInterval(30 * 86_400), now: now),
            .valid(daysRemaining: 30)
        )
        XCTAssertFalse(CertificateExpiryStatus.expired.isUsable)
        XCTAssertTrue(CertificateExpiryStatus.valid(daysRemaining: 10).isUsable)
    }

    func testCertificateLibraryIndexRoundTrip() throws {
        let previous = SigningCertificateLibrary.directoryOverride
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("cert-lib-\(UUID().uuidString)", isDirectory: true)
        SigningCertificateLibrary.directoryOverride = temp
        defer {
            SigningCertificateLibrary.directoryOverride = previous
            try? FileManager.default.removeItem(at: temp)
        }
        XCTAssertTrue(SigningCertificateLibrary.load().isEmpty)
        let entry = StoredSigningCertificate(
            identityID: "ABC",
            name: "Apple Development: Test",
            expiration: Date(timeIntervalSince1970: 1_800_000_000)
        )
        SigningCertificateLibrary.writeIndex(
            CertificateLibraryIndex(selectedID: entry.id, certificates: [entry])
        )
        let loaded = SigningCertificateLibrary.load()
        XCTAssertEqual(loaded.map(\.identityID), ["ABC"])
        XCTAssertEqual(SigningCertificateLibrary.selected()?.id, entry.id)
    }
}
