import XCTest
@testable import MacAssistantKit

final class IpaStoreServiceTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        LocalizationSettings.override = .simplifiedChinese
    }

    func testParseSearchJSON() throws {
        let apps = try IpaStoreService.parseApps(from: """
        {"level":"info","count":1,"apps":[{"id":899247664,"bundleID":"com.apple.TestFlight","name":"TestFlight","version":"3.8.0","price":0}]}
        """)
        XCTAssertEqual(apps.count, 1)
        XCTAssertEqual(apps[0].storeID, 899247664)
        XCTAssertEqual(apps[0].bundleIdentifier, "com.apple.TestFlight")
        XCTAssertEqual(apps[0].name, "TestFlight")
        XCTAssertEqual(apps[0].version, "3.8.0")
        XCTAssertEqual(apps[0].price, 0)
    }

    func testParseSearchAcceptsITunesFieldNamesAndIgnoresLogNoise() throws {
        let apps = try IpaStoreService.parseApps(from: """
        searching
        {"results":[{"trackId":1,"bundleId":"com.example.app","trackName":"Example","version":"1.0","price":1.99}]}
        """)
        XCTAssertEqual(apps.map(\.bundleIdentifier), ["com.example.app"])
        XCTAssertEqual(apps.first?.name, "Example")
        XCTAssertEqual(apps.first?.price, 1.99)
    }

    func testParseEmptySearch() throws {
        XCTAssertEqual(
            try IpaStoreService.parseApps(from: #"{"level":"info","count":0,"apps":[]}"#),
            []
        )
    }

    func testParseAccountAndVersions() throws {
        let account = try IpaStoreService.parseAccount(
            from: #"{"level":"info","name":"Jane","email":"jane@icloud.com","success":true}"#
        )
        XCTAssertEqual(account.email, "jane@icloud.com")
        XCTAssertEqual(account.summary, "Jane · jane@icloud.com")

        XCTAssertEqual(
            try IpaStoreService.parseVersionIDs(
                from: #"{"externalVersionIdentifiers":["630253062","123"],"bundleID":"com.apple.TestFlight","success":true}"#
            ),
            ["630253062", "123"]
        )
        XCTAssertEqual(
            try IpaStoreService.parseVersionIDs(from: #"{"externalVersionIdentifiers":[630253062,123]}"#),
            ["630253062", "123"]
        )

        let version = try IpaStoreService.parseVersionMetadata(
            from: #"{"externalVersionID":"630253062","displayVersion":"0.8.0","releaseDate":"2014-07-23T19:48:08Z","success":true}"#
        )
        XCTAssertEqual(version.displayVersion, "0.8.0")
        XCTAssertTrue(version.summary.contains("0.8.0"))
    }

    func testParseDownloadAndTwoFactor() throws {
        let download = try IpaStoreService.parseDownload(
            from: #"{"output":"/tmp/com.apple.TestFlight.ipa","purchased":false,"success":true}"#
        )
        XCTAssertEqual(download.url.path, "/tmp/com.apple.TestFlight.ipa")
        XCTAssertFalse(download.purchased)

        XCTAssertTrue(IpaStoreService.requiresTwoFactor(
            "2FA code is required; run the command again and supply a code using the `--auth-code` flag"
        ))
        XCTAssertFalse(IpaStoreService.requiresTwoFactor(#"{"success":true,"email":"a@b.c"}"#))
    }

    func testInvalidJSONIsRejected() {
        XCTAssertThrowsError(try IpaStoreService.parseApps(from: "not-json"))
    }

    func testKeyringMissIsNotLoggedIn() {
        XCTAssertThrowsError(
            try IpaStoreService.parseAccount(from: """
            {"level":"error","error":"failed to get account: failed to get item: The specified item could not be found in the keyring","success":false}
            """)
        ) { error in
            guard let store = error as? IpaStoreError else {
                return XCTFail("unexpected \(error)")
            }
            if case .notLoggedIn = store { return }
            XCTFail("expected notLoggedIn, got \(store)")
        }
    }

    func testLiveIpatoolWithoutLoginReportsNotLoggedIn() throws {
        guard ExternalTool.ipatool.isAvailable else {
            throw XCTSkip("本机未安装 ipatool")
        }
        XCTAssertNil(IpaStoreService.currentAccount())
        XCTAssertThrowsError(try IpaStoreService.accountInfo()) { error in
            guard let store = error as? IpaStoreError else {
                return XCTFail("unexpected \(error)")
            }
            if case .notLoggedIn = store { return }
            XCTFail("expected notLoggedIn, got \(store)")
        }
    }
}
